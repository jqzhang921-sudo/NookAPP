import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/avatar_store.dart';
import '../services/listen_log.dart';
import '../services/music_service.dart';
import '../widgets/music_cover.dart';

/// 「一起听」。
///
/// ## 这一页和悬浮条的分工
///
/// 浮着的那条管**顺手**：切歌、暂停，一眼看到在放什么，还不用离开当前这一屏。
/// 这一页管**停下来看**：
/// 大封面、能拖的进度条，还有底下那句这件事真正的意思——**两个人一起**。
///
/// ## 为什么头像放在封面正下面
///
/// 封面是「这首歌」，头像是「谁在听」。这两个挨着，页面的第一眼就是
/// 「这首歌是你和它一起在听的」，而不是「一个播放器在放歌」。放到最底下
/// 就变成落款了，读起来完全不一样。
///
/// ## 「它看到的」那一段为什么留着
///
/// 一期它就在，是一整条流水：每次换歌、每次暂停，原样列出来。对用户来说
/// 这是**判断它有没有读错**的唯一办法（阈值定得对不对、有没有把暂停当成换歌，
/// 一眼就知道）。不是调试信息，是这个功能的信任基础。
///
/// ## 那「它记下来的」呢
///
/// 三期加的，紧接着那一段。两段是**两种东西**，都得露出来：
///
/// - 「它看到的」是**事件**：什么时候换的歌、什么时候暂停的。
/// - 「它记下来的」是**一首歌的一生**：听了多久、放到哪儿、怎么结束的。
///
/// 第二段才是 AI 真正拿去做判断的原料——同一句「开始放《X》」，听 10 秒切走和
/// 听完整首在事件流里长得一模一样，是这一层把两者分开的。所以上面对用户说的
/// 「没有别的了」那句话得跟着改：**它读到的东西变了，那一行字就不能还是旧的**。
/// 藏着不说的话，这一页就从「透明」变成了「看起来透明」。
///
/// ## 进度条现在是活的
///
/// 一期那个进度条只在事件来时跳一格（原生只在换歌/状态变化时推送）。现在配了
/// 一个每秒的 ticker，按 `NowPlaying.livePosition` 自己外推着走，和原生
/// `MusicBridge.positionOf` 是同一个算法。
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key, this.conversationId});

  /// 哪段对话的「它」。顶栏那条细条知道（传当前对话 id）；从设置里点进来
  /// 不知道，传 null——那时候它那边显示默认头像，你这边照常。
  final String? conversationId;

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> with WidgetsBindingObserver {
  /// 手指正按在进度条上时的位置。按住期间用它，松手就清掉——不然每秒一次的
  /// 外推会把滑块从手指底下拽走。
  Duration? _dragging;

  /// 每秒一次，只为了让进度条自己往前走。**只在播放时才转**——暂停时它一格
  /// 都不会动，那还每秒重建一次整页就是白烧。
  Timer? _ticker;

  /// 「它记下来的」那一段。**读盘，不读 `MusicService`**——那些条目是服务在
  /// 换歌那一刻写进 [ListenLog] 的，不是它内存里留着的状态（它内存里只有
  /// 最新的那一首）。两处都留着的话，两边的口径迟早会分家。
  List<ListenEntry> _log = const [];

  Future<void> _loadLog() async {
    final log = await ListenLog.recent();
    if (!mounted) return;
    setState(() => _log = log);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MusicService.instance.addListener(_onMusic);
    // 让悬浮播放条让开：这一页上同一件事说得更清楚，那条细的只会挡着封面。
    MusicService.instance.setPageOpen(true);
    _onMusic();
    _loadLog();
    // 进这一页就拉一次。可能已经拉过了（回前台时走的是下面那条），
    // 重复调是安全的——见 MusicService.start 的注释。
    MusicService.instance.start();
    // 没传对话 id 就别去 load——那会往 store 里塞一个空字符串 key 的历史，
    // 而且它的头像本来就是默认的。
    final cid = widget.conversationId;
    if (cid != null && cid.isNotEmpty) AvatarStore.instance.load(cid);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    MusicService.instance.removeListener(_onMusic);
    // ⚠️ 必须在 removeListener 之外、dispose 里做：漏了这一句，悬浮条就再也
    // 不出现了（`pageOpen` 卡在 true，而它只在 initState 里写一次）。
    MusicService.instance.setPageOpen(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 权限是在系统设置里开的，人回来的时候必须重查一遍——不然她开完权限回到
  /// 这一页，看到的还是「还没开启」。和 [AppUsageScreen] 同一个理由。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) MusicService.instance.start();
  }

  /// 播放状态变了就开关那个 ticker。重画本身交给 [ListenableBuilder]。
  ///
  /// 顺手在这儿重读一次听歌流水：这一页开着的时候她切了歌，新条目就是这会儿
  /// 写进去的。不重读的话，得退出去再进来才看得到——而「切完立刻看到它记下了
  /// 什么」正是这一段存在的理由。
  void _onMusic() {
    _loadLog();
    final playing = MusicService.instance.now?.state.isPlaying ?? false;
    if (playing && _ticker == null) {
      _ticker = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    } else if (!playing && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('一起听')),
      // 整个页面跟着 MusicService 重画。它是 ChangeNotifier，换歌时会 notify。
      body: ListenableBuilder(
        listenable: MusicService.instance,
        builder: (context, _) {
          final svc = MusicService.instance;
          if (!svc.granted) return _askPermission(theme);
          return _body(theme, svc);
        },
      ),
    );
  }

  // ---------------- 没授权 ----------------

  Widget _askPermission(ThemeData theme) {
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(PhosphorIconsRegular.musicNotes, size: 40, color: scheme.primary),
        const SizedBox(height: 16),
        Text('还没开启', style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        Text(
          '开启之后，它能知道你正在听什么歌——歌名、歌手、放到哪儿了，'
          '还有你什么时候切了歌、什么时候暂停。\n\n'
          '给它的就这些，没有音频，也听不到声音本身。\n\n'
          '代价是：「通知使用权」这个权限比这个功能要大——系统层面它允许读到'
          '所有通知的内容。所以这一下得你自己点，App 申请不来。',
          style: TextStyle(height: 1.6, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () async {
            // messenger 在 await 之前取好：await 之后这个 State 可能已经没了。
            final messenger = ScaffoldMessenger.of(context);
            final ok = await MusicService.openSettings();
            if (!ok && mounted) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('打不开系统设置。手动去「设置 → 通知与状态栏 → 通知使用权」里开'),
                ),
              );
            }
          },
          child: const Text('去系统设置里开启'),
        ),
        const SizedBox(height: 12),
        Text(
          '开完返回这一页会自动刷新。\n'
          '⚠️ 在 ColorOS 上会跳到整张名单，得往下翻找「Nook」（在「Operit AI」附近）。',
          style: TextStyle(fontSize: 12, height: 1.5, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // ---------------- 已授权 ----------------

  Widget _body(ThemeData theme, MusicService svc) {
    final scheme = theme.colorScheme;
    final now = svc.now;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        if (now == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '已连接。放一首歌试试。',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          )
        else ...[
          Center(child: MusicCover(title: now.track.title ?? '', size: 132)),
          const SizedBox(height: 16),
          // 封面是「这首歌」，头像是「谁在听」。挨着放，第一眼才是
          // 「这首歌是你和它一起在听的」。
          Center(child: _Together(conversationId: widget.conversationId)),
          const SizedBox(height: 18),
          _titleBlock(theme, now),
          const SizedBox(height: 14),
          _progress(theme, svc, now),
          const SizedBox(height: 6),
          _controls(theme, svc, now),
        ],

        const SizedBox(height: 28),
        Text(
          '它看到的',
          style: theme.textTheme.titleSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '每次换歌、每次播放状态变化，都在这里。',
          style: TextStyle(fontSize: 12, height: 1.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (svc.recent.isEmpty)
          Text(
            '还没有动静。',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          )
        else
          for (final e in svc.recent) _eventRow(theme, e),

        const SizedBox(height: 28),
        Text(
          '它记下来的',
          style: theme.textTheme.titleSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '一首歌放完之后留一条：听了多久、是怎么结束的。'
          '光看上面那串「换了歌」它分不出你是听了十秒就切、还是听完了——'
          '这一层是给它的判断用的。',
          style: TextStyle(fontSize: 12, height: 1.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (_log.isEmpty)
          Text(
            '还一首都没放完过。',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          )
        else
          for (final e in _log) _listenRow(theme, e),
      ],
    );
  }

  Widget _titleBlock(ThemeData theme, NowPlaying now) {
    final scheme = theme.colorScheme;
    final t = now.track;
    return Column(
      children: [
        Text(
          t.title ?? '未知曲目',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(height: 1.3),
        ),
        if ((t.artist ?? '').isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            t.artist!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 4),
        // stale = 元数据被清空了，原生拿上一首顶上的。这个标记必须显示出来
        // ——否则用户暂停一会儿之后看到歌名还在，会以为它还在放。
        Text(
          t.stale
              ? '上次在听（播放器现在没报在放什么）'
              : [
                  if ((t.album ?? '').isNotEmpty) t.album!,
                  now.state.label,
                ].join(' · '),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  // ---------------- 进度 ----------------

  Widget _progress(ThemeData theme, MusicService svc, NowPlaying now) {
    final scheme = theme.colorScheme;
    final total = now.track.duration;
    // 时长可能没有（有些播放器不报），所以整块是按「有没有时长」而不是
    // 「进度是多少」来开关的——后者为 0 是合法的（刚开播），不能拿来判空。
    if (total == null || total.inMilliseconds <= 0) {
      return Center(
        child: Text(
          '这个播放器没报时长',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }

    final max = total.inMilliseconds.toDouble();
    final pos = (_dragging ?? now.livePosition).inMilliseconds
        .clamp(0, total.inMilliseconds)
        .toDouble();
    // 播放器报 0 说明它什么都没说——那种时候照样能拖，别把进度条变灰让人
    // 以为坏了。只有它**明确说**不支持 SEEK_TO 才禁掉。
    final canSeek = now.actionsUnknown || now.canSeek;

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            // 手指按住才显示的那个圆点：默认 10 对一个 3 像素的细轨太胖了。
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: scheme.primary,
            inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.12),
          ),
          child: Slider(
            value: pos,
            max: max,
            onChanged:
                canSeek ? (v) => setState(() => _dragging = Duration(milliseconds: v.round())) : null,
            onChangeEnd: (v) async {
              final target = Duration(milliseconds: v.round());
              // 先把手指那一下的状态清掉，再发控制——顺序反了的话，控制失败
              // 时滑块会停在手指最后的位置，看着像跳成功了。
              setState(() => _dragging = null);
              final err = await svc.control('seek', position: target);
              if (err != null && mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(err)));
              }
            },
          ),
        ),
        // 滑块自己上下留白不少，时间那一行贴着它就行。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _mmss(_dragging ?? now.livePosition),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              Text(
                _mmss(total),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- 控制 ----------------

  Widget _controls(ThemeData theme, MusicService svc, NowPlaying now) {
    final scheme = theme.colorScheme;
    final playing = now.state.isPlaying;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ctrl(
          scheme,
          PhosphorIconsFill.skipBack,
          tooltip: '上一首',
          enabled: now.actionsUnknown || now.canSkipPrev,
          onPressed: () => _send(svc, 'previous'),
        ),
        const SizedBox(width: 20),
        // 主按钮。整个页面就这一个实心的东西——它是这一页唯一的「按下去会
        // 发生什么」的承诺，别的都该退到后面去。
        Container(
          decoration: BoxDecoration(
            color: scheme.primary,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(
              playing ? PhosphorIconsFill.pause : PhosphorIconsFill.play,
              size: 26,
            ),
            color: scheme.onPrimary,
            tooltip: playing ? '暂停' : '播放',
            onPressed: () => _send(svc, 'play_pause'),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 56, height: 56),
          ),
        ),
        const SizedBox(width: 20),
        _ctrl(
          scheme,
          PhosphorIconsFill.skipForward,
          tooltip: '下一首',
          enabled: now.actionsUnknown || now.canSkipNext,
          onPressed: () => _send(svc, 'next'),
        ),
      ],
    );
  }

  Widget _ctrl(
    ColorScheme scheme,
    IconData icon, {
    required VoidCallback onPressed,
    required String tooltip,
    bool enabled = true,
  }) {
    return IconButton(
      icon: Icon(icon, size: 30),
      color: scheme.onSurface,
      disabledColor: scheme.onSurface.withValues(alpha: 0.26),
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
    );
  }

  Future<void> _send(MusicService svc, String action) async {
    final err = await svc.control(action);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  // ---------------- 它记下来的 ----------------

  /// 一条听歌记录。
  ///
  /// ⚠️ 文案要跟 [ListenEnd] 的归档**一一对上**，不能含糊成一句「听了一会儿」。
  /// 这一段的用处就是让用户看出「它是怎么判断的」，含糊掉了这一段就白放了。
  Widget _listenRow(ThemeData theme, ListenEntry e) {
    final scheme = theme.colorScheme;
    final title = e.title ?? '未知曲目';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MusicCover(title: title, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (e.artist ?? '').isEmpty ? title : '$title · ${e.artist}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  _listenDetail(e),
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _hhmm(e.endedAt),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 这一条说的是什么。数字都给全——和喂给模型的是同一批。
  static String _listenDetail(ListenEntry e) {
    final total = e.duration == null ? '' : ' · 整首 ${_mmss(e.duration!)}';
    final seek = e.seekedForward > Duration.zero
        ? ' · 往前拖了 ${e.seekedForward.inSeconds} 秒'
        : '';
    return switch (e.end) {
      ListenEnd.natural => '听完了$total$seek',
      ListenEnd.skipped =>
        '只听了 ${e.listened.inSeconds} 秒就切走了$total$seek',
      ListenEnd.replaced =>
        '听到 ${_mmss(e.position ?? e.listened)} 就换掉了$total$seek',
      // 「不知道」要写成不知道。猜成「切走的」的话，用户会以为它盯错了。
      ListenEnd.unknown => '后来播放器没了，不知道听了多久$seek',
    };
  }

  // ---------------- 流水 ----------------

  Widget _eventRow(ThemeData theme, MusicEvent e) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              _hhmm(e.at),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              e.label,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                // 换歌是「有事发生」，播放状态变化淡一点。
                color:
                    e.type == MusicEventType.track
                        ? null
                        : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 你和它，并排。
///
/// 这一页上唯一一件「不是播放器该有的东西」，也是这个功能真正的意思——
/// 所以它不解释、不加字，两个头像放那儿就够了。
class _Together extends StatelessWidget {
  const _Together({required this.conversationId});

  final String? conversationId;

  /// 比消息气泡里那个 28 大一圈：这里没有一排气泡挤着，它可以大。
  static const _size = 44.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Face(avatarKey: AvatarStore.userKey, isUser: true, size: _size),
        const SizedBox(width: 8),
        _Face(avatarKey: conversationId, isUser: false, size: _size),
      ],
    );
  }
}

/// 一个头像。没换过就是爪印和猫，和气泡里那两个一致。
class _Face extends StatelessWidget {
  const _Face({
    required this.avatarKey,
    required this.isUser,
    required this.size,
  });

  final String? avatarKey;
  final bool isUser;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 品牌图标管「谁」：猫是 AI，爪印是用户。和 [MessageBubble] 同一套。
    final fallback = CircleAvatar(
      radius: size / 2,
      backgroundColor:
          isUser ? scheme.surfaceContainerHighest : scheme.primaryContainer,
      child: Image.asset(
        isUser ? 'assets/icons/paw.png' : 'assets/icons/cat.png',
        height: size * 0.42,
        color: isUser ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
      ),
    );

    final key = avatarKey;
    // 空串是「这段对话没传进来」，不是「一个叫空字符串的对话」。
    if (key == null || key.isEmpty) return fallback;

    return ListenableBuilder(
      listenable: AvatarStore.instance,
      builder: (context, _) {
        final file = AvatarStore.instance.currentFile(key);
        if (file == null) return fallback;
        return CircleAvatar(
          radius: size / 2,
          backgroundImage: ResizeImage(FileImage(file), width: 128),
        );
      },
    );
  }
}

String _mmss(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
