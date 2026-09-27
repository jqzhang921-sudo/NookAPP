import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 悬浮播放条待在哪儿。
///
/// 和 `pet_state.dart` 同构：这里只放**能单独测的那一半**——存什么、怎么从存
/// 的东西算回坐标。画它的部分在 `widgets/music_float.dart`。
///
/// ## 为什么存「哪一边 + 多高」，不存绝对坐标
///
/// 小猫存的是绝对坐标。播放条不一样，它宽得多：一条 264 压在 393 宽的手机上，
/// 横着几乎没得选——停在中间就是压住正文。所以松手时它**吸附到离得近的那
/// 一边**，横坐标根本不用记；真正属于她的是**竖着多高**。存成 0~1 的比例，
/// 换分辨率、转屏、系统改字体大小之后都还在原来那个相对位置上。
///
/// 吸附还有一层：拖动结束那一刻位置会跳一下，跳的是她本来也会手动挪到的地方
/// ——贴边看着才像「停在那儿」，悬在正文中间像「还没放好」。
class MusicFloatState {
  static const _kRight = 'music_float_right';
  static const _kY = 'music_float_y';

  /// 她拖到哪儿了。没拖过就是 null，用 [defaultMusicFloatAnchor]。
  static Future<({bool right, double yFrac})?> saved() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final right = sp.getBool(_kRight);
      final y = sp.getDouble(_kY);
      if (right == null || y == null) return null;
      return (right: right, yFrac: y);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save({required bool right, required double yFrac}) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kRight, right);
      await sp.setDouble(_kY, yFrac);
    } catch (_) {
      // 存不上就存不上，下次开在默认位置而已。为这个把一次拖动变成崩溃不值。
    }
  }
}

/// 播放条的尺寸。宽高都固定——**不跟着歌名长短变**：一首歌一个宽度，
/// 翻歌的时候整条会一直抽动。
const musicFloatSize = Size(264, 50);

/// 默认位置：左边、偏上（竖着 34%）。
///
/// 这是个**猜的**，一次拖动就永远不用再管。挑左边偏上是因为它最不容易挡住
/// 当下要用的东西：
///
/// - 顶上那条 AppBar 要留出来，所以不能贴顶
/// - 聊天页最底下是输入框和发送键，所以不能贴底
/// - 消息是从下往上堆的，最新的话在最下面——偏上压住的是翻旧账的那一段
const defaultMusicFloatAnchor = (right: false, yFrac: 0.34);

/// 离屏幕边多远。
const _margin = 10.0;

/// 摆得下的范围。宽高比屏幕还大时（极窄屏、分屏）退化成贴着左上角，
/// 至少还点得到。
({double minX, double maxX, double minY, double maxY}) _bounds(
  Size box,
  Size screen,
  EdgeInsets safe,
) {
  final minX = safe.left + _margin;
  final minY = safe.top + _margin;
  final maxX = screen.width - safe.right - box.width - _margin;
  final maxY = screen.height - safe.bottom - box.height - _margin;
  return (
    minX: minX,
    maxX: maxX < minX ? minX : maxX,
    minY: minY,
    maxY: maxY < minY ? minY : maxY,
  );
}

/// 从「哪一边 + 多高」算出左上角该在哪儿。
Offset floatSpotFor({
  required bool right,
  required double yFrac,
  Size box = musicFloatSize,
  required Size screen,
  EdgeInsets safe = EdgeInsets.zero,
}) {
  final b = _bounds(box, screen, safe);
  final y = b.minY + (b.maxY - b.minY) * yFrac.clamp(0.0, 1.0);
  return Offset(right ? b.maxX : b.minX, y);
}

/// 反过来：这个位置算哪一边、多高。松手时存的是它。
({bool right, double yFrac}) floatAnchorOf(
  Offset spot, {
  Size box = musicFloatSize,
  required Size screen,
  EdgeInsets safe = EdgeInsets.zero,
}) {
  final b = _bounds(box, screen, safe);
  // 拿中线判，不拿左上角：拖到一半时整条已经越过去了，这时候吸到对面
  // 才是她眼睛看到的那个方向。
  final right = spot.dx + box.width / 2 > screen.width / 2;
  // 分母可能是 0（屏幕还没量出来、或者窄得放不下），那就当竖着没得选。
  final span = b.maxY - b.minY;
  final yFrac = span <= 0 ? 0.0 : ((spot.dy - b.minY) / span).clamp(0.0, 1.0);
  return (right: right, yFrac: yFrac);
}

/// 拖的时候不许拖出屏幕。
///
/// 和松手时的吸附是两件事：拖动途中**不吸**，手指到哪儿它到哪儿——中途往边上
/// 拽会像卡住了。这里只保证它不整个跑到屏幕外面去，免得拖丢了再也点不到。
Offset clampFloatDrag(
  Offset want, {
  Size box = musicFloatSize,
  required Size screen,
  EdgeInsets safe = EdgeInsets.zero,
}) {
  final b = _bounds(box, screen, safe);
  return Offset(
    want.dx.clamp(b.minX, b.maxX),
    want.dy.clamp(b.minY, b.maxY),
  );
}
