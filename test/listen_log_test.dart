import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/listen_log.dart';

/// 「她刚才听了什么」这块的纯逻辑。
///
/// 这块错起来的代价不在崩溃，在**说错话**：它会拿一个假的收听时长去跟用户
/// 搭话。所以每一条判据都钉在这儿。
///
/// ⚠️ 最要命的那条是**进度外推**（见 `OpenListen` 那组）。网易云一首歌只在
/// 曲目边界发布一次位置，然后整首哑着——照抄那个数的话，一首从头听到尾的歌
/// 会被记成「听到 0 秒就换掉了」。
void main() {
  final t0 = DateTime(2026, 9, 27, 20, 0);

  ListenEntry entry({
    String package = 'com.netease.cloudmusic',
    String? title = '起风了',
    String? artist = '买辣椒也用券',
    Duration? duration = const Duration(minutes: 5),
    DateTime? startedAt,
    int listenedSec = 200,
    Duration? position,
    ListenEnd end = ListenEnd.replaced,
  }) {
    final start = startedAt ?? t0;
    return ListenEntry(
      package: package,
      title: title,
      artist: artist,
      duration: duration,
      startedAt: start,
      endedAt: start.add(Duration(seconds: listenedSec)),
      position: position,
      end: end,
    );
  }

  group('怎么结束的', () {
    test('进度走到歌尾 = 放完了', () {
      expect(
        classifyEnd(
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 5),
          listened: const Duration(minutes: 5),
        ),
        ListenEnd.natural,
      );
    });

    test('差几秒也算放完——播放器报的数不会刚好卡在末尾', () {
      expect(
        classifyEnd(
          position: const Duration(seconds: 296),
          duration: const Duration(seconds: 300),
          listened: const Duration(seconds: 300),
        ),
        ListenEnd.natural,
      );
    });

    test('一上来就切走是最强的信号', () {
      expect(
        classifyEnd(
          position: const Duration(seconds: 12),
          duration: const Duration(minutes: 4),
          listened: const Duration(seconds: 12),
        ),
        ListenEnd.skipped,
      );
    });

    test('⚠️ 先判放完再判切走，顺序不能反', () {
      // 一首 20 秒的短歌放到底，会被「听了不到 30 秒」那条抓走记成「切掉的」。
      // 判据顺序反了就是这个症状。
      expect(
        classifyEnd(
          position: const Duration(seconds: 20),
          duration: const Duration(seconds: 20),
          listened: const Duration(seconds: 20),
        ),
        ListenEnd.natural,
      );
    });

    test('没有进度时退回墙钟', () {
      expect(
        classifyEnd(
          position: null,
          duration: const Duration(minutes: 3),
          listened: const Duration(minutes: 3),
        ),
        ListenEnd.natural,
      );
    });

    test('⚠️ 有进度就不看墙钟——中途暂停半小时再切走', () {
      // 墙钟是半小时，进度还停在 40 秒。拿墙钟算会得出「听完了」。
      expect(
        classifyEnd(
          position: const Duration(seconds: 40),
          duration: const Duration(minutes: 4),
          listened: const Duration(minutes: 30),
        ),
        ListenEnd.replaced,
      );
    });

    test('时长都不知道，只能靠逗留时长归档', () {
      expect(
        classifyEnd(position: null, duration: null, listened: const Duration(seconds: 8)),
        ListenEnd.skipped,
      );
      expect(
        classifyEnd(position: null, duration: null, listened: const Duration(minutes: 3)),
        ListenEnd.replaced,
      );
    });
  });

  group('听了多少', () {
    test('优先用进度算，不用墙钟', () {
      // 暂停过：墙钟 30 分钟，进度 40 秒 / 4 分钟 = 17%。
      expect(
        entry(
          duration: const Duration(minutes: 4),
          listenedSec: 1800,
          position: const Duration(seconds: 40),
        ).playedRatio,
        closeTo(1 / 6, 0.01),
      );
    });

    test('没进度就用墙钟顶上', () {
      expect(
        entry(listenedSec: 150, position: null).playedRatio,
        closeTo(0.5, 0.01), // 150s / 300s
      );
    });

    test('没有时长就不知道，不编一个出来', () {
      // 编一个数出来的话，它会理直气壮地说错；null 它自己会少说一句。
      expect(entry(duration: null).playedRatio, isNull);
      expect(entry(duration: Duration.zero).playedRatio, isNull);
    });

    test('拖过了头也不会算出大于 1', () {
      expect(
        entry(position: const Duration(minutes: 9), duration: const Duration(minutes: 5))
            .playedRatio,
        1.0,
      );
    });

    test('逗留时长取两头之差', () {
      expect(entry(listenedSec: 42).listened, const Duration(seconds: 42));
    });
  });

  group('同一首歌的登记名', () {
    test('带上包名——两个 App 里各有一首《起风了》，是两件事', () {
      final a = entry(package: 'com.netease.cloudmusic');
      final b = entry(package: 'com.tencent.qqmusic');
      expect(a.mentionKey, isNot(b.mentionKey));
      expect(a.mentionKey, contains('com.netease.cloudmusic'));
      expect(a.mentionKey, contains('起风了'));
      expect(a.mentionKey, contains('买辣椒也用券'));
    });

    test('同一首歌名一样，不依赖什么时候听的', () {
      expect(
        entry(startedAt: t0).mentionKey,
        entry(startedAt: t0.add(const Duration(days: 3))).mentionKey,
      );
    });
  });

  group('存下来再读回来', () {
    test('原样转一圈', () {
      final e = ListenEntry(
        package: 'com.netease.cloudmusic',
        title: '起风了',
        artist: '买辣椒也用券',
        duration: const Duration(minutes: 5, seconds: 25),
        startedAt: t0,
        endedAt: t0.add(const Duration(seconds: 200)),
        position: const Duration(seconds: 198),
        seekedForward: const Duration(seconds: 30),
        end: ListenEnd.skipped,
      );
      final back = ListenEntry.decode(jsonEncode(e.toJson()))!;
      expect(back.package, e.package);
      expect(back.title, e.title);
      expect(back.artist, e.artist);
      expect(back.duration, e.duration);
      expect(back.startedAt, e.startedAt);
      expect(back.endedAt, e.endedAt);
      expect(back.position, e.position);
      expect(back.seekedForward, e.seekedForward);
      expect(back.end, e.end);
    });

    test('缺字段也能读回来，只是少了那几个', () {
      final back = ListenEntry.decode(
        '{"p":"com.netease.cloudmusic","s":1000,"e":2000}',
      )!;
      expect(back.title, isNull);
      expect(back.duration, isNull);
      expect(back.position, isNull);
      expect(back.seekedForward, Duration.zero);
    });

    test('读不动就返回 null，不抛', () {
      // 旧版本留下的、手改坏的。为了它让整个 App 起不来是不划算的。
      for (final bad in ['', 'not json', '[]', '{"p":1,"s":2,"e":3}', '{"s":2}']) {
        expect(ListenEntry.decode(bad), isNull, reason: bad);
      }
    });

    test('认不出的结束方式退到 unknown，不当成「切走的」', () {
      final back = ListenEntry.decode(
        '{"p":"x","s":1,"e":2,"x":"somethingElse"}',
      )!;
      expect(back.end, ListenEnd.unknown);
    });
  });

  group('正在累积的那一首', () {
    // ⚠️ 这一组全是那个网易云怪癖：位置只在曲目边界报一次，之后整首哑着。
    test('进度会自己往前走——不然整首放完会被记成「听到 0 秒」', () {
      final open = OpenListen(
        package: 'com.netease.cloudmusic',
        title: '起风了',
        duration: const Duration(minutes: 5),
        startedAt: t0,
      )..saw(position: Duration.zero, at: t0, playing: true);

      expect(open.positionNow(t0.add(const Duration(seconds: 90))),
          const Duration(seconds: 90));
      // 收尾时归档也对：真放完了
      final closed = open.close(at: t0.add(const Duration(minutes: 5)))!;
      expect(closed.end, ListenEnd.natural);
    });

    test('暂停时就不走了——暂停十分钟不该算成听了十分钟', () {
      final open = OpenListen(
        package: 'x',
        title: 'y',
        duration: const Duration(minutes: 5),
        startedAt: t0,
      )..saw(position: const Duration(seconds: 40), at: t0, playing: false);

      expect(open.positionNow(t0.add(const Duration(minutes: 10))),
          const Duration(seconds: 40));
    });

    test('外推不越过歌尾', () {
      final open = OpenListen(
        package: 'x',
        title: 'y',
        duration: const Duration(minutes: 3),
        startedAt: t0,
      )..saw(position: Duration.zero, at: t0, playing: true);
      expect(open.positionNow(t0.add(const Duration(hours: 1))),
          const Duration(minutes: 3));
    });

    test('往前拖才记，往后拖不算', () {
      final open = OpenListen(package: 'x', title: 'y', startedAt: t0);
      open.seeked(from: const Duration(seconds: 10), to: const Duration(seconds: 70));
      expect(open.seekedForward, const Duration(seconds: 60));
      // 又拖回去重听——那不是「跳」
      open.seeked(from: const Duration(seconds: 70), to: const Duration(seconds: 20));
      expect(open.seekedForward, const Duration(seconds: 60));
    });

    test('没歌名的不记', () {
      final open = OpenListen(package: 'x', startedAt: t0);
      expect(open.close(at: t0.add(const Duration(minutes: 3))), isNull);
    });

    test('一秒都不到的噪声不记', () {
      // 刚连上就报了一首，不是她真听了。记进去会喂给模型一堆「听了 0 秒」。
      final open = OpenListen(package: 'x', title: 'y', startedAt: t0);
      expect(open.close(at: t0), isNull);
    });

    test('给定结束方式就照它记（播放器整个没了）', () {
      final open = OpenListen(package: 'x', title: 'y', startedAt: t0)
        ..saw(position: const Duration(seconds: 5), at: t0, playing: true);
      final closed =
          open.close(at: t0.add(const Duration(minutes: 4)), end: ListenEnd.unknown)!;
      expect(closed.end, ListenEnd.unknown);
    });
  });

  group('该不该跟它提这一嘴', () {
    ({String what, String mentionKey})? brief(
      List<ListenEntry> entries, {
      Set<String> mentioned = const {},
      NowPlayingBrief? playing,
      DateTime? now,
    }) => musicBriefFor(
      entries: entries,
      now: now ?? t0.add(const Duration(minutes: 10)),
      mentioned: mentioned,
      playing: playing,
    );

    test('什么都没发生就没有话说', () {
      expect(brief(const []), isNull);
    });

    test('提过的就不再提', () {
      final e = entry();
      expect(brief([e], mentioned: {e.mentionKey}), isNull);
      expect(brief([e]), isNotNull);
    });

    test('三天前的歌不该今天拿出来当由头', () {
      // 门槛那层的 `since` 是「上次开口到现在」，可能隔了三天——那条挡不住
      // 陈年老歌，所以这儿自己有一条更紧的新鲜度。
      final old = entry(startedAt: t0.subtract(const Duration(days: 3)));
      expect(brief([old]), isNull);
      final recent = entry(startedAt: t0.subtract(const Duration(minutes: 30)));
      expect(brief([recent]), isNotNull);
    });

    test('短切那条要带上秒数和整首长度', () {
      // 数字是给模型判断用的。只说「切了」它判不出是嫌长还是找别的。
      final b = brief([
        entry(listenedSec: 12, position: const Duration(seconds: 12), end: ListenEnd.skipped),
      ])!;
      expect(b.what, contains('12 秒'));
      expect(b.what, contains('5:00'));
      expect(b.what, contains('起风了'));
      expect(b.what, contains('网易云'));
    });

    test('连着三首短切成一句话说，不逐条列', () {
      final b = brief([
        entry(title: 'A', listenedSec: 8, position: const Duration(seconds: 8), end: ListenEnd.skipped),
        entry(title: 'B', listenedSec: 20, position: const Duration(seconds: 20), end: ListenEnd.skipped),
        entry(title: 'C', listenedSec: 31, position: const Duration(seconds: 31), end: ListenEnd.skipped),
      ])!;
      expect(b.what, contains('连着换了 3 首'));
      expect(b.what, contains('8–31 秒'));
      expect(b.what, contains('A'));
    });

    test('只有两首短切就不算「在翻歌单」，说最近那条', () {
      final b = brief([
        entry(title: 'A', listenedSec: 8, position: const Duration(seconds: 8), end: ListenEnd.skipped),
        entry(title: 'B', listenedSec: 20, position: const Duration(seconds: 20), end: ListenEnd.skipped),
      ])!;
      expect(b.what, isNot(contains('连着换了')));
      expect(b.what, contains('B')); // 最近的那条
    });

    test('中间夹了一首正常听的，「连着」就断了', () {
      final b = brief([
        entry(title: 'A', listenedSec: 8, position: const Duration(seconds: 8), end: ListenEnd.skipped),
        entry(title: 'B', listenedSec: 240, position: const Duration(minutes: 4), end: ListenEnd.replaced),
        entry(title: 'C', listenedSec: 9, position: const Duration(seconds: 9), end: ListenEnd.skipped),
        entry(title: 'D', listenedSec: 7, position: const Duration(seconds: 7), end: ListenEnd.skipped),
      ])!;
      expect(b.what, isNot(contains('连着换了')));
    });

    test('现在在放什么会另起一句带上', () {
      final b = brief(
        [entry(end: ListenEnd.natural, listenedSec: 300, position: const Duration(minutes: 5))],
        playing: const NowPlayingBrief(title: 'Come Back To Me', artist: '宇多田ヒカル', state: '在放'),
      )!;
      expect(b.what, contains('现在在放'));
      expect(b.what, contains('Come Back To Me'));
      expect(b.what, contains('宇多田ヒカル'));
    });

    test('没在放就不提「现在在放」', () {
      final b = brief([entry()])!;
      expect(b.what, isNot(contains('现在在放')));
    });

    test('认不出的 App 说包名，不编一个中文名', () {
      // 说错 App 比说得拗口糟得多。
      final b = brief([
        entry(package: 'com.some.player', listenedSec: 10,
            position: const Duration(seconds: 10), end: ListenEnd.skipped),
      ])!;
      expect(b.what, contains('com.some.player'));
    });

    test('没歌手的歌不留一个空括号', () {
      final b = brief([
        entry(artist: '', listenedSec: 10, position: const Duration(seconds: 10),
            end: ListenEnd.skipped),
      ])!;
      expect(b.what, contains('《起风了》'));
      expect(b.what, isNot(contains('（）')));
    });

    test('登记名取的是被说的那一首', () {
      final newest = entry(title: '新');
      final older = entry(title: '旧', startedAt: t0.subtract(const Duration(minutes: 5)));
      final b = brief([older, newest])!;
      expect(b.mentionKey, newest.mentionKey);
    });
  });
}
