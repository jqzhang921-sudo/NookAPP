import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/music_float_state.dart';

void main() {
  // 这块测的是**位置怎么算**，不是「能不能拖动」——后者要真机和真手指。
  // 位置这块出错的代价很具体：偏一点点是难看，算错了是**整条跑到屏幕外面**，
  // 她再也点不到，只能去清 App 数据。所以每条边界都钉一遍。

  const screen = Size(393, 852);
  const box = musicFloatSize;

  group('算位置', () {
    test('左边贴左，右边贴右', () {
      final l = floatSpotFor(right: false, yFrac: 0.5, screen: screen);
      final r = floatSpotFor(right: true, yFrac: 0.5, screen: screen);
      expect(l.dx, 10);
      expect(r.dx, 393 - box.width - 10);
      // 右边那个必须整条在屏幕里——这是「不许跑丢」那条的最低要求。
      expect(r.dx + box.width, lessThanOrEqualTo(screen.width));
    });

    test('竖着 0 贴顶、1 贴底，两头都不越界', () {
      final top = floatSpotFor(right: false, yFrac: 0, screen: screen);
      final bottom = floatSpotFor(right: false, yFrac: 1, screen: screen);
      expect(top.dy, 10);
      expect(bottom.dy + box.height, 852 - 10);
    });

    test('比例超范围也拉回来，不抛', () {
      // 手改坏的偏好设置、或者旧版本存的怪值。
      expect(floatSpotFor(right: false, yFrac: -3, screen: screen).dy, 10);
      expect(
        floatSpotFor(right: false, yFrac: 9, screen: screen).dy,
        floatSpotFor(right: false, yFrac: 1, screen: screen).dy,
      );
    });

    test('状态栏和手势条的地盘不去占', () {
      const safe = EdgeInsets.only(top: 47, bottom: 34);
      final top = floatSpotFor(
        right: false,
        yFrac: 0,
        screen: screen,
        safe: safe,
      );
      final bottom = floatSpotFor(
        right: false,
        yFrac: 1,
        screen: screen,
        safe: safe,
      );
      expect(top.dy, 57);
      expect(bottom.dy + box.height, 852 - 34 - 10);
    });

    test('屏幕比卡片还窄时也不算出负数', () {
      // 分屏、极窄屏。宁可挤在左上角，也不能算出一个负数坐标——
      // 那会让它半个身子在屏幕外。
      final at = floatSpotFor(right: true, yFrac: 0, screen: const Size(200, 400));
      expect(at.dx, greaterThanOrEqualTo(0));
      expect(at.dy, greaterThanOrEqualTo(0));
    });
  });

  group('反过来算哪一边', () {
    test('原样转一圈', () {
      for (final right in [true, false]) {
        for (final yFrac in [0.0, 0.34, 1.0]) {
          final spot = floatSpotFor(
            right: right,
            yFrac: yFrac,
            screen: screen,
          );
          final back = floatAnchorOf(spot, screen: screen);
          expect(back.right, right, reason: '$right / $yFrac 转丢了');
          expect(back.yFrac, closeTo(yFrac, 0.0001));
        }
      }
    });

    test('按中线判左右，不按左上角', () {
      // 一条 264 宽的卡片拖到中间偏右一点点：她的眼睛看到的是「在右边」，
      // 但左上角还在左半边。按左上角判会把它吸回左边——和手指反着来。
      final mid = (393 - box.width) / 2;
      final justRight = Offset(mid + 20, 100);
      expect(justRight.dx + box.width / 2, greaterThan(393 / 2));
      expect(floatAnchorOf(justRight, screen: screen).right, isTrue);
    });

    test('拖出屏幕外的那一截会被拉回来', () {
      final back = floatAnchorOf(const Offset(-5000, -5000), screen: screen);
      final spot = floatSpotFor(
        right: back.right,
        yFrac: back.yFrac,
        screen: screen,
      );
      expect(spot.dx, greaterThanOrEqualTo(0));
      expect(spot.dy, greaterThanOrEqualTo(0));
    });
  });

  group('拖动时不许拖丢', () {
    test('四个方向都收在屏幕里', () {
      for (final want in const [
        Offset(-999, 0),
        Offset(9999, 0),
        Offset(0, -999),
        Offset(0, 9999),
      ]) {
        final at = clampFloatDrag(want, screen: screen);
        expect(at.dx, inInclusiveRange(0, 393 - box.width));
        expect(at.dy, inInclusiveRange(0, 852 - box.height));
      }
    });

    test('中间随便放，不吸', () {
      // 拖动途中不吸附：拽到一半就往边上跑，手感像卡住了。
      const mid = Offset(60, 400);
      expect(clampFloatDrag(mid, screen: screen), mid);
    });
  });
}
