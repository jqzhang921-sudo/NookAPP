package com.phonetool.phone_ai_assistant

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 「一起听歌」的 Dart ↔ 原生管子。通道名 `music_session`。
 *
 * 数据本身全在 [MusicBridge] 里，这里只负责四件事：问权限、送人去开权限、
 * 把攒下的状态和事件递出去、把播放控制（放/停/上一首/下一首/快进）转给
 * [MusicBridge.control]。**这个类不持有任何状态**——因为它是跟着 Activity
 * 引擎走的，而 MusicBridge 和 [MusicListenerService] 活得比它长。
 *
 * ## 权限这条路和别的都不一样
 *
 * 「通知使用权」是**用户逐个 app 在系统设置里勾**的，不是 `uses-permission`，
 * 所以：
 * - manifest 里**不需要**（也不该）声明 `<uses-permission>`
 * - `requestPermissions` 要不来，弹窗申请这条路根本不存在
 * - 装上不等于有，得用户自己走一趟
 *
 * 所以这里跟 [AppUsageChannel] 对 PACKAGE_USAGE_STATS 的写法完全一致：
 * [hasPermission] 问状态、[openSettings] 把人送过去，**中间不假装能自动搞定**。
 *
 * ## exported="true" 那个疑点
 *
 * manifest 里那个服务写了 `android:exported="true"`，看着吓人，其实安全：
 * 它被 `BIND_NOTIFICATION_LISTENER_SERVICE` 保护，而那是签名级权限，只有系统
 * 持有；而且只有**用户勾选之后**系统才会去绑它。CTS 和 Flutter 的同类插件都
 * 是这么声明的。
 */
class MusicChannel(private val context: Context) {

    companion object {
        const val CHANNEL = "music_session"

        /**
         * API 30 起才有「跳到这一个服务的详情页」。
         *
         * ⚠️ 字符串写字面量，**不要**用 `Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS`
         * 那个常量：它在编译期就要 API 30，而我们 minSdk 是 24，直接引用过不了编译
         * （或者得加 @RequiresApi 再套一层判断，不值当）。这个 action 字符串本身
         * 是系统设置认的，写死不亏。
         *
         * 2026-09-27 实测（PKT110 / ColorOS）：**这条在 ColorOS 上不起作用**。
         * `am start` 报了 Starting、也不抛异常，但设置应用什么页面都没打开
         * （`topResumedActivity` 停在原来那页）。所以下面的兜底不是「以防万一」，
         * 是**这台机器上真正会走的那条路**。也正因为这样，`startActivity` 那里
         * 不能只看有没有抛异常来判断成功——ColorOS 是「不抛也不做」。
         */
        private const val ACTION_DETAIL =
            "android.settings.NOTIFICATION_LISTENER_DETAIL_SETTINGS"
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission())
            "openSettings" -> openSettings(result)
            // 「该绑没绑」的话求系统绑一次。见 [MusicListenerService.ensureBound]
            // ——**故意不并进 hasPermission 里**：那一个是个纯粹的查询，
            // 而这个是会去动系统状态的，读代码的人得一眼分得出来。
            "ensureBound" -> result.success(ensureBound())
            // 当前在放什么。null = 还没有任何会话（没在放歌，或者服务还没连上）。
            "snapshot" -> result.success(MusicBridge.snapshot())
            // 攒下的换歌/播放事件，**取走即清**。
            "takeEvents" -> result.success(MusicBridge.takeEvents())
            // 播放控制。**用 success 回一份带 success 字段的 map**，而不是
            // 失败时调 result.error——「现在没在放歌」是正常情况，走异常通道
            // 的话到了 Dart 只剩一个 code，那句能读懂的中文就丢了。
            "control" -> result.success(
                MusicBridge.control(
                    call.argument<String>("action").orEmpty(),
                    (call.argument<Number>("positionMs"))?.toLong(),
                )
            )
            else -> result.notImplemented()
        }
    }

    /**
     * 通知监听服务里有没有我们这一份被启用。
     *
     * 走 [NotificationManagerCompat.getEnabledListenerPackages] 而不是自己去读
     * `Settings.Secure` 里那个 `enabled_notification_listeners` 字符串：后者是个
     * 用 `:` 拼起来的 `包名/类名` 列表，各家拼法有细微差别（大小写、有没有斜杠），
     * 解析它等于自己实现一遍系统 API。
     *
     * 判的是**包名**不是具体哪个服务——我们包里只有这一个监听服务，够用。
     */
    private fun hasPermission(): Boolean = try {
        NotificationManagerCompat.getEnabledListenerPackages(context)
            .contains(context.packageName)
    } catch (e: Exception) {
        // 极少数定制系统上这个调用会抛。返回 false 比崩了好——上层会显示
        // 「未开启」并给一个去设置的按钮，用户点一下就知道了。
        false
    }

    /**
     * 授权开着、可我们那份监听服务没被绑上的话，求系统绑回来。
     *
     * 为什么要这一步见 [MusicListenerService.ensureBound] 的注释（一句话：
     * 强停之后没人会重绑，而用户看到的只是「音乐功能莫名其妙坏了」）。
     *
     * 没授权时直接返回 false、**不求重绑**：那会把「用户还没同意」和「用户
     * 同意了但系统没绑」两件事搅在一起，而这俩在前台是完全不同的两句话。
     */
    private fun ensureBound(): Boolean {
        if (!hasPermission()) return false
        return MusicListenerService.ensureBound(context)
    }

    /**
     * 把人送到该去的地方。
     *
     * 优先跳到**我们这一份服务自己的详情页**（API 30+），退而求其次才是整张
     * 「通知使用权」列表。差别很大：那张列表里通常躺着十几个 app（实测用户这台
     * 上有 4 个已启用、外加十几个未启用的），让人在里面找「Nook」是纯添堵。
     * 详情页直接就一个开关。
     *
     * 定制系统可能没实现详情页那个 action（ColorOS 上没实测过），所以必须能退。
     */
    private fun openSettings(result: MethodChannel.Result) {
        val detail = Intent(ACTION_DETAIL)
            .putExtra(
                Intent.EXTRA_COMPONENT_NAME,
                MusicListenerService.component(context).flattenToString(),
            )
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(detail)
            result.success(true)
            return
        } catch (_: ActivityNotFoundException) {
            // 往下走，用列表页兜底。
        } catch (_: Exception) {
            // 同上。有些 ROM 是抛 SecurityException 而不是 NotFound。
        }

        val list = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(list)
            result.success(true)
        } catch (e: Exception) {
            // 两个都打不开。报出去让上层说人话，别让用户点了没反应。
            result.error(
                "NO_SETTINGS",
                "打不开通知使用权设置页：${e.message}。可以手动去「设置 → 通知与状态栏 → 通知使用权」里找 Nook。",
                null,
            )
        }
    }
}
