import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/listen_log.dart';
import 'package:phone_ai_assistant/services/music_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `MusicService` 把原生事件**记成听歌流水**那一段的接线。
///
/// ## 为什么不测就在真机上看看
///
/// 因为这一段的坏法**不报错**：换歌时忘了给上一首收尾，或者收尾时把新歌当成
/// 刚结束的那首——症状是流水里少一条、或者一条歌的时长算成别人的。界面上完全
/// 看不出来，只有等 AI 拿一个错的时长来搭话才发现。而 [_open] 的接线只有几行，
/// 正是「看着对、写错了也不会喊疼」的那一类。
///
/// ## 为什么整个文件只有两个 test
///
/// `MusicService` 是单例，`_open` 和 `_now` 跨 test 不会重置。拆成十几个小 test
/// 的话，后一个会捡到前一个留下的半首歌，断言看着过、其实量的不是它以为的东西。
/// 所以按**时间线**走一遍，一次把该发生的都发生掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('music_session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  var controlResult = <String, dynamic>{'success': true};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ListenLog.resetCacheForTest();
    controlResult = {'success': true};
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'hasPermission':
          return true;
        // ⚠️ 空列表，不是 null。`_drain` 把 null 也当空处理，但返回 null 会让
        // 那个 `?? const []` 变成一次真实的空指针演练——没必要。
        case 'takeEvents':
          return <dynamic>[];
        case 'snapshot':
          return null;
        case 'control':
          return controlResult;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// 从原生推一条事件上来。走的是真 handler（`_onCall`），不是直接调私有方法
  /// ——这样连「handler 挂没挂上」也一起验了。
  Future<void> push(Map<String, dynamic> map) async {
    await messenger.handlePlatformMessage(
      'music_session',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onMusicEvent', map),
      ),
      (_) {},
    );
    // 让 `unawaited(ListenLog.add(...))` 那一路跑完。
    await Future<void>.delayed(Duration.zero);
  }

  Map<String, dynamic> track(
    String title, {
    required DateTime at,
    int? durationMs,
    int positionMs = 0,
    String state = 'playing',
    String? artist,
    String package = 'com.netease.cloudmusic',
  }) => {
    'type': 'current',
    'package': package,
    if (artist != null) 'artist': artist,
    'title': title,
    if (durationMs != null) 'durationMs': durationMs,
    'positionMs': positionMs,
    'state': state,
    'actions': 822,
    'at': at.millisecondsSinceEpoch,
  };

  test('一首歌的一生：切走、听完、播放器消失', () async {
    final t0 = DateTime.now().subtract(const Duration(minutes: 10));
    await MusicService.instance.start();

    // ---- 第一首：听 15 秒就切走 ----------------------------------------
    await push(
      track('起风了', at: t0, durationMs: 325000, artist: '买辣椒也用券'),
    );

    // ---- 第二首：听满整首 ----------------------------------------------
    // ⚠️ 第二首的位置报 0 之后就不动了（网易云的脾气）。收尾时能算出「放完了」
    // 全靠 `OpenListen.positionNow` 那个外推——照抄原生报的数的话，这里会变成
    // 一首「听到 0 秒就换掉」的歌。
    await push(track('第二首', at: t0.add(const Duration(seconds: 15)), durationMs: 240000));

    // ---- 第三首：刚开个头，播放器就没了 ---------------------------------
    await push(
      track('第三首', at: t0.add(const Duration(seconds: 265)), durationMs: 200000),
    );
    await push({
      'type': 'gone',
      'at': t0.add(const Duration(seconds: 285)).millisecondsSinceEpoch,
    });

    final log = await ListenLog.recent();
    expect(log, hasLength(3), reason: '三首各该有一条，不多不少');

    // 新的在前。
    expect(log[0].title, '第三首');
    expect(log[1].title, '第二首');
    expect(log[2].title, '起风了');

    // 听 15 秒切走 → 最强的那个信号
    expect(log[2].end, ListenEnd.skipped);
    expect(log[2].listened, const Duration(seconds: 15));

    // 听满整首 → natural。**这一条是那个外推的验收**。
    expect(log[1].end, ListenEnd.natural);

    // 播放器消失 → 不知道是怎么结束的，不能猜成「切走的」
    expect(log[0].end, ListenEnd.unknown);
    expect(log[0].listened, const Duration(seconds: 20));

    // 登记名带包名，同一首歌只提一次靠它。
    expect(log[2].mentionKey, contains('起风了'));
    expect(log[2].mentionKey, contains('com.netease.cloudmusic'));
  });

  test('往前拖记下来，往后拖不算；没歌名的歌不记', () async {
    // ⚠️ 这条接着上一条的时间线（单例不重置）——所以标题全用新的，
    // 保证它一定是一次「换歌」而不是「同一首」。
    //
    // ⚠️ 起点必须是**现在**，不能是「几分钟前」。seek 的起点用的是
    // `livePosition`（读数 + 从那以后流逝的时间），事件时间放在几分钟前的话，
    // 它会以为这首歌已经放了几分钟，算出来的起点比目标还靠后，于是「往前拖」
    // 被判成「往后拖」——这条测试就白测了，而且是**因为测试自己写错**才绿的。
    final t1 = DateTime.now();
    await push(track('带拖拽的', at: t1, durationMs: 300000));
    // ⚠️ 拖的时候这首歌得还开着。收尾之后再拖，进度就记不上了。
    await MusicService.instance.control('seek', position: const Duration(seconds: 90));
    await MusicService.instance.control(
      'seek',
      position: const Duration(seconds: 30), // 拖回去重听，不该算「跳」
    );
    await push(track('没歌名的', at: t1.add(const Duration(seconds: 40))));
    // 再来一首，把「没歌名的」那一首也推到收尾那一步。
    await push(track('再下一首', at: t1.add(const Duration(seconds: 50))));

    final log = await ListenLog.recent();
    final dragged = log.firstWhere((e) => e.title == '带拖拽的');
    expect(dragged.seekedForward.inSeconds, inInclusiveRange(88, 92));

    // 没报歌名的那一首整条不记——记了只会喂给模型「听了一首没名字的」。
    expect(log.any((e) => e.title == null), isFalse);
  });

  test('控制失败时不留痕迹', () async {
    // 一个反向的确认：原生说没成功，就**不该**往流水里写东西。
    controlResult = {'success': false, 'error': '播放器不认这个动作'};
    final before = (await ListenLog.recent()).length;
    final err = await MusicService.instance.control(
      'seek',
      position: const Duration(seconds: 200),
    );
    expect(err, isNotNull);
    expect((await ListenLog.recent()).length, before);
  });
}
