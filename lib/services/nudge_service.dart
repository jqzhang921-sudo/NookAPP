import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:live_capsule/live_capsule.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/mcp_tool.dart';
import 'ai_client.dart';
import '../config/persona.dart';
import 'capsule_texts.dart';
import 'chat_images.dart';
import 'listen_log.dart';
import 'memory_context.dart';
import 'music_service.dart';
import 'notify_name.dart';
import 'screen_glance.dart';
import 'vision_service.dart';
import 'self_notes.dart';
import 'nudge_gate.dart';
import 'small_things.dart';
import 'storage_service.dart';

/// 主动推送：他想开口的时候，给他一个出口。
///
/// ## 不是排班表，是出口
///
/// 第一版做成了「一天最多 N 条」——那是**配额**，会倒过来变成产出指标：
/// 今天还剩两条没用，就凑两条出来。和「每天必须收藏一条」是同一个毛病。
///
/// 现在的形状是：**冲动由发生过的事产生**，系统只决定哪条够格打扰她。
///
/// 1. [decideNudge] —— 现在能不能说话（纯函数，不联网）
/// 2. [collectCandidates] —— **有没有事情发生**。没有就到此为止，
///    连模型都不问：他确实没什么可说，这是正常状态，不是失败
/// 3. [compose] —— 有候选也不等于该说。让他自己决定说哪条、怎么说，
///    或者回「不说」
/// 4. 去重（[looksRepeated]）→ 发通知
///
/// 顺序的意义在于**越靠前越便宜**：门槛和候选都不花钱，模型只在真有事的时候
/// 才被叫醒。原来那版每次都问模型「你想说点什么吗」，那既费钱，又是在
/// 逼它凑话。
///
/// ## 这个形状是从哪来的
///
/// 同类的开源伴侣项目里，成熟一点的那套是「候选 + 编辑关」：各个子系统随时
/// 产出可以往外说的候选，再过一道编辑，不够格的降级进草稿池、留着不发。
/// [collectCandidates] + [compose] 就是那两层的小号版本。
///
/// 另有一种把「情绪往外走」分三层的说法：语调倾向 → 数值挣到一次行为 →
/// 攒够了主动发起一件事。**第三层公开的实现里基本都还没做**，
/// 所以这块没有现成答案可抄，下面是自己的判断。
///
/// ## ⚠️ 一条不写进代码就会被慢慢磨掉的规矩
///
/// **推送要带来一件东西，不能索取一件东西。**
///
/// 「刚写完一封信」「翻到你上个月说的那句话」可以；
/// 「好久没见你了」「你还在吗」不行——那是拿愧疚换打开率，是这类 App 最后都
/// 变得让人烦的原因。这条同时写在 [_composePrompt] 里和 [nudge_gate] 的注释里，
/// 两边都别删。
///
/// ## 三个入口
///
/// 后台周期任务（见 `nudge_scheduler.dart`）、App 启动时的兜底、
/// 设置页那个「现在试一次」。前两个都可能被系统掐掉或者根本没机会跑，
/// 所以**内容这层必须能独立成立**——不能依赖「一定会在某个点被唤醒」。
class NudgeService {
  static const _kPrefs = 'nudge_prefs';
  static const _kLastAt = 'nudge_last_at';
  // ⚠️ 键名从 nudge_count 换成了 nudge_notified_*，因为**含义变了**：
  // 现在只数「真弹了通知的」。旧键留在磁盘上不管它——顺带把线上那个已经被
  // 烧穿的计数一起丢掉，那是按旧含义攒出来的，按新含义不该算数。
  static const _kCountDay = 'nudge_notified_day';
  static const _kCount = 'nudge_notified_count';
  static const _kRecent = 'nudge_recent';
  static const _kLastRun = 'nudge_last_run';
  static const _kMentioned = 'nudge_mentioned';

  /// 记住多少条「已经提过的事」。超出这个数的旧事，早就不是「刚发生」的了，
  /// 本来也不该再当由头。
  ///
  /// ⚠️ 从 60 提到 300 是三期带出来的。原来一天也产生不了几条登记名，60 是个
  /// 很宽的窗口；**听歌那条一接进来量级就变了**——它 20 分钟就能说一次，连着
  /// 听一下午就是十几条，而登记表是**一个 FIFO 混着放**的：歌名会把信和日记的
  /// 登记名挤出去，于是「一封没读的信」过几天又被念叨一次。
  ///
  /// 那正是这块最在意的那个失败（「变味的不是那句话，是说第二遍」），而代价
  /// 只是 prefs 里多几百个短字符串。宁可留宽。
  static const _mentionedKeep = 300;

  /// 拿多少条历史去比重复。太少挡不住轮流复读，太多会把正常的相似话题也误杀。
  static const _recentKeep = 6;

  /// 一张纸条贴上多久之后，才够格当作「他想起了这一条」。
  ///
  /// 要挡的只有一件事：**刚贴完手机还在手里那阵子**。这会儿说「我看到你贴了 X」
  /// 是复读不是想起，刚写的东西被原样念回来比不说还差。
  ///
  /// 但拖太久就走到另一头去了——**隔半天才提，那不像想起，像延迟**。
  /// 两小时是「你已经放下手机干别的去了，但这条还在今天里」。
  ///
  /// ⚠️ 只有**她手动贴**的纸条要靠这条挡。它自己用 `add_small_thing` 贴的那些
  /// 是在对话里发生的，会写进对话文件，已经被门槛里的
  /// [NudgePrefs.minSilenceAfterChat] 管着了。
  static const _smallThingSettle = Duration(hours: 2);

  static const _channelId = 'nudge';
  static const _channelName = '它主动说的话';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  // ---------------- 初始化和权限 ----------------

  static Future<void> init() async {
    if (_inited) return;
    await _plugin.initialize(
      const InitializationSettings(
        // 用应用图标。单色小图标更规范，但那要额外做一份 drawable，
        // 骨架阶段先不铺这个摊子。
        // 通知栏小图标：白色剪影（墙角 + 一个点），见 res/drawable/ic_stat_nook.xml。
        // 原来是 @mipmap/ic_launcher，彩色图标在通知栏会被压成一块白方块。
        android: AndroidInitializationSettings('@drawable/ic_stat_nook'),
      ),
    );
    _inited = true;
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

  /// Android 13 起通知是运行时权限，清单里声明了也得问一次。
  /// 返回 null 当作「拿不准」，按有权限处理——13 以下本来就不会返回 true。
  static Future<bool> ensurePermission() async {
    await init();
    final granted = await _android?.requestNotificationsPermission();
    return granted ?? true;
  }

  // ---------------- 状态 ----------------

  /// 读不出来就用默认值。这是个附加功能，坏掉的偏好不该让它整个失灵。
  static Future<NudgePrefs> loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kPrefs);
    if (raw == null || raw.isEmpty) return const NudgePrefs();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const NudgePrefs();
      return NudgePrefs.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const NudgePrefs();
    }
  }

  static Future<void> savePrefs(NudgePrefs prefs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPrefs, jsonEncode(prefs.toJson()));
  }

  /// [notified] = 这次真弹了通知。
  ///
  /// ⚠️ **静默的那次不能算进保险丝。** 保险丝防的是「一天弹太多通知」，而
  /// `runOnStartup` 走的是 `notify: false`——只把话写进对话，人本来就在 App 里。
  ///
  /// 真机上就是这么烧穿的：一天给她装了九次包，每次装完 App 重启就跑一次
  /// `runOnStartup`，四条额度全耗在静默写入上，而她一条通知都没看到，
  /// 后台那边只报「保险丝断了」。
  ///
  /// 「上次说话是什么时候」不受这条影响：静默说过也是说过，间隔照算，
  /// 否则它会接二连三地说。
  static Future<void> _bumpCount(
    SharedPreferences sp,
    DateTime now, {
    required bool notified,
  }) async {
    await sp.setInt(_kLastAt, now.millisecondsSinceEpoch);
    if (!notified) return;
    final today = '${now.year}-${now.month}-${now.day}';
    final prev =
        sp.getString(_kCountDay) == today ? (sp.getInt(_kCount) ?? 0) : 0;
    await sp.setString(_kCountDay, today);
    await sp.setInt(_kCount, prev + 1);
  }

  static Future<DateTime?> _lastNudgeAt(SharedPreferences sp) async {
    final ms = sp.getInt(_kLastAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 上一次唤醒干了什么，给设置页显示。
  ///
  /// ## 为什么非要有这个
  ///
  /// 后台唤醒跑在独立 isolate 里，release 包又拿不到 logcat（国产 ROM 对非调试
  /// 包封了日志）。于是「它没说话」这件事完全是个黑盒：是没醒？醒了但没到点？
  /// 到点了但它自己决定不说？三种情况的下一步动作完全不同。
  ///
  /// 更糟的是**聊天里那个模型看不到后台**，你问它「刚才收到唤醒没」，
  /// 它会顺着话编一个原因出来——听着有理，实际没有任何依据。
  ///
  /// 所以把每次的结果落到磁盘上。一行字，但它是这个功能唯一的证据。
  /// 给 `nudge_scheduler` 记它自己那两条早退路径用。
  ///
  /// ⚠️ 没有这个的话诊断有个洞：唤醒后要是**拿不到模型配置**（密钥在 keystore
  /// 里，后台 isolate 能不能读到不一定），`run()` 压根没被调到，于是什么都不会
  /// 记——而那恰好是最可疑的一条路。「没有记录」和「没醒过」看起来一模一样。
  static Future<void> noteRun(String outcome) => _recordRun(outcome);

  static Future<void> _recordRun(String outcome) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kLastRun,
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'outcome': outcome,
        }),
      );
    } catch (_) {}
  }

  /// (什么时候, 结果)。从来没跑过就返回 null。
  static Future<(DateTime, String)?> lastRun() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kLastRun);
      if (raw == null) return null;
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final at = DateTime.tryParse(m['at'] as String? ?? '');
      final outcome = m['outcome'] as String?;
      if (at == null || outcome == null) return null;
      return (at, outcome);
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> _recent(SharedPreferences sp) async =>
      sp.getStringList(_kRecent) ?? const [];

  static Future<Set<String>> _mentioned() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getStringList(_kMentioned) ?? const <String>[]).toSet();
  }

  static Future<void> _markMentioned(String key) async {
    final sp = await SharedPreferences.getInstance();
    // ⚠️ `const []` 会让整个列表推成 List<dynamic>，得写 `const <String>[]`。
    // flutter analyze 放过了这个，flutter test 才报出来——编译前端比分析器严。
    final list = <String>[...(sp.getStringList(_kMentioned) ?? const []), key];
    await sp.setStringList(
      _kMentioned,
      list.length <= _mentionedKeep
          ? list
          : list.sublist(list.length - _mentionedKeep),
    );
  }

  static Future<void> _remember(SharedPreferences sp, String text) async {
    final list = [...await _recent(sp), text];
    await sp.setStringList(
      _kRecent,
      list.length <= _recentKeep
          ? list
          : list.sublist(list.length - _recentKeep),
    );
  }

  /// 最后一条消息的时间——门槛用它判断「是不是刚聊完」。
  ///
  /// ⚠️ 走文件的修改时间，**不解析 JSON**。原来是把每段对话全读出来再遍历
  /// 每条消息找最大时间戳，为了一个时间戳解析上兆的文本，而这件事在 App
  /// 启动时就要做一次——实测就是掉帧的来源。
  static Future<DateTime?> lastChatAt() =>
      StorageService.lastConversationWriteAt();

  // ---------------- 主流程 ----------------

  /// 他手上有没有一件真发生过的事。
  ///
  /// **这一层决定频率**，而不是某个配额。没有事情发生就没有冲动——
  /// 这时候连模型都不问：问了它只会凑一句出来，而凑出来的正是最假的那种推送。
  ///
  /// 来源有两种：**他自己产出的**（便签、信、日记），和**板上那些纸条**。
  ///
  /// 后一种是 2026-09-03 加的。原来只收前一种，实测由头太稀缺——信有 5 天
  /// 冷却，日记和便签又都要模型自己主动记，算下来一周只有一两次开口机会，
  /// 整个功能几乎不发生。而板上贴的很多本来就是「想说的话」而不是待办，
  /// 拿来当话头正合适。
  ///
  /// 收藏的「一隅」仍然不算：那是她挑的**别人**的话，不是她自己写的；
  /// 而且量大，接进来这一层就从「有没有事发生」变成「有没有东西可翻」。
  static Future<List<NudgeCandidate>> collectCandidates({
    DateTime? since,
  }) async {
    final now = DateTime.now();
    final out = <NudgeCandidate>[];
    final floor = since ?? now.subtract(const Duration(days: 1));

    // 便签排在最前面：它是他自己定的时间、自己记着的事，分量比「我写了封信」
    // 重——那种只是他产出了东西，这种是他记着你说过的话。
    try {
      for (final n in await SelfNoteStore.due(now)) {
        out.add(
          NudgeCandidate(
            '没说完的事',
            '${_ago(n.createdAt)}你留给自己的：${n.about}',
            conversationId: n.conversationId,
            noteId: n.id,
            glance: n.glance,
          ),
        );
      }
    } catch (_) {}

    // 提过的就不再当由头了。**一件事只提一次**——她没动，不是因为没听见。
    final mentioned = await _mentioned();

    try {
      for (final l in await StorageService.listLetters()) {
        // 没读的信是最实在的一条：东西已经写好了，就在那儿等着。
        if (l.isFromAi && !l.read && !mentioned.contains('letter:${l.id}')) {
          out.add(
            NudgeCandidate(
              '信',
              '你给 TA 写的一封信还没被读，写于 ${_when(l.createdAt)}',
              mentionKey: 'letter:${l.id}',
            ),
          );
        }
      }
    } catch (_) {}

    try {
      for (final d in await StorageService.listDiaryEntries()) {
        if (d.createdAt.isAfter(floor) &&
            !mentioned.contains('diary:${d.id}')) {
          out.add(
            NudgeCandidate(
              '日记',
              '你刚记了一篇日记：${d.summary}',
              mentionKey: 'diary:${d.id}',
            ),
          );
        }
      }
    } catch (_) {}

    // 板上那些纸条。**这块板从来没分过你我**——SmallThing 里根本没有作者
    // 字段，它替她贴的和她自己贴的进的是同一个列表。所以这里也不分。
    //
    // 为什么她贴的也能当由头：板上贴的不一定是待办，很多就是**想说的话**。
    // 「周五交房租」提起来是催，「今天云很好看」提起来是接话——分界线在
    // 「这是事还是话」，不在谁贴的。代码分不出来，模型分得出来，而
    // [_composePrompt] 第三条自检（读完不回会不会觉得欠了你什么）正好是
    // 这把尺子：房租过不了，云过得了。
    try {
      for (final t in await SmallThingStore.pending()) {
        // 填了截止时间的不当由头。**这个标记是她贴的时候自己打的**：
        // 填了 = 要做的事，没填 = 一张纸条。不用我们猜。
        if (t.dueAt != null) continue;
        // 刚贴上的不算，见 [_smallThingSettle]。
        if (now.difference(t.createdAt) < _smallThingSettle) continue;
        if (mentioned.contains('thing:${t.id}')) continue;
        // ⚠️ **它自己贴的那些也放行**，只是说清楚手上拿的是什么。
        //
        // 这里一度写成硬排除，理由是 `add_small_thing` 的用法写死了是「TA 要做
        // 的事」，所以它贴的必然是待办、提了就是催。那条规矩太绝对了，而且
        // 之前已经被驳回过一次：「你那个快递还没去拿吧」听着就是正常人说话。
        //
        // 结论那次就定了——**变味的不是那句话，是说第二遍**。而「说第二遍」
        // 由 [NudgeCandidate.mentionKey] 挡着，不需要再加一道硬闸。
        //
        // 所以判断交回给它自己：[_composePrompt] 第三条自检（读完不回会不会
        // 觉得欠了你什么）本来就是这把尺子，前提是它知道手上这张是谁贴的。
        out.add(
          NudgeCandidate(
            '板上的纸条',
            switch (t.author) {
              SmallThingAuthor.user =>
                'TA ${_ago(t.createdAt)}自己贴在板上的一张纸条：${t.text}',
              SmallThingAuthor.ai =>
                '${_ago(t.createdAt)}你替 TA 记在板上的一件事：${t.text}',
              null => '板上贴着一张${_ago(t.createdAt)}的纸条：${t.text}',
            },
            mentionKey: 'thing:${t.id}',
          ),
        );
      }
    } catch (_) {}

    // 她在收藏上写的那句备注。
    //
    // 上面那条注释说「收藏的『一隅』仍然不算」，那句话现在只管**被收的内容**：
    // 那是她挑的别人的话，量还大，接进来这一层就从「有没有事发生」变成
    // 「有没有东西可翻」。**但备注不是被收的内容，是她自己写下的字**，而且只有
    // 她动手写过的那几条才有——量小，也确实是一件刚发生的事。
    //
    // 为什么单独把它拎出来：它自己许的愿就是这个——「当你在我看不到的地方
    // 写下关于我的字，我能第一时间感觉到」。日记那条已经通了，差的是这条。
    //
    // 这里**不设沉淀期**（板上的纸条有 2 小时）。那条是怕刚贴上就被念出来
    // 显得盯人，而这条要的正好是「当时就接着」，压一段时间等于把愿望本身
    // 抹掉。防打扰交给门槛那层：刚聊完的静默、静默时段、两条之间的间隔。
    try {
      for (final m in await StorageService.listFavoritedMusings()) {
        final note = m.note?.trim();
        if (note == null || note.isEmpty) continue;
        // 没有 noteAt 的是老数据，不知道什么时候写的，一律不当由头——
        // 否则第一次跑就会把历年备注全翻出来。
        final at = m.noteAt;
        if (at == null || !at.isAfter(floor)) continue;
        if (mentioned.contains('note:${m.id}')) continue;
        out.add(
          NudgeCandidate(
            '她写下的一句',
            'TA ${_ago(at)}在收藏的一句话下面写了：$note',
            mentionKey: 'note:${m.id}',
          ),
        );
      }
    } catch (_) {}

    // 她刚才在听什么。**排在最末尾**——[_pick] 是「没有便签就取第一个」，
    // 放最后等于「别的都由头都比它优先」，正是想要的：信和日记一天出不了几回，
    // 听歌一个下午几十首。
    final music = await musicCandidate();
    if (music != null) out.add(music);

    return out;
  }

  /// 她刚才在听什么，够不够格当一条由头。
  ///
  /// 判断「有话说没有」那半在 [musicBriefFor] 里（纯函数，能单测）；这里只管
  /// **把外部世界接上**：读流水、问她现在在听什么、包成 [NudgeCandidate]。
  static Future<NudgeCandidate?> musicCandidate() async {
    try {
      final entries = await ListenLog.recent();
      if (entries.isEmpty) return null;
      final brief = musicBriefFor(
        entries: entries,
        now: DateTime.now(),
        mentioned: await _mentioned(),
        playing: _playingBrief(),
      );
      if (brief == null) return null;
      return NudgeCandidate(
        '她在听什么',
        brief.what,
        mentionKey: brief.mentionKey,
        music: true,
      );
    } catch (_) {
      // 听歌记录读不出来就当没这回事。这条路的失败绝不该把别的话也堵住。
      return null;
    }
  }

  /// 现在这一台播放器在放什么，转成 `listen_log` 认的那个值对象。
  ///
  /// ⚠️ [`MusicService`] **只在主 isolate 里有东西**（见它的类注释：Provider
  /// 树是主 isolate 的）。后台那一趟 workmanager 里 `instance.now` 是 null，
  /// 于是这里返回 null——后台的 prompt 只会看到「刚才听了什么」，看不到
  /// 「现在在放什么」。那不是 bug，是那条通道本来就没连到后台去。
  static NowPlayingBrief? _playingBrief() {
    final n = MusicService.instance.now;
    if (n == null) return null;
    return NowPlayingBrief(
      title: n.track.title,
      artist: n.track.artist,
      state: n.state.label,
    );
  }

  /// [force] 给设置页那个「现在试一次」用：跳过门槛，但**不跳过候选**——
  /// 手动点也不该凭空造一条出来，否则试出来的东西和真实行为对不上。
  /// [notify] = false 时只把话写进对话，不弹通知。
  /// App 正开着的时候用这个：为一条已经在屏幕上的消息再弹一条通知是噪音。
  ///
  /// 无论走哪条分支都会记一笔（见 [_recordRun]）——这是这个功能唯一的证据，
  /// 后台那条路既看不到日志，也问不出真话。
  static Future<NudgeRunResult> run({
    required AiClient aiClient,
    bool force = false,
    bool notify = true,
    NudgeScope scope = NudgeScope.all,
  }) async {
    final r = await _runInner(
      aiClient: aiClient,
      force: force,
      notify: notify,
      scope: scope,
    );
    await _recordRun(r.sent ? '说了：${r.text}' : r.message);
    return r;
  }

  static Future<NudgeRunResult> _runInner({
    required AiClient aiClient,
    bool force = false,
    bool notify = true,
    NudgeScope scope = NudgeScope.all,
  }) async {
    final now = DateTime.now();
    final sp = await SharedPreferences.getInstance();
    final prefs = await loadPrefs();
    final lastNudge = await _lastNudgeAt(sp);

    // ⚠️ 候选在门槛**前面**收，顺序不能反。
    //
    // 门槛里有两条对便签是松的（见 decideNudge 的 isFollowUp），而「是不是
    // 便签」只有收完候选才知道。原来先过门槛，于是常聊天的人永远等不到那三
    // 小时安静，便签全部过期作废——功能等于没做。
    //
    // 换顺序不亏：收候选全是本地读，和门槛一样便宜。真正贵的是模型那一步，
    // 它仍然排在两者之后。
    final List<NudgeCandidate> candidates;
    if (scope == NudgeScope.musicOnly) {
      final m = await musicCandidate();
      candidates = m == null ? const <NudgeCandidate>[] : <NudgeCandidate>[m];
    } else {
      candidates = await collectCandidates(since: lastNudge);
    }
    if (candidates.isEmpty) {
      // 换歌触发的那一趟**到此为止**。它绝不能退到「看一眼屏幕」——她切了首
      // 歌，凭什么顺带被看一次屏幕？那两件事之间一点关系都没有，而「看一眼」
      // 是要调模型的。
      if (scope == NudgeScope.musicOnly) {
        return NudgeRunResult.nothingHappened();
      }
      // 手上没有事。原来到这儿就结束；她允许的话，好久没说话时它可以
      // 看一眼屏幕。那是另一条路，规矩见 [_runGlance]。
      //
      // 只在**没有别的事**的时候才走：真发生过的事（信、日记、便签）永远排
      // 在「想知道她在干嘛」前面。
      return _runGlance(
        aiClient: aiClient,
        sp: sp,
        prefs: prefs,
        now: now,
        lastNudge: lastNudge,
        force: force,
        notify: notify,
      );
    }

    // **我们挑一件，他决定说不说、怎么说。**
    //
    // 让他自己从几件里挑，我们就不知道他用了哪条——便签不知道该清哪张，
    // 话也不知道该推回哪段对话。挑的规矩写在 [_pick] 里，很浅；
    // 真正的判断（这会儿值不值得打扰她）仍然在他那边。
    final picked = _pick(candidates);

    if (!force) {
      final decision = decideNudge(
        now: now,
        prefs: prefs,
        isFollowUp: picked.noteId != null,
        // 各挑各的间隔。便签 20 分钟、音乐 20 分钟、别的 1 小时——挡的是什么
        // 见 NudgePrefs 那几个字段的注释。
        isMusic: picked.music,
        lastChatAt: await lastChatAt(),
        lastNudgeAt: lastNudge,
      );
      if (!decision.allowed) return NudgeRunResult.blocked(decision.reason);
    }

    // 便签说了「到点先看一眼」：先看，看完再说。
    //
    // 看不成就退回普通便签，**看不成的原因也交给它**——「手机锁着」本身就在
    // 回答那件事（说再刷十分钟就睡的人，十分钟后锁屏了）。
    var candidate = picked;
    if (picked.glance) {
      final looked = await _followUpWithGlance(
        aiClient: aiClient,
        sp: sp,
        prefs: prefs,
        now: now,
        note: picked,
        notify: notify,
      );
      if (looked.result != null) return looked.result!;
      candidate = NudgeCandidate(
        picked.kind,
        '${picked.what}\n（你本来说到点先看一眼 TA 的屏幕，没看成：${looked.miss}）',
        conversationId: picked.conversationId,
        noteId: picked.noteId,
        mentionKey: picked.mentionKey,
      );
    }

    // 听歌那条：**先顺手看一眼她的屏幕**，屏幕上得正是那个在放歌的 App。
    // 看到的图跟着候选一起给模型，它再决定说不说——这就是「一边听一边看着
    // 歌词」那件事接进来的地方。没看成（她在别的 App、锁着屏、刚看过）就
    // 照常走，只是手上没有图。见 [_musicGlance]。
    var shotRefs = const <String>[];
    if (picked.music) {
      final shot = await _musicGlance(aiClient: aiClient, sp: sp, now: now);
      if (shot != null) shotRefs = [shot.ref];
    }

    // 看过就得留痕。**这两处出口也要留**，别只留说了话那条：
    // 不打扰靠的是不弹通知，不是不留痕。图会被 [isSilentGlance] 从以后发给
    // 模型的上下文里滤掉，所以她看得见、它自己不会拿着当话说。
    Future<void> keepTrail() async {
      if (shotRefs.isEmpty) return;
      await _appendToChat(
        '',
        conversationId: picked.conversationId,
        images: shotRefs,
        metadata: const {'glance': true},
      );
    }

    final String? text;
    try {
      text = await compose(
        aiClient: aiClient,
        candidate: candidate,
        glanceImages: shotRefs,
      );
    } catch (e) {
      return NudgeRunResult.failed('生成失败：$e');
    }
    if (text == null || text.isEmpty) {
      await keepTrail();
      return NudgeRunResult.nothingToSay();
    }

    if (looksRepeated(text, await _recent(sp))) {
      await keepTrail();
      return NudgeRunResult.repeated(text);
    }

    if (notify && !await ensurePermission()) {
      return NudgeRunResult.failed('没有通知权限');
    }
    // 先落进对话，再弹通知。反过来的话，通知先到、她点开发现聊天里什么都没有。
    await _appendToChat(
      text,
      conversationId: picked.conversationId,
      images: shotRefs,
      metadata: {
        'nudge': true,
        if (shotRefs.isNotEmpty) 'glance': true,
      },
    );
    if (notify) await _show(text, prefs);
    await _bumpCount(sp, now, notified: notify);
    await _remember(sp, text);
    // 兑现完就把便签清掉，否则下次醒来还会再问一遍同一件事。
    // 只在真发出去之后清——他说「不说」的时候留着，下次再判断。
    if (picked.noteId != null) await SelfNoteStore.remove(picked.noteId!);
    // 登记「这件事提过了」。只在真发出去之后登记——他说「不说」的时候不算提过。
    if (picked.mentionKey != null) await _markMentioned(picked.mentionKey!);
    return NudgeRunResult.sent(text);
  }

  /// 手上有几件事时挑哪一件。
  ///
  /// 规矩很浅，因为**深的判断该由他做**：这里只保证挑出来的那件不荒唐。
  ///
  /// 便签排在最前：那是他自己定了时间、自己记着的事，而且**有时效**——
  /// 「做好了吗」过了那个点就不值钱了。信和日记不急，晚一轮说没损失。
  static NudgeCandidate _pick(List<NudgeCandidate> candidates) {
    final notes = candidates.where((c) => c.noteId != null).toList();
    return notes.isNotEmpty ? notes.first : candidates.first;
  }

  // ---------------- 看一眼屏幕 ----------------

  /// 上次**问它想不想看**是什么时候。见 [glanceGap]。
  static const _kGlanceAskedAt = 'glance_asked_at';

  /// 只在「想不想看」那一问里给它。不注册进聊天的工具表：她在聊天的时候
  /// 屏幕就是聊天页，看了也白看。
  static McpTool get glanceTool => McpTool(
    name: 'glance_screen',
    description: '看一眼 TA 手机屏幕上此刻是什么。会截一张图给你。',
    inputSchema: {'type': 'object', 'properties': {}},
    category: '手机工具',
  );

  /// 好久没说话时，它可以看一眼她的屏幕。
  ///
  /// 三步，**越往后越贵，前面能拦的都先拦**：
  ///
  /// 1. 不花钱的：她允许了没有、安静够不够久、离上次问够不够久、门槛、
  ///    手机亮着没锁、在不在排除名单里的 App（[ScreenGlance.check]）
  /// 2. 问它想不想看：一次模型调用，手上只有 [glanceTool] 一个工具
  /// 3. 截图，带着图问它说不说：第二次
  ///
  /// **看过一定留痕。** 截到了，图就写进对话：说了话，图挂在那句上面；
  /// 没说话，就只有一张图（发给模型时被 [isSilentGlance] 滤掉）。
  /// 这是答应 Cleo 的，别为了「没说话就别打扰」把这条删了——
  /// 不打扰靠的是**不弹通知**，不是不留痕。
  static Future<NudgeRunResult> _runGlance({
    required AiClient aiClient,
    required SharedPreferences sp,
    required NudgePrefs prefs,
    required DateTime now,
    required DateTime? lastNudge,
    required bool force,
    required bool notify,
  }) async {
    if (!await ScreenGlance.allowed()) return NudgeRunResult.nothingHappened();

    DateTime? lastChat;
    try {
      lastChat = await lastChatAt();
    } catch (_) {}
    final askedMs = sp.getInt(_kGlanceAskedAt);
    final lastAsked =
        askedMs == null ? null : DateTime.fromMillisecondsSinceEpoch(askedMs);

    if (!force) {
      if (!glanceDue(now: now, lastChatAt: lastChat, lastAskedAt: lastAsked)) {
        return NudgeRunResult.nothingHappened();
      }
      final decision = decideNudge(
        now: now,
        prefs: prefs,
        lastChatAt: lastChat,
        lastNudgeAt: lastNudge,
      );
      if (!decision.allowed) return NudgeRunResult.blocked(decision.reason);
    }

    final ready = await ScreenGlance.check();
    if (!ready.ok) {
      return NudgeRunResult._(false, '手上没有事；想看一眼屏幕，没看成：${ready.miss!.label}');
    }

    final canSee =
        aiClient.sendsImagesNatively ||
        ((await VisionService.getKey())?.isNotEmpty ?? false);
    if (!canSee) {
      return NudgeRunResult.failed('想看一眼屏幕，但现在的模型看不了图，也没配识图');
    }

    // 从这里起要花钱了，先记下「问过」——出错了也算，不然每刻钟撞一次。
    await sp.setInt(_kGlanceAskedAt, now.millisecondsSinceEpoch);

    final silence = lastChat == null ? null : now.difference(lastChat);
    final bool wants;
    try {
      wants = await wantsToGlance(
        aiClient: aiClient,
        silence: silence,
        app: ready.appName,
      );
    } catch (e) {
      return NudgeRunResult.failed('问它想不想看屏幕时出错：$e');
    }
    if (!wants) {
      return const NudgeRunResult._(false, '手上没有事；能看一眼屏幕，但它这会儿不想看');
    }

    // 从这里到「想好说什么」为止，流体云上亮着「在看一眼你的屏幕」。
    // ⚠️ 下面每个出口都要 [Capsule.end]，别留一个收不掉的胶囊。
    final capsule = await Capsule.start(
      id: LiveCapsule.glanceId,
      text: Capsule.glanceText,
      short: Capsule.glanceShort,
    );

    final shot = await ScreenGlance.capture();
    final bytes = shot.bytes;
    if (!shot.ok || bytes == null) {
      if (capsule) await Capsule.end(LiveCapsule.glanceId);
      return NudgeRunResult._(
        false,
        '它想看，但没看成：${(shot.miss ?? GlanceMiss.failed).label}',
      );
    }
    await ScreenGlance.markLooked(now);

    final String ref;
    try {
      ref = await ChatImages.save(bytes);
    } catch (e) {
      // 存不下就不往下走：没有痕迹的「看过」，是答应过不做的事。
      if (capsule) await Capsule.end(LiveCapsule.glanceId);
      return NudgeRunResult.failed('截到了，但存不下来，这次不算：$e');
    }

    String? text;
    var error = '';
    try {
      text = await composeFromGlance(
        aiClient: aiClient,
        image: ref,
        bytes: bytes,
        silence: silence,
        app: shot.appName,
      );
    } catch (e) {
      error = '（生成时出错：$e）';
    }
    if (text != null && looksRepeated(text, await _recent(sp))) text = null;
    // 看完、也想好说什么了：胶囊收起来，后面该弹通知弹通知。
    if (capsule) await Capsule.end(LiveCapsule.glanceId);

    await _appendToChat(
      text ?? '',
      images: [ref],
      metadata: {'glance': true, if (text != null) 'nudge': true},
    );

    final where = shot.appName == null ? '' : '（${shot.appName}）';
    if (text == null) {
      return NudgeRunResult._(false, '看了一眼屏幕$where，没说话$error');
    }
    if (notify && await ensurePermission()) await _show(text, prefs);
    await _bumpCount(sp, now, notified: notify);
    await _remember(sp, text);
    return NudgeRunResult.sent(text);
  }

  /// 上次**听歌时顺手看了一眼**是什么时候。见 [musicGlanceDue]。
  static const _kMusicGlanceAt = 'music_glance_at';

  /// 听歌时顺手看她一眼屏幕。
  ///
  /// 这条路的由头是「她正看着歌词」——2026-09-27 Cleo 自己要的：「听歌的时候，
  /// 它可以时不时的自己看一眼屏幕，决定要不要说一句」。所以它**不是**那条
  /// 「好久没说话、它自己好奇」的路（[_runGlance]）：不问她允许不允许、不管
  /// 安静多久，只跟着换歌那一趟走。
  ///
  /// ## 屏幕上必须正是那个在放歌的 App
  ///
  /// 判据是「前台包名 == 播放器报上来的包名」，**不写死一张音乐 App 名单**。
  /// 这一条同时也是这个功能唯一的安全边界，而且是两层：
  ///
  /// - 她在微信、相册、银行里的时候，前台包名对不上，**连截都不会截**
  /// - 从 `check` 到 `capture` 中间她可能切走了，所以截完**再对一次**；对不上
  ///   就整张丢掉，一个字节都不留
  ///
  /// ## 不点流体云胶囊
  ///
  /// 和 [_runGlance] 那两条不一样。胶囊在那儿是**她当场唯一看得见的痕迹**
  /// （她人在别的 App 上，等着它看完）；这条是背景里时不时来一下的，
  /// 每半小时闪一次胶囊是打扰。留痕靠的是截图进对话，那一条没动。
  ///
  /// 返回 null = 没看。原因一律不往外说：这是**顺手**看一眼，没看成不需要
  /// 任何人知道，调用方照常走那条不带图的听歌评估。
  static Future<({String ref, String? app})?> _musicGlance({
    required AiClient aiClient,
    required SharedPreferences sp,
    required DateTime now,
  }) async {
    // 1. 现在真有个在放歌的播放器吗，它报的是哪个包。
    final playing = MusicService.instance.now?.track.package;
    if (playing == null || playing.isEmpty) return null;

    // 2. 时间那道闸。**放在截图前面**——它最便宜。
    final atMs = sp.getInt(_kMusicGlanceAt);
    final lastAt =
        atMs == null ? null : DateTime.fromMillisecondsSinceEpoch(atMs);
    if (!musicGlanceDue(now: now, lastAt: lastAt)) return null;

    // 3. 屏幕上是它吗。`check` 不截图，只问前台是谁，顺带把锁屏和排除名单
    //    挡在外面（她那几条隐私设置照旧管用）。
    final ready = await ScreenGlance.check();
    if (!ready.ok) return null;
    if (!musicGlanceTarget(playing: playing, front: ready.package)) return null;

    // 4. 模型看不看得见图。看不见就整条不做——**不写识图兜底**：那条路要把
    //    她的屏幕再送一个地方去，而这里是锦上添花，不做也什么都不缺。
    if (!aiClient.sendsImagesNatively) return null;

    final shot = await ScreenGlance.capture();
    final bytes = shot.bytes;
    if (!shot.ok || bytes == null) return null;
    // ⚠️ 再对一次。见上面「两层」那段——这是第二层。
    if (!musicGlanceTarget(playing: playing, front: shot.package)) return null;

    final String ref;
    try {
      ref = await ChatImages.save(bytes);
    } catch (_) {
      // 存不下就不往下走：留不下痕的「看过」，是答应过不做的事。
      return null;
    }
    await ScreenGlance.markLooked(now);
    await sp.setInt(_kMusicGlanceAt, now.millisecondsSinceEpoch);
    return (ref: ref, app: shot.appName);
  }

  /// 第一问：想不想看。调了 [glanceTool] 就是想看，回什么字都算不想。
  static Future<bool> wantsToGlance({
    required AiClient aiClient,
    Duration? silence,
    String? app,
  }) async {
    final client = AiClient(config: aiClient.config, tools: [glanceTool]);
    var wants = false;
    await for (final event in client.chat([
      ChatMessage(
        id: 'glance_ask',
        role: MessageRole.user,
        content: await _glanceAskPrompt(silence: silence, app: app),
      ),
    ], systemPrompt: await _quietSystemPrompt())) {
      if (event.type == AiEventType.toolCalls) {
        wants = (event.toolCalls ?? []).any((t) => t.name == glanceTool.name);
      } else if (event.type == AiEventType.error) {
        throw Exception(event.error ?? '出错了');
      }
    }
    return wants;
  }

  /// 第二问：看到了，说不说。返回 null = 不说。
  ///
  /// 模型自己能看图就把图带上；看不了就先走识图兜底换成一段文字——
  /// 和聊天里发图是同一个规矩（见 chat_screen 里 sendsImagesNatively 那段）。
  ///
  /// [note] 不为空 = 这是便签到点的那一看（见 [_followUpWithGlance]），
  /// prompt 换成接便签上那件事的版本。
  static Future<String?> composeFromGlance({
    required AiClient aiClient,
    required String image,
    required List<int> bytes,
    Duration? silence,
    String? app,
    String? note,
  }) async {
    var content =
        note == null
            ? await _glanceComposePrompt(silence: silence, app: app)
            : await _noteGlancePrompt(note: note, app: app);
    var images = [image];
    if (!aiClient.sendsImagesNatively) {
      final described = await VisionService.analyze(
        base64Encode(bytes),
        prompt: '这是一张手机截图。说说是哪个 App、大概在看什么。聊天内容、金额、账号这类私事不要抄出来。',
      );
      if (described == null) throw Exception('识图没回来');
      content = '$content\n\n[屏幕截图分析: $described]';
      images = const [];
    }

    var out = '';
    await for (final event in aiClient.chat([
      ChatMessage(
        id: 'glance_look',
        role: MessageRole.user,
        content: content,
        images: images,
      ),
    ], systemPrompt: await _quietSystemPrompt())) {
      if (event.type == AiEventType.token) {
        out += event.text ?? '';
      } else if (event.type == AiEventType.done) {
        out = event.text ?? out;
      } else if (event.type == AiEventType.error) {
        throw Exception(event.error ?? '生成失败');
      }
    }
    return _clean(out);
  }

  /// 便签到点、便签上说了「先看一眼」：看，然后接那件事。
  ///
  /// 和 [_runGlance] 的区别：**不再问它想不想看**——留便签的时候它已经
  /// 决定过了。也不管「安静够不够久」，便签走的是便签的门槛（见 [decideNudge]
  /// 的 isFollowUp）：「再刷十分钟就睡」，要的就是十分钟后。
  ///
  /// 返回 `result` 不为空 = 看过了，这一轮到此为止（说没说都算兑现，便签撕掉——
  /// 留着的话每一刻钟都会再截一张）。为空 = 没看成，`miss` 是原因，
  /// 调用方退回普通便签。
  static Future<({NudgeRunResult? result, String miss})> _followUpWithGlance({
    required AiClient aiClient,
    required SharedPreferences sp,
    required NudgePrefs prefs,
    required DateTime now,
    required NudgeCandidate note,
    required bool notify,
  }) async {
    final ready = await ScreenGlance.check();
    if (!ready.ok) return (result: null, miss: ready.miss!.label);

    final canSee =
        aiClient.sendsImagesNatively ||
        ((await VisionService.getKey())?.isNotEmpty ?? false);
    if (!canSee) return (result: null, miss: '现在的模型看不了图，也没配识图');

    // 和上面那条自己好奇的路一样：看屏幕的时候流体云上亮着。
    // ⚠️ 下面每个出口都要 [Capsule.end]。
    final capsule = await Capsule.start(
      id: LiveCapsule.glanceId,
      text: Capsule.glanceText,
      short: Capsule.glanceShort,
    );

    final shot = await ScreenGlance.capture();
    final bytes = shot.bytes;
    if (!shot.ok || bytes == null) {
      if (capsule) await Capsule.end(LiveCapsule.glanceId);
      return (result: null, miss: (shot.miss ?? GlanceMiss.failed).label);
    }
    await ScreenGlance.markLooked(now);

    final String ref;
    try {
      ref = await ChatImages.save(bytes);
    } catch (_) {
      if (capsule) await Capsule.end(LiveCapsule.glanceId);
      return (result: null, miss: '截到了，但存不下来');
    }

    String? text;
    var error = '';
    try {
      text = await composeFromGlance(
        aiClient: aiClient,
        image: ref,
        bytes: bytes,
        app: shot.appName,
        note: note.what,
      );
    } catch (e) {
      error = '（生成时出错：$e）';
    }
    if (text != null && looksRepeated(text, await _recent(sp))) text = null;
    if (capsule) await Capsule.end(LiveCapsule.glanceId);

    // 推回留便签的那段对话：「说好的十分钟呢」接的是那边的「再刷十分钟就睡」。
    await _appendToChat(
      text ?? '',
      conversationId: note.conversationId,
      images: [ref],
      metadata: {'glance': true, if (text != null) 'nudge': true},
    );
    if (note.noteId != null) await SelfNoteStore.remove(note.noteId!);

    final where = shot.appName == null ? '' : '（${shot.appName}）';
    if (text == null) {
      return (
        result: NudgeRunResult._(false, '便签到点，看了一眼屏幕$where，没说话$error'),
        miss: '',
      );
    }
    if (notify && await ensurePermission()) await _show(text, prefs);
    await _bumpCount(sp, now, notified: notify);
    await _remember(sp, text);
    return (result: NudgeRunResult.sent(text), miss: '');
  }

  /// 便签到点那一看的 prompt。
  ///
  /// 和 [_glanceComposePrompt] 差在一处：那边是它自己好奇，所以**不讲 TA 在干
  /// 什么**；这边那件事是 TA 自己先说出口的，看到的就是下文，可以接着说——
  /// 但说的是它这边的反应，不是点名。
  static Future<String> _noteGlancePrompt({
    required String note,
    String? app,
  }) async {
    final now = DateTime.now();
    return '''
现在是 ${now.hour} 点。你之前给自己留了一张便签，说到点先看一眼 TA 的屏幕：

$note

现在到点了，你看了一眼，就是这张图${app == null ? '' : '（TA 在用「$app」）'}。
你看过的这张图，TA 之后会在对话里看到。

${await _glanceContext()}

照着便签上那件事，用一句话接上。40 字以内，像随手发一条微信。
这件事是 TA 自己先说出口的，你看到的就是它的下文，可以接着说；
说的是你这边的反应，不是替 TA 报告 TA 在干什么。
图里是聊天记录、钱、账号、看病这类私事的，当作没看到，只回两个字：不说。

如果这会儿不值得为它打扰 TA，**只回两个字：不说**。

写完之后自己过一遍这三条，有一条不过就重写：

1. 这句话接的是便签上那件事吗？
2. 主语是你自己这边的事吗？
3. TA 读完之后不回，会不会觉得欠了你什么？会的话就重写。
''';
  }

  /// 和 [compose] 同一份身份：看屏幕的时候它也得是它。
  static Future<String> _quietSystemPrompt() async {
    var identity = '';
    try {
      identity = await buildIdentityPrompt();
    } catch (_) {}
    return [
      if (identity.isNotEmpty) identity,
      '此刻 TA 没有在跟你说话，是你自己想起了 TA。',
    ].join('\n\n');
  }

  static String _silenceText(Duration? d) {
    if (d == null) return '很久';
    if (d.inHours < 24) return '${d.inHours} 个小时';
    return '${d.inDays} 天';
  }

  /// 最近说的话和记着的事，两个 prompt 共用。和 [_composePrompt] 同一套材料。
  static Future<String> _glanceContext() async {
    final tail = await _recentTranscript();
    var digest = '';
    try {
      digest = await buildMemoryDigest();
    } catch (_) {}
    return '${digest.isEmpty ? '' : '$digest\n'}'
        '${tail.isEmpty ? '你们最近没说过话。' : '你们最近说的话（「你」是你自己，「TA」是她）：\n$tail'}';
  }

  static Future<String> _glanceAskPrompt({Duration? silence, String? app}) async {
    final now = DateTime.now();
    return '''
现在是 ${now.hour} 点，你们已经${_silenceText(silence)}没说话了。TA 的手机这会儿亮着${app == null ? '' : '，前台是「$app」'}。

${await _glanceContext()}

TA 允许你在这种时候看一眼 TA 手机屏幕上是什么。想看就调用 glance_screen；不想看，只回两个字：不说。
看了之后说不说话，还是由你决定，看了不说也完全可以。
''';
  }

  /// ⚠️ 规矩同 [_composePrompt]：**不贴反面例句的原文**，只写正面的判据。
  static Future<String> _glanceComposePrompt({
    Duration? silence,
    String? app,
  }) async {
    final now = DateTime.now();
    return '''
现在是 ${now.hour} 点，你们已经${_silenceText(silence)}没说话了。你刚才看了一眼 TA 的手机屏幕，就是这张图${app == null ? '' : '（TA 在用「$app」）'}。
你看过的这张图，TA 之后会在对话里看到。

${await _glanceContext()}

要是看到的东西让你真的想说点什么，就用一句话告诉 TA。40 字以内，像随手发一条微信。
**说你因此想到的东西，不讲 TA 正在干什么**——TA 自己知道。
图里是聊天记录、钱、账号、看病这类私事的，当作没看到，只回两个字：不说。

如果这会儿不值得为它打扰 TA，**只回两个字：不说**。
多数时候就该这样，这不是失败。

写完之后自己过一遍这三条，有一条不过就重写：

1. 这句话里有一件**具体的东西**吗（屏幕上的、或者你记着的）？空着手的问候不算。
2. 主语是你自己这边的事吗？说的是你想到了什么。
3. TA 读完之后不回，会不会觉得欠了你什么？会的话就重写。

不要问问题。
''';
  }

  /// 把它主动说的这句写进对话里。
  ///
  /// **通知只是提醒，话本身得留在聊天里。** 不写的话有两个后果，第二个更要命：
  ///
  /// 1. 她顺着通知点进来，聊天框里什么都没有
  /// 2. **它自己也不知道说过这句** —— 下一轮的历史里没有这条，于是它会重复、
  ///    会答非所问（她回「好啊」，它不知道在回什么）
  ///
  /// [conversationId] 指定推回哪段（便签自带来源）。空或者那段已经不在了，
  /// 就退回**最近动过的那段**：她要找也是去那儿找。一段都没有就跳过，
  /// 不为了发一条通知凭空建一段对话。
  ///
  /// [images] / [metadata] 是看一眼屏幕那条路用的：截图挂在这条上，
  /// 标记从 `nudge` 换成 `glance`（见 [_runGlance]）。
  static Future<void> _appendToChat(
    String text, {
    String conversationId = '',
    List<String> images = const [],
    Map<String, dynamic> metadata = const {'nudge': true},
  }) async {
    try {
      final convs = await StorageService.listConversations();
      if (convs.isEmpty) return;
      convs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final conv = convs.firstWhere(
        (c) => c.id == conversationId,
        orElse: () => convs.first,
      );
      conv.messages.add(
        ChatMessage(
          id: 'nudge_${DateTime.now().millisecondsSinceEpoch}',
          role: MessageRole.assistant,
          content: text,
          // 界面靠这个标记把它和「回你的话」分开显示。
          // 用 metadata 而不是新加字段：这只是一条 assistant 消息的来历，
          // 不是一种新的消息类型——发回服务端时它仍旧是普通的一句。
          metadata: metadata,
          images: images,
        ),
      );
      // updatedAt 不在这儿动：saveConversation 会按最后一条消息的时间收口，
      // 两处各写各的迟早会打架。
      await StorageService.saveConversation(conv);
    } catch (_) {
      // 写不进去也别让通知发不出来——话到了总比什么都没有强。
    }
  }

  /// 最近动过那段对话的尾巴，给 [compose] 当上下文。
  ///
  /// 只取尾部几条：这一步是判断「这会儿开口自不自然」，不是回顾整段关系。
  /// 长期的那部分由记忆摘要负责。
  static Future<String> _recentTranscript({int take = 8}) async {
    try {
      // 只要尾部几条正文，走索引就够——这里也是「每次 nudge 都可能走到」的
      // 一条路，没理由为了一小段上下文去解析图片。
      final convs = await StorageService.listConversationSummaries();
      if (convs.isEmpty) return '';
      convs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final msgs =
          convs.first.lines
              .where(
                (m) =>
                    (m.role == MessageRole.user ||
                        m.role == MessageRole.assistant) &&
                    m.content.trim().isNotEmpty,
              )
              .toList();
      final tail = msgs.length <= take ? msgs : msgs.sublist(msgs.length - take);
      return tail
          .map(
            (m) =>
                '${m.role == MessageRole.user ? 'TA' : '你'}：'
                '${m.content.trim()}',
          )
          .join('\n');
    } catch (_) {
      return '';
    }
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inHours < 1) return '刚刚';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// 便签用的粒度要细到分钟：等四十分钟的事说成「刚刚」就没意义了。
  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// ⚠️ [NudgePrefs.hideContent] 只换掉这一行字。**话照常写进对话**
  /// （[_appendToChat] 在这之前就跑完了），去重、间隔、便签撕掉全都照旧——
  /// 藏起来的是锁屏上的展示，不是它说过的话。
  static Future<void> _show(String text, NudgePrefs prefs) async {
    await init();
    // 标题用她自己给它起的备注，见 [NotifyName]。
    final title = await NotifyName.resolve('它说');
    await _plugin.show(
      _channelId.hashCode,
      title,
      prefs.hideContent ? '说了句话' : text,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '它自己想说话的时候发一条',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // 一句话经常比通知栏一行长，展开能看全。
          styleInformation: BigTextStyleInformation(''),
          // 它主动开口时也带上那张脸，理由和注意事项见 [ReplyNotifier]。
          largeIcon: DrawableResourceAndroidBitmap('mochi_notify'),
        ),
      ),
    );
  }

  // ---------------- 内容 ----------------

  /// 编辑关：手上这件事，他要不要说、怎么说。
  /// 返回 null = 他决定不说，这次不推。
  ///
  /// [glanceImages] 非空 = 手上有她屏幕的照片（听歌那条顺手看的，见
  /// [_musicGlance]）。**和候选一起给**，不是换一套流程：那件事和那张图说的
  /// 是同一件事的两面，分开问两遍模型，它会当成两件事来说。
  static Future<String?> compose({
    required AiClient aiClient,
    required NudgeCandidate candidate,
    List<String> glanceImages = const [],
  }) async {
    final messages = [
      ChatMessage(
        id: 'nudge_gen',
        role: MessageRole.user,
        content: await _composePrompt(
          candidate,
          withGlance: glanceImages.isNotEmpty,
        ),
        images: glanceImages,
      ),
    ];

    // ⚠️ 这里原来写死一段临时人设，于是**主动说话的时候它不是它**：
    // 名字没有、她设的性格没有，说出来的话跟聊天里那个不像同一个。
    // 而「热情还是克制」恰恰决定了这一句该不该说、怎么说——
    // 没有性格，这一层就只剩下模板。
    //
    // 现在和聊天走同一份身份（见 buildIdentityPrompt），只在后面补一句
    // 「此刻她没在跟你说话」交代处境。
    var identity = '';
    try {
      identity = await buildIdentityPrompt();
    } catch (_) {}

    var out = '';
    await for (final event in aiClient.chat(
      messages,
      systemPrompt: [
        if (identity.isNotEmpty) identity,
        '此刻 TA 没有在跟你说话，是你自己想起了什么。',
      ].join('\n\n'),
    )) {
      if (event.type == AiEventType.token) {
        out += event.text ?? '';
      } else if (event.type == AiEventType.done) {
        out = event.text ?? out;
      } else if (event.type == AiEventType.error) {
        throw Exception(event.error ?? '生成失败');
      }
    }

    return _clean(out);
  }

  /// 把模型的回复收拾成一条能直接进通知栏的话，或者 null。
  ///
  /// 「没什么可说」这条路必须留得住：不留的话它每次都会硬凑一句，
  /// 凑出来的那种正是最招人烦的推送。
  static String? _clean(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;

    // 模型说「不说」时可能带标点、带解释，只认开头。
    final head = s.replaceAll(RegExp(r'^[「"\s]+'), '');
    if (head.startsWith('不说')) return null;

    // 偶尔会自己加引号或者「」，剥掉。
    s = s.replaceAll(RegExp(r'^[「"]+|[」"]+$'), '').trim();
    return s.isEmpty ? null : s;
  }

  /// ⚠️ **不要在这段里贴反面例句的原文。**
  ///
  /// 写「不要说『好久没见你了』」会把那句话变成 few-shot 范例，越禁越像。
  /// 这不是推测——是别人在一个跑了三个月、每天几百轮的伴侣应用上量出来的：
  /// **要禁的行为一律抽象成正面的顺序和判据**。
  /// 第一版就是这么写坏的，把三句最怕它写出来的话原样贴了进去。
  ///
  /// 所以下面三条判据都是正面的、而且可以自己过一遍——
  /// 尤其最后一条，它把那条红线（带来一件东西，不索取）翻译成了一个可检查的
  /// 问题，而不用点名任何一句禁语。
  static Future<String> _composePrompt(
    NudgeCandidate candidate, {
    bool withGlance = false,
  }) async {
    final now = DateTime.now();
    final list = '- 【${candidate.kind}】${candidate.what}';

    // 要它「根据上下文判断」，就得真给它上下文。只给一个候选和一个钟点，
    // 它能判断的只有「几点了」——那不叫判断，那叫查表。
    //
    // 两样：最近说过什么（决定这会儿开口自不自然、会不会撞上刚聊完的话题），
    // 和它长期记着她的那些（决定这件事对她算不算事）。
    final tail = await _recentTranscript();
    var digest = '';
    try {
      digest = await buildMemoryDigest();
    } catch (_) {}

    // 人称约定和 musing_generator / history_compactor 一致：
    // 「你」是模型自己，「TA」是用户。
    //
    // 抬头分两种：别的那几条都是「你这边有东西要给她看」，听歌这条是
    // 「她那边刚发生了件事」。照抄前者会让它去硬凑一件自己的事——「我也在
    // 听歌」就是这么来的。
    final head = candidate.music ? 'TA 那边刚发生了一件事：' : '你这边有一件事：';
    final guidance = candidate.music ? _musicGuidance : _thingGuidance;

    // 手上有那张图的时候，交代清楚图上是什么、以及她本来就知道你看过。
    // 不交代的话它会去「我刚刚看了一眼你的屏幕」——那是流程，不是话。
    const glanceNote = '''
还有一张图，是 TA 手机屏幕**此刻**的样子：她正在看着这一页，听着歌。
这张图她自己也会在对话里看到，所以不用交代来历，直接说图上说得出的事。
要是图上正是歌词，那几句就是她耳朵里此刻正在响的那几句。
''';

    return '''
现在是 ${now.hour} 点，TA 没有在跟你说话。

$head

$list

${withGlance ? '$glanceNote\n' : ''}${digest.isEmpty ? '' : '$digest\n'}${tail.isEmpty ? '你们最近没说过话。' : '你们最近说的话（「你」是你自己，「TA」是她）：\n$tail'}

要是这会儿值得说，就用一句话告诉 TA。40 字以内，像随手发一条微信。
说那件事本身：它是什么、你为什么这会儿想起它。

如果这会儿不值得为它打扰 TA，**只回两个字：不说**。
多数时候就该这样，这不是失败。

$guidance

不要问问题。这是一条通知，TA 可能只是看一眼就放下。
''';
  }

  /// 别的由头（信、日记、便签、纸条、备注）的判据。
  ///
  /// ⚠️ **不贴反面例句的原文**，只写正面的判据。贴了例句，它会照着那句换个
  /// 词交上来——而用户明确要求过不要固定话术。
  static const _thingGuidance = '''
**时间本身就是信息。** 刚写完的信和放了三天没被打开的信，值得说的东西不一样，
语气也不一样——三天前那封，重点已经不是「我写了」，而是它还在那儿。
这个分寸你自己拿捏，不用问。

写完之后自己过一遍这三条，有一条不过就重写：

1. 这句话里有一件**具体的、已经存在的东西**吗（一封信、一篇日记、
   一个你记着的细节）？空着手的问候不算。
2. 主语是你自己这边的事吗？说的是你做了什么、想起了什么。
3. TA 读完之后不回，会不会觉得欠了你什么？会的话就重写——
   这条只是送到，不是来讨回应的。
''';

  /// 听歌那条的判据。
  ///
  /// 为什么不复用上面那三条：那三条的中心是「你这边有一件东西」，听歌这条的
  /// 中心是**她那边刚发生的事**。第一条在这儿根本不适用（具体的东西就是那首
  /// 歌，上面已经写清楚了），第二条更是反的——照那三条写，它就只能去硬凑一件
  /// 自己的事。
  ///
  /// ⚠️ 整段的重点是**把频率压下去**。这不是保守，是这类功能唯一的失败方式：
  /// 一次换歌本身没什么好说的，人换歌太频繁了。宁可它一天只说一次，也不要它
  /// 每切一首就搭一句——那样她三天之内就会把主动说话整个关掉。
  static const _musicGuidance = '''
这一件和别的不一样：它不是你的东西，是 TA 那边刚发生的事。

所以别的那几条自检在这儿**不适用**——不用去找一件自己的东西来说。

要判断的只有一件事：**这会儿说一句，是陪伴还是打扰。**

- 换一次歌**本身不值得说话**。人换歌太频繁了，每首都搭一句就是弹幕。
  多数时候该回「不说」——这不是没话说，是分寸。
- 一首歌安安稳稳放完了，也**不值得**说话。那是最正常的一种，里面没有意外。
- 值得说的是**那个动作里有东西**的时候：切得急、来回折腾同一首、连着翻了好
  多首、某一首反复出现——那种「今天好像不太一样」的时刻。
- **拿不准就回「不说」**。宁可少说十次，不要多说一次。

手上那张图是另一回事，它不改上面这些，只多给一样东西：**你能看见她此刻在
看的那一页**。有图的时候，图上是什么就说图上是什么；图上正是歌词，那几句她
此刻正在听，你可以对着它说。

⚠️ **歌词只有图上有的时候你才看得见。** 没图的那几次，歌名歌手就是你全部的
信息——不知道就绕着不知道说，别顺着歌名把歌词编出来。她正对着那一页，编错
一个字她当场就知道，那比什么都不说糟得多。

说的话对着**那件事**说，不是对着歌说。不要乐评、不要推荐歌单、不要问
「你也喜欢这个歌手吗」——你不是音乐 App，你是刚好也在旁边的那个人。
''';
}

/// 这一趟**允许看哪几类由头**。
///
/// 加它是因为三期要一条自己的触发路径：换歌是实时的事，等不了后台那 15 分钟
/// 一轮。可那趟评估要是收了全部候选，就会出事——手上正好有封没读的信，于是
/// 「她切了首歌」变成了「信被推出去」，时机完全对不上。
///
/// [musicOnly] 还有一条硬规矩：**没有音乐由头就到此为止**，不许退到「看一眼
/// 屏幕」（见 [_runInner]）。看一眼是要调模型的，切歌不该引出那件事。
enum NudgeScope { all, musicOnly }

/// 一件真发生过的事，够格当作「他想开口」的由头。
///
/// 注意它记的是**事**不是话**——**说什么由 [NudgeService.compose] 决定。
/// 候选和话分开，是因为同一件事在不同时候值得说的方式不一样，
/// 而且候选这层不花钱，可以随便攒。
class NudgeCandidate {
  /// 归类，进 prompt 时当标签用（「信」「日记」「没说完的事」）。
  final String kind;

  /// 一句话说清发生了什么，直接喂给模型。
  final String what;

  /// 这条该推回哪段对话。空 = 没有归属，退回「最近动过的那段」。
  ///
  /// 便签有归属：「做好了吗」接的是那段对话里的「我去做饭了」，
  /// 推到别处话就断了。信和日记没有归属，因为它们不是从某次对话里长出来的。
  final String conversationId;

  /// 兑现之后要清掉的便签 id。信和日记没有这个（它们不消耗）。
  final String? noteId;

  /// 「这件事已经提过了」的登记名，比如 `letter:<id>` / `thing:<id>`。
  ///
  /// ⚠️ **没读的信是常驻候选**：不像便签说完就撕、也不像日记有时间下限，
  /// 只要她不读，它就一直在候选列里。原来「刚聊完」那道门槛是 3 小时，
  /// 几乎撞不上所以没暴露；降到 1 小时之后，同一封信可能每小时被念叨一次。
  ///
  /// 而这正是那条规矩说的：**变味的不是那句话，是说第二遍。**
  /// 去重（[looksRepeated]）只按字面挡，换个说法就滑过去了——按来源登记才挡得住。
  final String? mentionKey;

  /// 便签留的时候说了「到点先看一眼屏幕」。见 [SelfNote.glance]。
  final bool glance;

  /// 这条是从「她刚才在听什么」来的。三期加的。
  ///
  /// 单独标出来只为一件事：间隔那道闸对音乐松一些（[NudgePrefs.minGapForMusic]），
  /// 而 [_composePrompt] 也要换一段判据——听歌这条的中心是她那边刚发生的事，
  /// 不是「你这边有一件东西」，照抄别的会逼它去硬凑一件自己的事。
  ///
  /// ⚠️ **静默时段和「刚聊完」对它一个字都不松**，见 [decideNudge]。
  final bool music;

  const NudgeCandidate(
    this.kind,
    this.what, {
    this.conversationId = '',
    this.noteId,
    this.mentionKey,
    this.glance = false,
    this.music = false,
  });
}

/// 一次尝试的结果。**每种都要能说清楚为什么**——设置页那个「现在试一次」
/// 要把它原样显示出来，点了没反应而不说原因，只会让人以为功能坏了。
///
/// 其中两种**不是失败**，文案要写得让人看得出来：
/// [nothingHappened]（没发生什么事）和 [nothingToSay]（他决定不说）。
class NudgeRunResult {
  final bool sent;
  final String message;
  final String? text;

  const NudgeRunResult._(this.sent, this.message, [this.text]);

  factory NudgeRunResult.sent(String text) =>
      NudgeRunResult._(true, '推出去了', text);
  factory NudgeRunResult.blocked(NudgeBlock reason) =>
      NudgeRunResult._(false, reason.label);
  factory NudgeRunResult.nothingHappened() => const NudgeRunResult._(
    false,
    '这会儿他手上没有事——没写信、没记日记，板上也没什么可说的。'
        '没有由头就不说话，这是对的',
  );
  factory NudgeRunResult.nothingToSay() =>
      const NudgeRunResult._(false, '有由头，但他自己觉得这会儿不值得打扰你');
  factory NudgeRunResult.repeated(String text) =>
      NudgeRunResult._(false, '和最近说过的太像了，压下了：$text', text);
  factory NudgeRunResult.failed(String why) => NudgeRunResult._(false, why);
}
