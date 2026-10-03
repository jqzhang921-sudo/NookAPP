package com.phonetool.phone_ai_assistant

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * 「一起听歌」的保命符：一个只是为了**不让进程被冻住**而存在的前台服务。
 *
 * ## 它不干任何事，这就是它的全部职责
 *
 * 这个类里没有一行代码是在读媒体会话——那是 [MusicListenerService] 的活。
 * 它唯一做的事是**把进程的分量抬起来**，让系统的 cached apps freezer 够不着我们。
 *
 * 机制上说得很死：AOSP `CachedAppOptimizer` 冻进程的判据是
 * `oom_adj >= 900`（正常模式）/ `>= 600`（Android 16 的激进模式），而一个跑着
 * 前台服务的进程落在 `PERCEPTIBLE_APP_ADJ = 200` 那一档。**所以这不是求系统
 * 开恩，是直接掉出了冻结器的适用范围。**
 *
 * ## ⚠️⚠️ 但在这台机器上，光有前台服务**不够**（2026-09-27 实测）
 *
 * 上面那段是 AOSP 的机制。**ColorOS 不看它。** 实测：前台服务明明已经生效
 * （`isForeground=true foregroundId=8801 types=0x2`、进程从 `BFGS`(50) 抬到
 * 200、心跳自报 `importance=125`），进程照样被冻——`/proc/<pid>/stat` 的
 * utime+stime 在后台 90 秒里**涨 0 个 tick**，日志几秒内全停，ServiceRecord
 * 和通知却都还在（通知是 system_server 画的，不能当活着的证据）。
 *
 * 而与此同时 Android 侧所有自检字段都说「我没冻它」：`isFrozen=false`、
 * cgroup `5:freezer:/`、待机桶 10(ACTIVE)、`RUN_ANY_IN_BACKGROUND: allow`、
 * `am get-inactive → Idle=false`。**所以别去这些字段里找原因，找不到的。**
 *
 * 真正解开它的是**用户在设置里把 Nook 的耗电管理改成「允许完全后台行为」**
 * （ColorOS：设置 → 应用 → Nook → 耗电管理，默认是「智能限制」）。改完之后
 * 同样的测法：后台心跳每 60.02 秒一条、`importance=125`、`推 track` 正常送到
 * 后台的 Nook。而且这跟「新进程还没被归类」无关——测之前特意把进程在前台
 * 养熟了 5 分钟。
 *
 * ⚠️ 这一档**不在任何 adb 能读的地方**：不在 `settings secure/global/system`，
 * 不在 appops，不在 `deviceidle whitelist`，不在 `dumpsys batterymanager`。
 * 它在 ColorOS 自己的库里（大概率 `com.oplus.athena`）。**所以别指望用命令行
 * 验证或设置它**——只能靠用户的手，或者靠我们的引导页把人送过去。
 * 顺带记一条：`cmd deviceidle whitelist +<包名>` **实测无效**，别把它当成
 * 「允许完全后台行为」的等价物。
 *
 * 结论：这个服务是**必要条件，不是充分条件**。它把 adj 抬起来，但还得用户
 * 在系统设置里放行。两者缺一，第三期在真机上都不成立。
 *
 * ## 为什么非要有它（2026-09-27 真机实测）
 *
 * App 切到后台几分钟后，ColorOS 冻住整个进程，`MediaController.Callback` 的
 * binder 投递**整个停掉**：
 *
 * ```
 * 21:43:11  切歌，回调照常触发、照常推事件
 * 21:43:14  ……之后彻底安静 2 分多钟，一行都没有
 * 21:45:2x  am start 把 Nook 拉回前台
 * 21:45:27  ├─ 日志当场恢复，接着往下记，没有一行 describe
 * ```
 *
 * **「恢复时没有任何重连日志」就是判据**——监听器和回调一直有效，冻的是投递。
 * 所以这不是 bug，别去 [MusicListenerService] 里找。
 *
 * 后果是第三期「AI 对换歌及时反应」在真机上不成立：用户听歌时人在 QQ音乐，
 * Nook 在后台冻着，换歌事件根本到不了 Dart。那 0.6 秒的识别延迟只在前台成立。
 *
 * ## ⚠️ 借的是 mediaPlayback 这个名字
 *
 * **我们不放任何音频**，只是「看」别人的媒体会话。借这个类型是因为 ColorOS
 * 的电池管理认得它（音乐 App 用的就是它）。侧载自用不受 Google Play 政策管；
 * 但如果哪天要上架，`mediaPlayback` 类型要提交用途说明 + 演示视频，而我们的
 * 申报是过不了的。**别把它当成 bug 改掉**——这是知情决策。
 *
 * ## 寿命：回前台起，停歌之后自己关
 *
 * 不是 24 小时常驻（Nook 实测 RSS 302MB，常驻这份内存不值当）。启动点在
 * [MusicChannel] 的 `keepAlive`，而 Dart 那边每次回前台都会走一趟——
 * **那是唯一合法的启动时机**，见下。
 *
 * 关的判据在 [tick] 里，两档：
 *
 * | 情况 | 判据 | 再留 |
 * |---|---|---|
 * | 会话还活着、只是暂停 | `MusicBridge.activeController != null` | [PAUSE_KEEP_MS]（15 分钟）|
 * | 会话没了 / 从没出过声 | 否则 | [DEAD_KEEP_MS]（3 分钟）|
 *
 * **两档不能合成一档**——这两件事的恢复概率差一个量级：暂停之后大概率还会
 * 接着听（关早了，等她再按播放时进程已经凉了，而后台又起不了前台服务），
 * 而播放器都退出了就是真不听了（再挂着纯属碍眼）。
 *
 * ⚠️ 副作用，知情接受：服务自关之后她**不打开 Nook 直接按播放**，那次就漏了
 * ——服务没人重启，进程凉着。这就是下面那条「固有启动缺口」，不是新问题。
 *
 * ## ⚠️ 为什么只能在 App 处于前台时启动
 *
 * Android 12+ 起，App 在后台时调 `startForegroundService()` 会抛
 * `ForegroundServiceStartNotAllowedException`。豁免清单里和我们相关的只有
 * 「App 有可见的 Activity」。所以触发点是 Dart 的
 * `didChangeAppLifecycleState(resumed)` → `MusicService.start()`，
 * 那一刻 Activity 可见、importance 是 FOREGROUND(100)，是教科书级的豁免情形。
 *
 * 这条限制决定了本方案有一个**固有的启动缺口**：用户很久没开 Nook 就直接去
 * QQ音乐 起播，那一刻 Nook 正被冻着，而我们从后台拉不起前台服务——那一次会漏掉。
 * 这是「不 24 小时常驻」的代价，不是 bug。
 *
 * 还有一条 Android 15 的新限制顺带记在这里，防止以后有人「顺手加个开机自启」：
 * **不能在 `BOOT_COMPLETED` 广播里起 `mediaPlayback` 类型的前台服务**，
 * 会抛 `FGS type mediaPlayback not allowed to start from BOOT_COMPLETED`。
 * 我们的设计里本来就没有开机自启。
 *
 * ## 这个服务挡不住什么
 *
 * - **从最近任务划掉** —— ColorOS 上那等于强停，整个进程连服务一起没。
 *   [MusicListenerService.ensureBound] 的注释里已经记过这条。
 * - **用户开省电模式** —— 那个会直接强停后台 App，前台服务也在内。
 * - **`com.oplus.athena`** —— OPPO 自己的进程管理，它不看 adj，看自己那套
 *   「是否常用 / 是否被用户保护」。**这就是上面那段实测里把光有前台服务
 *   打回来的那一位**：前台服务对它不够，得用户在耗电管理里放行才够。
 *   **判据是下面那条心跳日志**（见 [tick]），别去 dumpsys 里找。
 * - **刚装完 / 刚清过数据** —— 「允许完全后台行为」是用户级设置，换台机器、
 *   重装一次就没了。所以引导页不是一次性的事，是新装机器上的必经一步。
 */
class MusicKeepAliveService : Service() {

    companion object {
        /** 和 [MusicBridge] / [MusicListenerService] 共用，`adb logcat -s MusicSession` 一把捞全。 */
        private const val TAG = "MusicSession"

        /**
         * 通知渠道。**必须新开一个，不能复用现成的任何一个**：
         *
         * - `live` 是 LiveCapsulePlugin 给 Android 16 实时更新留的，
         *   用户在系统设置里关掉「实时更新」会把我们的前台通知一起关掉；
         * - `nudge` / `reply` 是「它想说话」，用户关掉它们是天经地义的
         *   ——而关掉之后前台服务就没通知了。
         *
         * ⚠️ 重要度**只能设一次**，用户改过之后我们改不回来。所以第一次就得
         * 选对：`IMPORTANCE_LOW`（静默、折在通知栏下半部分），不能用 DEFAULT
         * （每次刷新通知都会响/震），也不能用 MIN（会被折叠进「静默」分区
         * 甚至不显示）。
         */
        private const val CHANNEL_ID = "listening"
        private const val CHANNEL_NAME = "一起听"

        private const val NOTIFICATION_ID = 8801

        /** 和 [LiveCapsulePlugin] 那些功能错开，别共享 PendingIntent。 */
        private const val PI_REQUEST = 8801

        /**
         * `ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK`。
         *
         * **写字面量，不要引用那个常量**——理由和 LiveCapsulePlugin.EXTRA_PROMOTED、
         * [MusicChannel.ACTION_DETAIL] 一模一样：那个常量本身是 API 29 才有的，
         * 而我们 minSdk 是 24（Java 的 static final int 会被内联，运行时其实
         * 不会炸，但 lint 会唠叨，得加 @SuppressLint，不值当）。
         */
        private const val TYPE_MEDIA_PLAYBACK = 2

        /** 多久醒一次。见 [tick] 里关于精度的说明。 */
        private const val TICK_MS = 60_000L

        /**
         * 会话还活着、只是**暂停**时，最多再留 15 分钟。
         *
         * 为什么给这么长：她按暂停常常只是接个电话、回条消息，回来还要接着听。
         * 这时候把服务关了，等音乐再响起来时进程已经凉了，而 Android 12+
         * **禁止从后台重启前台服务**——那次就彻底漏掉了。
         */
        private const val PAUSE_KEEP_MS = 15 * 60_000L

        /**
         * 会话都没了（或者从起来就没出过声）时，最多留 3 分钟。
         *
         * 这个窗口只够「她刚退出播放器又马上打开」这种来回，不留白挂着——
         * 一条没有用的常驻通知挂半小时比没有更糟。
         */
        private const val DEAD_KEEP_MS = 3 * 60_000L

        /**
         * 起服务。**只能在 App 处于前台时调**，见类注释。
         *
         * 失败返回 false 不抛——和 MusicChannel.ensureBound、
         * LiveCapsulePlugin.show 一个口径：跨进程调用的那头（Dart）接不住异常，
         * 抛出去只会变成一个没人认识的 crash。
         */
        fun start(ctx: Context): Boolean = try {
            ContextCompat.startForegroundService(
                ctx, Intent(ctx, MusicKeepAliveService::class.java)
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "前台服务起不来：${e.javaClass.simpleName} ${e.message}", e)
            false
        }
    }

    private val main = Handler(Looper.getMainLooper())

    /** 这个实例是什么时候起来的（`elapsedRealtime`）。见 [tick] 里的 `空闲` 一栏。 */
    private var startedAt = 0L

    /**
     * 没有任何人 bind 它——[MusicListenerService] 那条 binder 是系统绑的，
     * 跟这个服务是两回事。绑定服务那套（`Binder` / `onUnbind`）在这里全都不需要。
     */
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startedAt = SystemClock.elapsedRealtime()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 第一件事必须是它，而且**在它之前不能有任何可能阻塞的东西**——
        // `startForegroundService()` 之后系统只给 5～10 秒，超了会以
        // ForegroundServiceDidNotStartInTimeException 崩掉。
        // 所以这个类的 `onCreate` / `onStartCommand` 里不许读磁盘、不许读
        // MusicBridge.snapshot()（那看着无害，其实是跨进程 binder 往返）。
        if (!goForeground()) {
            // startForeground 都没成功，这个服务就没有任何存在意义了。
            // **必须 stopSelf**：不 stop 的话系统记着「你欠我一次 startForeground」，
            // 下次会崩，而崩溃现场指向十秒前的另一次调用——极难查。
            stopSelf()
            return START_NOT_STICKY
        }

        main.removeCallbacks(tick)
        main.postDelayed(tick, TICK_MS)
        Log.i(TAG, "前台服务起来了")
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        main.removeCallbacks(tick)
        Log.i(TAG, "前台服务关了")
        super.onDestroy()
    }

    /**
     * 心跳。**它不是调试残留，是整个方案的验收手段。**
     *
     * 它回答的是唯一那个没被证实过的问题：**前台服务到底挡不挡得住 ColorOS**。
     * AOSP 那套冻结器我们有 adj 的机制依据（见类注释），但 OPPO 自己的
     * `com.oplus.athena` 不看 adj。所以判据落在实测上：
     *
     * - 后台放着歌，这个心跳每 60 秒准时一条、且 `importance=125` → 前台服务生效了；
     * - **心跳停了、可通知还在** → ColorOS 无视了前台服务。注意通知是系统画的，
     *   不受进程冻结影响，所以「通知还在」不能当成「服务还活着」。
     *   这是唯一一个能区分「我们的服务没起作用」和「别处有问题」的信号。
     *
     * 拉回前台看心跳是否续上，和当初测 binder 投递是同一个手法。
     *
     * ## ⚠️ 「60 秒」的精度不保证
     *
     * `Handler.postDelayed` 依赖主线程被调度，**熄屏进入深度睡眠时主循环不走**，
     * 所以实际间隔可能被拉长得多。这不影响正确性（只会醒得晚，不会醒得早），
     * 但别看到间隔是 5 分钟就以为是 bug。
     *
     * **不要**为了精确改成 `AlarmManager.setExactAndAllowWhileIdle`——那要
     * `SCHEDULE_EXACT_ALARM`（API 31+ 还得用户手动开），为一条心跳不值当。
     */
    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()

            // 「已经多久没响过了」。
            //
            // `maxOf(startedAt, ...)` 的 `startedAt` **不能省**：它保证
            // 「起来了但从来没放过歌」也能自己关（那时 [MusicBridge.lastAudibleAt]
            // 是 0，不加它的话 now - 0 是个天文数字，服务第一次心跳就自杀了
            // ——结果一样，但那是撞对的，不是算对的）。
            val idleSince = maxOf(startedAt, MusicBridge.lastAudibleAt)
            val keep = if (MusicBridge.activeController != null) PAUSE_KEEP_MS else DEAD_KEEP_MS

            if (now - idleSince >= keep) {
                Log.i(TAG, "空闲 ${(now - idleSince) / 1000}s 到了 ${keep / 1000}s，前台服务自己关")
                // 先摘通知再停。REMOVE 是必须的——DETACH 会把通知留在栏里，
                // 那就成了一条永远点不掉、也不知道是谁挂的死通知。
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }

            // 顺手重发一次前台通知。**这不是冗余**：Android 13+ 允许用户把
            // 前台服务通知划掉（`setOngoing` 挡不住单条下滑），而服务照跑；
            // 能把划掉的通知放回来的**只有 startForeground()**，`notify()` 不行。
            goForeground()

            Log.i(
                TAG,
                "心跳 importance=${importance()} 已运行=${(now - startedAt) / 1000}s" +
                    " 空闲=${(now - idleSince) / 1000}s",
            )
            main.postDelayed(this, TICK_MS)
        }
    }

    private fun goForeground(): Boolean = try {
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, buildNotification(), TYPE_MEDIA_PLAYBACK,
        )
        true
    } catch (e: Exception) {
        // 这里可能抛的，按排查难度排：
        // - MissingForegroundServiceTypeException：manifest 里的 foregroundServiceType
        //   和这里传的 type 对不上（Android 14+）；
        // - SecurityException：targetSdk 34+ 缺 FOREGROUND_SERVICE_MEDIA_PLAYBACK
        //   权限。**这个在 API 33 的机器上完全看不出来**，开发期用老机器测会一路绿灯；
        // - ForegroundServiceStartNotAllowedException：从后台启动了，见类注释。
        Log.e(TAG, "startForeground 没成功：${e.javaClass.simpleName} ${e.message}", e)
        false
    }

    /**
     * 当前进程对系统而言是什么分量。
     *
     * 125 = `IMPORTANCE_FOREGROUND_SERVICE`，400 = `IMPORTANCE_CACHED`。
     * **这四行是这个改动里最值钱的诊断**——它把「前台服务到底生效没有」从
     * 猜测变成 logcat 里一个数字。
     */
    private fun importance(): Int {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        return info.importance
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        // 幂等：tick 每 60 秒会走一次 goForeground，别每次都建渠道。
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW).apply {
                description = "切到后台之后还能知道你正在听什么"
                setShowBadge(false)     // 一条常驻状态，不该在图标上顶个圆点
                enableVibration(false)
                setSound(null, null)
            }
        )
    }

    /**
     * 前台服务的通知。**它同时是「服务还活着」的肉眼可见证据。**
     *
     * ⚠️ 文案这一版是写死的，**故意的**：想显示当前歌名就得调
     * [MusicBridge.snapshot]，那是跨进程 binder 往返，而它正好坐在
     * `startForeground()` 前面那条「不许阻塞」的红线上。等第一步证明了
     * 心跳在后台停不了，再考虑把歌名加进来（那时也可以放进 try 里）。
     *
     * 几点取舍：
     * - `setOngoing(true)` 是语义上的常驻，**别指望它挡住下滑手势**
     *   （`FLAG_NO_CLEAR` 在 API 33+ 上对用户的下滑已经无效）——放回来靠 [tick]。
     * - **不要 `setSilent(true)`**：它和渠道重要度是两套机制，同时用会互相打架，
     *   而且会覆盖用户在渠道上做的选择。渠道 LOW + `setOnlyAlertOnce` 就够了。
     * - `setForegroundServiceBehavior` 不调。默认行为是**延迟约 10 秒才显示通知**，
     *   这对我们是好事（用户开 App 十秒内又走了的话不会闪一下）。要点是：
     *   延迟的只是「显示」，**前台服务状态和 adj 是立刻生效的**，不影响防冻结。
     */
    private fun buildNotification(): Notification {
        val open = packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pi = open?.let {
            PendingIntent.getActivity(
                this, PI_REQUEST, it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_nook)
            .setContentTitle("在后台听着")
            .setContentText("切走之后也能知道你在听什么")
            .setContentIntent(pi)
            .setOngoing(true)
            // 每 60 秒重发一次，不设这个的话用户会以为通知在抽风。
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)   // 只有 26 以下看这个
            .build()
    }
}
