package com.phonetool.phone_ai_assistant

import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel

/**
 * 系统里正在播放的那个媒体会话，以及往 Dart 推事件的那根管子。
 *
 * ## 为什么需要这么一个静态单例
 *
 * 数据来自 [MusicListenerService]，它是个**系统绑定的服务**——系统会在任何时候
 * 把它拉起来，包括 App 主进程刚被杀、用户正在别的 App 里听歌的时候。而它自己
 * 拿不到 Flutter 引擎（引擎归 FlutterActivity 管）。所以中间必须有个不依赖
 * 任何一方存活的地方来放状态。
 *
 * 这和 [ShareIntentChannel] 面对的是同一个问题，解法也照抄它：
 * **存一份等人来取，同时管子通的时候顺手推一次。** 两条路都留着——「推了但
 * Dart 没收到」在真机上偶发，查起来极贵，宁可多一次空取。
 *
 * ## 实测踩到的坑：元数据会凭空消失
 *
 * 2026-09-27 在真机（PKT110 / Android 16 / ColorOS）上实测：网易云**停止播放
 * 之后会把 metadata 清空**——同一个会话，播放中 `metadata: size=12`，
 * `dispatch pause` 之后过一会儿变成 `size=0`、`position=0`，但**进程和会话都
 * 还在**（pid 16362 一直在）。
 *
 * 所以这里绝不能拿「刚读到的 metadata 是空的」当成「没在放歌」——那会让界面在
 * 用户暂停一会儿之后突然变空白，而这看起来就像个 bug。
 *
 * 对策是 [lastTrack] 记住最后一次**非空**的曲目信息；会话还在、元数据却空了
 * 的时候拿它兜底，并在回包里把 [KEY_STALE] 标成 true，让上层能自己决定怎么
 * 表现（比如进度条变灰、加一句「已暂停」）。
 *
 * ## 不推「进度」
 *
 * 播放位置每几百毫秒就变一次，全推过去等于拿事件刷屏。这里只在**曲目变了**和
 * **播放状态变了**的时候推；进度由 Dart 侧按 `positionMs` + 时间差自己外推，
 * 第二期界面上那个进度条就是这么走的。
 */
object MusicBridge {

    /** 曲目信息是上一次缓存来的（当前这次读到的是空的）。见类注释。 */
    const val KEY_STALE = "stale"

    /** 攒的事件上限。超过就丢最旧的——推到这份上说明 Dart 那边一直没起来。 */
    private const val MAX_PENDING = 50

    private val main = Handler(Looper.getMainLooper())

    /** 管子。null = Dart 还没起来，或者 Activity 已经销毁。 */
    private var channel: MethodChannel? = null

    /** 最后一次推出去（或攒下来）的完整状态。null = 从来没见过任何会话。 */
    private var current: MutableMap<String, Any?>? = null

    /** 管子不通时攒着的事件，管子通了倒给 Dart。 */
    private val pending = mutableListOf<Map<String, Any?>>()

    /** 最后一次**非空**的曲目信息。见类注释里那个坑。 */
    private var lastTrack: Map<String, Any?>? = null

    /**
     * 当前选中的那个 controller。
     *
     * 第一期只用它读快照；第二期的播放控制（[control]）就是拿它发
     * `transportControls`。null = 现在没有任何可用的媒体会话。
     */
    var activeController: MediaController? = null
        private set

    fun attach(channel: MethodChannel) {
        this.channel = channel
    }

    fun detach() {
        channel = null
    }

    /**
     * 当前状态快照。Dart 起来之后先要一份，不然要等下一次事件才有东西显示。
     *
     * ⚠️ 有活着的 controller 时**必须现场重算**，不能把 [current] 原样还回去。
     * 真机上踩到过：`current` 里那个 `positionMs` 是**上一次事件发生时**算的，
     * 而事件只在换歌/状态变化时才发——网易云一首歌中间能十几分钟不发一次。
     * 直接还回去的症状是「明明放到 1 分半了，界面写着 0:00」，而且看着像界面
     * 写错了，其实是这里端了一份陈的。
     *
     * [positionOf] 的外推本来就假设「读的那一刻」是现在，所以重算才是它的正确
     * 用法；只算不读等于把外推白算了。
     */
    fun snapshot(): Map<String, Any?>? {
        val c = activeController ?: return current
        val fresh = snap(c)
        // 顺手把缓存也刷新掉：这期间元数据可能刚被清空，正好在这儿把 lastTrack
        // 定住。**不发事件**——Dart 是主动来要的，再推一次就成了同一条报两遍。
        current = fresh
        return fresh
    }

    /**
     * 发一个播放控制出去。
     *
     * 返回的是一份**永远不抛**的 map：要么 `success=true`，要么 `success=false`
     * 加一句 `error`。不用异常是因为「现在没在放歌」对上层是**正常情况**而不是
     * 故障——模型要的是一句能读懂的话，好让它换个说法回用户，而不是一个平台
     * 异常（那玩意儿传到 Dart 就只剩一个 code 字符串了）。
     *
     * ## 为什么不在这里等结果
     *
     * `TransportControls` 全是**单向**的：发出去就没有回执。真实状态只能等
     * 播放器重新发布 `PlaybackState`——而网易云实测只在**曲目边界**发布，
     * 按了暂停它可能一句话都不说。所以这里发完就返回，**另外隔一拍主动去读
     * 一次**（见下面的 postDelayed）。Dart 那边也会先按「我们要求它做的事」
     * 把界面改掉，两边合起来才不会出现「按了按钮界面不动」。
     */
    fun control(action: String, positionMs: Long?): Map<String, Any?> {
        val c = activeController ?: return controlError(
            "现在没读到任何播放器。用户可能没在听歌。"
        )
        return try {
            when (action) {
                "play" -> c.transportControls.play()
                "pause" -> c.transportControls.pause()
                // 一下按钮，两种结果。判据取播放器自己报的状态（和 Dart 那边
                // 看到的同一个值），不另存一份「我以为在放」。
                "play_pause" ->
                    if (c.playbackState?.state == PlaybackState.STATE_PLAYING) {
                        c.transportControls.pause()
                    } else {
                        c.transportControls.play()
                    }
                "next" -> c.transportControls.skipToNext()
                "previous" -> c.transportControls.skipToPrevious()
                "seek" -> {
                    if (positionMs == null) return controlError("seek 要带 positionMs。")
                    if (positionMs < 0) return controlError("positionMs 不能是负数。")
                    // ⚠️ 用 seekTo，**不要**用 fastForward()：网易云的 actions 里
                    // 只有 SEEK_TO(256)，没有 FAST_FORWARD(64)（实测 actions=822），
                    // 调后者它不认。而且 fastForward 在 API 33 已经废弃了。
                    c.transportControls.seekTo(positionMs)
                }
                else -> return controlError(
                    "认不出这个动作「$action」。可用的是 " +
                        "play / pause / play_pause / next / previous / seek。"
                )
            }

            // 追一次真实状态。**加 activeController 的同一性判断**：这 500ms 里
            // 用户可能切去了别的播放器，那时候 refresh(c) 会把已经过期的 c 重新
            // 设成「当前会话」，界面就会跳回上一首。
            main.postDelayed({ if (activeController === c) refresh(c) }, 500)

            mapOf("success" to true, "action" to action, "package" to c.packageName)
        } catch (e: Exception) {
            controlError("发给「${c.packageName}」时出错：${e.message}")
        }
    }

    private fun controlError(msg: String) = mapOf("success" to false, "error" to msg)

    /** 取走攒下的事件（取走即清，和 ShareIntentChannel 的 take 一个语义）。 */
    fun takeEvents(): List<Map<String, Any?>> {
        val out = pending.toList()
        pending.clear()
        return out
    }

    /**
     * 会话列表变了 / 元数据变了 / 播放状态变了 / 会话没了——统统走这里。
     *
     * [controller] 传 null 表示「当前没有可用会话」。
     */
    fun refresh(controller: MediaController?) {
        if (controller == null) {
            activeController = null
            // 会话真没了。把 current 置空，但**不动 lastTrack**——下次会话回来时
            // 还得靠它判断「是不是同一首」。
            val had = current
            current = null
            if (had != null) {
                emit(
                    mutableMapOf(
                        "type" to "gone",
                        "at" to System.currentTimeMillis(),
                    ),
                )
            }
            return
        }

        activeController = controller
        val snapped = snap(controller)

        val prev = current
        current = snapped

        // 只在「曲目变了」或「播放状态变了」的时候推。进度不推，见类注释。
        //
        // 注意比的是 [snap] 现算出来的值，而 `prev` 可能是 [snapshot] 刷新过的
        // ——两边都只关心 package/title/artist/state，跟 position 无关，所以
        // 中间被刷新过也不会漏判。
        val trackChanged = prev == null ||
            prev["package"] != snapped["package"] ||
            prev["title"] != snapped["title"] ||
            prev["artist"] != snapped["artist"]
        val stateChanged = prev == null || prev["state"] != snapped["state"]
        if (!trackChanged && !stateChanged) return

        val event = snapped.toMutableMap()
        event["type"] = if (trackChanged) "track" else "state"
        emit(event)
    }

    /**
     * 把 [c] 此刻的样子读成一份快照。**唯一的读点**——[refresh] 和 [snapshot]
     * 都走这里，免得两处各写一份、以后加字段时只改一处。
     *
     * 会顺手更新 [lastTrack]（那是缓存，读的时候顺手刷新是对的），但**不改
     * [current]、不发事件**——那是调用方的事。
     */
    private fun snap(c: MediaController): MutableMap<String, Any?> {
        val pkg = c.packageName.orEmpty()

        val fresh = c.metadata?.let { readTrack(it, pkg) }
        if (fresh != null) lastTrack = fresh

        // 读不到就退回上次那首，并打上 stale 标记。
        val track = fresh ?: lastTrack
        val stale = fresh == null && lastTrack != null

        val ps = c.playbackState
        return mutableMapOf(
            "package" to pkg,
            "title" to track?.get("title"),
            "artist" to track?.get("artist"),
            "album" to track?.get("album"),
            "durationMs" to track?.get("durationMs"),
            KEY_STALE to stale,
            "state" to stateName(ps?.state),
            "positionMs" to positionOf(ps),
            "actions" to (ps?.actions ?: 0L),
            "at" to System.currentTimeMillis(),
        )
    }

    private fun emit(event: Map<String, Any?>) {
        val ch = channel
        if (ch == null) {
            // Dart 不在（引擎没起来 / Activity 没了）。攒着，等它来 take。
            pending.add(event)
            while (pending.size > MAX_PENDING) pending.removeAt(0)
            return
        }
        // MethodChannel 必须在主线程调。MediaController 的回调默认也在主线程，
        // 但 post 一下不亏——在别的线程调 invokeMethod 会直接崩。
        main.post { ch.invokeMethod("onMusicEvent", event) }
    }

    /**
     * 从 metadata 里抠出这一首的信息。全空返回 null。
     *
     * 返回 null 的语义是「这条 metadata 是**被清空**的」，不是「一首没名字的歌」。
     * 网易云清空之后 `size=0`，所以两个 key 都读不到。
     *
     * ARTIST 之外还兜底 ALBUM_ARTIST / DISPLAY_SUBTITLE：各家音乐 App 字段
     * 填得不一致，实测网易云给的是 ARTIST，但不能假定别的 App 也给。
     */
    private fun readTrack(md: MediaMetadata, pkg: String): Map<String, Any?>? {
        val title = md.getString(MediaMetadata.METADATA_KEY_TITLE)
            ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)
        val artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: md.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
            ?: md.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
        if (title.isNullOrBlank() && artist.isNullOrBlank()) return null

        val duration = md.getLong(MediaMetadata.METADATA_KEY_DURATION)
        return mapOf(
            "package" to pkg,
            "title" to title,
            "artist" to artist,
            "album" to md.getString(MediaMetadata.METADATA_KEY_ALBUM),
            // 有些 App 不报时长，给 0 的话上层会算出「听了 0%」，不如给 null 让它
            // 知道「这个数没有」，而不是「这个数是零」。
            "durationMs" to (if (duration > 0) duration else null),
        )
    }

    /**
     * 当前播放位置——**必须自己外推，不能直接读 `ps.position`**。
     *
     * `PlaybackState.getPosition()` 返回的是**上一次状态更新时**的位置，不是一个
     * 会自己走的活值。播放器只在 play/pause/seek 这些时刻更新 PlaybackState，
     * 中间几秒到几十秒不更新（网易云实测：一首 4 分钟的歌，两次更新之间能隔
     * 十几秒）。直接读的话，界面上那个进度条会一顿一顿地跳甚至卡住不动。
     *
     * 正确算法是「上次更新时的位置 + 从那之后流逝的真实时间 × 播放速度」。
     *
     * ⚠️ `getLastPositionUpdateTime()` 用的是 `SystemClock.elapsedRealtime()`
     * （开机以来的毫秒数），**不是** `currentTimeMillis()`（1970 年以来的）。
     * 用错会得到一个负数或者大得离谱的数——减去一个 1.7 万亿量级的墙钟值，
     * 结果是满屏乱跳。这两个时钟在真机上差着一整天的量级，很好认。
     */
    private fun positionOf(ps: PlaybackState?): Long {
        if (ps == null) return 0L
        val base = ps.position
        if (ps.state != PlaybackState.STATE_PLAYING) return base
        val elapsed = SystemClock.elapsedRealtime() - ps.lastPositionUpdateTime
        if (elapsed <= 0) return base
        // playbackSpeed 正常是 1.0，但倍速播放时会是 1.5/2.0，不乘的话会越算越偏。
        val advanced = (elapsed * ps.playbackSpeed).toLong()
        val duration = activeController?.metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        val pos = base + advanced
        // 别越过歌尾——外推过头会让进度条冲到头再弹回来。
        return if (duration > 0 && pos > duration) duration else pos
    }

    private fun stateName(state: Int?): String = when (state) {
        PlaybackState.STATE_PLAYING -> "playing"
        PlaybackState.STATE_PAUSED -> "paused"
        PlaybackState.STATE_BUFFERING -> "buffering"
        PlaybackState.STATE_STOPPED -> "stopped"
        PlaybackState.STATE_FAST_FORWARDING -> "fast_forwarding"
        PlaybackState.STATE_REWINDING -> "rewinding"
        PlaybackState.STATE_SKIPPING_TO_NEXT -> "skipping_next"
        PlaybackState.STATE_SKIPPING_TO_PREVIOUS -> "skipping_previous"
        PlaybackState.STATE_ERROR -> "error"
        PlaybackState.STATE_NONE -> "none"
        else -> "unknown"
    }
}
