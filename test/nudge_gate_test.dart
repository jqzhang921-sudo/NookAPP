import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/nudge_gate.dart';

const _on = NudgePrefs(enabled: true);

DateTime at(int hour, {int day = 10}) => DateTime(2026, 9, day, hour);

void main() {
  _hideContentTests();

  // 跨零点是这个文件里唯一容易写错的地方：
  // `h >= 23 && h < 8` 永远为假，一条都拦不住，而症状是「半夜被吵醒」。
  group('静默时段', () {
    test('默认 23–8：深夜和凌晨都算静默', () {
      for (final h in [23, 0, 3, 7]) {
        expect(inQuietHours(h, _on), isTrue, reason: '$h 点该静默');
      }
    });

    test('默认 23–8：白天不算', () {
      for (final h in [8, 12, 18, 22]) {
        expect(inQuietHours(h, _on), isFalse, reason: '$h 点不该静默');
      }
    });

    test('不跨零点的时段也要对', () {
      const noon = NudgePrefs(enabled: true, quietStartHour: 12, quietEndHour: 14);
      expect(inQuietHours(11, noon), isFalse);
      expect(inQuietHours(12, noon), isTrue);
      expect(inQuietHours(13, noon), isTrue);
      expect(inQuietHours(14, noon), isFalse); // 右开区间
    });

    test('起止相同 = 没有静默时段，不是全天静默', () {
      const none = NudgePrefs(enabled: true, quietStartHour: 9, quietEndHour: 9);
      expect(inQuietHours(9, none), isFalse);
      expect(inQuietHours(3, none), isFalse);
    });
  });

  group('拦不拦', () {
    test('没开就什么都不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: const NudgePrefs(), // enabled 默认 false
      );
      expect(d.allowed, isFalse);
      expect(d.reason, NudgeBlock.disabled);
    });

    test('什么都不挡的时候放行', () {
      final d = decideNudge(now: at(15), prefs: _on);
      expect(d.allowed, isTrue);
      expect(d.reason, NudgeBlock.none);
    });

    test('半夜不推', () {
      final d = decideNudge(now: at(2), prefs: _on);
      expect(d.reason, NudgeBlock.quietHours);
    });

    // ⚠️ 这里**没有**「一天几条」的用例，是因为那道闸拆掉了。
    //
    // 它本来防「某个 bug 连环推送」，可间隔那道已经把这件事做了——一小时一条，
    // 加上静默时段，一天上限本来就只有十几条。两道闸防同一件事，多的那道
    // 只会误伤：真机上静默写入也在计数，一天装九次包就把额度耗光，
    // 真该弹通知时反而被自己拦下。
    //
    // 下面这条钉的就是拆掉之后的行为：连着推很多次，只要间隔够，就不该拦。
    test('推过很多次也不拦，只看间隔', () {
      final d = decideNudge(
        now: at(20),
        prefs: _on,
        lastNudgeAt: at(18),
      );
      expect(d.allowed, isTrue);
    });

    test('离上一条太近不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        // 差 30 分钟，默认间隔 1 小时
        lastNudgeAt: at(15).subtract(const Duration(minutes: 30)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterNudge);
    });

    test('隔够了就放行', () {
      final d = decideNudge(
        now: at(18),
        prefs: _on,
        lastNudgeAt: at(15),
      );
      expect(d.allowed, isTrue);
    });

    // 刚聊完就弹一条，读起来像它没听见你刚说的话。
    test('话音刚落不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        lastChatAt: at(15).subtract(const Duration(minutes: 20)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterChat);
    });

    // ⚠️ 这个数从 3 小时降到 1 小时是有原因的：她一天聊一百多轮，**根本攒不出
    // 连续三小时不碰 App 的空档**，信和日记那两类候选于是永远推不出来。
    // 真正防打扰的是间隔和静默时段那两道，这条只保证「不是话音刚落就插一句」。
    test('聊完过了一小时就可以推', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        lastChatAt: at(14),
      );
      expect(d.allowed, isTrue);
    });

    // ⚠️ 这条钉的是设计红线，不是实现细节：
    // 「太久没聊」**不能**成为推送的理由。那是拿愧疚换打开率。
    // 门槛里没有任何一条会因为「隔得久」而变得更想推——
    // 隔一天和隔一个月，放行与否完全一样。
    test('隔了很久本身不构成推的理由，也不构成拦的理由', () {
      final aMonthAgo = DateTime(2026, 8, 10, 15);
      final justEnough = at(11); // 刚好过了三小时静默

      final longGone = decideNudge(
        now: at(15),
        prefs: _on,
        lastChatAt: aMonthAgo,
      );
      final recent = decideNudge(
        now: at(15),
        prefs: _on,
        lastChatAt: justEnough,
      );

      expect(longGone.allowed, isTrue);
      expect(recent.allowed, isTrue);
      expect(longGone.reason, recent.reason); // 两种情况一视同仁
    });

    // ⚠️ 这一组钉的是一个真实踩过的坑：常聊天的人（一天一百多轮）永远等不到
    // 三小时安静，于是所有便签都过期作废——功能等于没做。
    // 便签的时间是它自己在对话里定的，「刚聊完」这条不该反过来否决它。
    test('便签到点：刚聊完也照样放行', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        isFollowUp: true,
        lastChatAt: at(15).subtract(const Duration(minutes: 40)),
      );
      expect(d.allowed, isTrue);
    });

    test('同样的时刻，不是便签就还是拦', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        lastChatAt: at(15).subtract(const Duration(minutes: 40)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterChat);
    });

    test('便签之间用更短的间隔：差 25 分钟就能连着推两条', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        isFollowUp: true,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 25)),
      );
      expect(d.allowed, isTrue);
    });

    test('但便签也不能连着弹：差 10 分钟还是拦', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        isFollowUp: true,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 10)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterNudge);
    });

    test('便签也照样受静默时段管', () {
      expect(
        decideNudge(
          now: at(2),
          prefs: _on,
          isFollowUp: true,
        ).reason,
        NudgeBlock.quietHours,
      );
    });

    test('从来没聊过、从来没推过也不该崩', () {
      final d = decideNudge(now: at(15), prefs: _on);
      expect(d.allowed, isTrue);
    });
  });

  // 主动消息的通病是重复——单条读着没问题，连着三天收到同一句就假了。
  // 音乐那条单独一套间隔。它的量级和别的不一样：信和日记一天出不了几回，
  // 听歌一个下午几十首。沿用 1 小时等于白接，完全松开又变成每首歌一句的
  // 播报机——所以单开一条，而且只松这一条。
  group('听歌那条的间隔', () {
    test('隔 10 分钟就能说，不用等满 1 小时', () {
      // 这一条钉的正是「它比别的松」：同样两个时刻，普通由头会被拦下。
      // 10 分钟这个数**贴着 8 分钟那条线**（2026-09-27 从 20 调下来的），
      // 再调大的话它会跟着失效，不会假装还测着。
      final music = decideNudge(
        now: at(15),
        prefs: _on,
        isMusic: true,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 10)),
      );
      expect(music.allowed, isTrue);
      expect(music.reason, NudgeBlock.none);

      final other = decideNudge(
        now: at(15),
        prefs: _on,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 10)),
      );
      expect(other.reason, NudgeBlock.tooSoonAfterNudge);
    });

    test('刚说完 5 分钟又切歌，不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        isMusic: true,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 5)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterNudge);
    });

    test('⚠️ 静默时段对音乐一个字都不松', () {
      // 歌可以半夜照听，话不能半夜照说。松的只有间隔那一条。
      final d = decideNudge(
        now: at(2),
        prefs: _on,
        isMusic: true,
        lastNudgeAt: at(1),
      );
      expect(d.reason, NudgeBlock.quietHours);
    });

    test('⚠️ 刚聊完也不松', () {
      // 这次豁免的只有便签。她刚打完一行字，这边紧接着冒一句「这首你听了十秒
      // 就切了」——那不是陪伴，那是盯着她。
      final d = decideNudge(
        now: at(15),
        prefs: _on,
        isMusic: true,
        lastChatAt: at(15).subtract(const Duration(minutes: 20)),
      );
      expect(d.reason, NudgeBlock.tooSoonAfterChat);
    });

    test('没开就照旧什么都不推', () {
      final d = decideNudge(
        now: at(15),
        prefs: const NudgePrefs(), // enabled 默认 false
        isMusic: true,
      );
      expect(d.reason, NudgeBlock.disabled);
    });

    test('音乐冷却和便签冷却互不影响', () {
      // 同一个时刻、同一条「上回开口是 10 分钟前」，只有种类不同——音乐放行，
      // 便签照旧拦下。这一条钉的就是「两个是各算各的」，别哪天顺手把音乐那条
      // 也接到便签的冷却上去。
      final music = decideNudge(
        now: at(15),
        prefs: _on,
        isMusic: true,
        lastNudgeAt: at(15).subtract(const Duration(minutes: 10)),
      );
      expect(music.allowed, isTrue); // 10 > 8

      final followUp = decideNudge(
        now: at(15),
        prefs: _on,
        isFollowUp: true, // 便签走 20 分钟那条
        lastNudgeAt: at(15).subtract(const Duration(minutes: 10)),
      );
      expect(followUp.reason, NudgeBlock.tooSoonAfterNudge); // 10 < 20
    });
  });

  group('听歌时顺手看一眼屏幕', () {
    // 这一组的重点**不是截图成不成**，是**什么时候根本不截**。她在别的 App
    // 上的画面不该存在过，所以那几条要钉死。

    test('屏幕上正是那个在放歌的 App：可以看', () {
      expect(
        musicGlanceTarget(
          playing: 'com.netease.cloudmusic',
          front: 'com.netease.cloudmusic',
        ),
        isTrue,
      );
      // 歌词页、播放页、设置页——都是同一个包，都算。
      expect(
        musicGlanceTarget(
          playing: 'com.netease.cloudmusic',
          front: 'com.netease.cloudmusic',
        ),
        isTrue,
      );
    });

    test('⚠️ 她在任何别的 App 里：不看', () {
      for (final front in [
        'com.tencent.mm', // 微信
        'com.eg.android.AlipayGphone', // 支付宝
        'com.android.gallery3d', // 相册
        'com.phonetool.phone_ai_assistant', // 她自己就在 Nook 里
        'com.android.launcher', // 桌面
      ]) {
        expect(
          musicGlanceTarget(playing: 'com.netease.cloudmusic', front: front),
          isFalse,
          reason: '前台是 $front 的时候一次都不该截',
        );
      }
    });

    test('没有在放的播放器：不看', () {
      expect(musicGlanceTarget(playing: null, front: 'com.netease.cloudmusic'), isFalse);
      expect(musicGlanceTarget(playing: '', front: 'com.netease.cloudmusic'), isFalse);
    });

    test('前台查不出来：不看', () {
      // 锁屏、灭屏、排除名单里——`check` 这会儿不回包名，那就不看。
      expect(
        musicGlanceTarget(playing: 'com.netease.cloudmusic', front: null),
        isFalse,
      );
    });

    test('30 分钟那道闸', () {
      final t = at(15);
      expect(musicGlanceDue(now: t, lastAt: null), isTrue, reason: '从没看过');
      expect(
        musicGlanceDue(now: t, lastAt: t.subtract(const Duration(minutes: 29))),
        isFalse,
      );
      expect(
        musicGlanceDue(now: t, lastAt: t.subtract(const Duration(minutes: 31))),
        isTrue,
      );
      // ⚠️ 按**看**算不按「说不说」算：看了没说话，这 30 分钟照样算用过了，
      // 不然下一次换歌又来一张，留痕就成了刷屏。
      expect(musicGlanceGap, const Duration(minutes: 30));
    });
  });

  group('别把同一天过第二遍', () {
    test('换了标点和语序，仍然算同一句', () {
      const recent = ['我刚写完一封信，放在栖息里了'];
      expect(looksRepeated('我刚写完一封信，放在栖息里了。', recent), isTrue);
      expect(looksRepeated('刚写完一封信，放栖息里了', recent), isTrue);
    });

    test('说的是另一件事就该放行', () {
      const recent = ['我刚写完一封信，放在栖息里了'];
      expect(looksRepeated('昨天那本书我看到一半，主角忽然不说话了', recent), isFalse);
    });

    test('没有历史时永远不算重复', () {
      expect(looksRepeated('随便一句话', const []), isFalse);
    });

    test('只要和历史里任意一条像，就算重复', () {
      const recent = ['今天记了篇日记', '我刚写完一封信，放在栖息里了'];
      expect(looksRepeated('刚写完一封信，放栖息里了', recent), isTrue);
    });

    test('空串不该被判成重复', () {
      expect(looksRepeated('', const ['我刚写完一封信']), isFalse);
    });
  });

  // 拦下来的原因要能显示给用户看：点了「现在试一次」没反应，
  // 不说原因的话只会以为功能坏了。
  group('每个拦截原因都有话可说', () {
    test('文案都不为空，且不是重复的', () {
      final labels = NudgeBlock.values.map((b) => b.label).toList();
      expect(labels.every((s) => s.trim().isNotEmpty), isTrue);
      expect(labels.toSet().length, labels.length);
    });
  });
}

// ── 通知里显不显示内容 ────────────────────────────────────────────
//
// 这条不是防打扰，是防旁人：推送内容会原样上锁屏，而它说的话是从板上的
// 纸条、日记、信里长出来的。要保证的是**藏的只是展示**，不是内容。
void _hideContentTests() {
  group("通知内容开关", () {
    test("默认是显示的——藏起来该是她主动选的", () {
      expect(const NudgePrefs().hideContent, isFalse);
    });

    test("存得住读得回", () {
      for (final v in [true, false]) {
        final back = NudgePrefs.fromJson(
          const NudgePrefs().copyWith(hideContent: v).toJson(),
        );
        expect(back.hideContent, v);
      }
    });

    test("老偏好里没这个键，读出来是显示", () {
      final back = NudgePrefs.fromJson({
        "enabled": true,
        "quietStartHour": 23,
        "quietEndHour": 8,
      });
      expect(back.hideContent, isFalse);
      expect(back.enabled, isTrue);
    });

    test("它不参与门槛——藏内容不该改变推不推", () {
      final now = DateTime(2026, 9, 3, 15);
      for (final v in [true, false]) {
        final d = decideNudge(
          now: now,
          prefs: const NudgePrefs(enabled: true).copyWith(hideContent: v),
        );
        expect(d.allowed, isTrue);
      }
    });
  });
}
