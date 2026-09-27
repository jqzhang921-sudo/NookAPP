import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 哪些**格式**的端点能把 base64 图原样收下。
///
/// ⚠️ 这张表是手写的，不是问出来的——「这个模型支不支持识图」没有地方可问。
/// 所以新加一档时得顺手在这儿表个态：写进来 = 图随报文原样发过去；不写 = 图
/// 先送去转成文字（那条路要另配识图 key，转不出来就等于没发）。
///
/// 「格式」指的是**报文怎么写**，不是模型聪不聪明：同一份 base64 图，OpenAI
/// 那条路包成 `image_url`，Claude 那条路包成 `source`。两条路现在都能发图了，
/// 所以两个都写在表里。
///
/// `mimo` 2026-09-14 加进来。之前没写是因为「没验过」——其实早验过了：
/// [VisionService] 那条识图兜底调的就是同一个地址、同一个 `mimo-v2.5`，
/// 用的正是 `image_url` 这种报文。结果是**拿 MIMO 聊天时图被转给「视觉识图」，
/// 而视觉识图又是 MIMO**，还得另配一遍 key，没配就等于没发。
///
/// `custom` 仍然不写：默认模型 `deepseek-flash` 本身能收图，但「任意自建地址」
/// 后面到底是什么模型、收不收图，代码没法知道，不写、走识图兜底最稳妥。
/// ⚠️ `mimo` 同理有个前提：选的是能看图的那个模型。改成纯文本的型号，
/// 这里会照样放行。
///
/// 存在的理由见 [AiClient.sendsImagesNatively]：原来那里写的是
/// `provider == 'openai'` 一句死判断，而 `custom` 和 default 走的是同一个
/// `_openaiChat`、同一份报文格式——一个 OpenAI 兼容、模型也确实能识图的自定义
/// 端点，就因为名字不叫 openai 被判成「不能收图」，图被**悄悄丢掉**。
const kImageNativeProviders = <String>{'openai', 'gemini', 'anthropic', 'mimo'};

class ApiKeyConfig {
  static const _keyPrefix = 'api_key_';
  static const _endpointPrefix = 'api_endpoint_';
  static const _modelPrefix = 'api_model_';

  /// 「现在用的是哪一个」。
  static const _activeProviderKey = 'api_active_provider';

  final String provider;
  final String name;
  String? apiKey;
  String? endpoint;
  String? model;

  ApiKeyConfig({
    required this.provider,
    required this.name,
    this.apiKey,
    this.endpoint,
    this.model,
  });

  static List<ApiKeyConfig> get defaults => [
    ApiKeyConfig(
      provider: 'openai',
      name: 'OpenAI',
      endpoint: 'https://api.openai.com/v1',
      model: 'gpt-4o',
    ),
    ApiKeyConfig(
      provider: 'anthropic',
      name: 'Claude',
      endpoint: 'https://api.anthropic.com/v1',
      model: 'claude-sonnet-5',
    ),
    ApiKeyConfig(
      provider: 'gemini',
      // Gemini 原生的 OpenAI 兼容层，不是某个第三方中转。
      //
      // 地址结尾**不要**带斜杠：[AiClient] 那边是 `'$endpoint/chat/completions'`
      // 直接拼的，多一个斜杠就成了 `//chat/completions`。模型名也不带
      // `models/` 前缀，带了会 400。
      name: 'Gemini',
      endpoint: 'https://generativelanguage.googleapis.com/v1beta/openai',
      model: 'gemini-3.8-flash',
    ),
    ApiKeyConfig(
      provider: 'mimo',
      // 小米的 MIMO，OpenAI 兼容格式。地址和模型跟 [VisionService] 用的是同一
      // 份——那边「拿它看图」，这边「拿它聊天」，本来就是一个服务。
      // （原来写的是 api.mimo.com / mimo-vision，那个域名根本不存在。）
      name: '小米 MIMO',
      endpoint: 'https://api.xiaomimimo.com/v1',
      model: 'mimo-v2.5',
    ),
    ApiKeyConfig(
      provider: 'custom',
      name: '自定义',
      endpoint: '',
      model: 'deepseek-flash',
    ),
  ];
}

class ApiKeyService {
  static final _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Migrate an old plain-text key from SharedPreferences to secure storage,
  /// then delete the plain-text copy. Returns the migrated key (or empty).
  static Future<String> _migrateIfNeeded(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    final oldKey = prefs.getString('${ApiKeyConfig._keyPrefix}$provider');
    if (oldKey != null && oldKey.isNotEmpty) {
      try {
        await _secureStorage.write(
          key: '${ApiKeyConfig._keyPrefix}$provider',
          value: oldKey,
        );
        await prefs.remove('${ApiKeyConfig._keyPrefix}$provider');
        debugPrint('[secure] Migrated API key for $provider');
        return oldKey;
      } catch (e) {
        debugPrint('[secure] Migration failed for $provider: $e');
        return oldKey; // fall back to the plain-text value
      }
    }
    return '';
  }

  /// 空字符串按「没有」算。
  ///
  /// [AiClient] 那边是拿 `endpoint ?? '默认地址'` 判断的，给它一个空串，它就
  /// 拼出 `/chat/completions` 这种半截地址，还查不出为什么。
  static String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

  /// 读出可选的全部「兼容格式」。
  ///
  /// **四个内置格式永远都在**，存过的值只往里填字段，不决定哪一项出场。
  ///
  /// 这里原来是「`api_providers` 里有谁就返回谁」，而 [saveKey] 只往里加
  /// *当前选中的这一个*——于是保存过第一次之后，列表就只剩他刚选的那一项，
  /// 另外三个（连 MIMO 一起）凭空消失，再也选不回去。用户看到的就是
  /// 「选过一次兼容格式就退不出来了」。
  static Future<List<ApiKeyConfig>> loadKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('api_providers') ?? [];
    // 内置的按固定顺序排在前面；用户手里多出来的（以后支持自建时才会有）
    // 按存下来的顺序接在后面。
    final order = <String>[
      for (final d in ApiKeyConfig.defaults) d.provider,
      ...saved.where((p) => !ApiKeyConfig.defaults.any((d) => d.provider == p)),
    ];

    final result = <ApiKeyConfig>[];
    for (final p in order) {
      final fallback =
          ApiKeyConfig.defaults.where((d) => d.provider == p).firstOrNull;

      // 1) Try secure storage
      String? key = await _secureStorage.read(
        key: '${ApiKeyConfig._keyPrefix}$p',
      );

      // 2) If not found, try migration from old SharedPreferences
      if (key == null || key.isEmpty) {
        key = await _migrateIfNeeded(p);
      }

      final endpoint =
          prefs.getString('${ApiKeyConfig._endpointPrefix}$p') ?? '';
      final model = prefs.getString('${ApiKeyConfig._modelPrefix}$p') ?? '';
      final name = prefs.getString('api_name_$p') ?? fallback?.name ?? p;
      result.add(
        ApiKeyConfig(
          provider: p,
          name: name,
          apiKey: (key.isNotEmpty) ? key : null,
          // 一次都没存过的，填上内置的地址和模型——他不该为了知道 OpenAI 的
          // 地址长什么样去翻文档，光看这一眼就知道了。
          endpoint: _nonEmpty(endpoint) ?? _nonEmpty(fallback?.endpoint),
          model: _nonEmpty(model) ?? _nonEmpty(fallback?.model),
        ),
      );
    }
    return result;
  }

  static Future<void> saveKey(ApiKeyConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    // 这份清单只记「除内置的四个之外，他还配过谁」，**不再决定设置页列出
    // 哪些格式**——那是 [loadKeys] 的事，它现在把内置的几个一直摆着。
    final providers = prefs.getStringList('api_providers') ?? [];
    if (!providers.contains(config.provider)) {
      providers.add(config.provider);
      await prefs.setStringList('api_providers', providers);
    }

    // API key → encrypted storage
    await _secureStorage.write(
      key: '${ApiKeyConfig._keyPrefix}${config.provider}',
      value: config.apiKey ?? '',
    );

    // Non-sensitive metadata stays in SharedPreferences
    await prefs.setString(
      '${ApiKeyConfig._endpointPrefix}${config.provider}',
      config.endpoint ?? '',
    );
    await prefs.setString(
      '${ApiKeyConfig._modelPrefix}${config.provider}',
      config.model ?? '',
    );
    await prefs.setString('api_name_${config.provider}', config.name);

    // 「保存」这个动作本身就是「以后就用这个」——顺手记下来，见 [pickActive]。
    // key 是空的也照记：读的时候会跳过没有 key 的那一个。
    await prefs.setString(ApiKeyConfig._activeProviderKey, config.provider);

    // Clean up any lingering plain-text copy
    await prefs.remove('${ApiKeyConfig._keyPrefix}${config.provider}');
  }

  /// 「现在到底用的是哪一个」——**只有这一个地方回答这个问题**。
  ///
  /// 顺序：
  /// 1. 上次按过「保存」的那一个（[saveKey] 记下的），但它得有 key；
  /// 2. 否则第一个填了 key 的——老版本没有第 1 条时就是这个行为，原样保留；
  /// 3. 一个 key 都没有 → null。
  ///
  /// 为什么非要有第 1 条：内置的四个格式现在一直在列表里，谁都能填上 key，
  /// 于是「第一个填了 key 的」永远轮不到后面那几个——他把 key 填进 MIMO 存了，
  /// 重启之后用的还是 openai，界面上还说不出哪里不对。
  static Future<ApiKeyConfig?> pickActive(List<ApiKeyConfig> configs) async {
    if (configs.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getString(ApiKeyConfig._activeProviderKey);
    final chosen = configs.where((c) => c.provider == active).firstOrNull;
    if (chosen != null && (chosen.apiKey ?? '').isNotEmpty) return chosen;
    return configs.where((c) => (c.apiKey ?? '').isNotEmpty).firstOrNull;
  }

  static Future<void> deleteKey(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    final providers = prefs.getStringList('api_providers') ?? [];
    providers.remove(provider);
    await prefs.setStringList('api_providers', providers);

    await _secureStorage.delete(key: '${ApiKeyConfig._keyPrefix}$provider');
    await prefs.remove('${ApiKeyConfig._endpointPrefix}$provider');
    await prefs.remove('${ApiKeyConfig._modelPrefix}$provider');
    await prefs.remove('api_name_$provider');
    // Clean up old plain-text copy if it was never migrated
    await prefs.remove('${ApiKeyConfig._keyPrefix}$provider');
  }
}
