import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/music_service.dart';

void main() {
  // 这块里唯一值得测的是两件纯逻辑：**落盘的编解码**和**「是不是同一首歌」**。
  // 两个都不会在开发时喊疼——一个要等用户重启 App 才暴露（歌名没了），
  // 一个要等用户在听歌时暂停才暴露（流水里凭空多一条换歌）。

  group('落盘编解码', () {
    test('原样转一圈', () {
      const t = MusicTrack(
        package: 'com.netease.cloudmusic',
        title: 'Come Back To Me',
        artist: '宇多田ヒカル',
        album: 'First Love',
        duration: Duration(seconds: 254),
      );
      final back = MusicTrack.decode(t.encode());
      expect(back, isNotNull);
      expect(back!.package, t.package);
      expect(back.title, t.title);
      expect(back.artist, t.artist);
      expect(back.album, t.album);
      expect(back.duration, t.duration);
    });

    test('歌名里有分隔符也不会串味', () {
      // 这是选 \u0001 而不是竖线/冒号当分隔符的原因。歌名带冒号、竖线、
      // 引号的全都有，只有控制字符不会出现在正常文本里。
      const t = MusicTrack(
        package: 'com.tencent.qqmusic',
        title: 'A|B:C"D',
        artist: 'E,F',
      );
      final back = MusicTrack.decode(t.encode())!;
      expect(back.title, 'A|B:C"D');
      expect(back.artist, 'E,F');
    });

    test('缺字段解出来是 null 而不是空串', () {
      // 空串和 null 在这一块是**两个意思**：null = 播放器没给这个字段，
      // 空串会在界面上显示成一个空行。
      const t = MusicTrack(package: 'app.podcast.cosmos', title: '某期播客');
      final back = MusicTrack.decode(t.encode())!;
      expect(back.artist, isNull);
      expect(back.album, isNull);
      expect(back.duration, isNull);
    });

    test('解不出来返回 null，不抛', () {
      // 旧版本留下的、或者被人手改坏的一行，不该让整个 App 起不来。
      expect(MusicTrack.decode(''), isNull);
      expect(MusicTrack.decode('没有分隔符'), isNull);
    });
  });

  group('是不是同一首歌', () {
    test('同名同包算同一首', () {
      const a = MusicTrack(
        package: 'com.netease.cloudmusic',
        title: '起风了',
        artist: '买辣椒也用券',
        duration: Duration(seconds: 325),
      );
      const b = MusicTrack(
        package: 'com.netease.cloudmusic',
        title: '起风了',
        artist: '买辣椒也用券',
        duration: Duration(seconds: 331), // remaster 版，时长不一样
      );
      // 时长不同**不算换歌**：同一首歌的不同版本当「同一首」比当「换歌了」
      // 更接近用户的感受。用户在听《起风了》，不会因为切到了另一版就觉得
      // 自己换了首歌。
      expect(b.sameAs(a), isTrue);
    });

    test('换了 App 算换歌', () {
      const a = MusicTrack(package: 'com.netease.cloudmusic', title: '起风了');
      const b = MusicTrack(package: 'com.tencent.qqmusic', title: '起风了');
      expect(b.sameAs(a), isFalse);
    });

    test('以前没有、现在有，算换歌', () {
      // 冷启动时 _now 是 null，第一条事件必须算「换歌」——不算的话，
      // 界面上永远不会出现第一次的那首歌。
      const a = MusicTrack(package: 'com.netease.cloudmusic', title: '起风了');
      expect(a.sameAs(null), isFalse);
    });

    test('元数据被清空回传的那一首，不会被当成换歌', () {
      // 网易云停止播放会清空 metadata，原生拿上一首顶上并打 stale。
      // 这个 stale 的副本和原来那首必须判成「同一首」——判错的话，
      // 用户每暂停一次，流水里就多一条假的换歌记录。
      const original = MusicTrack(
        package: 'com.netease.cloudmusic',
        title: 'My Name',
        artist: 'Miyauchi',
        duration: Duration(seconds: 196),
      );
      final staleCopy = original.copyWith(stale: true);
      expect(staleCopy.sameAs(original), isTrue);
      expect(staleCopy.stale, isTrue);
      expect(original.stale, isFalse);
    });
  });

  group('播放器能力位', () {
    // 实机测到的网易云：actions=822 = 512(PLAY_PAUSE) + 256(SEEK_TO)
    //                                  + 32(SKIP_TO_NEXT) + 16(SKIP_TO_PREVIOUS)
    //                                  + 4(PLAY) + 2(PAUSE)
    // 注意它**没有** FAST_FORWARD(64) 也没有 STOP(1)——所以二期的「快进」
    // 只能用 seekTo，不能用 fastForward()。
    NowPlaying withActions(int actions) => NowPlaying(
      track: const MusicTrack(package: 'x', title: 'y'),
      state: PlaybackState.playing,
      position: Duration.zero,
      actions: actions,
      at: DateTime(2026, 9, 27),
    );

    test('网易云的 822：能切歌、能快进', () {
      final n = withActions(822);
      expect(n.canSeek, isTrue);
      expect(n.canSkipNext, isTrue);
      expect(n.canSkipPrev, isTrue);
    });

    test('只报播放暂停的播放器：不能快进', () {
      final n = withActions(512); // 只有 PLAY_PAUSE
      expect(n.canSeek, isFalse);
      expect(n.canSkipNext, isFalse);
    });

    test('什么都没报：不假装能做', () {
      // 这就是「如实告诉模型」那一层：能力是 0 的时候，二期那个工具必须
      // 回一句「这个播放器不支持」，而不是调了没反应。
      final n = withActions(0);
      expect(n.canSeek, isFalse);
      expect(n.canSkipNext, isFalse);
      expect(n.canSkipPrev, isFalse);
    });

    test('报 0 要能和「说了不支持」分开', () {
      // 上面那条说能力是 0 时不假装能做；这条是它的另一面——**界面**不能
      // 把 0 当成「不支持」去把按钮变灰，那样按钮全哑了，而其实点了能用。
      // 所以留了 actionsUnknown 让界面走另一条路。
      expect(withActions(0).actionsUnknown, isTrue);
      expect(withActions(512).actionsUnknown, isFalse);
    });
  });

  group('进度外推', () {
    // 原生给的 position 是**读的那一刻**的值，不是会自己走的活值——网易云
    // 一整首歌只在边界发布一次。界面要是不自己外推，进度条就只在事件来的
    // 那一下跳一格，中间一直冻着。
    NowPlaying at(Duration position, {Duration? duration, DateTime? readAt, PlaybackState state = PlaybackState.playing}) =>
        NowPlaying(
          track: MusicTrack(
            package: 'com.netease.cloudmusic',
            title: '起风了',
            duration: duration,
          ),
          state: state,
          position: position,
          actions: 822,
          at: readAt ?? DateTime.now(),
        );

    test('在放：读到 10 秒、五秒前读的，现在该是 15 秒左右', () {
      final n = at(
        const Duration(seconds: 10),
        duration: const Duration(minutes: 3),
        readAt: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      final live = n.livePosition;
      expect(live.inMilliseconds, greaterThanOrEqualTo(14900));
      expect(live.inMilliseconds, lessThan(15500));
    });

    test('暂停：一秒都不许加', () {
      // 暂停时还在往前走的话，界面会显示「放到 2:30 了」而歌是停的。
      final n = at(
        const Duration(seconds: 10),
        duration: const Duration(minutes: 3),
        readAt: DateTime.now().subtract(const Duration(seconds: 5)),
        state: PlaybackState.paused,
      );
      expect(n.livePosition, const Duration(seconds: 10));
    });

    test('外推不过歌尾', () {
      // 不加这道闸，进度条会冲到头再弹回来。
      final n = at(
        const Duration(seconds: 19),
        duration: const Duration(seconds: 20),
        readAt: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      expect(n.livePosition, const Duration(seconds: 20));
    });

    test('时间戳在将来（时钟对不上）时不倒退', () {
      final n = at(
        const Duration(seconds: 10),
        readAt: DateTime.now().add(const Duration(seconds: 5)),
      );
      expect(n.livePosition, const Duration(seconds: 10));
    });
  });

  group('播放状态解析', () {
    test('认识的照原样', () {
      expect(PlaybackState.parse('playing'), PlaybackState.playing);
      expect(PlaybackState.parse('paused'), PlaybackState.paused);
      expect(PlaybackState.parse('buffering'), PlaybackState.buffering);
    });

    test('不认识的落到 none，不抛', () {
      // 原生那边新增状态名（比如以后加了 'skipping_next'）时，旧版 App
      // 收到会走到这里。落到 none 只是标签显示「未知」，不会崩。
      expect(PlaybackState.parse('skipping_next'), PlaybackState.none);
      expect(PlaybackState.parse(''), PlaybackState.none);
    });
  });
}
