import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/config/api_keys.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';
import 'package:phone_ai_assistant/services/chat_images.dart';
import 'package:phone_ai_assistant/services/nudge_service.dart';

/// 听歌时顺手看一眼她的屏幕：**那张图有没有真送到模型手上**。
///
/// 这一条断了不会报错，只会表现为「它还是不知道歌词」——而那正是这个功能
/// 存在的全部理由。所以要有一个东西钉住请求体里真带着图。
///
/// 「什么时候根本不该截」在 `nudge_gate_test.dart` 的 `musicGlanceTarget` 那组，
/// 那一条比这条重要：她在别的 App 上的画面不该存在过。
///
/// 这里只走 [NudgeService.compose]——它不碰对话存储，所以不用起
/// `StorageService`。截图那一段（`_musicGlance`）要读系统状态，真机上验。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late void Function() restore;
  late List<Map<String, dynamic>> bodies;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('music_glance');
    ChatImages.dirPath = tmp.path;
    bodies = [];

    final original = AiClient.newHttpClient;
    restore = () => AiClient.newHttpClient = original;
    AiClient.newHttpClient =
        () => MockClient.streaming((request, body) async {
          bodies.add(
            jsonDecode(utf8.decode(await body.toBytes()))
                as Map<String, dynamic>,
          );
          final sse = [
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '这句词我今天听了一路'},
                },
              ],
            })}',
            'data: [DONE]',
            '',
          ].join('\n');
          return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
        });
  });

  tearDown(() async {
    restore();
    ChatImages.dirPath = null;
    await tmp.delete(recursive: true);
  });

  AiClient client() => AiClient(
    config: ApiKeyConfig(
      provider: 'openai',
      name: 'openai',
      endpoint: 'https://example.invalid/v1',
      model: 'm',
      apiKey: 'k',
    ),
  );

  /// 取一段消息的正文。**带图的时候它不是字符串**，是一串 content part
  /// （`[{type: text}, {type: image_url}]`），所以两边都要能读。
  String textOf(Object? content) => content is String
      ? content
      : (content as List)
            .map((p) => '${(p as Map)['text'] ?? ''}')
            .join('\n');

  /// 「这首你听了十秒就切了」那一类候选，和 `musicCandidate()` 包出来的同形。
  const candidate = NudgeCandidate(
    '她在听什么',
    '《起风了》听到 0:10 就切走了（整首 3:25）',
    mentionKey: 'song:com.netease.cloudmusic:起风了:买辣椒也用券',
    music: true,
  );

  test('手上有图：图跟着这次请求一起发出去，prompt 里也说清了图上是什么', () async {
    // 一个最小的 WebP 头就够了——这条路上没人会去解它的像素。
    final webp = [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80];
    final ref = await ChatImages.save(webp);

    final out = await NudgeService.compose(
      aiClient: client(),
      candidate: candidate,
      glanceImages: [ref],
    );
    expect(out, '这句词我今天听了一路');

    final sent = jsonEncode(bodies.single['messages']);
    expect(sent, contains('data:image/webp;base64,'), reason: '图没上去，等于没看');
    // 带图的时候 content 是一串 content part，不是一段字符串——图必须真的是
    // 一个 image_url 块，不能只把 base64 塞进正文里当字。
    final parts = bodies.single['messages'].last['content'] as List;
    expect(parts.where((p) => (p as Map)['type'] == 'image_url'), isNotEmpty);
    expect(sent, contains('听到 0:10 就切走了'), reason: '听歌那件事还得在');

    final prompt = textOf(bodies.single['messages'].last['content']);
    expect(prompt, contains('歌词'), reason: '得告诉它图上有歌词这回事');
    expect(prompt, contains('她自己也会在对话里看到'));
    expect(
      prompt,
      contains('别顺着歌名把歌词编出来'),
      reason: '⚠️ 没图的那几次，歌名歌手就是全部——这条不能丢',
    );
  });

  test('没有图：一个字都不提图片', () async {
    await NudgeService.compose(aiClient: client(), candidate: candidate);

    final sent = jsonEncode(bodies.single['messages']);
    expect(sent, isNot(contains('data:image')));
    final prompt = textOf(bodies.single['messages'].last['content']);
    expect(prompt, isNot(contains('还有一张图')));
    expect(prompt, contains('听到 0:10 就切走了'));
    // ⚠️ 没图是**绝大多数**换歌的样子（她在别的 App 里、锁着屏、或者刚看过），
    // 所以音乐那套判据一个字都不能少——上面那句「别编歌词」在这条路上才是
    // 真正干活的那个。
    expect(prompt, contains('别顺着歌名把歌词编出来'));
    expect(prompt, contains('换一次歌'));
  });
}
