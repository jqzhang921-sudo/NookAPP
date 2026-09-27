import 'package:flutter/material.dart';
// `RenderParagraph` 在 rendering 里，不在 material 里——`didExceedMaxLines`
// 是判断「真的画不下、省略号上场了」的那个信号。
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/music_float_state.dart';
import 'package:phone_ai_assistant/services/music_service.dart';
import 'package:phone_ai_assistant/widgets/music_float.dart';

/// 悬浮条那一行的**尺寸**。
///
/// 这块单独立一个文件，是因为它坏起来不报错：`Row` 里挤不下就悄悄省略号，
/// 界面照常起来，只是歌名少了半截。真的发生过——`IconButton` 默认
/// `MaterialTapTargetSize.padded`，`constraints: tightFor(32, 32)` 被顶成
/// 40×40，三个按钮多吃 24dp，副标题只显示到「·」。纯函数测不到这个，
/// 只有真摆一次再量。
void main() {
  NowPlaying playing({
    String title = 'Still In Love',
    String artist = 'AYUSE KOZUE',
    bool stale = false,
    int actions = 822,
  }) => NowPlaying(
    track: MusicTrack(
      package: 'com.netease.cloudmusic',
      title: title,
      artist: artist,
      duration: const Duration(seconds: 254),
      stale: stale,
    ),
    state: PlaybackState.playing,
    position: const Duration(seconds: 43),
    actions: actions,
    at: DateTime(2026, 9, 27, 20, 5),
  );

  Future<void> pumpRow(WidgetTester tester, NowPlaying now) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // ⚠️ **不要在外面套 SizedBox**。套了就替它把尺寸定了，而尺寸是
          // 长在这一行自己身上的——抽它出来的时候正是漏了这一点，卡片照着
          // 内容撑成 244×32（该是 264×50），外面套着的那版测试全绿。
          body: Center(child: MusicFloatRow(now: now, onControl: (_) {})),
        ),
      ),
    );
  }

  testWidgets('整行自己就是 264×50，不靠外面套', (tester) async {
    // 贴边、吸附那套算法全按这个尺寸算（见 music_float_state.dart）。
    // 这里量出来的和那儿不一致的话，它会贴着算法以为的边、实际差出一截。
    await pumpRow(tester, playing());
    expect(tester.getSize(find.byType(MusicFloatRow)), musicFloatSize);
  });

  testWidgets('三个按钮各占 32，没有被 padded 顶大', (tester) async {
    await pumpRow(tester, playing());
    final buttons = find.byType(IconButton);
    expect(buttons, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(
        tester.getSize(buttons.at(i)),
        const Size(32, 32),
        reason: '第 $i 个按钮超了。多半是 tapTargetSize 又变回 padded 了',
      );
    }
  });

  /// `IconButton` 把 `Tooltip` 包在自己**里面**，所以 `byTooltip` 找到的是
  /// Tooltip，要拿按钮得往上找一层。直接 `widget<IconButton>(byTooltip(...))`
  /// 会抛 `type 'Tooltip' is not a subtype of type 'IconButton'`。
  IconButton buttonAt(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        ),
      );

  testWidgets('标签那一列真的拿到了剩下的宽度', (tester) async {
    // ⚠️ 这里**测不了**「AYUSE KOZUE · 在放 放不放得下」。`flutter test` 用的
    // 是方框测试字体，每个字符都占满一个 font-size 的方块，拉丁字母也一样宽——
    // 比真字体宽得多，任何一句话在这儿都会被截断。真字体下的实际效果只能在
    // 真机上看（已经看过）。
    //
    // 能测、也正是当初坏掉的那个：这一列**有没有被按钮挤到只剩下零头**。
    // 拿一个必然超宽的长标题去量，量到的就是它实际拿到的宽度。
    await pumpRow(
      tester,
      playing(title: 'A Very Long Song Title That Goes On And On Forever'),
    );
    final w = tester.getSize(find.text('A Very Long Song Title That Goes On And On Forever')).width;
    expect(w, greaterThan(100), reason: '按钮那一排又变胖了，文字列被挤没了');
    expect(w, lessThan(130));
  });

  testWidgets('长歌名只是省略，不撑破卡片', (tester) async {
    // 挤爆会在测试里直接抛 overflow 异常，所以这一条是在确认
    // 「它选择省略」。省略号上场本身是对的。
    await pumpRow(
      tester,
      playing(title: 'A Very Long Song Title That Goes On And On Forever'),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.text('A Very Long Song Title That Goes On And On Forever'),
          )
          .didExceedMaxLines,
      isTrue,
    );
  });

  testWidgets('stale 的时候写「上次在听」', (tester) async {
    // 元数据被清空时原生拿上一首顶上。不标出来的话，用户暂停一会儿之后
    // 看见歌名还在，会以为它还在放。
    await pumpRow(tester, playing(stale: true));
    expect(find.text('上次在听'), findsOneWidget);
  });

  testWidgets('没歌手就只显示状态，不留一个孤零零的分隔点', (tester) async {
    await pumpRow(tester, playing(artist: ''));
    expect(find.text('在放'), findsOneWidget);
    expect(find.text(' · 在放'), findsNothing);
  });

  testWidgets('按钮报的是真动作名', (tester) async {
    // 这一串要和服务认的那批对齐，写错了界面按下去就是「认不出这个动作」。
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: musicFloatSize.width,
              height: musicFloatSize.height,
              child: MusicFloatRow(now: playing(), onControl: sent.add),
            ),
          ),
        ),
      ),
    );
    for (final label in ['上一首', '暂停', '下一首']) {
      await tester.tap(find.byTooltip(label));
      await tester.pump();
    }
    expect(sent, ['previous', 'play_pause', 'next']);
  });

  testWidgets('播放器没说支持什么的时候按钮照样能按', (tester) async {
    // actions=0 是「它什么都没说」，不是「它说不能」。变灰就全哑了。
    await pumpRow(tester, playing(actions: 0));
    for (final label in ['上一首', '下一首']) {
      expect(buttonAt(tester, label).onPressed, isNotNull, reason: '$label 不该是灰的');
    }
  });

  testWidgets('播放器明说不支持切歌时按钮才是灰的', (tester) async {
    await pumpRow(tester, playing(actions: 512)); // 只有 PLAY_PAUSE
    expect(buttonAt(tester, '下一首').onPressed, isNull);
    // 播放暂停是支持的，它不该跟着一起哑。
    expect(buttonAt(tester, '暂停').onPressed, isNotNull);
  });

  testWidgets('暂停时主按钮换成播放图标', (tester) async {
    await pumpRow(tester, playing());
    expect(find.byTooltip('暂停'), findsOneWidget);
    await pumpRow(
      tester,
      NowPlaying(
        track: playing().track,
        state: PlaybackState.paused,
        position: Duration.zero,
        actions: 822,
        at: DateTime(2026, 9, 27, 20, 5),
      ),
    );
    expect(find.byTooltip('播放'), findsOneWidget);
  });
}
