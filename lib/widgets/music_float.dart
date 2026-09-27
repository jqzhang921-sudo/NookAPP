import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../main.dart' show appNavigatorKey;
import '../screens/music_screen.dart';
import '../services/music_float_state.dart';
import '../services/music_service.dart';
import 'app_surface.dart';
import 'music_cover.dart';

/// 浮在 App 界面上的「一起听」。
///
/// ## 为什么从顶栏挪到这儿
///
/// 一开始它是 `ChatScreen` 的 `AppBar.bottom`——一条钉在聊天页顶上的细条。
/// 2026-09-27 Cleo：「这个播放器，就是细条，能做成悬浮的吗，可以拖动」。能。
/// 钉在顶上的问题是它只在那两页存在，而且位置是定死的：她想边看日记边切歌就
/// 没辙，想把它挪开让出地方也没辙。浮起来之后两件事都解决了。
///
/// **只浮在 Nook 自己界面上**，和 `MochiPet` 一个做法：不要
/// `SYSTEM_ALERT_WINDOW`、不被 ColorOS 的后台策略管、不挡别的 App。挂在
/// `MaterialApp.builder` 那一层，所以它盖在所有页面之上，包括推进导航栈的
/// 设置页、日记、信。
///
/// ## 和小猫的层叠顺序
///
/// 它画在**小猫下面**（见 `main.dart` 里那个 Stack 的顺序）。小猫只有 72 宽，
/// 盖上来还能看见底下大半张卡片、也还摸得到按钮；反过来卡片会整个压住小猫，
/// 那只猫就再也拖不动了。让小的在上面。
///
/// ## 拖完吸边
///
/// 松手时贴到离得近的那一边，竖着留在她放的地方。理由见
/// `music_float_state.dart`——一条 264 宽的卡片停在正文中间不像「放好了」。
///
/// ## 怎么消失
///
/// 没在放歌（[MusicService.showMiniPlayer] 为假）就整条不见，不留空壳。
/// **暂停了也算没在放**——用户原话是「没放音乐的时候可以隐藏一下，放音乐的
/// 时候拿出来就好了」，所以别在屏幕上留一条「暂停中的歌」占着地方。
/// 缓冲中算在放（见 [_audible]），不然播放中会跟着闪。
///
/// 「一起听」整页开着的时候也让开（[MusicService.pageOpen]）——那一页上同一件
/// 事说得更清楚，浮着的那条只会挡着它。
///
/// ⚠️ 没有「收起」这个动作，这是故意的：它没在放歌时自己就没了，而一个能被
/// 收起的悬浮控件必须回答「怎么再拿出来」，那个答案比这条本身复杂。
///
/// ⚠️ 代价：暂停之后这条就够不着了，进「一起听」整页只剩**设置 → 一起听**
/// 那一个入口。用户明确要了这个取舍（她嫌它占地方），所以照做。
class MusicFloat extends StatefulWidget {
  const MusicFloat({super.key});

  @override
  State<MusicFloat> createState() => _MusicFloatState();
}

class _MusicFloatState extends State<MusicFloat> {
  /// 她拖到哪儿了（左上角）。null = 用 [_anchor] 算。**只在拖动期间非空**，
  /// 松手时清掉，位置重新由吸附后的 [_anchor] 决定——那一下跳正是吸附。
  Offset? _drag;

  /// 吸附后的位置：哪一边、竖着多高。
  ({bool right, double yFrac})? _anchor;

  /// 手指正按着。拖的时候 `AnimatedPositioned` 的时长要归零，否则整条会
  /// 慢半拍地追着手指跑。
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final at = await MusicFloatState.saved();
    if (!mounted) return;
    setState(() => _anchor = at ?? defaultMusicFloatAnchor);
  }

  void _openPage() {
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    nav.push(
      MaterialPageRoute(
        builder: (_) => MusicScreen(
          // 悬浮条是 App 级的，不属于任何一段对话。「一起听」那一页要画谁的
          // 头像，只能问服务现在她正在看哪段。
          conversationId: MusicService.instance.activeConversationId,
        ),
      ),
    );
  }

  /// 发一个播放控制，失败了就把原因说出来。
  ///
  /// 按钮是单向的（`TransportControls` 没有回执），所以「按了没反应」和
  /// 「按了但播放器不认」在界面上长得一样。至少把原生带回来的那句中文露出来，
  /// 让她知道是哪儿的事——静默吞掉的话就只剩「这个按钮坏了」。
  Future<void> _control(BuildContext context, String action) async {
    // messenger 在 await 之前取好：await 之后这个 context 可能已经没了。
    final messenger = ScaffoldMessenger.maybeOf(context);
    final err = await MusicService.instance.control(action);
    if (err != null) {
      messenger?.showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MusicService.instance,
      builder: (context, _) {
        final svc = MusicService.instance;
        final anchor = _anchor;
        // 还没读出上次拖到哪儿就先别画。小猫可以先用默认位置顶着（它一直在
        // 那儿，跳一下无所谓），这一条是刚放歌才冒出来的——先画在默认位置
        // 再跳到记住的位置，看着像它自己飞了一下。
        if (anchor == null || svc.pageOpen || !svc.showMiniPlayer) {
          return const SizedBox.shrink();
        }
        final now = svc.now!;

        final media = MediaQuery.of(context);
        final screen = media.size;
        final safe = media.padding;
        final spot =
            _drag ??
            floatSpotFor(
              right: anchor.right,
              yFrac: anchor.yFrac,
              screen: screen,
              safe: safe,
            );

        return AnimatedPositioned(
          // 拖动中必须归零：`AnimatedPositioned` 是指哪追哪的补间，
          // 带着时长拖会明显跟不上手。
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          left: spot.dx,
          top: spot.dy,
          child: _card(context, now, screen, safe, spot),
        );
      },
    );
  }

  Widget _card(
    BuildContext context,
    NowPlaying now,
    Size screen,
    EdgeInsets safe,
    Offset spot,
  ) {
    return GestureDetector(
      // 卡片这一块整个归它管：按在按钮上往下拖也该是拖动卡片。
      // 点击不受影响——手指没动的话，按钮自己的 tap 在竞技场里赢。
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => setState(() {
        _dragging = true;
        _drag = spot;
      }),
      onPanUpdate: (d) => setState(() {
        _drag = clampFloatDrag(
          (_drag ?? spot) + d.delta,
          screen: screen,
          safe: safe,
        );
      }),
      onPanEnd: (_) {
        final at = _drag ?? spot;
        final anchor = floatAnchorOf(at, screen: screen, safe: safe);
        setState(() {
          _dragging = false;
          _drag = null;
          _anchor = anchor;
        });
        MusicFloatState.save(right: anchor.right, yFrac: anchor.yFrac);
      },
      child: AppSurface(
        borderRadius: AppRadius.mdAll,
        // 浮在正文上面，实心模式要一层更重的阴影才分得开。
        floating: true,
        child: Material(
          // 水波纹归它管，底色归 AppSurface——反过来会把玻璃盖掉。
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: _openPage,
            child: MusicFloatRow(
              now: now,
              onControl: (a) => _control(context, a),
            ),
          ),
        ),
      ),
    );
  }
}

/// 悬浮条里那一行。封面、歌名、三个按钮。
///
/// **和拖动、定位、AppSurface 都无关**，单独拎出来是为了能测：这一行的尺寸是
/// 算出来的（32 的封面 + 三个按钮），算错的表现是文字被挤掉半截——真发生过，
/// 按钮被 `MaterialTapTargetSize.padded` 顶到 40，副标题只显示到「·」。
/// 布局这种事纯函数测不到，`music_float_state_test.dart` 只管坐标。
class MusicFloatRow extends StatelessWidget {
  const MusicFloatRow({super.key, required this.now, required this.onControl});

  final NowPlaying now;

  /// 按了哪个键。字符串就是 `MusicService.control` 认的那几个动作名。
  final void Function(String action) onControl;

  /// 副标题。抽出来是为了测试能直接断言它**没有被截断**。
  static String subtitleOf(NowPlaying now) => now.track.stale
      // stale = 元数据被清空了，原生拿上一首顶上的。这个标记必须露出来，
      // 不然用户暂停一会儿之后看到歌名还在，会以为它还在放。
      ? '上次在听'
      : [
          if ((now.track.artist ?? '').isNotEmpty) now.track.artist!,
          now.state.label,
        ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = now.track;

    // ⚠️ 内容色用主题色，不用顶栏那套跟着壁纸走的 `bg.darkForeground`。
    // 跟输入框那套更一致：都是**画在一张 AppSurface 上的内容**，而 AppSurface
    // 回落到实心时就是主题的卡片色。
    final fg = scheme.onSurface;
    final dim = scheme.onSurfaceVariant;

    // ⚠️ 尺寸**长在这一行身上**，不能靠外面套。抽它出来的时候漏过一次：
    // 卡片于是照着内容自己撑，量出来是 244×32 而不是 264×50——而
    // `music_float_state.dart` 里所有吸附/贴边的算法都是按 264×50 算的，
    // 两边一错，它会贴着算法以为的边、实际差出一截。
    return SizedBox(
      width: musicFloatSize.width,
      height: musicFloatSize.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Row(
          children: [
            MusicCover(title: t.title ?? '', size: 32),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.title ?? '未知曲目',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                      color: fg,
                    ),
                  ),
                  Text(
                    subtitleOf(now),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, height: 1.3, color: dim),
                  ),
                ],
              ),
            ),
            _button(
              scheme,
              PhosphorIconsRegular.skipBack,
              tooltip: '上一首',
              // 播放器报 0 表示「它什么都没说」，不是「它说不能」。那种时候按钮
              // 不能变灰——点了能用，只是我们事先不知道。
              enabled: now.actionsUnknown || now.canSkipPrev,
              onPressed: () => onControl('previous'),
            ),
            _button(
              scheme,
              now.state.isPlaying
                  ? PhosphorIconsRegular.pause
                  : PhosphorIconsRegular.play,
              tooltip: now.state.isPlaying ? '暂停' : '播放',
              onPressed: () => onControl('play_pause'),
            ),
            _button(
              scheme,
              PhosphorIconsRegular.skipForward,
              tooltip: '下一首',
              enabled: now.actionsUnknown || now.canSkipNext,
              onPressed: () => onControl('next'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _button(
    ColorScheme scheme,
    IconData icon, {
    required VoidCallback onPressed,
    required String tooltip,
    bool enabled = true,
  }) {
    return IconButton(
      icon: Icon(icon, size: 18),
      onPressed: enabled ? onPressed : null,
      tooltip: tooltip,
      color: scheme.onSurface,
      disabledColor: scheme.onSurface.withValues(alpha: 0.26),
      padding: EdgeInsets.zero,
      // ⚠️ `constraints` 单独写是**没用的**。`IconButton` 默认
      // `MaterialTapTargetSize.padded`，`ButtonStyleButton` 会另加一层
      // `_InputPadding` 把最小尺寸顶到 `kMinInteractiveDimension`(48) 减掉密度
      // 补偿——实测（本机密度 480，`VisualDensity.compact`）：写
      // `tightFor(32, 32)` 出来的是 **40×40**。三个按钮因此多吃 24dp，副标题
      // 被挤掉半截。必须配 shrinkWrap 才收得住，测试盯着这一条。
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      // 32 是这一条 50 高里放得下的最大按钮。三个占 96，歌名剩下 116——
      // 手机上常见的「歌手名 · 状态」放得下，更长的靠省略号，点开整页看全的。
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    );
  }
}
