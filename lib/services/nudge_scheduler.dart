import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'app_providers.dart';
import 'glance_health.dart';
import 'letter_schedule.dart';
import 'nudge_service.dart';
import 'storage_service.dart';

/// 后台唤醒。让「主动说话」在 App 关着的时候也有机会发生。
///
/// ## 为什么轮询 15 分钟，而不是「到点了就推」
///
/// Android 的周期任务**最短就是 15 分钟**，而且系统只保证「大约」——它会
/// 攒着一批任务凑在一起跑，省电。所以这不是闹钟，是一次「看看有没有事」的
/// 巡查：绝大多数次会在 [NudgeService.run] 的前两步就返回（门槛没过，或者
/// 根本没有候选），**不联网、不调模型**，代价约等于读几个键。
///
/// 真正决定推不推的还是那两层，跟这里的频率无关。把频率调快只会更耗电，
/// 不会让它更想说话。
///
/// ## ⚠️ 国产 ROM 会杀后台，这条链本来就不保证准时
///
/// ColorOS / MIUI 那套省电策略会把周期任务掐掉或者大幅推迟，用户得手动给
/// App 开「自启动」和「后台运行」。所以：
///
/// - **内容那层必须能独立成立**——不能依赖「一定会在某个点被唤醒」
/// - 唤醒失败的后果只是「这条晚点再说」，不能是数据不一致
/// - 开着 App 的时候也走一遍（见 [runOnStartup]），后台被杀了至少还有这条路
class NudgeScheduler {
  static const _unique = 'nudge_periodic';
  static const _name = 'nudge';

  /// 在 `main()` 里调一次。只是把回调入口注册给原生侧，不会开始跑。
  static Future<void> init() async {
    await Workmanager().initialize(nudgeCallbackDispatcher);
  }

  /// 开关打开时调。[ExistingWorkPolicy.replace] 保证重复调用不会叠出多个任务。
  static Future<void> enable() async {
    await Workmanager().registerPeriodicTask(
      _unique,
      _name,
      frequency: const Duration(minutes: 15),
      // 立刻跑一次没意义：刚开开关时她人就在设置页，这会儿推一条最突兀。
      initialDelay: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      // 没网的时候连模型都调不了，让系统替我们省掉这次唤醒。
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.linear,
    );
  }

  static Future<void> disable() async {
    await Workmanager().cancelByUniqueName(_unique);
  }

  /// 进程启动时走一遍。
  ///
  /// 后台被 ROM 杀掉时这是还活着的路：她打开 App，攒下的那件事就有机会
  /// 说出口。门槛照走，所以不会因为多了这个入口就变吵。
  ///
  /// ⚠️ 这条**只在冷启动时跑**——它挂在根 widget 的 initState 上，那是
  /// 进程启动才走一次。Android 不会因为切走就杀进程，所以她连着用一整天的
  /// 话，这条兜底一次都不会再跑。切回前台那条见 [runOnResume]。
  static Future<void> runOnStartup() =>
      _runLocal(settle: const Duration(seconds: 3));

  /// 切回前台时走一遍。
  ///
  /// 补的是这个洞：进程活了一整天，期间**唯一的检查点只有后台周期任务**，
  /// 而那个在国产 ROM 上被攒到二三十分钟一次、还会整轮跳过。
  ///
  /// 延时比冷启动短得多：这会儿没有首屏要画，只需要躲开切回来那一下的动画。
  static Future<void> runOnResume() =>
      _runLocal(settle: const Duration(milliseconds: 600));

  // ---------------- 换歌那条路（三期） ----------------

  /// 换歌之后停多久再评估。
  ///
  /// **防抖是这儿的主要目的**：她连切五首歌，只该评估一次。这 25 秒里她要是
  /// 又切了，定时器重来，前面那几首就一起塌缩进「连着翻了好多首」那句里——
  /// 而那正是这几首里唯一值得说的东西。不防抖的话，五首歌就是五次 API，
  /// 其中四次只能得到「不说」。
  ///
  /// 也不能太短：播放器在曲目边界会连着报好几次状态，太短会在同一首歌上
  /// 反复触发。
  static const musicSettle = Duration(seconds: 25);

  static Timer? _musicTimer;

  /// 换歌了。`MusicService.onTrackChanged` 挂的就是这个。
  ///
  /// ⚠️ 这里**只定时，不评估**。评估要读盘、可能要调模型，而这是从原生事件
  /// 回调里叫起来的——在那一帧上干活会直接掉帧，和 [_runLocal] 那个 `settle`
  /// 是同一个理由。何况这会儿她多半正在看屏幕。
  static void onTrackChanged() {
    _musicTimer?.cancel();
    _musicTimer = Timer(musicSettle, () => unawaited(_runMusic()));
  }

  /// 进程内，重启就忘。
  ///
  /// 忘了也不要紧：[NudgeService] 那道闸是拿**盘里的**「上次说话时间」算的，
  /// 重启之后照样压得住。这个只是提前一步——连模型都不调。
  static DateTime? _lastMusicRun;

  /// 音乐那条路现在开不开。纯的，好测。
  ///
  /// ⚠️ 这道闸挡的不是「说不说话」，是**「白调一次模型」**。[decideNudge] 里
  /// 那条 `minGapForMusic` 是它的下游，可那条只有等模型读完 prompt 回了「不说」
  /// 才会发现「间隔不够」——而钱已经花了。一次换歌就够一次 API，一个下午几十
  /// 次，那笔钱该在这儿省下来。
  ///
  /// 所以两道都要：这儿管「别问」，那儿管「别说」，两件事。
  static bool shouldAskAboutMusic(
    DateTime now,
    DateTime? last, {
    required Duration gap,
  }) => last == null || now.difference(last) >= gap;

  /// 换歌之后真去看一眼「要不要说句话」。
  static Future<void> _runMusic() async {
    final now = DateTime.now();
    try {
      final prefs = await NudgeService.loadPrefs();
      if (!prefs.enabled) return;
      if (!shouldAskAboutMusic(now, _lastMusicRun, gap: prefs.minGapForMusic)) {
        return;
      }
      _lastMusicRun = now;

      final client = await buildStoredAiClient();
      if (client == null) return;

      // ⚠️ 和 [_runLocal] 那条路**不一样**：那条一定是前台的（她刚切回来），
      // 这条两种都可能。App 退到后台而进程还活着是很常见的情形——那正是她
      // 在听歌的时候。所以这儿得现问一句。
      //
      // 前台不弹通知：为一条她马上就能看到的对话消息再弹一条，是噪音。
      final foreground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      await NudgeService.run(
        aiClient: client,
        scope: NudgeScope.musicOnly,
        notify: !foreground,
      );
    } catch (e) {
      debugPrint('[nudge] 换歌这次没跑成：$e');
    }
  }

  /// 上一次在前台跑是什么时候。**进程内的，重启就忘**——冷启动本来就会跑一次，
  /// 忘掉正好对上。
  static DateTime? _lastLocalRun;

  /// 两次前台检查之间至少隔多久。
  ///
  /// 不是怕它话多（门槛管那个），是怕**掉帧**：每次都要读信、日记、对话列表，
  /// 全在主 isolate 上。而她复制个验证码切出去再回来就是一次 resumed，
  /// 一天几十次——没有这道闸，那就是几十次文件遍历。
  static const _localGap = Duration(minutes: 30);

  /// 纯的，好测：[last] 是上次跑的时间，null = 没跑过。
  static bool shouldRunLocally(DateTime now, DateTime? last) =>
      last == null || now.difference(last) >= _localGap;

  /// **不弹通知**（`notify: false`）：人已经在 App 里了，为一条马上就能看到的
  /// 消息再弹一条通知是噪音。话照样落进对话，她翻到就看见。
  static Future<void> _runLocal({required Duration settle}) async {
    final now = DateTime.now();
    if (!shouldRunLocally(now, _lastLocalRun)) return;
    _lastLocalRun = now;
    try {
      // ⚠️ 让界面先画完。
      //
      // 这条路要读文件、可能还要调模型，全在主 isolate 上。跟首屏抢会直接掉帧，
      // 而它一点都不急——攒下的事晚几秒说没有任何区别。
      await Future.delayed(settle);

      final prefs = await NudgeService.loadPrefs();
      if (!prefs.enabled) return;
      final client = await buildStoredAiClient();
      if (client == null) return;
      await NudgeService.run(aiClient: client, notify: false);
    } catch (e) {
      debugPrint('[nudge] 前台这次没跑成：$e');
    }
  }
}

/// 后台 isolate 的入口。
///
/// ⚠️ 三条都不能少，少一条就是「装上之后永远不响，也没有报错」：
///
/// 1. **顶层函数**——要能被 `PluginUtilities.getCallbackHandle` 拿到句柄，
///    类的静态方法不行
/// 2. **`@pragma('vm:entry-point')`**——release 构建下没有它会被 tree-shake
///    掉，debug 下却是好的，所以这个坑只在装了正式包之后才现形
/// 3. **一律 `return true`**——返回 false 会让 WorkManager 认为任务失败并按
///    退避策略重试。而「他没什么想说的」是正常结果，不是失败，重试只会浪费
///    唤醒次数
@pragma('vm:entry-point')
void nudgeCallbackDispatcher() {
  // executeTask 内部已经做了 WidgetsFlutterBinding 和 DartPluginRegistrant
  // 的初始化，所以这里能直接用 SharedPreferences、通知插件这些。
  Workmanager().executeTask((task, inputData) async {
    try {
      // ⚠️ 后台引擎不走 main()，StorageService 的目录没人设。
      //
      // 原来这里没有这一句：`lastChatAt` / 写进对话 / 列信和日记，全部碰到
      // 没初始化的 `_dir` 就抛——于是后台醒来那条路要么记成「出错了」，要么
      // 被各处的 catch 吞掉、候选收不上来。前台那两条入口有 main() 兜着，
      // 所以一直没看出来。2026-09-15 接「看一眼屏幕」时发现的：截到的图
      // 也要靠这里设好的 ChatImages.dirPath 才存得下。
      await StorageService.init();
      // 「看一眼屏幕」被系统停掉之后不会自己接回来，她不去设置页就不知道。
      // 放在开关判断前面：主动说话关着，看一眼断了也该说。
      await GlanceHealth.notifyIfBroken();
      final prefs = await NudgeService.loadPrefs();
      if (!prefs.enabled) {
        await NudgeService.noteRun('醒了，但主动说话是关着的');
        return true;
      }

      final client = await buildStoredAiClient();
      if (client == null) {
        // 最可疑的一条：密钥存在 keystore（flutter_secure_storage）里，
        // 后台 isolate 读不读得到不一定。读不到就等于没配模型。
        await NudgeService.noteRun('醒了，但读不到模型配置（后台拿不到密钥？）');
        return true;
      }

      // 排在推送前面：到点的信在这一轮就写出来，紧接着它自己就成了候选。
      // 「我刚写完一封信」这句话第一次能在真的刚写完的时候说出口——
      // 前提就是写这个动作发生在她不看手机的时候。
      await LetterSchedule.writeIfDue(aiClient: client);

      await NudgeService.run(aiClient: client);
    } catch (e) {
      // 后台里抛出去没人接得住，而且会被系统记成任务失败触发重试。
      // debugPrint 在这里是白写的：国产 ROM 封了非调试包的 logcat，
      // 所以异常也要落到那行记录上，否则又是一次「什么都看不见」。
      debugPrint('[nudge] 后台这次没跑成：$e');
      await NudgeService.noteRun('醒了，但出错了：$e');
    }
    return true;
  });
}
