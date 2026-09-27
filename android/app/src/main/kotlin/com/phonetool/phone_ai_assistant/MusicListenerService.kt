package com.phonetool.phone_ai_assistant

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
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
     *   1. 正在放的（STATE_PLAYING）——最强信号
     *   2. 退一步，有歌名的（暂停中的也算，用户按了暂停不代表没在听那首）
     *   3. 再退，有会话就算
     *
     * 不排除自己的包：Nook 自己不放音频，没有会话，排除了也是空写。
     */
    private fun pick(): MediaController? {
        if (bound.isEmpty()) return null
        return bound.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: bound.firstOrNull { !it.titleOrNull().isNullOrBlank() }
            ?: bound.first()
    }

    private fun MediaController.titleOrNull(): String? =
        metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)

    /** 给 logcat 看的一行摘要。字段和 MusicBridge 读的是同一批。 */
    private fun describe(c: MediaController): String {
        val md = c.metadata
        val ps = c.playbackState
        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE)
        val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
        val dur = md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
        return buildString {
            append("  [${c.packageName}] ")
            if (title.isNullOrBlank() && artist.isNullOrBlank()) {
                // 这条日志是「元数据被清空」那个坑的现场证据，别当成没在放歌。
                append("（元数据为空，session 还活着）")
            } else {
                append("《$title》")
                if (!artist.isNullOrBlank()) append(" - $artist")
                if (dur > 0) append(" (${dur / 1000}s)")
            }
            append(" state=${ps?.state} actions=${ps?.actions} pos=${ps?.position}")
        }
    }
}
