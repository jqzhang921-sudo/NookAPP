import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/listen_log.dart';
import 'package:phone_ai_assistant/services/music_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 悬浮的「一起听」那条**什么时候在屏幕上、什么时候收回去**。
///
/// ## 为什么要单独测这一个 bool
///
/// 它是两个 getter 之间一道很容易被后来的改动抹平的缝：
///
/// - [MusicService.showMiniPlayer] —— 界面看不看得见那条
/// - [MusicService.hasLivePlayer] —— 给 AI 注入 `[now_playing: ...]` 用不用
///
/// 它们**看起来**像同一件事，2026-09-27 之前也确实是同一个表达式。用户说了
/// 「没放音乐的时候可以隐藏一下，放音乐的时候拿出来就好了」之后才拆开的：
/// 暂停了条要收回去，可那首歌还是她在听的那首，模型理应知道。
///
/// 谁哪天顺手把 `_attachNowPlaying` 改回 `showMiniPlayer`，界面上一片正常、
/// 测试也不会红——除非有这么一个文件钉着。所以这里量的是**两个**，不是一个。
///
/// ## 单例，所以按时间线走一遍
///
/// 同 `music_listen_log_test.dart` 的理由：`MusicService` 是单例，拆成十几个
/// 小 test 的话后一个会捡到前一个留下的状态。一个 test 从头走到尾。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('music_session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ListenLog.resetCacheForTest();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'takeEvents':
          return <dynamic>[];
        case 'snapshot':
          return null;
        case 'control':
          return <String, dynamic>{'success': true};
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> push(Map<String, dynamic> map) async {
    await messenger.handlePlatformMessage(
      'music_session',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onMusicEvent', map),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  Map<String, dynamic> track({
    required String state,
    String title = '起风了',
    String? artist = '买辣椒也用券',
    bool stale = false,
    int durationMs = 325000,
  }) => {
    'type': 'current',
    'package': 'com.netease.cloudmusic',
    if (artist != null) 'artist': artist,
    'title': title,
    if (stale) 'stale': true,
    'durationMs': durationMs,
    'positionMs': 0,
    'state': state,
    'actions': 822,
    'at': DateTime.now().millisecondsSinceEpoch,
  };

  test('在放 / 缓冲中挂着，暂停 / 停了 / 没了就收回去', () async {
    final svc = MusicService.instance;
    await svc.start();

    // ---- 还没有任何会话 -------------------------------------------------
    expect(svc.showMiniPlayer, isFalse, reason: '什么都没有的时候不该凭空挂一条出来');
    expect(svc.hasLivePlayer, isFalse);

    // ---- 在放：两边都真 ------------------------------------------------
    await push(track(state: 'playing'));
    expect(svc.showMiniPlayer, isTrue);
    expect(svc.hasLivePlayer, isTrue);

    // ---- 缓冲中：**条还得挂着** ----------------------------------------
    // 网易云正常播着的时候就在 playing / buffering 之间来回跳。这一条要是
    // 塌了，那条会跟着一下一下地闪——真机上看着像坏了。
    await push(track(state: 'buffering'));
    expect(svc.showMiniPlayer, isTrue, reason: '缓冲中算在放，不然会闪');
    expect(svc.hasLivePlayer, isTrue);

    // ---- 暂停：条收回去，但「她在听这首」还成立 --------------------------
    await push(track(state: 'paused'));
    expect(svc.showMiniPlayer, isFalse, reason: '暂停了就不该再占着屏幕');
    expect(
      svc.hasLivePlayer,
      isTrue,
      reason: '⚠️ 这条是给 AI 注入 now_playing 用的——她没有在放，但听的就是这首',
    );
    expect(svc.now?.track.title, '起风了');

    // ---- 又放起来：回来 -------------------------------------------------
    await push(track(state: 'playing'));
    expect(svc.showMiniPlayer, isTrue, reason: '再按播放要能自己回来');

    // ---- 停了：收回去 ---------------------------------------------------
    await push(track(state: 'stopped'));
    expect(svc.showMiniPlayer, isFalse);

    // ---- 网易云那个坑：暂停后元数据被清空，原生回传带 stale 的上一首 ----
    await push(track(state: 'paused', stale: true, artist: null));
    expect(svc.showMiniPlayer, isFalse);
    expect(svc.now?.track.title, '起风了', reason: '元数据空了也不该把歌名丢给她');

    // ---- 会话整个没了 ---------------------------------------------------
    await push({
      'type': 'gone',
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    expect(svc.showMiniPlayer, isFalse);
    expect(
      svc.hasLivePlayer,
      isFalse,
      reason: '播放器真没了就不能再跟模型说「她正在听」',
    );
    expect(svc.now?.track.title, '起风了', reason: '歌名留着，界面上还有「上次在听」');
  });
}
