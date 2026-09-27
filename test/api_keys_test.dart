import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/config/api_keys.dart';

/// 这里只测一件事：**设置页那个「兼容格式」列表里应该出现什么**。
///
/// 起因是一个真实的坑——`api_providers` 曾经同时兼职「他存过哪些格式」和
/// 「设置页该列出哪些格式」。而保存只往里加当前选中的那一个，于是存过第一次
/// 之后，列表就塌成一项，别的格式（包括小米 MIMO）再也选不回来了。
/// 真机上抓到的样子：四个 chip 只剩一个 `OpenAI`。
const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 钥匙串那一半走平台通道，测试里换成一张内存表。
  final secure = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure.clear();
    messenger.setMockMethodCallHandler(_secureChannel, (call) async {
      final args = (call.arguments as Map).cast<String, dynamic>();
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secure[key];
        case 'write':
          secure[key!] = args['value'] as String;
          return null;
        case 'delete':
          secure.remove(key);
          return null;
        case 'containsKey':
          return secure.containsKey(key);
        case 'readAll':
          return Map<String, String>.from(secure);
        case 'deleteAll':
          secure.clear();
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_secureChannel, null);
  });

  List<String> providers(List<ApiKeyConfig> cs) =>
      cs.map((c) => c.provider).toList();

  ApiKeyConfig pick(List<ApiKeyConfig> cs, String p) =>
      cs.firstWhere((c) => c.provider == p);

  test('一次都没配过：五个内置格式都在，顺序固定', () async {
    final configs = await ApiKeyService.loadKeys();
    expect(providers(configs), [
      'openai',
      'anthropic',
      'gemini',
      'mimo',
      'custom',
    ]);
  });

  test('存过一个之后，另外三个不会被挤掉', () async {
    // 真机上就是这样：只存过 openai，而且地址填的是小米的。
    SharedPreferences.setMockInitialValues({
      'api_providers': ['openai'],
      'api_endpoint_openai': 'https://api.xiaomimimo.com/v1',
      'api_model_openai': 'mimo-v2.5',
    });

    final configs = await ApiKeyService.loadKeys();
    expect(providers(configs), [
      'openai',
      'anthropic',
      'gemini',
      'mimo',
      'custom',
    ], reason: '存过一个不等于只要这一个——其余几个还得能点得回去');
    // 存过的值照旧生效，不能被内置默认值顶掉。
    expect(pick(configs, 'openai').endpoint, 'https://api.xiaomimimo.com/v1');
    expect(pick(configs, 'openai').model, 'mimo-v2.5');
  });

  test('走一遍真实的保存，列表也不塌', () async {
    await ApiKeyService.saveKey(
      ApiKeyConfig(
        provider: 'openai',
        name: 'OpenAI',
        apiKey: 'sk-test',
        endpoint: 'https://api.xiaomimimo.com/v1',
        model: 'mimo-v2.5',
      ),
    );

    final configs = await ApiKeyService.loadKeys();
    expect(providers(configs), [
      'openai',
      'anthropic',
      'gemini',
      'mimo',
      'custom',
    ]);
    expect(pick(configs, 'openai').apiKey, 'sk-test');
  });

  test('小米 MIMO 那一条指向的是真地址', () async {
    final mimo = pick(await ApiKeyService.loadKeys(), 'mimo');
    // 和 VisionService 用的是同一个服务、同一份地址与模型名，改一个就得改另一个。
    expect(mimo.endpoint, 'https://api.xiaomimimo.com/v1');
    expect(mimo.model, 'mimo-v2.5');
    expect(mimo.name, contains('MIMO'));
  });

  test('Gemini 那一条指向的是原生兼容层，地址不带尾斜杠', () async {
    final gemini = pick(await ApiKeyService.loadKeys(), 'gemini');
    // 尾斜杠会拼成 `…/openai//chat/completions`；`models/` 前缀会 400。
    expect(
      gemini.endpoint,
      'https://generativelanguage.googleapis.com/v1beta/openai',
    );
    expect(gemini.endpoint, isNot(endsWith('/')));
    expect(gemini.model, isNot(startsWith('models/')));
  });

  test('自定义留空的地址是 null，不是空串', () async {
    // AiClient 那边是 `config.endpoint ?? '默认地址'`——给个空串，它拼出来的
    // 就是 `/chat/completions` 这种半截地址，还查不出为什么。
    final custom = pick(await ApiKeyService.loadKeys(), 'custom');
    expect(custom.endpoint, isNull);
    expect(custom.model, 'deepseek-flash');
  });

  test('没存过地址的格式，填上内置默认值', () async {
    final configs = await ApiKeyService.loadKeys();
    expect(pick(configs, 'openai').endpoint, 'https://api.openai.com/v1');
    expect(pick(configs, 'anthropic').endpoint, 'https://api.anthropic.com/v1');
  });

  group('现在用的是哪一个', () {
    // 这一组管的是另一半：光把四个 chip 摆回去不够，还得让「选了之后真的换过去」
    // 成立——不然重启一次又用回 openai，从他那边看还是「选了没用」。

    test('老数据没记过：第一个填了 key 的（和从前一样）', () async {
      secure['api_key_openai'] = 'sk-openai';
      secure['api_key_mimo'] = 'sk-mimo';
      final configs = await ApiKeyService.loadKeys();
      expect((await ApiKeyService.pickActive(configs))?.provider, 'openai');
    });

    test('记着上次保存的那个，就轮不到 openai 插队', () async {
      SharedPreferences.setMockInitialValues({
        'api_providers': ['openai', 'mimo'],
        'api_active_provider': 'mimo',
      });
      secure['api_key_openai'] = 'sk-openai';
      secure['api_key_mimo'] = 'sk-mimo';
      final configs = await ApiKeyService.loadKeys();
      expect((await ApiKeyService.pickActive(configs))?.provider, 'mimo');
    });

    test('记着的那个 key 被清空了，就退回第一个有 key 的', () async {
      SharedPreferences.setMockInitialValues({'api_active_provider': 'mimo'});
      secure['api_key_openai'] = 'sk-openai';
      final configs = await ApiKeyService.loadKeys();
      expect((await ApiKeyService.pickActive(configs))?.provider, 'openai');
    });

    test('一个 key 都没有 → null（界面据此显示「缺密钥」）', () async {
      expect(await ApiKeyService.pickActive(await ApiKeyService.loadKeys()), isNull);
    });

    test('保存谁，以后就用谁', () async {
      await ApiKeyService.saveKey(
        ApiKeyConfig(
          provider: 'mimo',
          name: '小米 MIMO',
          apiKey: 'sk-mimo',
          endpoint: 'https://api.xiaomimimo.com/v1',
          model: 'mimo-v2.5',
        ),
      );
      final configs = await ApiKeyService.loadKeys();
      expect((await ApiKeyService.pickActive(configs))?.provider, 'mimo');
    });

    test('存了个空 key 的，不算「在用」', () async {
      await ApiKeyService.saveKey(
        ApiKeyConfig(provider: 'mimo', name: '小米 MIMO', apiKey: ''),
      );
      expect(await ApiKeyService.pickActive(await ApiKeyService.loadKeys()), isNull);
    });
  });
}
