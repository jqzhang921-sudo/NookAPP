import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/phone_tools/music_tool.dart';

void main() {
  // 要走平台通道（哪怕只是为了撞上「没有 handler」那条路），先得把 binding
  // 起起来——不起的话 `MethodChannel.binaryMessenger` 自己就抛了，测出来的
  // 是 binding 没初始化，跟这个工具一点关系都没有。
  TestWidgetsFlutterBinding.ensureInitialized();

  // 这块测的是**这个工具怎么跟模型交代事情**，不是它能不能真的切歌——
  // 后者要真机和真播放器，测不了。能测的是三条：
  //
  // 1. schema 里列的动作和代码里认的动作是同一批（列了不认 = 模型调了就撞墙）
  // 2. 报错说的是「怎么改」，不是「失败了」
  // 3. 没权限时说清楚是哪种没权限
  //
  // 测试环境里没有平台通道，所以 hasPermission 一律 false。控制类的动作
  // 全都会停在「没有通知使用权」那一句上，不会真去碰播放器。

  group('动作派发', () {
    test('schema 里列的每一个动作，代码都认得', () async {
      // ⚠️ 这条是防「加了动作忘了改派发」的。`enum` 是模型看到的清单，
      // `execute` 里那张表是真正认的——两边对不上，模型会照着 schema 调，
      // 然后收到一句「认不出这个动作」，而它没有任何办法自己修。
      final schema = MusicTool.definition.inputSchema;
      final actions = (schema['properties']! as Map)['action']! as Map;
      final listed = (actions['enum']! as List).cast<String>();

      expect(listed, isNotEmpty);
      for (final a in listed) {
        final r = await MusicTool.execute({'action': a});
        expect(
          '${r['error'] ?? ''}',
          isNot(contains('认不出')),
          reason: 'schema 里列了 $a，execute 却不认',
        );
      }
    });

    test('认不出的动作把可用的都列出来', () async {
      final r = await MusicTool.execute({'action': 'shuffle'});
      expect(r['success'], isFalse);
      final err = '${r['error']}';
      expect(err, contains('shuffle')); // 回声，让它看清自己发了什么
      expect(err, contains('next')); // 可用清单
      expect(err, contains('seek'));
    });

    test('动作名大小写和空格不影响', () async {
      // 模型发出来的参数不总是干净的。这一条不 trim 的话，`"Next "` 会撞到
      // 「认不出」上，而那是它自己修不了的。
      final r = await MusicTool.execute({'action': '  NEXT '});
      expect('${r['error'] ?? ''}', isNot(contains('认不出')));
    });
  });

  group('seek 的参数', () {
    test('没给 position_ms 时说清楚要给什么', () async {
      final r = await MusicTool.execute({'action': 'seek'});
      expect(r['success'], isFalse);
      final err = '${r['error']}';
      expect(err, contains('position_ms'));
      // 光说「缺少参数」模型会瞎猜一个数；给个换算例子它才知道单位是毫秒。
      expect(err, contains('60000'));
    });

    test('给了 position_ms 就不再拦它', () async {
      final r = await MusicTool.execute({'action': 'seek', 'position_ms': 60000});
      // 会停在权限那一步，但**不是**参数那一句——参数这关过了。
      expect('${r['error'] ?? ''}', isNot(contains('position_ms')));
    });

    test('浮点数的毫秒也收', () async {
      // 有些模型把整数写成 60000.0。`as int?` 会抛，`as num?` 不会。
      final r = await MusicTool.execute({'action': 'seek', 'position_ms': 60000.0});
      expect('${r['error'] ?? ''}', isNot(contains('position_ms')));
    });
  });

  group('没权限', () {
    test('读和控制都要说清是哪种没权限', () async {
      // 「读不到」和「控制不了」是两件事，用户要做的事却是同一件（去开权限）。
      // 所以两句都得提到「通知使用权」，并且指出去哪儿开——不然模型只能说
      // 「我做不到」，用户没法接下一步。
      final read = await MusicTool.execute({'action': 'now_playing'});
      final write = await MusicTool.execute({'action': 'pause'});
      for (final r in [read, write]) {
        expect(r['success'], isFalse);
        expect('${r['error']}', contains('通知使用权'));
      }
    });
  });

  group('工具定义', () {
    test('描述里写明了不许不问就控制', () async {
      // 这不是文风问题。播放控制是唯一一个**会打断用户当下正在做的事**的
      // 手机工具，而 `next` 就摆在模型手边——描述里不说死，它很容易顺手
      // 「帮」用户换一首。这条测试是那句话的看门人。
      final d = MusicTool.definition.description;
      expect(d, contains('打断'));
      expect(d, contains('不要'));
    });

    test('归在手机工具这一类', () {
      expect(MusicTool.definition.category, '手机工具');
    });
  });
}
