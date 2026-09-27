import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/config/api_keys.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';

/// 「哪个格式能把图原样发给模型」靠的是 [kImageNativeProviders] 那张**手写**
/// 的表。以前这儿写的是 `provider == 'openai'` 一句死判断，而 `custom` 和
/// default 走的是同一个 `_openaiChat`、同一份报文——OpenAI 兼容又能识图的自定义
/// 端点（Gemini 就是一个）图会被**悄悄丢掉**，模型只看到文字。
///
/// 悄悄丢掉是最难查的一类：没有报错、没有日志，表现就是「模型说它没收到图」。
/// 所以这几条钉住「谁能收、谁不能收」，加新档位时改动这里会立刻红。
void main() {
  AiClient clientOf(String provider) =>
      AiClient(config: ApiKeyConfig(provider: provider, name: provider));

  test('能收图的格式：图随报文原样发过去', () {
    // anthropic 也在这边——两条路报文的装法不同（image_url vs source），
    // 但都真的把图发出去了。加档位时忘了配报文，`sendsImagesNatively` 会
    // 提前放行，图却哪儿都没去，比「转成文字」还难查。
    //
    // mimo 2026-09-14 挪到这一组：视觉识图那条兜底本来就是拿同一个 MIMO 地址、
    // 同一种 image_url 报文在看图。原来留在外面，拿 MIMO 聊天时图就被转去
    // 「视觉识图」——而那边又是 MIMO，还得另配一遍 key。
    for (final p in ['openai', 'gemini', 'anthropic', 'mimo']) {
      expect(clientOf(p).sendsImagesNatively, isTrue, reason: p);
    }
  });

  test('不能收图的格式：图得先送去转成文字', () {
    // custom 的默认模型 deepseek-flash 本身能收图，但「任意自建地址」后面是什么
    // 模型代码没法知道，有的能收图、有的不能。所以它不写进表里、走识图兜底。
    for (final p in ['custom']) {
      expect(clientOf(p).sendsImagesNatively, isFalse, reason: p);
    }
  });

  test('表里的名字都得是真有的档位', () {
    final builtin = ApiKeyConfig.defaults.map((d) => d.provider).toSet();
    // 防手滑：写出 `{'openai', 'gpt-5'}` 这种，这条会立刻红。
    for (final p in kImageNativeProviders) {
      expect(builtin, contains(p), reason: '$p 不在内置档位里');
    }
  });

  group('认得出图是什么格式', () {
    // Anthropic 那边 media_type 对不上是**整条请求 400**，所以这里错不起。
    String b64(List<int> head) =>
        base64Encode([...head, ...List.filled(16, 0)]);

    test('四种相册里常见的都认得', () {
      expect(
        mimeOfImage(b64([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])),
        'image/png',
      );
      expect(mimeOfImage(b64([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
      expect(
        mimeOfImage(b64([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])),
        'image/gif',
      );
      // webp 是 RIFF 容器：前四字节谁都是 RIFF，第 8 字节起才写着 WEBP。
      expect(
        mimeOfImage(
          b64([
            0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, //
            0x57, 0x45, 0x42, 0x50,
          ]),
        ),
        'image/webp',
      );
    });

    test('RIFF 但不带 WEBP 的，不算 webp', () {
      // wav、avi 也是 RIFF 开头。认成 webp 就是给对端递一个它解不开的东西。
      expect(
        mimeOfImage(
          b64([
            0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, //
            0x57, 0x41, 0x56, 0x45,
          ]),
        ),
        isNot('image/webp'),
      );
    });

    test('认不出来、或者根本不是图：按 jpeg 报，不抛', () {
      // 宁可让对端自己去猜，也别在这儿抛——这一步挂掉就是「发图就崩」。
      expect(mimeOfImage(b64([0x00, 0x01, 0x02, 0x03])), 'image/jpeg');
      expect(mimeOfImage(''), 'image/jpeg');
      expect(mimeOfImage('abc'), 'image/jpeg');
      expect(mimeOfImage('!!!!not base64!!!!'), 'image/jpeg');
    });
  });
}
