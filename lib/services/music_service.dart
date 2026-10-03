import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'listen_log.dart';

/// 「两个人一起听歌」的 Dart 这一头：现在在放什么、刚发生了什么。
///
/// ## 它是缓存，不是真相源
///
/// 真相在原生那边（`MusicListenerService` 读系统媒体会话）。这里做两件事：
/// **接住原生推过来的事件**，以及**把最后一首已知的歌存起来**。
///
/// 后者不是优化，是前提。两个原因：
///
/// 1. 原生那边实测过——网易云停止播放后会把元数据清空（歌名歌手全没），
///    会话却还活着。原生用 `lastTrack` 兜了一层，这里再存一层，因为
/// 2. **原生那层也会没**：进程整个被杀之后，`MusicBridge` 那个静态单例跟着
///    一起死。用户下次打开 App，界面上至少该显示「上次在听」而不是一片空白。
///
/// ## 为什么是 ChangeNotifier
///
/// [AppUsage] / [ScreenGlance] 那种全静态的写法够用，因为它们是「问一次、
/// 拿一次」。音乐是要**挂在界面上实时变**的：用户切歌，聊天页顶部那条得跟着
/// 变。所以这里是个挂在 Provider 树上的单例。
///
/// ⚠️ 但它**只在主 isolate 里存在**。后台那个 workmanager isolate 拿不到它
/// （Provider 树是主 isolate 的），所以第三期让 AI 主动开口时，那段代码
/// **只能读 SharedPreferences，不能碰这个类**。
class MusicService extends ChangeNotifier {
  MusicService._();

  static final MusicService instance = MusicService._();

  static const _channel = MethodChannel('music_session');

  /// 最后一首已知的歌。原生没了之后靠它兜底，见类注释。
  static const _kLastTrack = 'music_last_track';

  /// 最近的事件留多少条。够界面显示「刚才听了什么」，也不至于无限涨。
  static const _keepEvents = 30;

  NowPlaying? _now;

  /// 现在在放什么。null = 还没收到过任何东西（没授权 / 没在放歌 / 刚装上）。
  NowPlaying? get now => _now;

  bool _granted = false;

  /// 「通知使用权」开了没。
  ///
  /// 和 `AppUsage.hasPermission` 一样**不缓存**——用户可能随时在系统设置里
  /// 收回，而 App 这边不会收到任何通知。
  bool get granted => _granted;

  final _events = <MusicEvent>[];

  /// 刚真的发生过的事（换歌、播放状态变了），新的在前。
  List<MusicEvent> get recent => List.unmodifiable(_events);

  bool _listening = false;

  bool _live = false;

  /// 原生那边现在有没有一个**活着的**播放器会话。
  ///
  /// 和「[_now] 是不是空的」是两件事，界面必须分得开。[_now] 里那首有可能是
  /// 从盘里捡回来的「上次在听」（[_warmUpFromDisk]），也可能播放器早就被关了
  /// ——会话没了之后 [_now] 是**故意保留**的（见 [_refresh]），不然用户暂停
  /// 一会儿再回来界面上就一片空白。
  ///
  /// 所以「要不要挂那条悬浮的『一起听』」只能看这个，不能看 [_now]（见
  /// [showMiniPlayer]）。
  ///
  /// 注意它是**只进不出**的：一旦读到过真实会话就是 true，直到原生报 `gone`
  /// 才翻回 false。中间那些「读到的是空元数据」的时刻不算——那正是网易云暂停
  /// 之后的样子。
  bool get live => _live;

  /// 现在有没有东西可显示。
  bool get ready => _granted && _now != null;

  /// 现在**有声音出来没有**——在放，或者正在缓冲。
  ///
  /// [PlaybackState.buffering] 必须算「在放」：网易云正常播着的时候就在
  /// `playing` / `buffering` 之间来回跳（流水里那两条是交替出现的），把缓冲
  /// 排除掉的话，那条悬浮条会跟着一下一下地闪。
  ///
  /// 反过来 `paused` / `stopped` / `none` 都不算：暂停了就是没在放。
  /// [PlaybackState.none] 还多担一层——[warmUpFromDisk] 捡回来的「上次在听」
  /// 就是这个状态，它当然不该让悬浮条冒出来。
  bool get _audible =>
      _now != null &&
      (_now!.state == PlaybackState.playing ||
          _now!.state == PlaybackState.buffering);

  /// 有没有一个活着的播放器（在放、暂停都算），也就是「她当前在听的那首
  /// 是什么」还说不说得清。
  ///
  /// 判据是 [live] 而不是 [ready]：`ready` 只问「手里有没有一首歌」，而盘里
  /// 捡回来的「上次在听」也算有。播放器早关了还说得出「她在听这首」，是假的。
  ///
  /// ⚠️ **这个和 [showMiniPlayer] 是两件事，别合并**。给 AI 注入
  /// `[now_playing: ...]` 用的是这个：她按了暂停，那首歌**还是她在听的那首**，
  /// 模型理应知道；可悬浮条这时候已经收回去了。
  bool get hasLivePlayer => _live && _now != null;

  /// 该不该把悬浮播放条挂出来。
  ///
  /// **只在真的在放的时候挂**（见 [_audible]）：暂停了就收回去，别在屏幕上留
  /// 一条「暂停中的歌」占地方——用户原话是「没有放音乐的时候可以隐藏一下，
  /// 放音乐的时候拿出来就好了」。要看那首歌（进「一起听」整页）仍然可以走
  /// 设置里那一行。
  bool get showMiniPlayer => hasLivePlayer && _audible;

  /// 她**正在看**的那段对话。
  ///
  /// 悬浮播放条挂在 App 那一层，不属于任何一段对话；可它点开的「一起听」要画
  /// 两个头像，得知道另一边是谁。所以由 ChatScreen 每次建的时候放一次。
  /// 和 `SelfNoteTool.currentConversationId` 同一个理由：工具/浮层拿不到调用现场。
  ///
  /// 故意是个裸字段：改它**不发通知**（它不是「状态变了」，是「她换页了」），
  /// 用到它的那一刻现读就行。
  String? activeConversationId;

  /// 正在累积的那一首（三期用）。
  ///
  /// 和 [_now] 的区别：[_now] 是**给界面看的当前状态**，一直是最新那首；这个是
  /// **记流水用的**，一首歌走完（或者播放器没了）才收尾写进 [ListenLog]。
  /// 没有它的话，事件流里剩下的只有「开始放《X》」，而「听 10 秒切走」和
  /// 「听完整首」在那里面长得一模一样——正是三期要分的那件事。
  OpenListen? _open;

  /// 换了首歌的时候叫一声。三期拿它去触发「要不要开口」的评估。
  ///
  /// 做成一个**可空回调**而不是直接让 `nudge_scheduler` 监听这个
  /// ChangeNotifier：监听的话它得自己从事件流里认出「这次是换歌不是改状态」，
  /// 而这里本来就知道。也避免 music_service 反过来 import nudge 那一摊。
  ///
  /// 只在 `announce && !same` 的那一支叫——第一次同步（`announce: false`）不叫，
  /// 那不是「有事发生」。
  void Function()? onTrackChanged;

  bool _pageOpen = false;

  /// 「一起听」整页现在开着没有。
  ///
  /// 开着的时候悬浮条要让开——同一件事在一屏上说两遍是噪音，而且那一页有更大
  /// 的封面和能拖的进度条，那条细的只会挡着它。**这个标记只能放在这儿**：
  /// 悬浮条要读它，那一页要写它，两边都已经 import 了 MusicService，另立一个
  /// notifier 会让 `music_screen.dart` 和 `music_float.dart` 互相 import。
  bool get pageOpen => _pageOpen;

  void setPageOpen(bool v) {
    if (_pageOpen == v) return;
    _pageOpen = v;
    notifyListeners();
  }

  /// 冷启动、回前台都调一次。可以重复调，不会重复挂 handler。
  Future<void> start() async {
    _granted = await hasPermission();
    if (!_granted) {
      // 权限被收回了（用户随时可能在系统设置里关掉，而 App 收不到任何通知）。
      // 浮着的那条也得跟着消失——留着一条按不动的「一起听」比没有更糟：
      // 它会一直显示一首早就不在放的歌，而按钮全是哑的。
      _live = false;
      notifyListeners();
      return;
    }

    if (!_listening) {
      _channel.setMethodCallHandler(_onCall);
      _listening = true;
    }

    // 授权是开着的，可原生那份监听服务**不一定被绑上了**。强停（ColorOS 上
    // 从最近任务划掉、装完新包）会把整个进程连服务一起抹掉，而系统此后不会
    // 自己重绑——授权还在，就是没人读得到会话。见原生 `ensureBound` 的注释。
    //
    // 放在这儿而不是 `start()` 开头：没授权时这一步没有意义，也不该做（那会
    // 把「还没同意」和「同意了但没绑上」搅成一件事）。**不必等它**——它只是
    // 给系统递个话；绑上之后原生会主动推一次当前状态过来。
    unawaited(_ensureBound());

    // 顺手把前台服务拉起来，**趁 App 还在前台**——这是唯一合法的时机。
    //
    // 为什么非要它：ColorOS 会在 App 切到后台几分钟后冻住整个进程，
    // `MediaController.Callback` 的 binder 投递全停（判据是恢复时没有任何
    // 重连日志）。而她听歌时人在 QQ音乐，Nook 正在后台——换歌事件根本到不了
    // 这儿。前台服务把进程抬到 PERCEPTIBLE_APP_ADJ，直接掉出冻结器的范围。
    //
    // ⚠️ 位置很讲究：**必须排在上面那两个 await 之前**。_drain / _refresh
    // 各带 3 秒超时，排在它们后面最坏会拖到 resumed 之后 6 秒——那时她可能
    // 已经切走了，而 Android 12+ 不许从后台启动前台服务。
    unawaited(_ensureKeepAlive());

    // 先把攒下的补齐（进程被杀那段时间的事件全在这儿），再要一份当前的。
    //
    // 顺序不能反：历史事件是**只进流水**的，碰不到 `_now`；要是反过来，
    // 刚拿到的当前状态会被随后灌进来的旧事件盖掉。
    await _drain();
    await _refresh();
  }

  /// 见 [start] 里那段注释。失败不吭声——它不是她能做的事，报了也只是噪音；
  /// 真绑不回来的时候，界面照旧显示「没在放歌」以外什么都不缺。
  Future<void> _ensureBound() async {
    try {
      await _channel
          .invokeMethod<bool>('ensureBound')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // 不是安卓、老版本原生没有这个方法、通道卡住——都当没有这一步。
    }
  }

  /// 见 [start] 里那段注释。和 [_ensureBound] 一个口径：失败不吭声——
  /// 拉不起来前台服务不是她能处理的事，报了只是噪音。最坏的结果是回到加它
  /// 之前的样子（后台被冻住），而不是功能坏掉。
  Future<void> _ensureKeepAlive() async {
    try {
      await _channel
          .invokeMethod<bool>('keepAlive')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // 不是安卓、老版本原生没有这个方法、通道卡住——都当没有这一步。
    }
  }

  /// 停止监听（热重载、测试里用）。
  Future<void> stop() async {
    if (_listening) {
      _channel.setMethodCallHandler(null);
      _listening = false;
    }
  }

  // ---------------- 权限 ----------------

  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 不是安卓
    }
  }

  /// 送用户去开权限。先去我们这一份服务的详情页，打不开才退到整张列表。
  static Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  // ---------------- 控制 ----------------

  /// 发一个控制给播放器。**返回 null 表示发出去了**，否则是一句给人看的原因。
  ///
  /// 能发的动作：`play` / `pause` / `play_pause` / `next` / `previous` /
  /// `seek`——seek 要带 [position]。
  ///
  /// ## 为什么发完就先把界面改掉
  ///
  /// 播放器不一定会为这次操作重新发布 `PlaybackState`。网易云实测只在**曲目
  /// 边界**发布，按了暂停它可能一声不吭。要是等它回话，按下去界面上还写着
  /// 「在放」——看着就是按钮坏了，而其实是播放器没回执。
  ///
  /// 所以**已经要求它跳到 X 了，就先按 X 显示**；它下次真发布时会把我们纠正
  /// 回来。原生那边同时也隔 500ms 主动读一次（`MusicBridge.control`），两条
  /// 路合起来才不会出现「按了没反应」。
  Future<String?> control(String action, {Duration? position}) async {
    Map<String, dynamic>? map;
    try {
      map = await _channel
          .invokeMapMethod<String, dynamic>('control', {
            'action': action,
            if (position != null) 'positionMs': position.inMilliseconds,
          })
          // 平台通道卡住的话没有任何东西会叫醒它，症状是「点了按钮没反应」，
          // 而且看不出跟音乐有关。和 [_snapshot] 同一个理由。
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return '没能把控制递到原生那一层。';
    }
    if (map == null) return '原生没有回应。';
    if (map['success'] != true) {
      final e = '${map['error'] ?? ''}';
      return e.isEmpty ? '没控制成功。' : e;
    }

    _applyLocally(action, position);
    return null;
  }

  /// 按「我们刚要求它做的事」更新本地状态。理由见 [control]。
  ///
  /// 只认得出结果的那几个动作——`next` / `previous` 换出来的是哪首**不知道**，
  /// 只能等播放器报上来，所以这里什么都不做。
  void _applyLocally(String action, Duration? position) {
    final now = _now;
    if (now == null) return;

    PlaybackState? state;
    Duration? pos;
    if (action == 'play') {
      state = PlaybackState.playing;
    } else if (action == 'pause') {
      state = PlaybackState.paused;
    } else if (action == 'play_pause') {
      state = now.state.isPlaying ? PlaybackState.paused : PlaybackState.playing;
    } else if (action == 'seek') {
      pos = position;
      // 往前拖才算「跳」。往后拖是重听，记进去只会让模型以为她在乱跳。
      //
      // 起点用 `livePosition` 而不是 `now.position`：后者是原生**读的那一刻**
      // 的值，而网易云整首歌只报一次位置，直接拿来当起点会把拖拽量算大一截。
      final target = position;
      if (target != null) {
        _open?.seeked(from: now.livePosition, to: target);
      }
    }
    if (state == null && pos == null) return;

    _now = NowPlaying(
      track: now.track,
      state: state ?? now.state,
      position: pos ?? now.position,
      actions: now.actions,
      at: DateTime.now(),
    );
    // 让「正在累积的那一首」也跟上：拖完如果她马上切歌，收尾读到的得是拖过去
    // 之后的位置。
    final updated = _now!;
    _open?.saw(
      position: updated.position,
      at: updated.at,
      playing: updated.state.isPlaying,
    );
    notifyListeners();
  }

  // ---------------- 和原生打交道 ----------------

  /// 原生反向推过来的事件。
  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'onMusicEvent') return;
    final map = _asMap(call.arguments);
    if (map == null) return;
    _absorbCurrent(map);
  }

  /// 拉一次当前状态。
  Future<void> _refresh() async {
    final map = await _snapshot();
    // null = 原生说「现在没有任何会话」。可能是真没在放歌，也可能是服务没
    // 连上。**什么都不做，尤其不清空 `_now`**——和原生那边同一个道理：用户
    // 暂停一会儿、或者进程被系统杀了重启，界面上维持最后一首比突然变空白好。
    if (map == null) return;
    // 第一次同步**不记流水**：那不是「有事发生」，只是「我们刚连上」。
    // 不这么分的话，每开一次 App，「它看到的」里就多一条「开始听《X》」——
    // 开二十次二十条，而用户什么也没做。
    //
    // 注意判据是 `_now == null` 而**不是**「第一次调 _refresh」：warmUpFromDisk
    // 可能已经从盘里捡回一首了，那种情况下这一趟是真有可能在报「换了首歌」的
    // （盘里那首 → 现在这首），该记。
    _absorbCurrent(map, announce: _now != null);
  }

  Future<Map<String, dynamic>?> _snapshot() async {
    try {
      return await _channel
          .invokeMapMethod<String, dynamic>('snapshot')
          // 平台通道卡住的话没有任何东西会叫醒它，症状是界面干等——而且看不出
          // 跟音乐有关。和 AppUsage.query / ScreenGlance._invoke 同一个理由。
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  /// 取走攒下的事件。**取走即清**——所以失败就当没有，不能重试。
  Future<void> _drain() async {
    final List<dynamic> raw;
    try {
      raw =
          await _channel
              .invokeMethod<List<dynamic>>('takeEvents')
              .timeout(const Duration(seconds: 3)) ??
          const [];
    } catch (_) {
      return;
    }
    if (raw.isEmpty) return;
    // 反过来放：原生的 pending 是先进先出，而 _events 新的在前。
    for (final e in raw.reversed) {
      final map = _asMap(e);
      if (map != null) _absorbHistorical(map);
    }
    notifyListeners();
  }

  /// 吃一份**当前状态**（原生推来的，或者 snapshot 拉来的）。
  ///
  /// 会更新 `_now`，并在「换了歌」或「播放状态变了」时记一条事件。
  ///
  /// [announce] = false 时只更新状态、不记流水，用于第一次同步（见 [_refresh]）。
  void _absorbCurrent(Map<String, dynamic> map, {bool announce = true}) {
    final at = _ms(map['at']);

    if ('${map['type']}' == 'gone') {
      // 会话真没了。**保留 `_now`**——见 _refresh 的注释。只记一条。
      //
      // 先翻 _live 再通知：ListenableBuilder 是标脏、下一帧才重建，但
      // 「先改值后通知」是这个类里所有地方的定式，破例迟早出事。
      _live = false;
      // 播放器整个消失，手上这一首就永远等不到「下一首」来给它收尾了。
      // 不在这儿补一刀的话，从最后一次换歌到她关播放器之间那首歌会凭空
      // 消失——而那首歌可能正是她听得最久的一首。
      _closeListen(at: at, end: ListenEnd.unknown);
      if (announce) {
        _push(MusicEvent(type: MusicEventType.gone, at: at));
      } else {
        notifyListeners();
      }
      return;
    }

    _live = true;
    final track = _trackOf(map);
    final state = PlaybackState.parse('${map['state'] ?? ''}');
    final pos = Duration(milliseconds: _int(map['positionMs']));

    // 先记下上一首再改 `_now`——顺序反了的话，事件里的 previous 会变成
    // 新歌自己，界面上就成了「《B》→《B》」。
    final prevTitle = _now?.track.title;
    final prevState = _now?.state;

    // 元数据被清空时原生会把上一首回传过来并打上 stale。那种不该算「换了
    // 一首歌」——否则每暂停一次，流水里就多一条假的换歌记录。
    final same = track.sameAs(_now?.track);

    _now = NowPlaying(
      track: track,
      state: state,
      position: pos,
      actions: _int(map['actions']),
      at: at,
    );

    if (announce && !same) {
      // ⚠️ 顺序不能反：**先给上一首收尾，再给新歌开头**。反过来的话
      // `_open` 已经换成新歌了，收尾收到的就是刚开的那一首。
      _closeListen(at: at);
      _openListen(track, at: at, position: pos, playing: state.isPlaying);
      _push(
        MusicEvent(
          type: MusicEventType.track,
          at: at,
          track: track,
          previous: prevTitle,
        ),
      );
      // 换歌是实时发生的事，三期要趁热评估。防抖在 nudge_scheduler 那一层
      // ——连切五首歌该塌缩成一次，不是五次。
      onTrackChanged?.call();
    } else {
      // 同一首：把进度记上，收尾时判断「是不是真放完了」要用它。
      //
      // `_open == null` 是冷启动：盘里捡回来的那首和现实里的是同一首，于是
      // 从来没人给它开过头（第一次同步走的是 `announce: false` 或者 `same`）。
      // 补开一个，不然这首歌整个漏掉。
      final open = _open;
      if (open == null) {
        _openListen(track, at: at, position: pos, playing: state.isPlaying);
      } else {
        open.saw(position: pos, at: at, playing: state.isPlaying);
      }

      if (announce && state != prevState) {
        _push(
          MusicEvent(type: MusicEventType.state, at: at, track: track, state: state),
        );
      } else {
        // 状态确实更新了（进度动了，或者这是第一次同步），得让界面重画——
        // 但**不记流水**，那会把「它看到的」刷满没有信息量的条目。
        notifyListeners();
      }
    }

    unawaited(_remember(track));
  }

  /// 给一首歌开头，开始累积它的一生。
  void _openListen(
    MusicTrack track, {
    required DateTime at,
    required Duration position,
    required bool playing,
  }) {
    // 没歌名的不记。收尾时 [OpenListen.close] 也会再挡一次，但留在这儿能
    // 省掉一个对象——播放器报空元数据的那段时间里这个函数会被叫很多次。
    if ((track.title ?? '').isEmpty) return;
    _open = OpenListen(
      package: track.package,
      title: track.title,
      artist: track.artist,
      duration: track.duration,
      // **倒推**开头，不是「我们注意到它的那一刻」：冷启动时歌可能已经放到
      // 一半了，那会儿记的 `startedAt` 会让这首歌看着只听了十几秒。
      startedAt: at.subtract(position),
    )..saw(position: position, at: at, playing: playing);
  }

  /// 给上一首收尾，写进听歌流水。
  ///
  /// [end] 给定就照它记（播放器消失那种），没给就按进度和时长归档。
  void _closeListen({required DateTime at, ListenEnd? end}) {
    final open = _open;
    _open = null;
    if (open == null) return;
    final entry = open.close(at: at, end: end);
    // 存盘是 fire-and-forget：她切歌的这一刻不该等一次磁盘写。写失败也只是
    // 少一条记录（[ListenLog.add] 自己吞），不影响放歌。
    if (entry != null) unawaited(ListenLog.add(entry));
  }

  /// 吃一份**历史事件**（drain 出来的）。
  ///
  /// 只进流水 + 更新「上次在听」，**不碰 `_now`**。理由在 [start] 里。
  ///
  /// ⚠️ **它也不进听歌流水**（[ListenLog]），这是有意的。攒下的那些事件是进程
  /// 被杀那段时间的，看着正好是「她在我不知道的时候听了什么」，可它们没有
  /// 「上一首什么时候结束的」——那要按事件之间的间隔去猜，而 [_drain] 后面紧跟着
  /// 的 [_refresh] 会推一份**当前状态**上来，猜出来的那一首会被接上一条假的结尾。
  ///
  /// 代价是**一个过渡会漏掉**：进程被杀期间听的那几首，AI 不会知道。它的后果
  /// 只是「这次没什么可说的」，不是「说错了」——而说错了要贵得多。
  void _absorbHistorical(Map<String, dynamic> map) {
    if ('${map['type']}' == 'gone') {
      _push(MusicEvent(type: MusicEventType.gone, at: _ms(map['at'])), notify: false);
      return;
    }
    final track = _trackOf(map);
    _push(
      MusicEvent(
        type: MusicEventType.track,
        at: _ms(map['at']),
        track: track,
        state: PlaybackState.parse('${map['state'] ?? ''}'),
      ),
      notify: false,
    );
    unawaited(_remember(track));
  }

  void _push(MusicEvent e, {bool notify = true}) {
    _events.insert(0, e);
    while (_events.length > _keepEvents) {
      _events.removeLast();
    }
    if (notify) notifyListeners();
  }

  MusicTrack _trackOf(Map<String, dynamic> map) => MusicTrack(
    package: '${map['package'] ?? ''}',
    title: _str(map['title']),
    artist: _str(map['artist']),
    album: _str(map['album']),
    duration: _duration(map['durationMs']),
    stale: map['stale'] == true,
  );

  // ---------------- 落盘 ----------------

  /// 把最后一首**有名字的**歌写进盘。
  ///
  /// 只在 title 非空时写：`stale` 的快照里 title 是原生缓存的值，写进去也
  /// 不算错；真正要防的是「进程重启后什么都没了」。
  Future<void> _remember(MusicTrack t) async {
    if ((t.title ?? '').isEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kLastTrack, t.encode());
    } catch (_) {
      // 存不下就算了，不影响当前这一轮显示。
    }
  }

  /// 读回上次那首。
  Future<MusicTrack?> lastKnown() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kLastTrack);
      if (raw == null) return null;
      return MusicTrack.decode(raw);
    } catch (_) {
      return null;
    }
  }

  /// 冷启动时用存下来的那首把界面填上，免得空等原生。
  ///
  /// **不改 `_granted`**——这是「我们记得什么」，不是「它现在知道什么」。
  /// 界面上要区分得开：记得的那首标 `stale`，看着就是「上次在听」而不是
  /// 「现在在放」。
  Future<void> warmUpFromDisk() async {
    if (_now != null) return;
    final t = await lastKnown();
    if (t == null) return;
    // ⚠️ 读完盘**再查一次**。`lastKnown()` 是异步的，这中间 [start] 可能
    // 已经把真正的当前曲目填进来了——不查的话，这里会用盘里那首旧的把它
    // 盖掉，还标着 stale，界面上就成了「明明在放歌，却显示上次在听》。
    if (_now != null) return;
    _now = NowPlaying(
      track: t.copyWith(stale: true),
      state: PlaybackState.none,
      position: Duration.zero,
      actions: 0,
      at: DateTime.now(),
    );
    notifyListeners();
  }
}

// ---------------- 数据 ----------------

enum PlaybackState {
  playing,
  paused,
  buffering,
  stopped,
  none;

  static PlaybackState parse(String raw) => switch (raw) {
    'playing' => PlaybackState.playing,
    'paused' => PlaybackState.paused,
    'buffering' => PlaybackState.buffering,
    'stopped' => PlaybackState.stopped,
    _ => PlaybackState.none,
  };

  bool get isPlaying => this == PlaybackState.playing;

  String get label => switch (this) {
    PlaybackState.playing => '在放',
    PlaybackState.paused => '暂停',
    PlaybackState.buffering => '缓冲中',
    PlaybackState.stopped => '停了',
    PlaybackState.none => '未知',
  };
}

class MusicTrack {
  final String package;
  final String? title;
  final String? artist;
  final String? album;

  /// null = 播放器没报时长（**不是**零长）。
  final Duration? duration;

  /// 这条信息是从缓存来的——元数据被清空了，原生拿上一首顶上的。
  final bool stale;

  const MusicTrack({
    required this.package,
    this.title,
    this.artist,
    this.album,
    this.duration,
    this.stale = false,
  });

  MusicTrack copyWith({bool? stale}) => MusicTrack(
    package: package,
    title: title,
    artist: artist,
    album: album,
    duration: duration,
    stale: stale ?? this.stale,
  );

  bool sameAs(MusicTrack? other) {
    if (other == null) return false;
    if (package != other.package) return false;
    // 只比 title。同一首歌的两个版本（remaster / live）会共用一个 title 但
    // duration 不同——那种当「同一首」比当「换歌了」更接近用户的感受。
    //
    // ⚠️ **这条成立的前提是 `title` 真的是歌名**，而它会假——原生那边读的是
    // 媒体会话的 `METADATA_KEY_TITLE`，QQ音乐 播放中往那一栏里写的是**滚动
    // 歌词**（1–3 秒换一句），于是每一句歌词都会走到「换了首歌」那一支，
    // 听歌流水被假记录刷满。现在那条路由 `MusicBridge.noticeFor` 兜住了：
    // 原生侧优先用播放器自己通知里的歌名，会话那一份只在读不到通知时才用。
    //
    // 所以这里的判据本身没改，改的是**上游喂进来的东西**。哪天要动
    // `noticeFor`，先回来看一眼这段。
    return title == other.title;
  }

  /// 界面上那一行。
  String get display {
    final t = title ?? '';
    final a = artist ?? '';
    if (t.isEmpty && a.isEmpty) return '未知曲目';
    if (t.isEmpty) return a;
    if (a.isEmpty) return t;
    return '$t · $a';
  }

  /// 落盘用。
  ///
  /// 用 `\u0001` 分隔的裸字符串而不是 JSON 编整个 map：JSON 的话，以后加字段
  /// 时旧数据解不出来会**抛异常**，而这里解不出来只是少几个字段。歌名里有
  /// 竖线、冒号、引号的都有，所以分隔符挑了个控制字符——正常文本里不会有。
  String encode() => [
    package,
    title ?? '',
    artist ?? '',
    album ?? '',
    '${duration?.inMilliseconds ?? ''}',
  ].join('\u0001');

  static MusicTrack? decode(String raw) {
    final parts = raw.split('\u0001');
    if (parts.length < 2) return null;
    final ms = int.tryParse(parts.length > 4 ? parts[4] : '');
    return MusicTrack(
      package: parts[0],
      title: parts[1].isEmpty ? null : parts[1],
      artist: parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null,
      album: parts.length > 3 && parts[3].isNotEmpty ? parts[3] : null,
      duration: ms == null ? null : Duration(milliseconds: ms),
    );
  }
}

class NowPlaying {
  final MusicTrack track;
  final PlaybackState state;
  final Duration position;

  /// 原生报上来的 `PlaybackState.actions` 位掩码。第二期判断「这个播放器支不
  /// 支持快进」就靠它（`SEEK_TO` 是 256）。
  final int actions;

  final DateTime at;

  const NowPlaying({
    required this.track,
    required this.state,
    required this.position,
    required this.actions,
    required this.at,
  });

  /// 这个播放器支不支持快进。网易云实测 `actions=822`，那一位是有的。
  bool get canSeek => actions & 256 != 0;

  bool get canSkipNext => actions & 32 != 0;
  bool get canSkipPrev => actions & 16 != 0;

  /// 播放器**什么都没报**。有些 App（尤其是网页套壳的）`actions` 是 0。
  ///
  /// 界面上这个要单独判：不能拿「没报」当成「不支持」，那样按钮会一律变灰，
  /// 而其实点了能用。宁可让它点下去、失败时说一句。
  bool get actionsUnknown => actions == 0;

  /// **此刻**的进度。
  ///
  /// [position] 是原生**读的那一刻**的值，不是个会自己走的活值——原生只在换歌
  /// 和状态变化时推事件，中间不推。直接拿它渲染，进度条就只在事件来的那一下
  /// 跳一格。外推的算法和原生 `MusicBridge.positionOf` 是同一个：读到的位置
  /// ＋从那以后流逝的时间。
  ///
  /// 注意用的是 [at]（原生读的那一刻）而不是「上次界面刷新时」——后者会让每次
  /// 重画都把已经走过的时间再算一遍，越推越远。
  Duration get livePosition {
    if (state != PlaybackState.playing) return position;
    final elapsed = DateTime.now().difference(at);
    if (elapsed <= Duration.zero) return position;
    final pos = position + elapsed;
    final total = track.duration;
    // 别越过歌尾——外推过头会让进度条冲到头再弹回来。
    return (total != null && pos > total) ? total : pos;
  }
}

enum MusicEventType { track, state, gone }

class MusicEvent {
  final MusicEventType type;
  final DateTime at;
  final MusicTrack? track;
  final PlaybackState? state;

  /// 换掉的那一首的歌名，用来写「《A》→《B》」。
  final String? previous;

  const MusicEvent({
    required this.type,
    required this.at,
    this.track,
    this.state,
    this.previous,
  });

  /// 给用户看的一行。
  ///
  /// **给模型看的那份要另写**（第三期）——那边得说「只听了几秒就切了」这种
  /// 判断，措辞完全不同，不能共用一个 getter 然后把模型的话带歪。
  String get label => switch (type) {
    MusicEventType.track => previous == null
        ? '开始听《${track?.display ?? "未知"}》'
        : '《$previous》→《${track?.display ?? "未知"}》',
    MusicEventType.state => state?.label ?? '状态变了',
    MusicEventType.gone => '没在放了',
  };
}

// ---------------- 小工具 ----------------

Map<String, dynamic>? _asMap(Object? raw) =>
    raw is Map ? Map<String, dynamic>.from(raw) : null;

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

DateTime _ms(Object? v) => DateTime.fromMillisecondsSinceEpoch(_int(v));

String? _str(Object? v) {
  if (v is! String) return null;
  return v.isEmpty ? null : v;
}

Duration? _duration(Object? v) {
  final n = (v as num?)?.toInt();
  if (n == null || n <= 0) return null;
  return Duration(milliseconds: n);
}
