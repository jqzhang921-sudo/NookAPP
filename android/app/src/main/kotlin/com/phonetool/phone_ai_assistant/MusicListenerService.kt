package com.phonetool.phone_ai_assistant

import android.app.Notification
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Bundle
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.util.Log

/**
 * 「一起听歌」的眼睛：读系统里正在播放的媒体会话。
 *
 * ## 为什么非得是通知监听
 *
 * 第三方 App 直接调 [MediaSessionManager.getActiveSessions] 会抛
 * `SecurityException`——`MEDIA_CONTENT_CONTROL` 是签名级权限，只发给系统应用。
 * 官方给第三方留的唯一口子就是这条路：自己是个**已被用户启用**的通知监听器，
 * 然后拿**自己的 ComponentName** 去调 getActiveSessions()。
 *
 * 所以这个类本身不干别的，它的存在**就是那张门票**——能调那个 API 的资格来自
 * 「用户在这个服务上勾了通知使用权」，而不是来自这个类里写了什么。
 *
 * ## 生命周期不是我们控制的
 *
 * 这是系统绑定的服务：用户开了授权之后，**系统想什么时候拉起来就什么时候拉**，
 * 包括 App 主进程刚被杀、用户正在别的 App 里听歌的时候。反过来系统也会解绑它
 * （省电、内存紧张、用户手动关）。所以：
 *
 * - 状态不能放这里，得放 [MusicBridge] 那个不依赖任何一方存活的单例里
 * - `onListenerDisconnected` 里主动要一次重绑——ColorOS 杀了后台不会自己重绑，
 *   症状是「用了几天之后突然就读不到了」，而用户完全不知道为什么
 *
 * ## 这一版只打日志
 *
 * 方案第一期第 2 步就是「先只往 logcat 打」，用真机确认网易云的会话和元数据
 * 到底收不收得到。这是整个功能里唯一一个「文档说可以、真机可能不行」的地方
 * （ColorOS 改过什么没人知道），所以**先用 logcat 证明它成立，再往上搭东西**。
 * 下面那些 Log 不是调试残留，是这一步的验收手段。
 */
class MusicListenerService : NotificationListenerService() {

    companion object {
        private const val TAG = "MusicSession"

        /**
         * 从通知里读到的歌名缓存多久（毫秒）。**别删**，见 [noticeFor]。
         *
         * 取 250ms 的依据：风暴里回调间隔约 3ms，250ms 能把 ~80 次塌成 1 次；
         * 而换歌时仍然读得到新歌，因为**两首歌之间本来就隔着比这长得多的时间**
         * （真机实测 2.7 秒），进新歌时缓存早凉了。最坏情况是自动连播时晚
         * 250ms 认出换歌——不影响任何事。
         */
        private const val NOTICE_TTL_MS = 250L

        /**
         * 自己这一份 ComponentName。`getActiveSessions` 要它。
         *
         * 有些资料说 API 33+ 这个参数被忽略了——忽略也无所谓，传自己永远是对的。
         */
        fun component(ctx: Context) = ComponentName(ctx, MusicListenerService::class.java)

        /**
         * 系统现在绑着我们这一份没有。
         *
         * 是 `companion` 上的静态字段而不是服务实例上的：`companion` 跟着类走，
         * 类跟着进程走——**没有实例的时候它也一样能读**，而「没有实例」正是
         * [ensureBound] 要分辨的那个状态。
         */
        @Volatile
        private var connected = false

        /**
         * 「通知使用权开着，可我们这份服务根本没被绑上」——把系统求回来。
         *
         * ## 为什么光有 [onListenerDisconnected] 那个 requestRebind 不够
         *
         * 那一条只在**服务已经被绑起来过、然后被解绑**时才有机会跑。而用户
         * 手上最常见的操作是**强停**（ColorOS 上从最近任务划掉就是强停，装完
         * 新包 adb 也会停一次），强停是把整个进程连同服务一起抹掉——服务从来
         * 没启动过，[onListenerDisconnected] 也就永远等不到。留下的状态是：
         * 授权还在（系统设置里那个开关还是开的），进程也活得好好的（用户刚把
         * App 打开），**但没有任何人会去重绑它**。用户看到的是「音乐功能莫名其妙
         * 就坏了」，而设置里一切正常——2026-09-27 实测就是这么一副样子：
         * `dumpsys activity services` 里只有 geolocator，没有我们这一份。
         *
         * 所以补的这条路是：**进程活着的时候自己发现「该绑没绑」，主动求一次**。
         * 调用点在 [MusicChannel] 的 `ensureBound`，而 Dart 那边每次
         * `MusicService.start()`（冷启动 + 每次回前台）都会走一趟。
         *
         * @return 真的求了一次就是 true。已经绑着的话返回 false——**情况不同，
         *   调用方不该把两者混着看**。
         */
        fun ensureBound(ctx: Context): Boolean {
            if (connected) return false
            Log.i(TAG, "服务没被绑上（多半是被强停过），想法子把它弄回来")
            val c = component(ctx)

            // 第一条：官方那条路。
            try {
                requestRebind(c)
            } catch (e: Exception) {
                Log.w(TAG, "requestRebind 没成功", e)
            }

            // 第二条：把组件禁用再启用一次。
            //
            // ⚠️ 2026-09-27 实测：**光靠第一条在这台机器上是没用的**。调完
            // `requestRebind` 之后 `dumpsys activity services` 里那条 ServiceRecord
            // 还在，但 `app=null`——一直没被绑上，`onListenerConnected` 也始终
            // 不来，界面就是「音乐功能莫名其妙坏了」的样子。
            //
            // 而 `cmd notification disallow_listener && allow_listener` 一跑就活
            // （logcat 里立刻出现「✅ onListenerConnected / 初次拉取：1 个会话」）。
            // 那个命令做的是**把监听器从系统的已批准列表里摘掉再挂上**，也就是一次
            // 真正的重新注册；`requestRebind` 只是把状态标成 UNBOUND，系统并不一定
            // 真去 bind。改组件的启用状态会让 PackageManager 发一条包变更，
            // NMS 顺着它重新过一遍监听器——这是应用**自己够得着**的那一手。
            //
            // 代价是这一下会顺带波及这个组件自己；`DONT_KILL_APP` 保证进程不被
            // 重启（重启的话我们刚做的这些就白做了）。
            try {
                val pm = ctx.packageManager
                pm.setComponentEnabledSetting(
                    c,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
                pm.setComponentEnabledSetting(
                    c,
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP,
                )
            } catch (e: Exception) {
                Log.w(TAG, "改组件启用状态也没成功", e)
            }
            return true
        }
    }

    private var manager: MediaSessionManager? = null

    /**
     * 交给 [MusicBridge] 的那个读通知的钩子。
     *
     * 存成字段而不是每次现造一个 lambda，是为了**摘的时候能认出是不是自己**——
     * 系统重绑的瞬间可能新旧两个实例同时在，旧的 `onDestroy` 要是无脑把
     * `noticeFor` 清掉，刚装上的那一个就白装了，症状是「歌名又变回滚动歌词」，
     * 而这种情况没有任何日志会指向这里。
     */
    private val noticeHook: (String) -> NoticeTrack? = { pkg -> noticeFor(pkg) }

    /**
     * 读到的通知按包名缓存，见 [NOTICE_TTL_MS]。
     *
     * 存 [CachedNotice] 而不是直接存 [NoticeTrack]——**得能区分「没读过」和
     * 「读过，但当时读不到」**。后者也要缓存：通知读不到的那段时间里，
     * 每次回调都还会各打一次 binder 白跑。
     *
     * 只在主线程碰（会话回调、MethodChannel 处理都在主线程），所以不用并发容器。
     * 键是包名，撑死几个音乐 App，不用淘汰。
     */
    private val noticeCache = HashMap<String, CachedNotice>()

    /** [noticeCache] 的值。[track] 可以是 null——那是「读过但没有」的意思。 */
    private class CachedNotice(val at: Long, val track: NoticeTrack?)

    /** 当前挂上回调的会话，**保持顺序**——getActiveSessions 是按优先级排的。 */
    private var bound = listOf<MediaController>()

    /**
     * sessionToken → 挂在它上面的回调，解绑时要用来 unregister。
     *
     * ⚠️ 键用的是 **token 而不是 `MediaController` 对象本身**。
     * `MediaController` 没有重写 `equals`（`MediaSession.Token` 重写了，比的是
     * 底下那个 binder），所以 `getActiveSessions` 每次返回的都是**新的对象实例**，
     * 拿它们当 map 的键永远对不上——症状是每来一次会话列表变动就重新挂一遍
     * 回调、旧的还摘不掉，回调越积越多，同一次换歌被报好几次。
     *
     * 这个 bug 不会在开发时喊疼（要等系统里第二个媒体会话出现才会显形），
     * 所以这里不靠「看起来对」，靠 token 的相等语义。
     */
    /// 值里**必须一起存 controller 实例**：回调是挂在注册时的那个实例上的，
    /// 摘的时候得拿同一个实例去摘（换一个实例调 unregisterCallback 是空操作，
    /// 那个回调就永远留在系统里了）。
    private val callbacks =
        mutableMapOf<MediaSession.Token, Pair<MediaController, MediaController.Callback>>()

    private val onSessionsChanged =
        MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
            Log.i(TAG, "会话列表变了：${controllers?.size ?: 0} 个")
            bind(controllers.orEmpty())
        }

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "✅ onListenerConnected —— 拿到门票了")
        connected = true

        // 把「从通知里读干净歌名」这一手交给 [MusicBridge]。**读通知本来就是
        // 这个服务的本职**（我们就是个通知监听器），所以这条路不用再要权限。
        // 为什么非要它不可，见 MusicBridge.noticeFor 那段实测记录。
        MusicBridge.noticeFor = noticeHook

        val mgr = getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
        if (mgr == null) {
            Log.e(TAG, "❌ 拿不到 MediaSessionManager，这台机器上没法做")
            return
        }
        manager = mgr

        mgr.addOnActiveSessionsChangedListener(onSessionsChanged, component(this))

        // ⚠️ 注册监听**不会**补发「当前已经存在的」那些会话。不放歌的时候注册，
        // 而用户已经在听歌的话，不主动拉这一次就会一直什么都收不到，直到他切歌。
        try {
            val now = mgr.getActiveSessions(component(this))
            Log.i(TAG, "初次拉取：${now?.size ?: 0} 个会话")
            bind(now.orEmpty())
        } catch (e: SecurityException) {
            // 走到这儿说明「通知使用权开着但没生效」，或者厂商动了这个检查。
            // 兜底路径是「从通知里捞 MediaSession.Token」——NLS 本来就能读通知，
            // 那条路不经过这个权限检查。第一期先不做，等真机上真撞上再说。
            Log.e(TAG, "❌ getActiveSessions 被拒（SecurityException）——" +
                "计划里的兜底方案（从通知捞 token）该上了", e)
        }
    }

    override fun onListenerDisconnected() {
        Log.w(TAG, "⚠️ onListenerDisconnected —— 系统把我们解绑了")
        connected = false
        unbindAll()
        dropNoticeHook()
        manager?.removeOnActiveSessionsChangedListener(onSessionsChanged)
        manager = null
        // 主动要一次重绑。ColorOS 上不保证成功（这也是界面那边要留一个
        // 「重新连接」按钮的原因），但不试一定不会绑回来。
        try {
            requestRebind(component(this))
        } catch (e: Exception) {
            Log.w(TAG, "requestRebind 也没成功", e)
        }
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        connected = false
        unbindAll()
        dropNoticeHook()
        manager?.removeOnActiveSessionsChangedListener(onSessionsChanged)
        manager = null
        // 服务没了，但**不清 MusicBridge 的状态**——界面还在的话，让它继续显示
        // 最后一首已知的歌，比突然变空白好。这是那个「元数据会被清空」的坑的
        // 同一个道理，只不过这次是整个服务都没了。
        Log.i(TAG, "服务销毁，保留最后一首已知的歌供界面兜底")
        super.onDestroy()
    }

    /**
     * 把回调挪到 [incoming] 这批会话上。
     *
     * 不能整个推倒重来（unbind 全部再 bind 全部）：那样每次列表变动都会让
     * 正在放着的那首重新挂一遍回调，中间那一小段空窗会漏掉事件。
     */
    private fun bind(incoming: List<MediaController>) {
        val incomingTokens = incoming.map { it.sessionToken }.toSet()

        // 已经消失的会话：摘掉回调。用 token 比，见 [callbacks] 的注释。
        val goneTokens = callbacks.keys - incomingTokens
        for (token in goneTokens) {
            val (ctrl, cb) = callbacks.remove(token) ?: continue
            try {
                ctrl.unregisterCallback(cb)
            } catch (_: Exception) {
            }
        }

        // 新来的：挂回调。**已经在册的跳过**——同一个会话可能换了新的
        // controller 实例回来，旧那次注册依然有效，再挂一次就重复了。
        for (c in incoming) {
            val token = c.sessionToken
            if (callbacks.containsKey(token)) continue
            val cb = object : MediaController.Callback() {
                override fun onMetadataChanged(metadata: MediaMetadata?) {
                    Log.i(TAG, "  · 元数据变了 ← ${c.packageName}")
                    publish()
                }

                override fun onPlaybackStateChanged(state: PlaybackState?) {
                    Log.i(TAG, "  · 播放状态变了 → ${state?.state} ← ${c.packageName}")
                    publish()
                }

                override fun onSessionDestroyed() {
                    Log.i(TAG, "  · 会话销毁 ← ${c.packageName}")
                    publish()
                }
            }
            c.registerCallback(cb)
            callbacks[token] = c to cb
        }
        bound = incoming

        // 每次列表变动都把当前会话列一遍——这是判断「谁在放」最直接的证据。
        for (c in bound) {
            Log.i(TAG, describe(c))
        }
        publish()
    }

    private fun unbindAll() {
        for ((_, pair) in callbacks) {
            val (ctrl, cb) = pair
            try {
                ctrl.unregisterCallback(cb)
            } catch (_: Exception) {
            }
        }
        callbacks.clear()
        bound = emptyList()
    }

    /** 挑一个「当前在放」的会话，交给 [MusicBridge]。见 pick 的注释。 */
    private fun publish() {
        MusicBridge.refresh(pick())
    }

    /**
     * 从一堆活着的会话里挑出「用户正在听的那个」。
     *
     * 真机上会同时有好几个：网易云在后台攥着会话、QQ音乐也在、小宇宙也在、
     * B站放着视频。getActiveSessions 返回的顺序**大致**按最近活跃排，但不保证。
     * 挑错的症状是——界面显示 B 站的视频标题，而用户明明在听歌。
     *
     * 判据按可靠程度排：
     *   1. 在出声的（[isAudible]）——最强信号
     *   2. 退一步，有歌名的（暂停中的也算，用户按了暂停不代表没在听那首）
     *   3. 再退，有会话就算
     *
     * 不排除自己的包：Nook 自己不放音频，没有会话，排除了也是空写。
     */
    private fun pick(): MediaController? {
        if (bound.isEmpty()) return null
        return bound.firstOrNull { it.isAudible() }
            ?: bound.firstOrNull { !it.titleOrNull().isNullOrBlank() }
            ?: bound.first()
    }

    /**
     * 这个会话在出声没有。**缓冲也算。**
     *
     * ⚠️ 2026-09-27 补：原先只认 `STATE_PLAYING`，漏了 `STATE_BUFFERING`。
     * 那条判据的用途是「从一堆活着的会话里挑出她正在听的那个」，而缓冲中的
     * 播放器显然就是她正在听的那个。
     *
     * 漏掉的后果不是随机的：两台播放器**可以同时活着**（实测这台机器上网易云的
     * 会话从 19:44 一直挂到 21:30 都没死，进程也没死，只是 paused），第一判据
     * 踏空之后就落到「谁有歌名」上——那是按 `getActiveSessions` 的返回顺序，
     * 而那个顺序**只大致按最近活跃排，不保证**。撞上的症状是界面显示上一首
     * 还在网易云里的歌，耳朵里响的却是 QQ音乐。
     *
     * Dart 那边 `MusicService._audible` 早就是把 buffering 算成「在放」的
     * （见那边的注释：网易云正常播着就在 playing/buffering 之间来回跳），
     * 这里跟它对齐。
     */
    private fun MediaController.isAudible(): Boolean {
        val s = playbackState?.state ?: return false
        return s == PlaybackState.STATE_PLAYING || s == PlaybackState.STATE_BUFFERING
    }

    private fun MediaController.titleOrNull(): String? =
        metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)

    /** 只摘自己装的那一个钩子。见 [noticeHook] 的注释。 */
    private fun dropNoticeHook() {
        if (MusicBridge.noticeFor === noticeHook) MusicBridge.noticeFor = null
    }

    /**
     * 这个包现在挂在通知上的歌名/歌手，**带 [NOTICE_TTL_MS] 缓存**。
     *
     * ## 为什么要缓存
     *
     * ⚠️ 这一层不是「顺手优化」，是**换歌那一瞬间不卡的必要条件**。实测
     * QQ音乐 换一首歌会在 0.5 秒内打 109 次回调（89 次元数据 + 20 次播放状态），
     * 每一次都要走 [MusicBridge.snap] → 这里，而 [readNotice] 里那句
     * `activeNotifications` 是**一次跨进程 binder 往返**、还在主线程上。
     * 不缓存就是每换一首都拿小半秒的主线程，去反复换一个**根本不会变**的结果
     * ——那 109 次读到的其实是同一张通知。
     *
     * 真机实测：一场换歌风暴 0.5 秒里 109 次回调；没有缓存的话，每一次都要
     * 打一次 binder。加了 250ms 的窗口之后，同一场风暴里最多读 1–2 次。
     *
     * ⚠️ 别把它说成「实测省了 0.3 秒卡顿」——**回调的节奏是 QQ音乐 自己发的**，
     * 实测间隔跟着它的发射速率走（换歌那 0.5 秒里 5–10ms 一次），主线程并不
     * 是限速的那一环。这里省下的是实实在在的工作量（每换一首少约 100 次跨进程
     * 往返），但**没有测到帧时间因此变好**。
     *
     * 诊断（[describe]）要的是**此刻**的真相，走 [readNotice] 绕开这里。
     */
    private fun noticeFor(pkg: String): NoticeTrack? {
        val now = SystemClock.elapsedRealtime()
        val hit = noticeCache[pkg]
        if (hit != null && now - hit.at < NOTICE_TTL_MS) return hit.track

        val fresh = readNotice(pkg)
        noticeCache[pkg] = CachedNotice(now, fresh)
        return fresh
    }

    /**
     * 真的去读一次活动通知。**不带缓存**——缓存在 [noticeFor] 里。
     *
     * 这一份才是干净的歌名，前因后果见 [MusicBridge.noticeFor] 那段实测记录。
     *
     * 挑哪一条通知：同包 + `category=transport`。实测 QQ音乐 那条是
     * `category=transport`，网易云也是；用 category 而不是去比 `EXTRA_MEDIA_SESSION`
     * 里那个 token，是因为 token 的读取在 API 33 之后分了新旧两套写法，而
     * category 这一条从 API 21 到现在没动过。
     *
     * 读不到就返回 null，上层退回会话里那一份——**这条路上任何一步失败都不该
     * 让整件事停下来**，最坏的结果只是歌名又变回滚动歌词。
     */
    private fun readNotice(pkg: String): NoticeTrack? {
        val list = try {
            activeNotifications
        } catch (e: Exception) {
            // 服务刚断、或者系统那边不让读。不吵：这是降级，不是故障。
            Log.w(TAG, "读不到活动通知，歌名只能会话里那一份了", e)
            return null
        } ?: return null

        val n = list.firstOrNull {
            it.packageName == pkg && it.notification?.category == Notification.CATEGORY_TRANSPORT
        }?.notification ?: return null

        val title = n.extras.getCharSequence(Notification.EXTRA_TITLE)
            ?.toString()?.trim().orEmpty()
        if (title.isBlank()) return null
        return NoticeTrack(title = title, artist = artistFromNotice(n.extras, title))
    }

    /**
     * 通知第二行是 `歌手 - 别的`，**两家都是歌手打头**：
     * QQ音乐 给的是 `Jeff Bernat - The Gentleman Approach`（歌手 - 专辑），
     * 网易云 给的是 `Jada Facer - Float`（歌手 - 歌名）。
     * 后头跟的是专辑还是歌名各家不一样，但歌手都在最前面，所以取第一个
     * 「 - 」前面那截。
     *
     * 取出来跟歌名一模一样、或者是空的，就说明这一行根本不是那个格式——
     * **宁可不给**，让上层留着会话报的歌手（丑一点但至少不是编的），
     * 也好过塞一个假的进去。
     */
    private fun artistFromNotice(extras: Bundle, title: String): String? {
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)
            ?.toString()?.trim().orEmpty()
        if (text.isBlank()) return null
        val head = text.substringBefore(" - ").trim()
        if (head.isBlank() || head == title) return null
        return head
    }

    /**
     * 给 logcat 看的一行摘要。
     *
     * ⚠️ **会话那一份和通知那一份都要打**，因为它们经常不一样——QQ音乐 的会话
     * 里歌名栏是滚动歌词（见 [MusicBridge.noticeFor]）。只打一行的话，两边恰好
     * 一样时分不清「通知本来就干净」和「压根没读到通知」，而这两种情况下
     * 真正会用的那份是不同的。
     */
    private fun describe(c: MediaController): String {
        val md = c.metadata
        val ps = c.playbackState
        val sTitle = md?.getString(MediaMetadata.METADATA_KEY_TITLE)
        val sArtist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
        val dur = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        // 走 readNotice 绕开缓存：这一行是诊断，要的是**此刻**的通知长什么样。
        // 缓存只差 250ms，但诊断的价值全在「准」上，而这里一次会话变动才调一次。
        val notice = readNotice(c.packageName.orEmpty())
        return buildString {
            append("  [${c.packageName}] ")
            if (sTitle.isNullOrBlank() && sArtist.isNullOrBlank()) {
                // 这条日志是「元数据被清空」那个坑的现场证据，别当成没在放歌。
                append("（元数据为空，session 还活着）")
            } else {
                append("会话《$sTitle》")
                if (!sArtist.isNullOrBlank()) append(" - $sArtist")
                if (dur > 0) append(" (${dur / 1000}s)")
            }
            append("｜通知")
            append(
                if (notice == null) "（没读到，用会话那份）"
                else buildString {
                    append("《${notice.title}》")
                    if (notice.artist != null) {
                        append(" - ${notice.artist}")
                    } else {
                        append("（歌手没取到，留会话的）")
                    }
                },
            )
            append(" state=${ps?.state} actions=${ps?.actions} pos=${ps?.position}")
        }
    }
}
