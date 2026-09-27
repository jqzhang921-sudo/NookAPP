import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_keys.dart';
import '../models/chat_message.dart';
import '../models/mcp_tool.dart';
import 'chat_images.dart';
import 'music_service.dart';

/// 把时间戳格式化并拼在消息内容前面，让模型能看到每条消息的发生时间。
String _withTimestamp(String content, DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final ts =
      '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  return '[time: $ts]\n$content';
}

/// 从 base64 图里嗅出真实的 MIME 类型。
///
/// 为什么不能写死：图是从相册里挑的，png、jpeg、webp、gif 都有。以前这里一律
/// 报 `image/jpeg`——OpenAI 那边不看这个字段，混过去一直没人发现；Anthropic
/// 那边 `media_type` 是**校验**的，把 png 报成 jpeg 整条请求直接 400，不是
/// 「图丢了」而是「消息发不出去」。
///
/// 认不出来的一律按 jpeg 报：宁可让对端自己去猜，也别在这儿抛异常——
/// 这一步挂掉的话，用户看到的是「发图就崩」。
///
/// 拆成公开的、不依赖网络的纯函数，就是为了能直接测——认字节这件事是这里
/// 唯一会错的地方，而它的错法（Anthropic 400）在真机上不摆弄一次看不出来。
///
/// 不再标 `@visibleForTesting`：2026-09-14 起 [VisionService] 也用它——
/// 聊天图片改存 WebP 之后，那边原来写死的 `image/jpeg` 每张都是错的。
String mimeOfImage(String base64Image) {
  // 只看开头一小截就够，不必把整张图解出来。截断的长度得是 4 的倍数，
  // 否则 base64.decode 会当成非法输入。
  final take = base64Image.length - (base64Image.length % 4);
  if (take < 12) return 'image/jpeg';
  final List<int> bytes;
  try {
    bytes = base64.decode(base64Image.substring(0, take));
  } catch (_) {
    return 'image/jpeg';
  }

  bool startsWith(List<int> sig) {
    if (bytes.length < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[i] != sig[i]) return false;
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  // RIFF 只是容器（wav、avi 都是它），第 8 字节起写着真正的格式。
  if (startsWith([0x52, 0x49, 0x46, 0x46]) &&
      bytes.length >= 12 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  // 剩下的按 jpeg 算，jpeg 自己的头（FF D8 FF）也落在这儿。
  return 'image/jpeg';
}

/// 去掉模型可能复读出来的 [time: ...] 时间戳标记。
String _stripTimeMarkers(String text) {
  return text
      .replaceAll(RegExp(r'\[time:[^\]]*\]'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trimLeft();
}

/// 修复损坏的对话历史：如果某条 assistant 消息发起了工具调用，但对应的
/// tool_call_id 在后面找不到匹配的 toolResult 消息（比如因为工具执行时
/// 异常中断、或者旧版本代码的bug导致结果没存下来），就给它补一条占位的
/// 失败结果。不修的话，这类对话会在每次发消息时都被服务商 API 以
/// "tool_calls 缺少对应响应" 为由拒绝（400），且没法靠重试恢复，因为
/// 坏掉的历史已经存进本地了。
List<ChatMessage> _sanitizeToolCallHistory(List<ChatMessage> messages) {
  final result = <ChatMessage>[];
  for (var i = 0; i < messages.length; i++) {
    final msg = messages[i];
    result.add(msg);
    if (msg.role != MessageRole.assistant ||
        msg.toolCalls == null ||
        msg.toolCalls!.isEmpty) {
      continue;
    }
    // 收集紧随其后、属于这一轮的 toolResult 消息，看看有没有覆盖所有
    // tool_call_id（一直找到下一条非 toolResult 消息为止）
    // 扫描其后的全部历史，而不是只看紧邻的连续 toolResult。
    //
    // 原来一遇到非 toolResult 消息就 break：只要结果之间夹了任何一条别的消息
    // （模型在工具调用之间说了句话、或多轮工具交错），后面的结果就被判成
    // 「没有响应」，于是补上占位、真结果反而被 _repairToolMessages 当孤儿剔除，
    // 服务端照样报 tool_call_id 缺响应。
    final answered = <String>{};
    for (var j = i + 1; j < messages.length; j++) {
      final next = messages[j];
      if (next.role == MessageRole.toolResult && next.toolCallId != null) {
        answered.add(next.toolCallId!);
      }
    }
    for (final tc in msg.toolCalls!) {
      if (!answered.contains(tc.id)) {
        result.add(
          ChatMessage(
            id: 'repair_${tc.id}',
            role: MessageRole.toolResult,
            content: jsonEncode({
              'success': false,
              'error': '工具结果丢失（历史记录已自动修复，此结果为占位）',
            }),
            toolCallId: tc.id,
          ),
        );
      }
    }
  }
  return result;
}

/// 服务端在为 `reasoning_content` 这个字段抱怨吗，抱怨哪一种。
///
/// 2026-09-16 Cleo 让它看一眼屏幕，那一轮 400 断在这儿：
/// `The reasoning_content in the thinking mode must be passed back to the API`。
///
/// 带思考的模型（DeepSeek 系）把思路放在 `reasoning_content` 里；**一旦这一轮
/// 出现过工具调用，后面每次请求都得把它原样带回去**。我们一直收着（存成
/// [ChatMessage.thinking]），但拼报文时没带上——于是它调一次工具就必然 400，
/// 再也接不下去。
///
/// 反过来也有：有的中转站不认这个字段，照发反而报错。所以分两种对症，
/// 别拿一种办法治两个方向。
enum ReasoningComplaint {
  /// 「必须带回来」——我们漏了。
  mustPass,

  /// 「这是什么字段」——它不认。
  notAllowed,

  none,
}

ReasoningComplaint reasoningComplaintOf(String error) {
  final e = error.toLowerCase();
  if (!e.contains('reasoning_content') && !e.contains('reasoning content')) {
    return ReasoningComplaint.none;
  }
  // 「必须传回来」那一类的说法：must be passed / must be provided / required。
  if (e.contains('must be') || e.contains('required') || e.contains('必须')) {
    return ReasoningComplaint.mustPass;
  }
  // 「不认识 / 不允许」那一类：unknown / unsupported / not allowed / invalid。
  if (e.contains('unknown') ||
      e.contains('unsupported') ||
      e.contains('not allowed') ||
      e.contains('unexpected') ||
      e.contains('invalid')) {
    return ReasoningComplaint.notAllowed;
  }
  // 认不出是哪一种：当成「它不认」。少发一个字段顶多丢一点思路，
  // 多发一个可能整条请求发不出去。
  return ReasoningComplaint.notAllowed;
}

/// 把 `reasoning_content` 全部摘掉。
List<Map<String, dynamic>> stripReasoning(List<Map<String, dynamic>> messages) {
  return [
    for (final m in messages)
      if (m.containsKey('reasoning_content'))
        {
          for (final e in m.entries)
            if (e.key != 'reasoning_content') e.key: e.value,
        }
      else
        m,
  ];
}

/// 给缺思路的 assistant 消息补一个空的 `reasoning_content`。
///
/// 用在「必须带回来」那条重试上：她那段对话是这个修复之前存下来的，
/// 有工具调用、却没有存思路——补不回真的，只能补一个空的，
/// 好让这段历史还能接着往下聊，而不是每次发送都 400。
List<Map<String, dynamic>> fillMissingReasoning(
  List<Map<String, dynamic>> messages,
) {
  return [
    for (final m in messages)
      if (m['role'] == 'assistant' && m['reasoning_content'] == null)
        {...m, 'reasoning_content': ''}
      else
        m,
  ];
}

/// 它看了一眼屏幕、决定不说话时留下的那条：只有截图，没有字。
///
/// 这条是**给她翻的痕迹**（看过一定留痕），不是它说过的一句话。发给模型就是
/// 一条空的 assistant——有的端点直接 400，没报错的也等于教它「可以说空话」。
/// 截图本身也不重发：assistant 的图本来就不进报文，见 [AiClient._sendableImages]。
bool isSilentGlance(ChatMessage m) =>
    m.role == MessageRole.assistant &&
    m.metadata?['glance'] == true &&
    m.content.trim().isEmpty &&
    (m.toolCalls?.isEmpty ?? true);

/// 一次回复最多生成多少 token。
///
/// 原来是 4096。推理模型把**思考也算进输出**，4096 经常在它还没想完的时候
/// 就被砍断——症状是话说到一半没了，或者干脆只出思考不出正文。
/// 8192 是各家普遍都接受的上限，再往上有的端点会直接报错。
const _maxOutputTokens = 8192;

/// 系统级提示：时间戳只是元数据，模型不应复述。
const _timeMetaInstruction =
    '注意：消息内容中可能带有 [time: ...] 前缀，这是系统自动注入的发送时间元数据，'
    '仅供你了解对话时间线。绝对不要在回复中输出、模仿或重复 [time: ...] 这类标记。';

class AiClient {
  final ApiKeyConfig config;
  final List<McpTool>? tools;

  AiClient({required this.config, this.tools});

  /// [systemPrompt] 是**长期不变**的人设，[memoryContext] 是每天都在变的记忆。
  /// 两者必须分开传，别在调用方就拼成一个字符串——原因见 [_attachMemory]。
  Stream<AiStreamEvent> chat(
    List<ChatMessage> messages, {
    String? systemPrompt,
    String? memoryContext,
    String? historySummary,
  }) {
    final safeMessages = _sanitizeToolCallHistory(
      messages.where((m) => !isSilentGlance(m)).toList(),
    );
    switch (config.provider) {
      case 'openai':
        return _openaiChat(
          safeMessages,
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: historySummary,
        );
      case 'anthropic':
        return _anthropicChat(
          safeMessages,
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: historySummary,
        );
      default:
        return _openaiChat(
          safeMessages,
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: historySummary,
        );
    }
  }

  /// 摘要拼进 system 块，而不是像记忆那样挂到尾部。
  ///
  /// 两者的易变程度不同：记忆几乎天天变，所以必须躲开缓存前缀；摘要只在每次
  /// 压缩时变一次（几十条消息才一次），放在前面反而更合理——它代表的就是被
  /// 折叠掉的那段最早的历史，位置上本来就该在那儿。
  static String _buildSystemContent(String? systemPrompt, String? summary) {
    final buf = StringBuffer('$systemPrompt\n\n$_timeMetaInstruction');
    if (summary != null && summary.trim().isNotEmpty) {
      buf.write(
        '\n\n## 更早对话的摘要\n（这段聊得比较久了，早期原文已折叠成下面这段。'
        '需要时可以当作你记得的事，但别复述给用户听。）\n$summary',
      );
    }
    return buf.toString();
  }

  /// 把记忆挂到**最后一条用户消息**上，而不是拼进 system。
  ///
  /// 为了 prompt caching。服务端缓存的是请求前缀，命中要求跟已存的缓存单元
  /// 完整匹配；记忆放在最前面，它一变（写了篇日记、或者只是「最近一封信是 3
  /// 天前」跨天变成 4 天前），后面几千 token 的对话历史就整段错位，全部落空。
  ///
  /// 挂到尾部之后，`[人设][对话历史]` 这一大段跨轮次逐字节不变，正好是
  /// DeepSeek 文档里「第一轮 A+B，第二轮 A+B+C」那种能整段命中的形状。
  ///
  /// 不新增一条 system 消息、而是并进用户消息里，是为了避开兼容性风险——
  /// 不是所有 OpenAI 兼容端点都接受 system 出现在消息列表中间或末尾。
  /// 这个格式能不能直接把图发给模型。
  ///
  /// 依据是 [kImageNativeProviders] 那张**手写**的表，不是问出来的：
  /// 「这个模型支不支持识图」没有地方可问。表里没写、但模型其实能识图的端点
  /// （自定义那一档最常见），图会被**悄悄丢掉**，模型只看到文字，还查不出
  /// 为什么。真要根治得让用户在设置里自己说，或者试探一次记下来——那是单独
  /// 一件事。
  ///
  /// 但**这个判断只许有这一处**。散到 UI 层去，两边迟早说不到一起。
  bool get sendsImagesNatively =>
      kImageNativeProviders.contains(config.provider);

  /// 发出请求后，等响应头最多等多久。
  ///
  /// ## 为什么要有超时
  ///
  /// 原来**一个超时都没有**。连接要是没断、只是卡住（代理半死不活、握手挂着），
  /// `client.send` 和读流都会一直等下去——界面上就是进度条永远在走，发送键
  /// 灰着，也没有报错。2026-09-14 读书讨论《窄门》那条就是这么卡住的，
  /// 当时 Cleo 手机开着代理。
  ///
  /// 断掉的连接会报 HandshakeException，那种早就能看见；怕的是**不断也不回**。
  @visibleForTesting
  static Duration responseTimeout = const Duration(seconds: 60);

  /// 流开始以后，两段数据之间最多隔多久。
  ///
  /// 放得比 [responseTimeout] 宽：有的推理模型想的时候不往外吐 reasoning，
  /// 会安静一阵子。这里只防「彻底没动静」。
  @visibleForTesting
  static Duration idleTimeout = const Duration(seconds: 90);

  /// 测试里换成假的 client。
  @visibleForTesting
  static http.Client Function() newHttpClient = http.Client.new;

  static String _timeoutMessage(TimeoutException e) =>
      '连接超时：${e.duration?.inSeconds ?? '?'} 秒没收到模型的回音。'
      '多半是网络或代理的问题，再发一次试试。';

  /// 这条消息里真正要随报文发出去的图（base64）。
  ///
  /// 图现在大多是文件引用，发的时候才读出来；超过 30 天被清掉的、文件
  /// 找不到的，直接不带（见 [ChatImages]）。一张都不剩就按纯文字发——
  /// 不能因为一张旧图没了，整轮请求发不出去。
  List<String> _sendableImages(ChatMessage msg) {
    if (!sendsImagesNatively || msg.images.isEmpty) return const [];
    return msg.images.map(ChatImages.base64Of).whereType<String>().toList();
  }

  /// 把「她现在在听什么」贴到最后一条用户消息上。
  ///
  /// ## 为什么必须单独有这一块
  ///
  /// 三期那条「AI 主动开口」的路只是**偶尔**响一次。可这个功能真正要的是
  /// **它一直知道**：她随口提一句「这首歌」，或者问「我在听什么」，它得接得住。
  /// 只靠主动开口，它平时就是个瞎子——那就不叫「两个人一起听」了。
  ///
  /// ## 为什么和记忆一样是个**块**，不走 `_withTimestamp` 那套前缀
  ///
  /// 那套前缀是**用户消息的一部分**，模型会当成她说过的话。这条不是她说的，
  /// 是她那边正在发生的事，该和 [memoryContext] 一样是背景。
  ///
  /// ⚠️ 顺序：这个必须在 [_attachMemory] **之前**调。它俩都是「往最后一条用户
  /// 消息前面插一段」，后插的在外层——`_attachMemory` 里那个 `---` 分隔符是
  /// 紧挨着她的原话的，得让它保持在那儿。这样现在的顺序是
  /// `记忆 / --- / 在听什么 / 她的话`：两块都是背景，而最新鲜的那条离她的话最近。
  ///
  /// ⚠️ **判据是「有没有活着的播放器」，不是「悬浮条挂没挂着」**
  /// （[MusicService.hasLivePlayer]，**故意不用 `showMiniPlayer`**）。
  /// 暂停了悬浮条收回去，可她听的还是那首——模型这时候更应该知道，因为她
  /// 很可能就是停下来想聊两句。
  ///
  /// ⚠️ 后台 isolate 里 `MusicService.instance.now` 是 null（Provider 树是主
  /// isolate 的），于是这里直接返回。不是 bug，见 [MusicService] 的类注释。
  static void _attachNowPlaying(List<Map<String, dynamic>> apiMessages) {
    final svc = MusicService.instance;
    if (!svc.hasLivePlayer) return;
    final now = svc.now;
    final title = now?.track.title;
    if (now == null || title == null || title.isEmpty) return;

    final artist = now.track.artist;
    final total = now.track.duration;
    final at = now.livePosition;

    final block =
        '（这不是 TA 说的话，是 TA 那边此刻正在发生的事：'
        '正在听《$title》${(artist ?? '').isEmpty ? '' : '（$artist）'}，'
        '${now.state.label}'
        '${total == null ? '' : '，${_mmss(at)} / ${_mmss(total)}'}。）\n\n';

    final idx = apiMessages.lastIndexWhere((m) => m['role'] == 'user');
    if (idx < 0) return;
    final content = apiMessages[idx]['content'];
    if (content is String) {
      apiMessages[idx] = {...apiMessages[idx], 'content': '$block$content'};
    } else if (content is List) {
      apiMessages[idx] = {
        ...apiMessages[idx],
        'content': [
          {'type': 'text', 'text': block},
          ...content,
        ],
      };
    }
  }

  static String _mmss(Duration d) {
    final s = d.inSeconds.clamp(0, 24 * 3600);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  static void _attachMemory(
    List<Map<String, dynamic>> apiMessages,
    String? memoryContext,
  ) {
    if (memoryContext == null || memoryContext.trim().isEmpty) return;
    final idx = apiMessages.lastIndexWhere((m) => m['role'] == 'user');
    if (idx < 0) return;

    final block =
        '（以下是你这边的背景记录，供你参考。不是用户说的话，'
        '也不用主动提起。）\n$memoryContext\n\n---\n\n';

    final content = apiMessages[idx]['content'];
    if (content is String) {
      apiMessages[idx] = {...apiMessages[idx], 'content': '$block$content'};
    } else if (content is List) {
      // 带图片的消息，content 是分块数组，插一个文本块在最前面
      apiMessages[idx] = {
        ...apiMessages[idx],
        'content': [
          {'type': 'text', 'text': block},
          ...content,
        ],
      };
    }
  }

  Stream<AiStreamEvent> _openaiChat(
    List<ChatMessage> messages, {
    String? systemPrompt,
    String? memoryContext,
    String? historySummary,
  }) async* {
    final endpoint = config.endpoint ?? 'https://api.openai.com/v1';
    final model = config.model ?? 'gpt-4o';

    final apiMessages = <Map<String, dynamic>>[];

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      apiMessages.add({
        'role': 'system',
        'content': _buildSystemContent(systemPrompt, historySummary),
      });
    }

    for (final msg in messages) {
      switch (msg.role) {
        case MessageRole.user:
          final images = _sendableImages(msg);
          if (images.isNotEmpty) {
            apiMessages.add({
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': _withTimestamp(msg.content, msg.timestamp),
                },
                // 多张图就是多个 image_url 块，顺序按用户选的来。
                // 一条消息里给全，模型才看得到图与图之间的关系——
                // 拆成几条发就只剩几张互不相干的图。
                for (final image in images)
                  {
                    'type': 'image_url',
                    'image_url': {
                      'url': 'data:${mimeOfImage(image)};base64,$image',
                    },
                  },
              ],
            });
          } else {
            apiMessages.add({
              'role': 'user',
              'content': _withTimestamp(msg.content, msg.timestamp),
            });
          }
          break;
        case MessageRole.assistant:
          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            final contentText = msg.content;
            apiMessages.add({
              'role': 'assistant',
              'content':
                  contentText.isEmpty
                      ? null
                      : _withTimestamp(contentText, msg.timestamp),
              // 带思考的模型要求把思路原样带回来，尤其是这一条——有工具调用的
              // assistant。见 [ReasoningComplaint]。只有真收到过思路才发，
              // 不思考的模型这个字段根本不会出现。
              if (msg.thinking != null && msg.thinking!.isNotEmpty)
                'reasoning_content': msg.thinking,
              'tool_calls':
                  msg.toolCalls!
                      .map(
                        (t) => {
                          'id': t.id,
                          'type': 'function',
                          'function': {
                            'name': t.name,
                            'arguments': jsonEncode(t.arguments),
                          },
                        },
                      )
                      .toList(),
            });
          } else {
            // ⚠️ 纯文字的回复**不回传思考**。
            //
            // 2026-09-21 加回传是为了修「调过工具之后必然 400」，但当时给
            // 历史里每一条带思考的 assistant 都带上了。2026-09-22 Cleo 发现
            // 「它的心声被当成正文发出来」——它开始把内心独白写进回复里。
            //
            // 最可能的原因就在这儿：整段历史的内心独白一直摆在对话里，
            // 模型会把那种口吻读成「可以说出口的话」。顺带还每轮白付一次钱——
            // 思考通常比正文长得多。
            //
            // 服务端真正要求的只是**带工具调用的那条**（见上面那个分支）。
            // 万一某个端点仍然报「必须带」，[ReasoningComplaint] 那道补上重试
            // 的保险还在，不会退回 400。
            apiMessages.add({
              'role': 'assistant',
              'content': _withTimestamp(msg.content, msg.timestamp),
            });
          }
          break;
        case MessageRole.toolResult:
          apiMessages.add({
            'role': 'tool',
            'tool_call_id': msg.toolCallId ?? '',
            'content': msg.content,
          });
          break;
        case MessageRole.toolCall:
          // Skip - tool_calls already embedded in assistant messages
          break;
        case MessageRole.system:
          apiMessages.add({'role': 'system', 'content': msg.content});
          break;
      }
    }

    // 记忆挂在尾部，必须在 _repairToolMessages 之前——那一步会按 tool_call_id
    // 重排消息，之后再挂就可能挂错位置。
    // 顺序：先听歌，再记忆。两边都是往最后一条用户消息前面插，后插的在外层
    // ——`_attachMemory` 那个 `---` 得留在紧挨她原话的位置。详见它俩的注释。
    _attachNowPlaying(apiMessages);
    _attachMemory(apiMessages, memoryContext);

    // 兜底：确保每个 assistant 的 tool_calls 都有对应的 tool 响应。
    // 若历史里存在"孤儿" tool_calls（工具执行中断/异常留下的），
    // 直接补一条错误响应，否则 DeepSeek 报 invalid_request_error。
    final cleaned = _repairToolMessages(apiMessages);

    final body = <String, dynamic>{
      'model': model,
      'messages': cleaned,
      'stream': true,
      'max_tokens': _maxOutputTokens,
      // ⚠️ 这里**不发思考档位**，是查过之后决定的，别再加回来。
      //
      // 2026-09-22 Cleo 问「以前它按需思考，现在每次都想，这个不可控吗」。
      // 查下来：DeepSeek 的 OpenAI 格式接口只有 `thinking: {type: enabled|disabled}`
      // 两档，**没有 adaptive**（我一度照着一份不可靠的摘要加过 adaptive，
      // 发过去被静默忽略）。`reasoning_effort` 只调想多久，文档原话是
      // 「low 仍然是在想，不是开关」。
      //
      // 也就是说没有「按需思考」这回事，只能在「每次都想」和「完全不想」之间选。
      // 她选了前者：思考和答得准是一路的（见 app-persona-brevity-tradeoff 那次实测）。
      // 要关，就是 `'thinking': {'type': 'disabled'}`，别去折腾 reasoning_effort。
    };

    if (tools != null && tools!.isNotEmpty) {
      body['tools'] =
          tools!
              .map(
                (t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.inputSchema,
                  },
                },
              )
              .toList();
    }

    try {
      var attempt = 0;
      while (true) {
        attempt++;
        // 每次尝试配一个自己的 client，用完关掉。
        //
        // 原来是 `await http.Client().send(request)`：建完就撒手，没人 close。
        // 一个 Client 背后挂着连接池和已连的 socket，不关就一直占着——
        // 而这是**每发一条消息都要走一次**的路，聊得越久积得越多。
        // 见 [chat]：这是用户提「内存越来越大」时最值得先修的一处。
        final client = newHttpClient();
        try {
          final request = http.Request(
            'POST',
            Uri.parse('$endpoint/chat/completions'),
          );
          request.headers.addAll({
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${config.apiKey}',
          });
          request.body = jsonEncode(body);

          final response = await client.send(request).timeout(responseTimeout);

          if (response.statusCode == 200) {
            // ⚠️ 不能写 `yield*`。`yield*` 里冒出来的异常**不会在这一行抛出**，
            // 而是原样转给下游的监听者——外面那层 try/catch 根本碰不到它。
            // 读流超时就是这么漏出去的：调用方拿到一个裸 TimeoutException，
            // 而不是一条能显示的错误事件。`await for` 才会在这里抛。
            await for (final event in _streamOpenAiResponse(response)) {
              yield event;
            }
            return;
          }

          final error = await response.stream.bytesToString();
          final lowered = error.toLowerCase();
          final toolHistoryError =
              lowered.contains('invalid_request_error') &&
              (lowered.contains('tool_call') ||
                  lowered.contains('tool messages') ||
                  lowered.contains('insufficient'));
          if (toolHistoryError && attempt == 1) {
            // 工具历史异常（如孤儿 tool_calls）：去掉全部工具消息，纯文本重试一次。
            //
            // ⚠️ 这个兜底会让模型完全看不到工具结果——工具明明执行成功了，
            // 模型却回答「我这边是空的」。原来这里把服务端错误直接吞掉，
            // 于是两边都看不见问题。先打出来，好定位第一次请求为什么非法。
            debugPrint(
              '[ai_client] 工具历史被服务端拒绝，将丢弃全部工具消息重试。'
              '原始错误：$error',
            );
            // 手机上看不到日志，所以直接显示在对话里——否则这个降级完全无声，
            // 用户只会看到模型说「我没收到结果」，看不出是 App 丢掉的。
            // 定位完根因后应当移除。
            yield AiStreamEvent.token(
              '⚠️ 工具结果被服务端拒绝，已丢弃后重试。原始错误：\n'
              '${error.length > 500 ? '${error.substring(0, 500)}…' : error}\n\n',
            );
            // 用 cleaned 而不是 apiMessages：后者没经过 _repairToolMessages
            body['messages'] = _stripAllToolMessages(cleaned);
            continue;
          }
          // 服务端在为 reasoning_content 抱怨：对症补一次或摘一次，重试。
          //
          // 两个方向都只可能各来一次：补过之后每条 assistant 都有这个字段，
          // 摘过之后一条都没有——于是下一轮同样的抱怨不会再触发 continue，
          // 不会死循环。
          final complaint = reasoningComplaintOf(error);
          if (complaint != ReasoningComplaint.none) {
            final msgs = (body['messages'] as List).cast<Map<String, dynamic>>();
            final has = msgs.any((m) => m['reasoning_content'] != null);
            final missing = msgs.any(
              (m) => m['role'] == 'assistant' && m['reasoning_content'] == null,
            );
            if (complaint == ReasoningComplaint.mustPass && missing) {
              debugPrint('[ai_client] 服务端要 reasoning_content，补空的重试。原始错误：$error');
              body['messages'] = fillMissingReasoning(msgs);
              continue;
            }
            if (complaint == ReasoningComplaint.notAllowed && has) {
              debugPrint('[ai_client] 服务端不认 reasoning_content，去掉重试。原始错误：$error');
              body['messages'] = stripReasoning(msgs);
              continue;
            }
          }
          yield AiStreamEvent.error('API 错误 (${response.statusCode}): $error');
          return;
        } finally {
          // 放在 finally 里：正常出流、重试、抛异常、以及被调用方取消订阅
          // （用户切走页面）这四条路都会走到这儿。
          client.close();
        }
      }
    } on TimeoutException catch (e) {
      yield AiStreamEvent.error(_timeoutMessage(e));
    } catch (e) {
      yield AiStreamEvent.error('网络错误: $e');
    }
  }

  /// 处理 OpenAI 兼容的流式响应并产出事件。
  Stream<AiStreamEvent> _streamOpenAiResponse(
    http.StreamedResponse response,
  ) async* {
    String? contentBuffer;
    // 直接建成非空 list：原来是 `List<ToolCallInfo>? toolCalls` 加一路 `!`，
    // 空列表和 null 在这里本来就是同一个意思（末尾按 isNotEmpty 判断）。
    final toolCalls = <ToolCallInfo>[];
    // Accumulate raw argument JSON text per tool call index
    final Map<int, String> argBuffers = {};

    // 必须走 LineSplitter，不能对每个分片各自 split('\n')。
    //
    // response.stream 给的是任意大小的字节块，不保证按行对齐。一行 SSE 被切在
    // 两个分片里时，原来的写法两半都会丢：前半段 `data: {"delta":{"content":"想`
    // jsonDecode 失败被下面的 catch 吞掉，后半段 `到了"}}]}` 不以 data: 开头被
    // 跳过——于是这个 token 无声消失。表现是长回复里零星掉字（不是尾部截断），
    // 回复越长分片越多、掉得越厉害。
    //
    // LineSplitter 自己维护跨分片的缓冲，只吐完整的行，末尾没有换行符的最后
    // 一行也会补吐出来。
    await for (final line in response.stream
        .timeout(idleTimeout)
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6).trim();
      if (data == '[DONE]') break;

      try {
        final json = jsonDecode(data);

        // 缓存命中情况：流式响应的最后一片会带 usage（部分服务端要显式开启才给）。
        // 打出来才能验证「记忆挂尾部」到底有没有让前缀命中，否则全靠猜。
        final usage = json['usage'];
        if (usage is Map) {
          final hit = usage['prompt_cache_hit_tokens'];
          final miss = usage['prompt_cache_miss_tokens'];
          if (hit != null || miss != null) {
            debugPrint('[ai_client] prompt cache 命中 $hit / 未命中 $miss');
          } else {
            debugPrint('[ai_client] usage: $usage');
          }
        }

        final delta = json['choices']?[0]?['delta'];

        if (delta == null) continue;

        // 推理模型把思考放在 reasoning_content 里，跟 content 是两个字段。
        // 只读 content 的话，它想了半天你这边一个字都不出——看着像卡死。
        // 字段名各家不统一（reasoning_content / reasoning），两个都认。
        final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield AiStreamEvent.thinking(reasoning);
        }

        if (delta['content'] != null) {
          contentBuffer = (contentBuffer ?? '') + delta['content'];
          yield AiStreamEvent.token(delta['content']);
        }

        if (delta['tool_calls'] != null) {
          for (final tc in delta['tool_calls']) {
            final idx = tc['index'] ?? 0;

            while (toolCalls.length <= idx) {
              toolCalls.add(ToolCallInfo(id: '', name: '', arguments: {}));
            }

            if (tc['id'] != null) {
              toolCalls[idx] = ToolCallInfo(
                id: tc['id'],
                name: toolCalls[idx].name,
                arguments: toolCalls[idx].arguments,
              );
            }
            if (tc['function']?['name'] != null) {
              toolCalls[idx] = ToolCallInfo(
                id: toolCalls[idx].id,
                name: tc['function']['name'],
                arguments: toolCalls[idx].arguments,
              );
            }
            // 只累积，不在分片阶段解析——解析统一放到流结束后。
            //
            // 原来每来一个分片就试着 jsonDecode：只要某个中间状态恰好是合法
            // JSON（比如先到一个 `{}`），arguments 就被锁成空对象；之后拼上
            // 真内容，缓冲区变成 `{}{"query":"…"}` 永远解析失败，catch 静默吞掉，
            // 于是发出去的调用里 query 一直是空的。
            if (tc['function']?['arguments'] != null) {
              argBuffers[idx] =
                  (argBuffers[idx] ?? '') +
                  tc['function']['arguments'].toString();
            }
          }
        }
      } catch (e) {
        // 别再静默吞了——掉字的 bug 就是藏在这个 catch 后面躲了这么久。
        debugPrint('[ai_client] SSE 行解析失败（$e）：$data');
      }
    }

    if (toolCalls.isNotEmpty) {
      // 流结束了，参数分片已经完整，这时才解析
      for (var i = 0; i < toolCalls.length; i++) {
        final raw = argBuffers[i]?.trim();
        if (raw == null || raw.isEmpty) continue;
        try {
          final parsed = jsonDecode(raw);
          if (parsed is Map) {
            toolCalls[i] = ToolCallInfo(
              id: toolCalls[i].id,
              name: toolCalls[i].name,
              arguments: Map<String, dynamic>.from(parsed),
            );
          }
        } catch (e) {
          debugPrint('[ai_client] 工具参数解析失败，原始内容：$raw（$e）');
        }
      }
      yield AiStreamEvent.toolCalls(toolCalls);
    } else if (contentBuffer != null) {
      yield AiStreamEvent.done(_stripTimeMarkers(contentBuffer));
    }
  }

  /// 纯文本兜底：去掉所有 tool 消息与 assistant 的 tool_calls，只保留文字消息。
  static List<Map<String, dynamic>> _stripAllToolMessages(
    List<Map<String, dynamic>> apiMessages,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final msg in apiMessages) {
      final role = msg['role'];
      if (role == 'tool') continue;
      if (role == 'assistant') {
        final copy = Map<String, dynamic>.from(msg)..remove('tool_calls');
        final text = (copy['content'] as String?)?.trim() ?? '';
        if (text.isEmpty) continue;
        out.add(copy);
      } else {
        out.add(msg);
      }
    }
    return out;
  }

  Stream<AiStreamEvent> _anthropicChat(
    List<ChatMessage> messages, {
    String? systemPrompt,
    String? memoryContext,
    String? historySummary,
  }) async* {
    final endpoint = config.endpoint ?? 'https://api.anthropic.com/v1';
    final model = config.model ?? 'claude-sonnet-5';

    final apiMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      switch (msg.role) {
        case MessageRole.user:
          final images = _sendableImages(msg);
          if (images.isNotEmpty) {
            apiMessages.add({
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text': _withTimestamp(msg.content, msg.timestamp),
                },
                // Claude 的图片块和 OpenAI 长得像，装法不一样：没有 `image_url`，
                // 要的是 `source` 里三个字段。`media_type` 会被**校验**，对不上
                // 直接 400——所以上面那个 [mimeOfImage] 在这儿是必须的。
                for (final image in images)
                  {
                    'type': 'image',
                    'source': {
                      'type': 'base64',
                      'media_type': mimeOfImage(image),
                      'data': image,
                    },
                  },
              ],
            });
          } else {
            apiMessages.add({
              'role': 'user',
              'content': _withTimestamp(msg.content, msg.timestamp),
            });
          }
          break;
        case MessageRole.assistant:
          if (msg.toolCalls != null && msg.toolCalls!.isNotEmpty) {
            final content = <Map<String, dynamic>>[];
            if (msg.content.isNotEmpty) {
              content.add({
                'type': 'text',
                'text': _withTimestamp(msg.content, msg.timestamp),
              });
            }
            for (final tc in msg.toolCalls!) {
              content.add({
                'type': 'tool_use',
                'id': tc.id,
                'name': tc.name,
                'input': tc.arguments,
              });
            }
            apiMessages.add({'role': 'assistant', 'content': content});
          } else {
            apiMessages.add({
              'role': 'assistant',
              'content': _withTimestamp(msg.content, msg.timestamp),
            });
          }
          break;
        case MessageRole.toolResult:
          apiMessages.add({
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': msg.toolCallId,
                'content': msg.content,
              },
            ],
          });
          break;
        case MessageRole.toolCall:
          // Skip - tool_use already embedded in assistant messages
          break;
        case MessageRole.system:
          apiMessages.add({'role': 'user', 'content': msg.content});
          break;
      }
    }

    // 顺序：先听歌，再记忆。两边都是往最后一条用户消息前面插，后插的在外层
    // ——`_attachMemory` 那个 `---` 得留在紧挨她原话的位置。详见它俩的注释。
    _attachNowPlaying(apiMessages);
    _attachMemory(apiMessages, memoryContext);

    final body = <String, dynamic>{
      'model': model,
      'max_tokens': _maxOutputTokens,
      'messages': apiMessages,
      'stream': true,
    };

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      body['system'] = _buildSystemContent(systemPrompt, historySummary);
    }

    if (tools != null && tools!.isNotEmpty) {
      body['tools'] =
          tools!
              .map(
                (t) => {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.inputSchema,
                },
              )
              .toList();
    }

    // 同 _openaiChat 里那处修复：Client 建了就得关，否则连接的 socket
    // 和连接池一直留着。这条是 Claude 分支，每次发消息都会走。
    final client = newHttpClient();
    try {
      final request = http.Request('POST', Uri.parse('$endpoint/messages'));
      request.headers.addAll({
        'Content-Type': 'application/json',
        'x-api-key': config.apiKey ?? '',
        'anthropic-version': '2023-06-01',
      });
      request.body = jsonEncode(body);

      final response = await client.send(request).timeout(responseTimeout);

      if (response.statusCode != 200) {
        final error = await response.stream.bytesToString();
        yield AiStreamEvent.error(
          'Claude API 错误 (${response.statusCode}): $error',
        );
        return;
      }

      String contentBuffer = '';
      final toolCalls = <ToolCallInfo>[];

      // 同 _streamOpenAiResponse：按分片切行会丢掉跨分片的那一行。
      await for (final line in response.stream
          .timeout(idleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6);
        if (data == '[DONE]') break;

        try {
          final json = jsonDecode(data);
          final type = json['type'];

          if (type == 'content_block_delta') {
            final delta = json['delta'];
            if (delta?['type'] == 'text_delta') {
              contentBuffer += delta['text'];
              yield AiStreamEvent.token(delta['text']);
            } else if (delta?['type'] == 'thinking_delta') {
              // Anthropic 那边叫 thinking_delta，走同一个出口。
              final t = delta['thinking'];
              if (t is String && t.isNotEmpty) yield AiStreamEvent.thinking(t);
            }
          } else if (type == 'content_block_start') {
            final block = json['content_block'];
            if (block?['type'] == 'tool_use') {
              toolCalls.add(
                ToolCallInfo(
                  id: block['id'],
                  name: block['name'],
                  arguments: Map<String, dynamic>.from(block['input'] ?? {}),
                ),
              );
            }
          } else if (type == 'message_delta') {}
        } catch (e) {
          debugPrint('[ai_client] SSE 行解析失败（$e）：$data');
        }
      }

      if (toolCalls.isNotEmpty) {
        yield AiStreamEvent.toolCalls(toolCalls);
      } else {
        yield AiStreamEvent.done(_stripTimeMarkers(contentBuffer));
      }
    } on TimeoutException catch (e) {
      yield AiStreamEvent.error(_timeoutMessage(e));
    } catch (e) {
      yield AiStreamEvent.error('网络错误: $e');
    } finally {
      // 正常出流、报错、以及被调用方取消订阅，三条路都走到这儿。
      client.close();
    }
  }

  /// 修复消息历史：确保 assistant 的每个 tool_call_id 都有对应 tool 响应。
  /// 若缺失（工具中断/异常留下孤儿 tool_calls），补一条错误响应，
  /// 防止 DeepSeek/OpenAI 报 "insufficient tool messages"。
  static List<Map<String, dynamic>> _repairToolMessages(
    List<Map<String, dynamic>> apiMessages,
  ) {
    // 第一遍：收集所有被 assistant 引用过的 tool_call_id，以及已响应的 id
    final allCallIds = <String>{};
    final respondedIds = <String>{};
    for (final msg in apiMessages) {
      if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
        for (final tc in msg['tool_calls'] as List) {
          final id = (tc as Map)['id'] as String?;
          if (id != null && id.isNotEmpty) allCallIds.add(id);
        }
      } else if (msg['role'] == 'tool') {
        final id = msg['tool_call_id'] as String?;
        if (id != null && id.isNotEmpty) respondedIds.add(id);
      }
    }

    final completeIds = allCallIds.intersection(respondedIds);
    final orphanIds = allCallIds.difference(respondedIds);

    // 第二遍：剔除孤儿 tool_calls 及其对应的 tool 消息，
    // 保证发出的每个 assistant(tool_calls) 都有完整响应（顺序保留）。
    final cleaned = <Map<String, dynamic>>[];
    for (final msg in apiMessages) {
      if (msg['role'] == 'tool') {
        final id = msg['tool_call_id'] as String?;
        if (id != null && orphanIds.contains(id)) continue;
        cleaned.add(msg);
        continue;
      }
      if (msg['role'] == 'assistant' && msg['tool_calls'] != null) {
        final calls =
            (msg['tool_calls'] as List).where((tc) {
              final id = (tc as Map)['id'] as String?;
              return id != null && completeIds.contains(id);
            }).toList();
        if (calls.isEmpty) {
          final text = (msg['content'] as String?)?.trim() ?? '';
          if (text.isEmpty) continue; // 纯工具消息且无响应 → 整条丢弃
          final copy = Map<String, dynamic>.from(msg)..remove('tool_calls');
          cleaned.add(copy);
        } else {
          final copy = Map<String, dynamic>.from(msg)..['tool_calls'] = calls;
          cleaned.add(copy);
        }
        continue;
      }
      cleaned.add(msg);
    }
    return _reorderToolMessages(cleaned);
  }

  /// 把每组 tool 响应挪回它对应的 assistant(tool_calls) 紧后面。
  ///
  /// 服务端要求的不只是「存在响应」，而是响应必须**紧邻**排在 tool_calls 之后
  /// （报错原文：insufficient tool messages following tool_calls message）。
  /// 而模型经常在发起调用和拿到结果之间说话，那条文本消息会把两者隔开，
  /// 于是整条历史被判非法。这里按 tool_call_id 归位，不改变其余消息的相对顺序。
  static List<Map<String, dynamic>> _reorderToolMessages(
    List<Map<String, dynamic>> msgs,
  ) {
    // 先把所有 tool 消息按 id 索引出来
    final toolById = <String, Map<String, dynamic>>{};
    for (final m in msgs) {
      if (m['role'] == 'tool') {
        final id = m['tool_call_id'] as String?;
        if (id != null && id.isNotEmpty) toolById[id] = m;
      }
    }
    if (toolById.isEmpty) return msgs;

    final placed = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final m in msgs) {
      if (m['role'] == 'tool') {
        final id = m['tool_call_id'] as String?;
        // 已经跟着 assistant 放过了，这里跳过，避免重复
        if (id != null && placed.contains(id)) continue;
        out.add(m);
        continue;
      }
      out.add(m);
      if (m['role'] == 'assistant' && m['tool_calls'] != null) {
        for (final tc in m['tool_calls'] as List) {
          final id = (tc as Map)['id'] as String?;
          if (id == null) continue;
          final toolMsg = toolById[id];
          if (toolMsg != null && placed.add(id)) out.add(toolMsg);
        }
      }
    }
    return out;
  }
}

class AiStreamEvent {
  final AiEventType type;
  final String? text;
  final List<ToolCallInfo>? toolCalls;
  final String? error;

  const AiStreamEvent._({
    required this.type,
    this.text,
    this.toolCalls,
    this.error,
  });

  factory AiStreamEvent.token(String text) =>
      AiStreamEvent._(type: AiEventType.token, text: text);

  /// 模型的思考过程，和正文分开走。
  ///
  /// 单独一个事件类型、而不是混进 [token]，是因为这两段的去处不一样：正文要
  /// 进气泡、要存进历史、要发回给服务端当上文；思考只给人看一眼，不参与后续
  /// 请求。混在一起的话，下一轮就会把它当成自己说过的话喂回去。
  factory AiStreamEvent.thinking(String text) =>
      AiStreamEvent._(type: AiEventType.thinking, text: text);

  factory AiStreamEvent.toolCalls(List<ToolCallInfo> calls) =>
      AiStreamEvent._(type: AiEventType.toolCalls, toolCalls: calls);

  factory AiStreamEvent.done(String text) =>
      AiStreamEvent._(type: AiEventType.done, text: text);

  factory AiStreamEvent.error(String error) =>
      AiStreamEvent._(type: AiEventType.error, error: error);
}

enum AiEventType { token, thinking, toolCalls, done, error }
