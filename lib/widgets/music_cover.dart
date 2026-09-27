import 'package:flutter/material.dart';

/// 画出来的封面。
///
/// ## 为什么没有真的封面图
///
/// 方案里一期就明确砍掉了「封面图下载」。`MediaMetadata` 里那张 artwork 是个
/// Bitmap，要跨通道传得先编成 PNG，每换一首歌就多几十上百 KB——为了顶栏那个
/// 32 像素的方块付这个代价不值。
///
/// 那**留个灰方块吗**？不行：灰方块在界面上的意思是「图没加载出来」，是个
/// 待修复的状态，用户会一直等它。与其给一个看着像坏了的占位，不如按歌名
/// 生成一个稳定的色块加首字——同一首歌每次都是同一个颜色，看着像这张专辑
/// 本来就长这样。
///
/// 真封面以后要加（比如第三期让 AI 聊到某首歌时），换掉这一个组件即可。
class MusicCover extends StatelessWidget {
  const MusicCover({super.key, required this.title, required this.size});

  /// 用来定色和取首字的歌名。空的话就是一个中性色块、没有字。
  final String title;

  final double size;

  @override
  Widget build(BuildContext context) {
    // 色相由歌名定，同一首歌永远同一个颜色。String.hashCode 在 Dart 里按内容
    // 算，同一个进程里稳定——这里只要「前后一致」就够，不需要跨版本稳定。
    final hue = (title.hashCode % 360).abs().toDouble();
    // 按 runes 取第一个字，不用 `title[0]`——后者切的是 UTF-16 码元，汉字没事，
    // emoji 和某些符号会被切成半个字符，渲染成一个方框。
    final runes = title.runes;
    final initial = runes.isEmpty ? '' : String.fromCharCode(runes.first);

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.40, 0.60).toColor(),
            HSLColor.fromAHSL(1, (hue + 32) % 360, 0.44, 0.44).toColor(),
          ],
        ),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.42,
          height: 1,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}
