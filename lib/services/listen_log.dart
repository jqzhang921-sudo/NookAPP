import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 「她刚才听了什么」——三期让 AI 主动开口的那批原料。
///
/// ## 为什么要有这个，而不是直接拿 `MusicService.recent`
///
/// `MusicService` 记的是**事件**：「开始放《X》了」「状态变成暂停了」。那只够
/// 画界面。要判断「TA 刚才切得很突然」，得知道的是**一首歌她听了多久、怎么结束
/// 的**——同一句「开始放《X》」，听 10 秒切走和听完整首是两件完全不同的事，
/// 而事件流里这两条长得一模一样。
///
/// 所以这里记的是**一首歌的一生**：什么时候开始、听了多久、放到哪儿了、往前
/// 拖过没有、最后是放完的还是被切走的。
///
/// ## 判定不写死
///
/// [ListenEnd] 只做**最粗**的归档（放完了 / 一上来就切 / 听了一半切走），
/// 而且这些字段是**原样喂给模型**的，不是拿去做规则的。用户明确要求不要固定
/// 话术——「听了 12 秒就切」值不值得说一句，由它自己判断。这里只负责别把
/// 事实记错。
///
/// 纯逻辑在这一层（能单测），读写在 [ListenLog]。
enum ListenEnd {
  /// 放完了。
  natural,

  /// 一上来就切走（听了不到 [_skipThreshold]）。
  skipped,

  /// 听了一会儿才换的。
  replaced,

  /// 播放器没了 / 进程被杀，不知道是怎么结束的。
  unknown,
}

/// 「一上来就切」的界线。30 秒是这一块唯一的硬编码数字，它只影响**归档标签**，
/// 不影响要不要开口——那个交给模型。
const _skipThreshold = Duration(seconds: 30);

/// 一首歌听完之后的记录。
class ListenEntry {
  const ListenEntry({
    required this.package,
    this.title,
    this.artist,
    this.duration,
    required this.startedAt,
    required this.endedAt,
    this.position,
    this.seekedForward = Duration.zero,
    this.end = ListenEnd.replaced,
  });

  final String package;
  final String? title;
  final String? artist;

  /// 这首歌本身多长。播放器不报就是 null。
  final Duration? duration;

  final DateTime startedAt;
  final DateTime endedAt;

  /// 结束时放到哪儿了。判断「是不是真放完了」比墙钟靠得住——她中途暂停半小时
  /// 再切走，墙钟算出来听了半小时，而进度还在原地。
  final Duration? position;

  /// 这首歌里她累计往前拖了多少。往后拖不算——那是重听，不是跳。
  final Duration seekedForward;

  final ListenEnd end;

  /// 墙钟上听了多久。**含暂停**，所以它是「这首歌在这段时间里占着播放器」，
  /// 不严格等于「耳朵里响了多久」。文案里用 [position] 说进度、用它说逗留，
  /// 不要拿它当收听时长去下结论。
  Duration get listened => endedAt.difference(startedAt);

  /// 听掉了整首的几分之几。没有时长就不知道。
  ///
  /// 优先用进度算；进度也没有就退回墙钟。两者都缺就是 null——**不编一个数
  /// 出来**，模型看到 null 会自己少说一句，看到假数字会理直气壮地说错。
  double? get playedRatio {
    final d = duration?.inMilliseconds ?? 0;
    if (d <= 0) return null;
    final at = position?.inMilliseconds ?? listened.inMilliseconds;
    return (at / d).clamp(0.0, 1.0);
  }

  /// 这首歌的登记名。同一首歌只提一次（见 nudge_service 的「已经提过」）。
  ///
  /// 带上包名：网易云和 QQ 音乐里各有一首《起风了》，是两件不同的事。
  String get mentionKey =>
      'song:$package:${title ?? ''}:${artist ?? ''}';

  Map<String, dynamic> toJson() => {
    'p': package,
    if (title != null) 't': title,
    if (artist != null) 'a': artist,
    if (duration != null) 'd': duration!.inMilliseconds,
    's': startedAt.millisecondsSinceEpoch,
    'e': endedAt.millisecondsSinceEpoch,
    if (position != null) 'o': position!.inMilliseconds,
    if (seekedForward > Duration.zero) 'f': seekedForward.inMilliseconds,
    'x': end.name,
  };

  /// 解不出来返回 null，不抛。旧版本留下的、或者被人手改坏的一行，不该让
  /// 整个 App 起不来（和 `MusicTrack.decode` 同一个理由）。
  static ListenEntry? decode(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final pkg = m['p'];
      final s = m['s'];
      final e = m['e'];
      if (pkg is! String || s is! int || e is! int) return null;
      return ListenEntry(
        package: pkg,
        title: m['t'] as String?,
        artist: m['a'] as String?,
        duration: _dur(m['d']),
        startedAt: DateTime.fromMillisecondsSinceEpoch(s),
        endedAt: DateTime.fromMillisecondsSinceEpoch(e),
        position: _dur(m['o']),
        seekedForward: _dur(m['f']) ?? Duration.zero,
        end: ListenEnd.values.firstWhere(
          (v) => v.name == m['x'],
          orElse: () => ListenEnd.unknown,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static Duration? _dur(Object? v) =>
      v is int && v > 0 ? Duration(milliseconds: v) : null;
}

/// 归档：这首歌是怎么结束的。
///
/// 纯函数，好测。判据只有两条，而且**顺序不能反**——先判「放完了」，再判
/// 「一上来就切」。反过来的话，一首 20 秒的短歌放到底会被记成「切走的」。
ListenEnd classifyEnd({
  required Duration? position,
  required Duration? duration,
  required Duration listened,
}) {
  // 「放完了」优先看进度：位置到了歌尾 5 秒以内就算。墙钟在这儿不可靠
  // ——暂停过的话它会大出一截。
  if (duration != null && duration > Duration.zero && position != null) {
    if (position >= duration - const Duration(seconds: 5)) {
      return ListenEnd.natural;
    }
  }
  // 进度不知道的时候，只能退到墙钟 + 时长都比过：听够了整首那么久，
  // 多半是放完了（用户没在拖的前提下）。
  if (position == null && duration != null && duration > Duration.zero) {
    if (listened >= duration - const Duration(seconds: 5)) {
      return ListenEnd.natural;
    }
  }
  if (listened < _skipThreshold) return ListenEnd.skipped;
  return ListenEnd.replaced;
}

/// 正在听的那一首，还没收尾。
///
/// 放在这个文件而不是 `music_service` 里，是因为收尾那一下（[classifyEnd]）
/// 和「往前拖了多少」都是纯逻辑，混进 service 就测不到了。
///
/// ## ⚠️ 进度不能照抄播放器报的数
///
/// 网易云**一首歌只在曲目边界发布一次位置**（实测：`position=0` 报一次，然后
/// 整首都哑着）。照抄的话，一首从头放到尾的歌收尾时记的是
/// 「听到 0 秒就换掉了」——归档标签错，喂给模型的数字也是错的。
///
/// 所以这里存的是**读数 + 读数时刻 + 当时在不在放**，[positionNow] 现算。
/// 和 `NowPlaying.livePosition` 是同一个外推法。
class OpenListen {
  OpenListen({
    required this.package,
    this.title,
    this.artist,
    this.duration,
    required this.startedAt,
  });

  final String package;
  final String? title;
  final String? artist;
  final Duration? duration;

  /// 这首歌**大概是什么时候开始的**。
  ///
  /// 不是「我们注意到它的时候」：冷启动时可能歌已经放到一半了，那会儿记的
  /// `startedAt` 会让这首歌看着只听了十几秒。所以由调用方按「那一刻的进度」
  /// 倒推（见 music_service 的 `_openListen`）。
  final DateTime startedAt;

  Duration _base = Duration.zero;
  DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);
  bool _playing = false;

  /// 这首歌里她累计往前拖了多少。
  Duration seekedForward = Duration.zero;

  /// 收到一次状态。位置和「在不在放」都记最新的那份。
  void saw({
    required Duration position,
    required DateTime at,
    required bool playing,
  }) {
    _base = position;
    _at = at;
    _playing = playing;
  }

  /// 她往前拖了。**往后拖不算**——那是重听，不是跳。
  void seeked({required Duration from, required Duration to}) {
    final d = to - from;
    if (d > Duration.zero) seekedForward += d;
  }

  /// 此刻大概放到哪儿了。
  Duration positionNow(DateTime now) {
    var p = _base;
    if (_playing) {
      final e = now.difference(_at);
      if (e > Duration.zero) p += e;
    }
    final total = duration;
    // 外推别越过歌尾——越过去了归档就成了「放完了」，而它可能只是暂停得比较久。
    return (total != null && p > total) ? total : p;
  }

  /// 收尾。返回 null = 这一首不值得记（没歌名，或者短得不像真听过）。
  ///
  /// [end] 给定就照它记（比如播放器整个消失了，那是 [ListenEnd.unknown]），
  /// 没给就按进度和时长归档。
  ListenEntry? close({required DateTime at, ListenEnd? end}) {
    if ((title ?? '').isEmpty) return null;
    final listened = at.difference(startedAt);
    // 一秒钟都不到的，多半是「刚连上就报了一首」之类的噪声，不是她真听了。
    // 记进去的话，模型会看到一堆「听了 0 秒」，比没有更糟。
    if (listened < const Duration(seconds: 1)) return null;
    final pos = positionNow(at);
    return ListenEntry(
      package: package,
      title: title,
      artist: artist,
      duration: duration,
      startedAt: startedAt,
      endedAt: at,
      position: pos,
      seekedForward: seekedForward,
      end:
          end ??
          classifyEnd(position: pos, duration: duration, listened: listened),
    );
  }
}

/// 现在这一刻在放什么。**故意是个裸的值对象**，不引 `music_service`——
/// 那会让这个文件没法单测（要真机和真播放器）。
class NowPlayingBrief {
  const NowPlayingBrief({this.title, this.artist, this.state});

  final String? title;
  final String? artist;

  /// 「在放」/「暂停」那种中文标签，直接用 `PlaybackState.label`。
  final String? state;
}

/// 多久之内的听歌动静还算「刚发生」。
///
/// 比 `collectCandidates(since:)` 那道闸更紧，是故意的：那道闸是「上次开口
/// 到现在」，可能隔了三天。三天前听的一首歌不该今天拿出来当由头。
const _fresh = Duration(minutes: 90);

/// 连着几首短切算「在翻歌单」。
const _flipCount = 3;

/// 这段时间里的听歌动静，归纳成一句喂给模型的话。
///
/// 返回 null = 没什么可说的（或者都已经提过了）。有话说时给出 [what] 和
/// 这首歌的登记名 [mentionKey]。
///
/// **这里只做「有没有新东西」和「把事实说准」两件事**，不做「值不值得开口」
/// ——那是模型的事。所以宁可把数字都给全，让它自己去掂量。
({String what, String mentionKey})? musicBriefFor({
  required List<ListenEntry> entries,
  required DateTime now,
  required Set<String> mentioned,
  NowPlayingBrief? playing,
}) {
  final fresh =
      entries
          .where((e) => now.difference(e.endedAt) <= _fresh)
          .where((e) => !mentioned.contains(e.mentionKey))
          .toList()
        ..sort((a, b) => b.endedAt.compareTo(a.endedAt));
  if (fresh.isEmpty) return null;

  // 「连着几首都是几十秒就切」比单首更值得说一句：那不是「跳过了这首歌」，
  // 那是「在翻歌单」——两件事该说的话不一样。
  final run = <ListenEntry>[];
  for (final e in fresh) {
    if (e.end != ListenEnd.skipped) break;
    run.add(e);
  }

  final lines = <String>[];
  if (run.length >= _flipCount) {
    lines.add(
      'TA 刚才连着换了 ${run.length} 首，每首都只听了 '
      '${_range(run.map((e) => e.listened.inSeconds))} 秒就切走：'
      '${run.map(_name).join('、')}。',
    );
  } else {
    lines.add(_describe(fresh.first));
  }
  if (playing != null && (playing.title ?? '').isNotEmpty) {
    lines.add(
      '现在${playing.state ?? '在放'}的是《${playing.title}》'
      '${(playing.artist ?? '').isEmpty ? '' : '（${playing.artist}）'}。',
    );
  }

  return (what: lines.join('\n'), mentionKey: fresh.first.mentionKey);
}

/// 一首歌怎么说。带够数字，别下结论。
String _describe(ListenEntry e) {
  final app = _appName(e.package);
  final name = _name(e);
  final dur = _mmss(e.duration);
  final seek = e.seekedForward > Duration.zero
      ? '，中间往前拖了 ${e.seekedForward.inSeconds} 秒'
      : '';

  switch (e.end) {
    case ListenEnd.natural:
      return 'TA 在$app 把$name 听完了${dur == null ? '' : '（整首 $dur）'}。';
    case ListenEnd.skipped:
      // ⚠️ 这一条是整块里信号最强的：从开始到切走只有几秒，中间几乎不可能
      // 发生别的事，所以「她不喜欢」还是「她在找别的」模型一读就分得出来。
      return 'TA 在$app 放$name，只听了 ${e.listened.inSeconds} 秒就切走了'
          '${dur == null ? '' : '（整首 $dur）'}$seek。';
    case ListenEnd.replaced:
      final at = _mmss(e.position);
      return 'TA 在$app 听$name，听到 ${at ?? '${e.listened.inSeconds} 秒'}'
          '${dur == null ? '' : '（整首 $dur）'}就换掉了$seek。';
    case ListenEnd.unknown:
      return 'TA 在$app 听$name，后来播放器没了，不知道听了多久$seek。';
  }
}

String _name(ListenEntry e) {
  final t = e.title ?? '一首没报歌名的';
  return (e.artist ?? '').isEmpty ? '《$t》' : '《$t》（${e.artist}）';
}

/// 一列秒数说成「12–40」那样。全都一样时只说一个数。
String _range(Iterable<int> seconds) {
  final list = seconds.toList()..sort();
  if (list.isEmpty) return '0';
  return list.first == list.last ? '${list.first}' : '${list.first}–${list.last}';
}

String? _mmss(Duration? d) {
  if (d == null || d <= Duration.zero) return null;
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 包名 → 说法。认不出就退回包名本身，**不要编一个中文名**——说错 App
/// 比说得拗口糟得多。
String _appName(String package) => switch (package) {
  'com.netease.cloudmusic' => '网易云',
  'com.tencent.qqmusic' => 'QQ 音乐',
  'app.podcast.cosmos' => '小宇宙',
  'com.ximalaya.ting.android' => '喜马拉雅',
  'tv.danmaku.bili' => 'B 站',
  _ => package,
};

/// 听歌记录的落盘。薄薄一层，逻辑都在上面那些纯函数里。
///
/// 为什么要落盘：这一整条链只在**进程活着**时才有事件（监听服务跑在我们自己
/// 的进程里）。进程被国产 ROM 杀掉之后，那次换歌就再也没人评估了——存下来
/// 的话，下次冷启动 `runOnStartup` 那一趟还捡得到。
class ListenLog {
  static const _k = 'listen_log';

  /// 留多少条。够模型看出「连着几首都是短切」就行，多了只是白读盘。
  static const _keep = 12;

  static List<ListenEntry>? _cache;

  /// 只在第一次真读一次盘。
  static Future<List<ListenEntry>> recent() async {
    final c = _cache;
    if (c != null) return List.unmodifiable(c);
    final out = <ListenEntry>[];
    try {
      final sp = await SharedPreferences.getInstance();
      for (final raw in sp.getStringList(_k) ?? const <String>[]) {
        final e = ListenEntry.decode(raw);
        if (e != null) out.add(e);
      }
    } catch (_) {
      // 读不出来就当没有。这块的失败绝不该影响放歌，更不该影响开口。
    }
    _cache = out;
    return List.unmodifiable(out);
  }

  /// 记一首。新的在前。
  static Future<void> add(ListenEntry e) async {
    try {
      final list = <ListenEntry>[e, ...(await recent())];
      final kept = list.take(_keep).toList();
      _cache = kept;
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_k, kept.map((x) => jsonEncode(x.toJson())).toList());
    } catch (_) {}
  }

  /// 测试用：把进程内的缓存清掉（存盘不动）。
  static void resetCacheForTest() => _cache = null;
}
