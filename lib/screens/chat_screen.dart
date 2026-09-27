import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/conversation_summary.dart';
import '../widgets/app_surface.dart';
import '../widgets/typing_indicator.dart';
import 'persona_screen.dart';
import '../config/app_tab.dart';
import '../services/ai_client.dart';
import '../services/app_providers.dart';
import '../config/persona.dart';
import '../services/chat_events.dart';
import '../services/avatar_store.dart';
import '../services/chat_images.dart';
import '../services/capsule_texts.dart';
import '../services/reply_notifier.dart';
import '../services/phone_tools/avatar_tool.dart';
import '../widgets/avatar_sheet.dart';
import '../services/mcp_server.dart';
import '../services/phone_tools/self_note_tool.dart';
import '../services/self_notes.dart';
import '../services/small_things.dart';
import '../services/tool_run_repair.dart';
import '../services/home_list.dart';
import '../services/stickers.dart';
import '../services/tool_tiers.dart';
import '../services/storage_service.dart';
import '../services/vision_service.dart';
import '../config/settings.dart';
import '../services/tts_service.dart';
import '../services/memory_context.dart';
import '../models/musing_entry.dart';
import '../services/musing_generator.dart';
import '../services/history_compactor.dart';
import '../search/history_search_delegate.dart';
import '../search/search_result_model.dart';
import '../widgets/chat_message_item.dart';
import '../widgets/background_sheet.dart';
import '../widgets/mark_backdrop.dart';
import '../services/music_service.dart';
import 'settings_screen.dart';
import 'musing_corner_screen.dart';
import 'pc_chat_screen.dart';
import 'xiaoke_chat_screen.dart';
import '../config/app_shape.dart';

class ChatScreen extends StatefulWidget {
  /// 底部导航切换回调，用于从聊天页跳转到书架 / 工具 / 设置。
  final void Function(AppTab tab)? onSwitchTab;

  /// 聊天背景变化回调，用于通知 HomeShell 刷新全局背景。
  final VoidCallback? onBackgroundChanged;

  /// 对话模式变化回调：true=进入对话（隐藏 Tab 栏），false=回到主页。
  final ValueChanged<bool>? onChatModeChanged;

  const ChatScreen({
    super.key,
    this.onSwitchTab,
    this.onBackgroundChanged,
    this.onChatModeChanged,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  /// 输入区实际有多高，用来给消息列表垫底部内边距。
  ///
  /// ## 为什么要量，不能写死
  ///
  /// 输入框会随文字长到 5 行，上面还可能挂一条待发图片。写死一个数，
  /// 图片一多就把最后一条消息压住了——而**输入框浮起来之后，被压住的
  /// 恰好是你正在等的那一条**。
  ///
  /// 76 是空框时的高度，只做首帧的兜底，量到真值就换掉。
  final GlobalKey _inputKey = GlobalKey();
  double _inputHeight = 76;

  void _measureInput() {
    final box = _inputKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final h = box.size.height;
    if ((h - _inputHeight).abs() < 0.5 || !mounted) return;
    setState(() => _inputHeight = h);
  }

  final _focusNode = FocusNode();
  final _uuid = const Uuid();
  final _picker = ImagePicker();

  /// 一条消息最多几张图。
  ///
  /// 不是产品洁癖，是报文大小：每张按 1920px 压完再 base64，一张就一两百 KB，
  /// 而且历史里每一条都要重发。六张已经是单条消息一兆上下了。
  static const _kMaxImagesPerMessage = 6;

  /// 选好但**还没发出去**的图。这是这次改动的全部要点——
  /// 以前没有这个中间状态，选完就飞出去了。
  final _pendingImages = <XFile>[];
  bool _isLoading = false;
  bool _chatMode = false;

  /// 已存的对话，**只留纯文本索引**。
  ///
  /// ⚠️ 这里以前是 `List<Conversation>`——每一场对话连同全部 base64 图片。
  /// 而这个 State 活在 `home_shell` 的 IndexedStack 里永不销毁，于是那份全量
  /// 加载一旦读进来就跟着 App 活到进程结束。真机上量过：4 场对话 2516 条消息，
  /// 正文 953K 字符、图片 base64 187,212K 字符——**图片是正文的两百倍**，
  /// 它们就是这个页面常驻内存的全部来源。
  ///
  /// 现在只留索引（同一份数据约 1 MB），点开哪一场才读哪一场。
  /// 见 [StorageService.listConversationSummaries]。
  List<ConversationSummary> _savedConversations = [];
  String? _musingContent;
  bool _musingFavorited = false;
  bool _musingLoading = false;
  String _userName = '';
  String _aiName = '';

  /// 抽屉右侧那几个数字。开抽屉时刷新一次，不常驻订阅。
  int _favoriteCount = 0;
  int _trashCount = 0;

  /// 主页「最近对话」展开着没有。默认收起，见 [homeConversations]。
  bool _homeExpanded = false;

  late Conversation _conversation;

  /// 存一份引用，dispose 时要用它摘监听——那时候 context 已经不能读 Provider 了。
  AiClientProvider? _aiClients;

  @override
  void initState() {
    super.initState();
    _conversation = Conversation(id: _uuid.v4());
    _aiClients =
        context.read<AiClientProvider>()..addListener(_onAiClientChanged);
    _loadConversations();
    _loadMusing();
    _loadUserName();
    _loadHomeExpanded();
    // 时间线上那几条灰字（写了信、记了日记）。附加信息，读失败也不影响聊天。
    _loadChatEvents();
  }

  Future<void> _loadUserName() async {
    final settings = await AppSettings.load();
    if (!mounted) return;
    setState(() {
      _userName = settings.userName;
      _aiName = settings.aiName;
    });
  }

  /// 上次她把「最近对话」留在展开还是收起。记住的理由见
  /// [StorageService.setHomeConversationsExpanded]。
  Future<void> _loadHomeExpanded() async {
    final expanded = await StorageService.getHomeConversationsExpanded();
    if (!mounted || expanded == _homeExpanded) return;
    setState(() => _homeExpanded = expanded);
  }

  Future<void> _loadDrawerCounts() async {
    final favorites = await StorageService.listFavoritedMusings();
    final trashed = await StorageService.listTrashedConversations();
    if (!mounted) return;
    setState(() {
      _favoriteCount = favorites.length;
      _trashCount = trashed.length;
    });
  }

  /// 抽屉顶部那句「和 XX 一起，N 条消息」。
  ///
  /// 数的是 `messages.length`，即**条数**——用户和它的话都算。原来这里叫
  /// 「N 轮对话」，但一轮是一来一回，条数差着一倍；而首页的对话卡片一直
  /// 写的是「N 条消息」，同一个数在两处叫两个名字。统一成条。
  int get _totalMessages =>
      _savedConversations.fold(0, (sum, c) => sum + c.messageCount);

  @override
  void dispose() {
    _aiClients?.removeListener(_onAiClientChanged);
    _textController.dispose();
    _scrollController.dispose();
    // 之前漏了这一个。是卫生问题而不是内存泄漏（State 一没，
    // FocusNode 也就没人引用了），但既然是要「用」的对象就该还回去。
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    final convs = await StorageService.listConversationSummaries();
    if (mounted) setState(() => _savedConversations = convs);
  }

  Future<void> _loadMusing() async {
    final cached = await StorageService.getTodayMusing();
    if (cached != null) {
      if (mounted) {
        setState(() {
          _musingContent = cached['content'] as String?;
          _musingFavorited = cached['favorited'] as bool? ?? false;
        });
      }
      return;
    }
    await _refreshMusing();
  }

  /// 在别处发生、要插进这条时间线的事（它写了信、记了日记）。
  ///
  /// 只取**这段对话开始之后**的：更早的事对这段对话没有意义，
  /// 全塞进来会在开头堆一片跟当下无关的灰条。
  List<ChatEvent> _chatEvents = const [];

  Future<void> _loadChatEvents() async {
    if (_conversation.messages.isEmpty) return;
    final since = _conversation.messages.first.timestamp;
    final events = await ChatEvents.since(since, aiName: _aiName);
    if (mounted) setState(() => _chatEvents = events);
  }

  /// 今天的「我想说」还欠着，等 AI 客户端就绪补生成。
  ///
  /// [_loadMusing] 在 initState 里调，而 `AiClientProvider.load()` 是异步的
  /// ——那一刻 `currentClient` 基本都是 null。原来这里直接 return，于是跨天
  /// 之后首页永远停在昨天那句，只能手动点刷新（用户反馈「大部分情况都得
  /// 自己刷」就是这个）。现在标记待办，由 [_onAiClientChanged] 补跑。
  bool _musingPending = false;

  void _onAiClientChanged() {
    if (!_musingPending) return;
    if (_aiClients?.currentClient == null) return;
    _musingPending = false;
    _refreshMusing();
  }

  Future<void> _refreshMusing() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) {
      _musingPending = true;
      return;
    }
    if (mounted) setState(() => _musingLoading = true);
    try {
      final content = await generateDailyMusing(aiClient: aiClient);
      if (content != null) {
        await StorageService.setTodayMusing(content);
        if (mounted) {
          setState(() {
            _musingContent = content;
            _musingFavorited = false;
          });
        }
      }
    } catch (_) {
      // 生成失败就静默保留原内容，不打扰用户
    } finally {
      if (mounted) setState(() => _musingLoading = false);
    }
  }

  Future<void> _toggleFavoriteMusing() async {
    if (_musingContent == null) return;
    final newState = !_musingFavorited;
    setState(() => _musingFavorited = newState);
    await StorageService.setTodayMusingFavorited(newState);
    if (newState) {
      await StorageService.addFavoritedMusing(
        MusingEntry(
          id: _uuid.v4(),
          date: DateTime.now(),
          content: _musingContent!,
        ),
      );
    } else {
      // 取消收藏：从收藏列表里把今天这条同内容的条目摘掉
      final favorites = await StorageService.listFavoritedMusingsForToday();
      final match =
          favorites.where((m) => m.content == _musingContent).firstOrNull;
      if (match != null) {
        await StorageService.removeFavoritedMusing(match.id);
      }
    }
  }

  /// 还在生成回复的那几段，按 id。见 [_continueChat]。
  ///
  /// 她发完消息回了首页，那一轮还在跑、还在往**那个对象**里写。这时候她再点
  /// 进同一段，从盘上读出来的是一个新对象——不接回去的话，她看到的是没写完
  /// 的旧样子，跑完的那一轮也不会出现在屏幕上。
  final Map<String, Conversation> _running = {};

  void _switchConversation(Conversation conv) {
    _saveIfChanged();
    final live = _running[conv.id];
    if (live != null) conv = live;
    // 刚从盘上读出来（或刚存过）的，就是存盘时的样子。
    _savedSig = _sigOf(conv);
    AvatarStore.instance.load(conv.id);
    setState(() {
      _conversation = conv;
      _isLoading = live != null;
      _textController.clear();
      _chatMode = true;
      // 换了对话，上一段的事件行不能留着——它们的时间落在这一段之外。
      _chatEvents = const [];
    });
    _loadChatEvents();
    widget.onChatModeChanged?.call(true);
    _scrollToBottom();
  }

  void _newConversation() {
    _saveIfChanged();
    setState(() {
      _conversation = Conversation(id: _uuid.v4());
      _isLoading = false;
      _textController.clear();
      _chatMode = true;
    });
    widget.onChatModeChanged?.call(true);
    _loadConversations();
  }

  /// 返回主页：保存当前对话，回到主页模式。
  void _goHome() {
    _saveIfChanged();
    setState(() {
      _conversation = Conversation(id: _uuid.v4());
      _isLoading = false;
      _chatMode = false;
      _textController.clear();
    });
    widget.onChatModeChanged?.call(false);
    _loadConversations();
  }

  void _enterChatMode() {
    if (_chatMode) return;
    setState(() => _chatMode = true);
    widget.onChatModeChanged?.call(true);
  }

  /// 列表是倒着排的（见 build 里的 `reverse: true`），「最底下」就是偏移 0。
  ///
  /// 原来跳的是 `maxScrollExtent`：那个数要等布局把整张列表的高度估出来才准，
  /// 所以跳一次、100ms 后还得补跳一次；流式时每来一个字就排两次。偏移 0 不用估。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _scrollController.offset != 0) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _openSearch() async {
    final result = await showSearch<HistorySearchSelection?>(
      context: context,
      delegate: HistorySearchDelegate(_savedConversations),
    );
    if (result != null && mounted) {
      await _switchToSearchResult(result);
    }
  }

  Future<void> _switchToSearchResult(HistorySearchSelection selection) async {
    await _openConversation(
      selection.conversation.id,
      scrollToMessage: selection.scrollToMessageIndex,
    );
  }

  /// 拿到某场对话的**完整**对象。
  ///
  /// ⚠️ 正开在手上的那一场必须用内存里这份，**不能回盘上读**：盘上那份是上次
  /// 存盘时的快照，还没存下去的几条新消息回读一次就没了，而且接手的正是这份
  /// 旧状态——下一轮存盘就把新消息覆盖掉，等于丢消息。
  ///
  /// 这个坑是改索引带出来的。以前 `_switchConversation` 直接接手列表里那个
  /// `Conversation`，而它和 `_conversation` 往往**就是同一个对象**（连
  /// `messages` 都是同一条 List），所以点当前这场等于什么都没做。现在列表上
  /// 只有索引，多了一次「按 id 去取」的机会，也就多了这一次丢消息的机会。
  Future<Conversation?> _fullConversation(String id) async {
    if (id == _conversation.id) return _conversation;
    // 还在生成回复的那段：盘上那份是没写完的样子，拿活的。
    final live = _running[id];
    if (live != null) return live;
    // 盘上那份可能停在「一轮被打断」的样子：有调用没结果，那张工具卡会永远转圈。
    // 收尾时已经补过一次（[_finishTurn]），但那一轮要是连收尾都没跑到——进程被系统
    // 杀掉——就只剩这里能补。补完不立刻存盘：下一轮收尾自然会存，读一次多写一次盘
    // 不划算，而且这个修补是幂等的，再打开一次照样补得上。
    final stored = await StorageService.loadConversation(id);
    if (stored != null && hasOrphanToolCalls(stored.messages)) {
      final fixed = repairOrphanToolCalls(
        stored.messages,
        newId: () => _uuid.v4(),
      );
      stored.messages
        ..clear()
        ..addAll(fixed);
    }
    return stored;
  }

  /// 从列表/搜索结果打开一场对话。
  ///
  /// 列表上手里只有[索引][ConversationSummary]——正文（和图片）还在文件里，
  /// 到这一步才读出来，而且只管这一场。
  ///
  /// 读不出来（文件坏了、或刚好在别处被删了）就什么都不做：下一次
  /// `_loadConversations()` 会把它从列表里去掉。用户看到的是「它不在了」，
  /// 而不是点进去一个空白页。
  Future<void> _openConversation(String id, {int? scrollToMessage}) async {
    final conv = await _fullConversation(id);
    if (conv == null || !mounted) return;
    _switchConversation(conv);
    if (scrollToMessage != null) _scrollToMessage(scrollToMessage);
  }

  void _scrollToMessage(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      // Estimate: each message roughly 100px, tool cards ~80px
      // 列表倒着排，偏移从最底下往上量——数的是这条**之后**的消息。
      double offset = 0;
      for (int i = index + 1; i < _conversation.messages.length; i++) {
        final msg = _conversation.messages[i];
        if (msg.role == MessageRole.toolCall && msg.toolCalls != null) {
          offset += 80;
        } else {
          offset += 100;
        }
      }
      final maxScroll = _scrollController.position.maxScrollExtent;
      _scrollController.animateTo(
        offset.clamp(0.0, maxScroll),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// 选图**只放进待发区，不发出去**。
  ///
  /// 原来这个函数叫 `_pickAndSendImage`：选完立刻调识图、拼消息、`_continueChat()`，
  /// 中间没有任何一处可以反悔或者补一句话。从相册点一张图，它就已经飞出去了
  /// ——这不是发消息该有的节奏，而且它绕开了 `_sendMessage`，
  /// 于是「空文本不发送」那条判断从来没在这条路上生效过。
  ///
  /// 拍照仍然是单张（相机一次就拍一张），相册用 `pickMultiImage`。
  Future<void> _pickImages(ImageSource source) async {
    final picked = <XFile>[];
    if (source == ImageSource.camera) {
      // 这里只限尺寸，**不压画质**：发送前统一转 WebP（见
      // [ChatImages.toWebp]）。这里再压一道 JPEG，就是有损压两遍。
      final shot = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (shot != null) picked.add(shot);
    } else {
      picked.addAll(
        await _picker.pickMultiImage(maxWidth: 1920, maxHeight: 1920),
      );
    }
    if (picked.isEmpty || !mounted) return;

    final room = _kMaxImagesPerMessage - _pendingImages.length;
    _enterChatMode();
    setState(() => _pendingImages.addAll(picked.take(room)));

    // 超出的**明说**，别默默吞掉——用户选了八张只看到六张，
    // 不告诉他就成了「这 App 有时候会丢图」。
    if (picked.length > room) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '一条消息最多 $_kMaxImagesPerMessage 张，多出的 ${picked.length - room} 张没有加进来',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        ctx,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.smiley,
                        '表情',
                        () => Navigator.of(ctx).pop(),
                        action: _showStickerSheet,
                      ),
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.camera,
                        '拍照',
                        () => Navigator.of(ctx).pop(),
                        action: () => _pickImages(ImageSource.camera),
                      ),
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.images,
                        '相册',
                        () => Navigator.of(ctx).pop(),
                        action: () => _pickImages(ImageSource.gallery),
                      ),
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.fileText,
                        '文件',
                        () => Navigator.of(ctx).pop(),
                        action: _pickAndSendFile,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Widget _attachmentItem(
    BuildContext ctx,
    IconData icon,
    String label,
    VoidCallback onClose, {
    required VoidCallback action,
  }) {
    final scheme = Theme.of(ctx).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () {
          onClose();
          action();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                child: Icon(icon, size: 24, color: scheme.onSurface),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndSendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      _enterChatMode();
      final file = result.files.single;
      final name = file.name;
      var content = '';
      final path = file.path;
      if (path != null) {
        final f = File(path);
        if (await f.exists() && await f.length() < 200 * 1024) {
          try {
            final bytes = await f.readAsBytes();
            content = utf8.decode(bytes, allowMalformed: true);
          } catch (_) {}
        }
      }
      final trimmed = content.trim();
      final msgText =
          trimmed.isNotEmpty
              ? '📎 文件：$name\n\n${trimmed.length > 2000 ? trimmed.substring(0, 2000) : trimmed}'
              : '📎 文件：$name（${file.size} 字节，非文本内容，已附带文件名）';

      final userMsg = ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.user,
        content: msgText,
      );
      setState(() {
        _conversation.messages.add(userMsg);
        _isLoading = true;
      });
      _scrollToBottom();
      _continueChat();
    } catch (_) {}
  }

  /// 「正在输入」只在**还没吐出第一个字**时显示。
  ///
  /// 流式消息的 id 以 `stream_` 开头（见 [_updateAssistantMessage]）。一旦它
  /// 有了内容，回复本身就在屏幕上了，再挂一个「正在输入」是同一件事说两遍，
  /// 而且它就悬在正在生长的那段字下面，很吵。
  ///
  /// 工具轮次里最后一条是 toolResult，这时仍然显示——那会儿它确实还没开口。
  bool get _showTyping {
    if (!_isLoading) return false;
    final messages = _conversation.messages;
    if (messages.isEmpty) return true;
    final last = messages.last;
    return !(last.role == MessageRole.assistant &&
        last.id.startsWith('stream_') &&
        last.content.isNotEmpty);
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    // **只有图、一个字都没打，也是一条完整的消息**——用户就是想给它看一眼。
    // 原来这里是 `text.isEmpty` 直接 return，而选图那条路自己绕开了
    // _sendMessage，所以这条判断在图片上从来没生效过。
    if ((text.isEmpty && _pendingImages.isEmpty) || _isLoading) return;

    // context 要在 await 之前用掉，别跨异步边界再摸它。
    final client = context.read<AiClientProvider>().currentClient;

    HapticFeedback.lightImpact();
    _enterChatMode();
    _textController.clear();

    final picked = List<XFile>.from(_pendingImages);
    setState(() => _pendingImages.clear());

    // 图存成文件，消息里只记引用。原来是整张 base64 塞进消息，
    // 对话文件就是这么涨到 200MB 的，见 [ChatImages]。
    final pickedBytes = [
      for (final file in picked)
        await ChatImages.toWebp(await file.readAsBytes()),
    ];
    final images = [
      for (final bytes in pickedBytes) await ChatImages.save(bytes),
    ];

    // 识图服务是**兜底**，不是主路。
    //
    // 模型自己能看图的时候（sendsImagesNatively），原图会随报文一起发过去，
    // 再调一次外部识图就是同一张图分析两遍、付两份钱，而且模型会同时收到
    // 图和一段别人写的描述——描述和它自己看到的不一致时，它信哪个都不对。
    //
    // 只有模型看不到图时才退回来换一段文字。没配 key 的话 analyze 直接返回
    // null，这里也就是几次空转。
    var content = text;
    if (images.isNotEmpty && client != null && !client.sendsImagesNatively) {
      final described = <String>[];
      for (final bytes in pickedBytes) {
        final result = await VisionService.analyze(
          base64Encode(bytes),
          prompt: text.isNotEmpty ? text : null,
        );
        if (result != null) described.add(result);
      }
      if (described.isNotEmpty) {
        content =
            '${text.isNotEmpty ? '$text\n\n' : ''}'
            '[图片分析: ${described.join('；')}]';
      }
    }

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: content,
      images: images,
    );

    if (!mounted) return;
    setState(() {
      _conversation.messages.add(userMsg);
      _isLoading = true;
    });
    _scrollToBottom();
    _continueChat();
  }

  /// 跑一轮对话。**不管里面出了什么事，都要把「生成中」放下来。**
  ///
  /// 原来没有这一层：身份、记忆、历史压缩这几步都在 [_runChatTurn] 的
  /// try 外面，任何一处抛异常，[_isLoading] 就永远是 true——一直在加载，
  /// 没有网络连接，也没有报错。2026-09-14 晚上读书讨论先这样卡过，
  /// 接着主 App 也卡了。读书那边的同一层兜底见 `BookChatStreaming.continueTurn`。
  Future<void> _continueChat() async {
    // ⚠️ 这一轮从头到尾只认**开始时的那段对话**，不认 `_conversation`。
    //
    // 她发完消息回首页，`_goHome` 会把 `_conversation` 换成一段空的。原来这一轮
    // 接着往 `_conversation` 里写，于是回复写进了空对话，真正那段存下来是半截
    // 的——Cleo 2026-09-15：「他正在回复的时候，我返回，回复就被打断了」。
    final conv = _conversation;
    _running[conv.id] = conv;
    try {
      // 写回复的这一路亮着流体云胶囊：她中途返回、去刷别的，抬头就知道它还在写。
      // 写完由 [_finishTurn] 弹通知叫她回来看，两件事接在一起。
      await Capsule.whileReplying(() => _runChatTurn(conv));
    } catch (e) {
      debugPrint('[chat] 这一轮出错：$e');
      _updateAssistantMessage(conv, '❌ 发送消息失败: $e');
      _finalizeStreamMessage(conv);
    } finally {
      _running.remove(conv.id);
    }
    _finishTurn(conv);
  }

  /// 一轮收尾：存盘；她不在这段上就弹通知，叫她回来看。
  void _finishTurn(Conversation conv) {
    final here = mounted && identical(conv, _conversation);
    if (here) {
      setState(() => _isLoading = false);
      _scrollToBottom();
    }
    // 这一轮要是在半路断了（系统把 App 冻住、抛异常），会留下「有调用没结果」的
    // 工具，那张卡就永远转圈——Cleo 2026-09-16 让它看屏幕时撞到的。理由见
    // [repairOrphanToolCalls]：看屏幕恰恰要求她切出去，而那正是被冻的时刻。
    if (hasOrphanToolCalls(conv.messages)) {
      final fixed = repairOrphanToolCalls(
        conv.messages,
        newId: () => _uuid.v4(),
      );
      _touch(conv, () {
        conv.messages
          ..clear()
          ..addAll(fixed);
      });
    }
    _saveConversation(conv);

    final last = conv.messages.lastOrNull;
    if (last == null ||
        last.role != MessageRole.assistant ||
        last.content.trim().isEmpty) {
      return;
    }
    if (ReplyNotifier.shouldNotify(
      onThatConversation: here,
      lifecycle: WidgetsBinding.instance.lifecycleState,
    )) {
      ReplyNotifier.show(conversationId: conv.id, text: last.content);
    }
  }

  /// 改这一轮的对话。她还在这段上就连界面一起刷；不在了（回了首页、换了一段）
  /// 就只改数据——那个对象还在 [_running] 里，跑完会存盘。
  void _touch(Conversation conv, VoidCallback change) {
    if (mounted && identical(conv, _conversation)) {
      setState(change);
    } else {
      change();
    }
  }

  Future<void> _runChatTurn(Conversation conv) async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    final mcpServer = context.read<McpServerProvider>().server;

    if (aiClient == null) {
      _touch(conv, () {
        conv.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: '⚠️ 请先在设置中配置 API Key',
          ),
        );
      });
      return;
    }

    // 便签工具要知道自己身处哪段对话，才能把「做好了吗」推回原地。
    // 工具执行器的签名只有 args，拿不到调用现场，所以在这儿放一次。
    SelfNoteTool.currentConversationId = conv.id;
    AvatarTool.currentConversationId = conv.id;
    AvatarTool.latestUserImages = () => _latestUserImagesIn(conv);

    // Build client with tools once, reuse for all rounds
    // Always include local phone tools (regardless of MCP Server toggle)
    final mcpTools = mcpServer.registeredTools.map((r) => r.tool).toList();
    final externalTools = context.read<ExternalMcpProvider>().allExternalTools;
    final allTools = [...mcpTools, ...externalTools];

    // 分两层：常驻的几个直接声明，其余的收进索引，用 find_tools 现取。
    // 实际的 tools 数组在下面的工具循环里逐轮算，理由见那儿。
    ToolTiers.begin(conv.id, allTools);

    // 身份（名字 + 性格）抽到了 config/persona.dart：主动说话那条路要用
    // **同一份**，否则它开口时不是它。三层优先级和取名字的理由都写在那儿。
    //
    // 传 fallback 是因为 AppSettings.load() 里那句读 keystore 没有 try/catch，
    // 出问题会整个抛。这条路在发消息的主路上，不能为了一个名字把消息卡住——
    // initState 拿到的那份旧一点，但有。
    final identity = await buildIdentityPrompt(
      conversationPersona: conv.systemPrompt,
      fallbackAiName: _aiName,
      fallbackUserName: _userName,
    );

    // 人设和记忆分开传，别在这儿拼成一个字符串。
    //
    // 人设长期不变、记忆几乎天天变，拼在一起会让整个 system 块每天都变一次；
    // 而它排在最前面，一变就把后面几千 token 的对话历史全部挤出 prompt 缓存。
    // ai_client 会把记忆挂到最后一条用户消息上，详见 _attachMemory。
    final memoryContext = await buildMemoryContext();

    // 长期记忆的摘要层进 system 块，**不进 memoryContext**。
    //
    // 那两块的去处是不一样的：memoryContext 天天变，挂在最后一条用户消息
    // 尾部；这一块几乎不变，跟人设一起待在前缀里吃 KV 缓存。详见
    // buildMemoryDigest 的注释。
    //
    // 排在人设和规则之后：那两段是 const，最不变；摘要偶尔会改，
    // 排在它们后面，改一次不至于把前面那两段也一起失效。
    //
    // 同样兜异常——它只是「知道得多一点」，读不出来就当没有，
    // 不能因为它把消息卡住。
    var digest = '';
    try {
      digest = await buildMemoryDigest();
    } catch (e) {
      debugPrint('[chat] 读长期记忆失败，这次不带：$e');
    }

    // 顺序是按「多久变一次」排的，越不变的越靠前。前缀命中缓存是逐字节从头
    // 比对的，把易变的放前面会把后面整段一起作废。
    //
    // 身份（名字 + 人设，几乎不变）→ 读记录的规则（const）→ 写记忆的规矩
    // （const）→ 记忆摘要（记忆改了才变）。近期记录不在这儿：它天天变，
    // 挂在最后一条用户消息尾部。
    //
    // 写记忆的规矩紧跟读记忆的，中间不夹会变的东西；摘要排在它俩后面——
    // 「先看已有的那几条」指的就是它。
    //
    // 两段规矩都在身份外面：自定义了性格的对话会整段替掉人设，
    // 记不记东西、怎么读记录，不该被「用什么口吻说话」连坐。
    // 收着的那些工具的一行索引。排在 const 规矩之后、摘要之前：
    // 它只有连上/断开外部服务器时才变，比摘要还稳，但不是 const。
    final toolIndex = ToolTiers.buildIndex(allTools);

    final systemPrompt = [
      identity,
      memoryReadingRules,
      memoryWritingRules,
      selfNoteRules,
      smallThingRules,
      if (toolIndex.isNotEmpty) toolIndex,
      if (digest.isNotEmpty) digest,
    ].join('\n\n');

    // 聊得够久了就把早期消息折成摘要。
    //
    // 用不带工具的 aiClient：摘要任务不需要工具，带上只会多烧 token，还可能
    // 让模型在整理记录时莫名其妙去调用工具。
    if (needsCompaction(conv)) {
      final compacted = await compactHistory(conv: conv, aiClient: aiClient);
      if (compacted) _saveConversation(conv);
    }

    // Loop: keep calling AI and executing tools until AI responds with text
    int maxRounds = 5;
    while (maxRounds > 0) {
      maxRounds--;

      String? fullResponse;
      // 思考单独攒。它不进 fullResponse——那个要发回给服务端当上文。
      String? thinkingBuffer;

      // ⚠️ 工具列表和 _visibleHistory() 一样，必须放在循环里算。
      //
      // find_tools 是在**工具轮次里**执行的，它取出来的工具要到下一轮才能
      // 出现在 tools 数组里。提到循环外面就是个过期快照——它搜到了工具，
      // 却调不了，而 find_tools 的返回值还告诉它「这一轮就能直接调」。
      //
      // ⚠️ 这里**只能给 active()，不能给 allTools**：tools 数组在 prompt
      // 缓存的前缀里，给全量等于分层白做。active() 在一段对话里只增不减，
      // 所以取一次工具赔一次缓存，之后前缀重新稳定，不是每轮都赔。
      //
      // AiClient 只有两个 final 字段、没有连接状态，每轮新建不花什么。
      final clientWithTools = AiClient(
        config: aiClient.config,
        tools: ToolTiers.active(allTools),
      );

      try {
        // 切片放在循环里算，不能提到外面：工具轮次会往 messages 末尾追加，
        // 提到外面就是个过期快照，后面几轮发出去的历史会缺东西。
        await for (final event in clientWithTools.chat(
          _visibleHistory(conv),
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: conv.summary,
        )) {
          switch (event.type) {
            case AiEventType.thinking:
              // 思考先到、正文还没开始，所以这里 fullResponse 通常还是 null：
              // 传空串让气泡先立起来，人就能看见它在想，而不是干等。
              thinkingBuffer = (thinkingBuffer ?? '') + (event.text ?? '');
              _updateAssistantMessage(
                conv,
                fullResponse ?? '',
                thinking: thinkingBuffer,
              );
              break;

            case AiEventType.token:
              fullResponse = (fullResponse ?? '') + (event.text ?? '');
              _updateAssistantMessage(conv, fullResponse);
              break;

            case AiEventType.toolCalls:
              fullResponse = fullResponse ?? '';
              // Embed tool calls in the assistant message, then finalize
              _updateAssistantMessage(
                conv,
                fullResponse,
                toolCalls: event.toolCalls ?? [],
              );
              _finalizeStreamMessage(conv);
              for (final tc in event.toolCalls ?? []) {
                String toolResult;
                try {
                  toolResult = await _executeTool(mcpServer, tc);
                } catch (e) {
                  // 无论工具执行内部出什么问题，都必须给这个 tool_call_id
                  // 留一条结果消息——不然对话历史会永久损坏（AI 服务商的
                  // API 要求每个 tool_calls 都必须有对应的响应，缺一个就会
                  // 一直 400，且没法靠重试恢复，因为坏掉的历史已经存下来了）
                  toolResult = jsonEncode({
                    'success': false,
                    'error': '工具执行异常: $e',
                  });
                }
                conv.messages.add(
                  ChatMessage(
                    id: _uuid.v4(),
                    role: MessageRole.toolResult,
                    content: toolResult,
                    toolCallId: tc.id,
                  ),
                );
                // send_voice 成功之后，把它接成一条**真的语音消息**。
                //
                // 工具本身只负责合成和存盘；「这条出现在对话里」是界面的事。
                // 不这么接的话，用户看到的只是一个工具调用卡片，
                // 那句话等于没说出口。
                _appendVoiceMessage(conv, tc.name, toolResult);
                // send_sticker 成功之后，把它接成一条**真的表情消息**。
                // 和语音同一个路子：工具只负责产出，「这条出现在对话里」是界面的事。
                _appendStickerMessage(conv, tc.name, toolResult);
                // ask_choice 的结果接成一张选项卡，见 [_appendChoiceMessage]。
                _appendChoiceMessage(conv, tc.name, toolResult);
                // glance_screen 截到的图接成一条消息，下一轮模型才看得到。
                await _appendGlanceShot(conv, aiClient, tc.name, toolResult);
              }
              // Break out of the stream loop to continue the outer while loop
              fullResponse = null; // signal that we need another round
              break;

            case AiEventType.done:
              fullResponse = event.text ?? fullResponse ?? '';
              _updateAssistantMessage(conv, fullResponse);
              break;

            case AiEventType.error:
              debugPrint('[chat] AI error: ${event.error}');
              _updateAssistantMessage(conv, '⚠️ 错误: ${event.error ?? "未知"}');
              _finalizeStreamMessage(conv);
              fullResponse = 'done';
              break;
          }
        }
      } catch (e) {
        _updateAssistantMessage(conv, '❌ 发送消息失败: $e');
      }

      // 可选：自动朗读 AI 回复
      // 自动朗读只在她还在这段上时读：人走了还在耳边念，吓人。
      if (fullResponse != null &&
          fullResponse.isNotEmpty &&
          mounted &&
          identical(conv, _conversation)) {
        final last = conv.messages.isNotEmpty ? conv.messages.last : null;
        if (last != null &&
            last.role == MessageRole.assistant &&
            last.content.trim().isNotEmpty) {
          try {
            // 先把 service 取出来再 await：await 之后这个 State 可能已经销毁，
            // 那时再碰 context 就是 use_build_context_synchronously 说的那种崩法。
            final tts = context.read<TtsService>();
            final settings = await AppSettings.load();
            if (settings.ttsAutoPlay) {
              await tts.toggle(last.id, last.content);
            }
          } catch (_) {
            // 自动朗读失败不影响聊天
          }
        }
      }

      // If there was a tool call, the loop continues
      // If there was an error or done with text, exit
      if (fullResponse != null) break;
    }

    // 收尾（放下「生成中」、存盘、弹通知）在 [_finishTurn]。
  }

  /// 去掉已被摘要覆盖的那段，只发剩下的原文。
  List<ChatMessage> _visibleHistory(Conversation conv) {
    final n = conv.summarizedCount;
    if (n <= 0 || n >= conv.messages.length) {
      return conv.messages;
    }
    return conv.messages.sublist(n);
  }

  static const _toolTimeout = Duration(seconds: 60);

  /// `glance_screen` 截到了：把截图接成一条消息，模型下一轮才看得到。
  ///
  /// 挂在 **user** 消息上，是因为工具结果只能是文字——OpenAI 兼容那一路的
  /// tool 消息里放不了图。界面上按 `glanceShot` 画在它那一边、字不显示
  /// （见 MessageBubble）。模型自己看不了图时走识图兜底，和她发图同一个规矩。
  Future<void> _appendGlanceShot(
    Conversation conv,
    AiClient client,
    String toolName,
    String rawResult,
  ) async {
    if (toolName != 'glance_screen') return;
    try {
      final r = jsonDecode(rawResult);
      if (r is! Map || r['success'] != true) return;
      final ref = r['image'];
      if (ref is! String) return;
      final app = r['app'] as String?;
      var content =
          '（这是你刚才用 glance_screen 看到的 TA 的屏幕'
          '${app == null ? '' : '，TA 在用「$app」'}。）';
      if (!client.sendsImagesNatively) {
        final b64 = ChatImages.base64Of(ref);
        final described =
            b64 == null
                ? null
                : await VisionService.analyze(
                  b64,
                  prompt: '这是一张手机截图。说说是哪个 App、在看什么。聊天内容、金额、账号这类私事不要抄出来。',
                );
        if (described != null) content = '$content\n[屏幕截图分析: $described]';
      }
      _touch(conv, () {
        conv.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.user,
            content: content,
            images: [ref],
            metadata: const {'glanceShot': true},
          ),
        );
      });
      if (identical(conv, _conversation)) _scrollToBottom();
    } catch (e) {
      debugPrint('[glance] 接截图失败：$e');
    }
  }

  /// 把 `send_voice` 的结果变成一条语音消息。
  ///
  /// 文字仍然存在 [ChatMessage.content] 里——它是「转文字」的来源，也是
  /// 发回给模型的上文（不然它不记得自己说过什么）。只是**界面上不显示**。
  /// 把 `ask_choice` 的结果变成一张选项卡。
  ///
  /// 正文就是那句问题——**不藏进 metadata**。这样即使以后卡片渲染坏了，
  /// 聊天记录读起来仍然是通顺的：它问了一句，她答了一句。选项挂在 metadata 上，
  /// 画在气泡下面。
  ///
  /// 和语音、表情同一条路：工具只负责产出，「这条出现在对话里」是界面的事。
  /// 工具**不等她点**——聊天里的工具有 60 秒超时，真等她点，她去倒杯水回来
  /// 这一轮就报错了。
  void _appendChoiceMessage(
    Conversation conv,
    String toolName,
    String rawResult,
  ) {
    if (toolName != 'ask_choice') return;
    try {
      final r = jsonDecode(rawResult);
      if (r is! Map || r['success'] != true) return;
      final question = r['question'];
      final options = r['options'];
      if (question is! String || options is! List || options.length < 2) return;
      _touch(conv, () {
        conv.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: question,
            metadata: {
              'choice': {
                'options': [
                  for (final o in options)
                    if (o is Map)
                      {
                        'label': '${o['label']}',
                        if (o['note'] != null) 'note': '${o['note']}',
                      },
                ],
              },
            },
          ),
        );
      });
      if (identical(conv, _conversation)) _scrollToBottom();
    } catch (e) {
      debugPrint('[choice] 接选项卡失败：$e');
    }
  }

  /// 她点了选项卡上的某一项。
  ///
  /// 两件事：把那条标成「选了哪个」（以后翻上去看得懂当时选的是什么），
  /// 然后**作为她的一条消息发出去**，对话照常往下走。
  ///
  /// 她也可以不点、直接打字说别的——卡片是建议，不是拦路的弹窗。
  void _pickChoice(ChatMessage card, String label) {
    final conv = _conversation;
    final i = conv.messages.indexWhere((m) => m.id == card.id);
    if (i >= 0) {
      final old = conv.messages[i];
      final meta = Map<String, dynamic>.from(old.metadata ?? {});
      final choice = Map<String, dynamic>.from(
        (meta['choice'] as Map?) ?? const {},
      );
      // 已经点过就不再受理：重复点一次会再发一条一样的消息。
      if (choice['picked'] != null) return;
      choice['picked'] = label;
      meta['choice'] = choice;
      _touch(conv, () {
        conv.messages[i] = ChatMessage(
          id: old.id,
          role: old.role,
          content: old.content,
          timestamp: old.timestamp,
          toolCalls: old.toolCalls,
          toolCallId: old.toolCallId,
          metadata: meta,
          images: old.images,
          thinking: old.thinking,
        );
      });
    }
    _touch(conv, () {
      conv.messages.add(
        ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.user,
          content: label,
        ),
      );
    });
    _scrollToBottom();
    _continueChat();
  }

  /// 把 `send_sticker` 的结果变成一条表情消息。
  ///
  /// 消息里只记一个 key（[Sticker.key]），图是打包进 App 的资源——不走聊天图片
  /// 那条路，所以不会被 30 天清理扫掉。正文留空：表情就是这条消息的全部内容，
  /// 气泡那边看见 sticker 就不画气泡（见 `MessageBubble`）。
  void _appendStickerMessage(
    Conversation conv,
    String toolName,
    String rawResult,
  ) {
    if (toolName != 'send_sticker') return;
    try {
      final r = jsonDecode(rawResult);
      if (r is! Map || r['success'] != true) return;
      final key = r['sticker'];
      if (key is! String || stickerOf(key) == null) return;
      _touch(conv, () {
        conv.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: '',
            metadata: {'sticker': key},
          ),
        );
      });
      if (identical(conv, _conversation)) _scrollToBottom();
    } catch (e) {
      debugPrint('[sticker] 接表情消息失败：$e');
    }
  }

  /// 她自己发一张表情。
  ///
  /// 正文写成 `[表情：困了]` 是**给模型看的**——它读不到图，不写的话它只知道
  /// 收到一条空消息。界面上这句不显示，只画图（见 `MessageBubble`）。
  void _sendSticker(Sticker sticker) {
    final conv = _conversation;
    _touch(conv, () {
      conv.messages.add(
        ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.user,
          content: '[表情：${sticker.label}]',
          metadata: {'sticker': sticker.key},
        ),
      );
    });
    _scrollToBottom();
    // 发表情也是说了一句话，照常让它接话。
    _continueChat();
  }

  /// 表情面板。放在加号里，和拍照/相册/文件并列。
  void _showStickerSheet() {
    showModalBottomSheet(
      context: context,
      // 三十六张排下来六排开外，默认高度会把后面几排截掉——要能滚，
      // 并且封顶在屏幕六成，不然整屏被它占满。
      isScrollControlled: true,
      builder:
          (ctx) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final s in kStickers)
                      InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _sendSticker(s);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset(
                                s.asset,
                                width: 64,
                                height: 64,
                                // 像素画：插值会把它糊成一团。
                                filterQuality: FilterQuality.none,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                s.label,
                                style: Theme.of(ctx).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  void _appendVoiceMessage(
    Conversation conv,
    String toolName,
    String rawResult,
  ) {
    if (toolName != 'send_voice') return;
    try {
      final r = jsonDecode(rawResult);
      if (r is! Map || r['success'] != true) return;
      final voice = r['voice'];
      final text = r['text'];
      if (voice is! Map || text is! String || text.trim().isEmpty) return;
      _touch(conv, () {
        conv.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: text,
            metadata: {'voice': Map<String, dynamic>.from(voice)},
          ),
        );
      });
      if (identical(conv, _conversation)) _scrollToBottom();
    } catch (e) {
      debugPrint('[voice] 接语音消息失败：$e');
    }
  }

  Future<String> _executeTool(McpServer mcpServer, ToolCallInfo tc) async {
    final extProvider = context.read<ExternalMcpProvider>();

    // Try local MCP server first
    final executor =
        mcpServer.registeredTools
            .where((r) => r.tool.name == tc.name)
            .firstOrNull
            ?.executor;
    // 一律 jsonEncode，不要用 .toString()。
    //
    // 工具返回的是 Map，Map.toString() 出来是 Dart 格式（`{success: true, ...}`）——
    // 键和字符串值都没有引号，不是合法 JSON。这个字符串既发回给模型（于是模型
    // 从来没真正读到过工具结果），又被界面拿去 jsonDecode（于是每次都解析失败、
    // 显示「未成功」且展开空白）。
    if (executor != null) {
      return _runToolWithTimeout(
        () async => jsonEncode(await executor(tc.arguments)),
        tc.name,
      );
    }

    // Try external MCP servers
    for (final client in extProvider.clients) {
      if (client.tools.any((t) => t.name == tc.name)) {
        return _runToolWithTimeout(
          () async => jsonEncode(await client.callTool(tc.name, tc.arguments)),
          tc.name,
        );
      }
    }

    return jsonEncode({'success': false, 'error': '工具 ${tc.name} 未找到'});
  }

  /// 工具执行统一加超时并吞掉异常：无论成功/超时/失败都返回字符串结果，
  /// 避免 assistant(tool_calls) 成为“孤儿”导致下次发送报 invalid_request_error。
  Future<String> _runToolWithTimeout(
    Future<String> Function() run,
    String toolName,
  ) async {
    // 失败路径同样返回 JSON：模型和界面都按 JSON 解析，
    // 混进裸字符串会让两边都拿不到结构化的失败原因。
    try {
      return await run().timeout(
        _toolTimeout,
        onTimeout:
            () => jsonEncode({
              'success': false,
              'error': '工具 $toolName 执行超时（${_toolTimeout.inSeconds} 秒），请重试',
            }),
      );
    } catch (e) {
      return jsonEncode({'success': false, 'error': '工具 $toolName 执行失败: $e'});
    }
  }

  /// [thinking] 传 null 表示「这次没有新的思考」，不是「把已有的清掉」——
  /// 正文每来一个 token 就重建一次这条消息，不保留的话思考会被后面的正文冲掉。
  void _updateAssistantMessage(
    Conversation conv,
    String content, {
    List<ToolCallInfo>? toolCalls,
    String? thinking,
  }) {
    // 过滤模型可能复读出来的 [time: ...] 标记（系统注入的时间戳元数据）
    final cleaned =
        content
            .replaceAll(RegExp(r'\[time:[^\]]*\]'), '')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trimLeft();
    _touch(conv, () {
      if (conv.messages.isNotEmpty &&
          conv.messages.last.role == MessageRole.assistant &&
          conv.messages.last.id.startsWith('stream_')) {
        conv.messages.last = ChatMessage(
          id: conv.messages.last.id,
          role: MessageRole.assistant,
          content: cleaned,
          toolCalls: toolCalls,
          thinking: thinking ?? conv.messages.last.thinking,
        );
      } else {
        conv.messages.add(
          ChatMessage(
            id: 'stream_${_uuid.v4()}',
            role: MessageRole.assistant,
            content: cleaned,
            toolCalls: toolCalls,
            thinking: thinking,
          ),
        );
      }
    });
    if (identical(conv, _conversation)) _scrollToBottom();
  }

  void _finalizeStreamMessage(Conversation conv) {
    _touch(conv, () {
      if (conv.messages.isNotEmpty &&
          conv.messages.last.role == MessageRole.assistant &&
          conv.messages.last.id.startsWith('stream_')) {
        final old = conv.messages.last;
        conv.messages.last = ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.assistant,
          content: old.content,
          toolCalls: old.toolCalls,
          thinking: old.thinking,
        );
      }
    });
  }

  void _showConversationList() {
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Text(
                        '对话历史',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(PhosphorIconsRegular.plus, size: 18),
                        label: const Text('新建'),
                        onPressed: () => _newConversation(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                InkWell(
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _openSearch();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          PhosphorIconsRegular.magnifyingGlass,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '搜索历史对话',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child:
                      _savedConversations.isEmpty
                          ? const Center(child: Text('暂无历史对话'))
                          : ListView.builder(
                            itemCount: _savedConversations.length,
                            itemBuilder: (ctx, i) {
                              final conv = _savedConversations[i];
                              final isCurrent = conv.id == _conversation.id;
                              return ListTile(
                                title: Text(
                                  conv.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${conv.messageCount} 条消息 · ${conv.model}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                selected: isCurrent,
                                trailing: IconButton(
                                  icon: const Icon(
                                    PhosphorIconsRegular.trash,
                                    size: 18,
                                  ),
                                  onPressed: () async {
                                    await StorageService.deleteConversation(
                                      conv.id,
                                    );
                                    _loadConversations();
                                    if (ctx.mounted) Navigator.of(ctx).pop();
                                  },
                                ),
                                onTap: () => _openConversation(conv.id),
                              );
                            },
                          ),
                ),
              ],
            ),
          ),
    ).then((_) => _loadConversations());
  }

  void _showRenameDialog() {
    final controller = TextEditingController(text: _conversation.title);
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('重命名对话'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '输入对话名称',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _conversation.title = controller.text.trim();
                    _conversation.titleManuallySet = true;
                  });
                  _saveConversation();
                  Navigator.of(ctx).pop();
                },
                child: const Text('确定'),
              ),
            ],
          ),
    );
  }

  /// 重命名列表里的某一场对话。
  ///
  /// **改名得先把完整对话读出来**：标题和 `titleManuallySet` 都长在正文文件里，
  /// 而列表上手里只有[索引][ConversationSummary]。读盘放在「确定」那一下而不是
  /// 弹框的时候——点开又取消不该付一次全量读盘，那正是刚从这一页拿掉的东西。
  /// 存回去时索引会跟着刷新，见 [StorageService.saveConversation]。
  void _showRenameConversationDialog(ConversationSummary summary) {
    final controller = TextEditingController(text: summary.title);
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('重命名对话'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '输入对话名称',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  final title = controller.text.trim();
                  Navigator.of(ctx).pop();
                  if (title.isEmpty) return;
                  final conv = await _fullConversation(summary.id);
                  if (conv == null) return;
                  conv.title = title;
                  conv.titleManuallySet = true;
                  await StorageService.saveConversation(conv);
                  // 等存完再刷。原来是不等就刷，紧接着的那次列对话有可能
                  // 抢在写盘前面，读到的还是旧标题。
                  if (mounted) _loadConversations();
                },
                child: const Text('确定'),
              ),
            ],
          ),
    );
  }

  /// 编这段对话自己的性格。
  ///
  /// 这个入口在 4c2fd85（全局改版）里被删掉了，但 `Conversation.systemPrompt`
  /// 的字段、JSON 读写、读取路径一直都在——只是没地方设置。这次是把入口补回来。
  ///
  /// ⚠️ 旧版那个对话框改完 `_conversation.systemPrompt` **没有调
  /// `_saveConversation()`**，退出去可能就没了。这次补上。
  Future<void> _editPersona() async {
    // 只是为了判断「全局那边空不空」，读不出来就当空的——
    // 最坏后果是多问一次，不该因此打不开编辑页。
    var globalPersona = '';
    try {
      globalPersona = (await AppSettings.load()).persona.trim();
    } catch (e) {
      debugPrint('[chat] 读全局性格失败，按空的算：$e');
    }
    if (!mounted) return;

    final result = await Navigator.of(context).push<PersonaResult>(
      MaterialPageRoute(
        builder:
            (_) => PersonaScreen(
              initial: _conversation.systemPrompt ?? '',
              globalIsEmpty: globalPersona.isEmpty,
            ),
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      // 空串存成 null，不存空字符串：null 才是「没设过，用默认」，
      // 空串会被上面那个 ?? 当成「设过了，就是空的」，于是人设整个消失。
      _conversation.systemPrompt = result.text.isEmpty ? null : result.text;
    });
    _saveConversation();

    if (result.alsoGlobal) {
      try {
        final settings = await AppSettings.load();
        settings.persona = result.text;
        // 用户刚说了「用在所有对话」，那就得真的生效——存了文本却不开开关，
        // 等于什么都没发生，而他不会知道为什么。
        settings.personaEnabled = true;
        await settings.save();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('这段对话存好了，但没能存进全局：$e')));
      }
    }
  }

  Future<void> _exportConversation() async {
    if (_conversation.messages.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有消息可以导出')));
      return;
    }
    try {
      final buffer = StringBuffer();
      buffer.writeln('📱 手机 AI 助手 - 对话导出');
      buffer.writeln('标题: ${_conversation.title}');
      buffer.writeln('时间: ${DateTime.now().toLocal().toString()}');
      buffer.writeln('=' * 40);
      buffer.writeln('');

      for (final msg in _conversation.messages) {
        String role;
        switch (msg.role) {
          case MessageRole.user:
            role = '👤 你';
          case MessageRole.assistant:
            role = '🤖 AI';
          case MessageRole.toolCall:
            role = '🛠 工具';
          case MessageRole.toolResult:
            role = '📋 结果';
          default:
            role = '📝 系统';
        }
        buffer.writeln('$role: ${msg.content}');
        if (msg.images.isNotEmpty) {
          buffer.writeln('  [图片附件 × ${msg.images.length}]');
        }
        buffer.writeln('');
      }

      // Save to temp file and share
      final dir = await getTemporaryDirectory();
      final fileName =
          '对话_${_conversation.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(buffer.toString());

      await Share.shareXFiles([
        XFile(file.path),
      ], text: '📱 手机 AI 助手 - ${_conversation.title}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  /// 存一段对话，不传就是屏幕上这段。
  ///
  /// [_savedSig] 只在存的正是屏幕上这段时才更新：它记的是「屏幕上这段上次
  /// 存盘时的样子」。后台跑完的那一轮存的是别的对象，拿它更新，离开时的
  /// 比对就失准了。
  void _saveConversation([Conversation? which]) {
    final c = which ?? _conversation;
    if (!c.titleManuallySet) {
      // content 本身不可空，所以后面那个 `?.` 是无效的。顺手把空内容也归到
      // 「新对话」：原来第一条消息是空串时，substring(0,0) 会把标题存成空字符串。
      final first = c.messages.firstOrNull?.content;
      c.title =
          (first == null || first.isEmpty)
              ? '新对话'
              : first.substring(0, first.length.clamp(0, 30));
    }
    if (identical(c, _conversation)) _savedSig = _sigOf(c);
    StorageService.saveConversation(c);
  }

  /// 上次存盘（或读盘）时这场对话的样子，见 [_saveIfChanged]。
  String? _savedSig;

  /// 粗略的「变没变」。不是哈希全文——那本身就要把两千条过一遍。
  ///
  /// 够用的理由：这个页面对消息只做两种改动，**往后加**和**替换最后一条**
  /// （流式、定稿），两种都会动到条数或最后一条的 id/长度。标题和人设改完
  /// 当场就存了，这里只是兜底。
  String _sigOf(Conversation c) {
    final last = c.messages.lastOrNull;
    return '${c.messages.length}|${last?.id}|${last?.content.length}|'
        '${last?.thinking?.length}|${last?.metadata?.length}|'
        '${c.summarizedCount}|${c.title}|${c.titleManuallySet}|'
        '${c.systemPrompt}|${c.isPinned}';
  }

  /// 离开一场对话时：变了才存。
  ///
  /// ⚠️ 原来是**无条件**存。一段两千条的对话光编码就是七百多 KB，还要顺手
  /// 重写一份索引——什么都没聊、点进去看一眼就返回，也要白等这一趟，
  /// 返回键就是这么变慢的。每一轮聊完本来就存过了（见 `_continueChat` 末尾）。
  void _saveIfChanged() {
    if (_conversation.messages.isEmpty) return;
    if (_sigOf(_conversation) == _savedSig) return;
    _saveConversation();
  }

  /// 首页那一排快捷入口。图标二选一：品牌图标给 [asset]，功能图标给 [icon]——
  /// 星=新对话、书=书架属于「地方和内容」，显示器属于「机器」，各归各的。
  Widget _quickActionCard(
    ThemeData theme, {
    IconData? icon,
    String? asset,
    required String label,
    bool primary = false,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    return Expanded(
      // 阴影画在 Material 外面：Material 的 elevation 出来偏灰，
      // AppSurface 负责底（玻璃或实心），Material 透明浮在上面只管水波纹。
      // 不能反过来让 Material 上色——那会盖掉玻璃。
      child: AppSurface(
        borderRadius: AppRadius.mdAll,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color:
                          primary
                              ? scheme.primary.withValues(alpha: 0.11)
                              : scheme.onSurface.withValues(alpha: 0.055),
                      shape: BoxShape.circle,
                    ),
                    child:
                        asset != null
                            ? Image.asset(
                              'assets/icons/$asset.png',
                              height: asset == 'books' ? 15 : 16,
                              color:
                                  primary
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                            )
                            : Icon(
                              icon,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 输入框会随内容变高（多行文字、待发图片），每帧之后量一次；
    // 没变就不 setState，不会打转。
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureInput());
    final theme = Theme.of(context);
    final bg = context.watch<BackgroundProvider>();
    final darkFg = bg.darkForeground ?? (theme.brightness == Brightness.light);
    final fgColor = darkFg ? const Color(0xFF171717) : Colors.white;

    // 悬浮播放条挂在 App 那一层（见 `main.dart` 的 builder / `music_float.dart`），
    // 不在这棵树上。它不知道自己在哪段对话里，而它点开的「一起听」要画两个
    // 头像——所以在这儿放一次。放 build 里而不是发消息那一处：头像该跟着她
    // **正在看**的那段对话，不是她最后一次说话的那段。
    MusicService.instance.activeConversationId = _conversation.id;

    return PopScope(
      canPop: !_chatMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _chatMode) _goHome();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        drawer: _buildDrawer(theme),
        onDrawerChanged: (open) {
          if (open) _loadDrawerCounts();
        },
        drawerEnableOpenDragGesture: !_chatMode,
        drawerEdgeDragWidth: 48,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          foregroundColor: fgColor,
          toolbarHeight: _chatMode ? null : 64,
          leading: Builder(
            builder:
                (ctx) =>
                    _chatMode
                        ? _topBarIcon(
                          PhosphorIconsRegular.arrowLeft,
                          onPressed: _goHome,
                          tooltip: '返回主页',
                          color: fgColor,
                        )
                        : _topBarIcon(
                          PhosphorIconsRegular.list,
                          onPressed: () => Scaffold.of(ctx).openDrawer(),
                          tooltip: '菜单',
                          color: fgColor,
                        ),
          ),
          title:
              !_chatMode
                  ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Consumer<SettingsProvider>(
                        builder: (context, sp, _) {
                          final serif = sp.settings?.titleSerif ?? true;
                          return Text(
                            _greeting(),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontFamily: serif ? 'NotoSerifSC' : null,
                              fontWeight: FontWeight.w700,
                              color: fgColor,
                            ),
                          );
                        },
                      ),
                      Text(
                        _homeDateStr(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: fgColor.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  )
                  : (_conversation.messages.isNotEmpty
                      ? _chatTitle(theme, fgColor)
                      : null),
          actions: [
            _topBarIcon(
              PhosphorIconsRegular.magnifyingGlass,
              onPressed: _openSearch,
              tooltip: '搜索',
              color: fgColor,
            ),
            // 对话模式下汉堡被返回键顶掉了，抽屉只能靠边缘滑——
            // 「重命名 / 导出」这两个动作等于藏起来了。给它们一个明面入口。
            if (_chatMode)
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                iconSize: 19,
                icon: _maybeGlassCircle(
                  size: 36,
                  child: Icon(
                    PhosphorIconsRegular.dotsThree,
                    color: fgColor,
                    size: 19,
                  ),
                ),
                tooltip: '更多',
                onSelected: (v) {
                  if (v == 'rename') _showRenameDialog();
                  if (v == 'persona') _editPersona();
                  if (v == 'export') _exportConversation();
                },
                // 菜单本体也走玻璃。
                //
                // PopupMenuButton 的背景是它自己那层 Material 画的，塞不进
                // BackdropFilter。所以反过来：把 Material 设成透明、去掉阴影，
                // **整张菜单做成一个 PopupMenuItem**，里面放一块 AppSurface——
                // 玻璃就由我们自己那层来糊。
                color: Colors.transparent,
                elevation: 0,
                shadowColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                menuPadding: EdgeInsets.zero,
                itemBuilder:
                    (ctx) => [
                      PopupMenuItem(
                        // 整块自己处理点击，外层这一层不参与
                        enabled: false,
                        padding: EdgeInsets.zero,
                        child: AppSurface(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          floating: true,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _menuRow(ctx, '重命名', 'rename'),
                              _menuRow(ctx, 'TA 的性格', 'persona'),
                              _menuRow(ctx, '导出聊天', 'export'),
                            ],
                          ),
                        ),
                      ),
                    ],
              ),
          ],
        ),
        // 对话模式下输入框**浮在消息上面**，消息从它底下滚过去。
        //
        // 原来是 Column，输入框把列表顶在上面——那条玻璃底下只有壁纸，
        // 等于白糊一次。浮起来之后它糊的才是活的内容。
        //
        // 代价是列表必须自己垫出等高的底部内边距（见 [_inputHeight]），
        // 否则滚到底时最后一条正好被压住。
        body: Stack(
          children: [
            // 内容区：主页模式显示首页，对话模式显示消息
            Positioned.fill(
              child:
                  _chatMode
                      ? (_conversation.messages.isEmpty
                          ? _buildEmptyChatHint(theme)
                          : Builder(
                            builder: (context) {
                              // 连续的工具消息折成一组，不能在 itemBuilder 里
                              // 逐条判断——单条消息看不出后面还有没有
                              final items = groupChatItems(
                                _conversation.messages,
                                events: _chatEvents,
                              );
                              final typing = _showTyping;
                              // 最新的排在第 0 项、贴着最底下，所以 builder
                              // 的 i 要倒过来换成 items 里的下标。
                              final base = typing ? 1 : 0;
                              return MarkBackdrop(
                                child: ListView.builder(
                                  controller: _scrollController,
                                  // ⚠️ 倒着排。原来是正着排、打开后再跳到底：
                                  // 第一帧画的是两千条里的**第一条**，
                                  // 下一帧才跳过去，而跳到底要先估出整张列表
                                  // 多高——长对话点进去就是「先闪一下开头、
                                  // 卡一下、再滚到最新」。倒过来之后偏移 0
                                  // 就是最新那条，第一帧就对，也不用估高度。
                                  reverse: true,
                                  // 倒着排时这个 bottom 仍然在屏幕底部，
                                  // 给浮着的输入框让位。
                                  padding: EdgeInsets.fromLTRB(
                                    12,
                                    12,
                                    12,
                                    _inputHeight + 12,
                                  ),
                                  itemCount: items.length + base,
                                  // 倒着排，每来一条新消息，所有旧项的 i 都
                                  // 往后挪一位。不按 key 找回原位的话，
                                  // 正在播的语音条、展开的思考会**串到隔壁
                                  // 那条上**。
                                  findChildIndexCallback: (key) {
                                    if (key is! ValueKey<String>) return null;
                                    if (key.value == 'typing') {
                                      return typing ? 0 : null;
                                    }
                                    final at = items.indexWhere(
                                      (it) => it.key == key.value,
                                    );
                                    return at < 0
                                        ? null
                                        : items.length - 1 - at + base;
                                  },
                                  itemBuilder: (context, i) {
                                    // 「正在输入」贴在最底下：回复将来落在
                                    // 哪儿，它就等在哪儿。
                                    if (typing && i == 0) {
                                      return TypingIndicator(
                                        key: const ValueKey('typing'),
                                        name: _aiName,
                                      );
                                    }
                                    final index = items.length - 1 - (i - base);
                                    return KeyedSubtree(
                                      key: ValueKey(items[index].key),
                                      child: chatDisplayItem(
                                        items,
                                        index,
                                        conversationId: _conversation.id,
                                        onPickChoice: _pickChoice,
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
                          ))
                      : _buildHome(theme),
            ),

            // 输入区只在对话模式出现。
            //
            // 主页原来底部同时挂着输入框和悬浮导航胶囊，两个白色悬浮元素上下
            // 叠着互相抢，底部没有唯一焦点。发消息的入口收到「新对话」和
            // 具体某段对话里去。
            if (_chatMode)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: KeyedSubtree(
                  key: _inputKey,
                  child: _buildInputArea(theme),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 这段对话里 TA 最近发来的那条带图消息里的图，给 `set_avatar` 用。
  List<String> _latestUserImagesIn(Conversation conv) {
    for (final m in conv.messages.reversed) {
      // 它自己截的屏幕不算 TA 发来的图——不然「拿你刚发的那张当头像」
      // 会拿到一张截图。
      if (m.metadata?['glanceShot'] == true) continue;
      if (m.role == MessageRole.user && m.images.isNotEmpty) return m.images;
    }
    return const [];
  }

  /// 点顶栏头像：换它在这段对话里的头像。菜单和换你自己头像的是同一个。
  Future<void> _showAvatarSheet() => showAvatarSheet(context, _conversation.id);

  /// 对话页顶栏：猫底座 + 标题 + 一行状态。
  ///
  /// 「在线」不是写死的装饰——它读 `AiClientProvider.currentClient`：
  /// 为 null 就是模型没配好，这一屏根本发不出去。密钥过期时
  /// 这里会先变成「未配置模型」，比发出去之后报错早一步。
  Widget _chatTitle(ThemeData theme, Color fgColor) {
    final scheme = theme.colorScheme;
    final online = context.watch<AiClientProvider>().currentClient != null;
    final count = _conversation.messages.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 点它换头像。它自己也能换（set_avatar），两边改的是同一份，
        // 所以这里听着 AvatarStore，它一换这里跟着变。
        GestureDetector(
          onTap: _showAvatarSheet,
          child: ListenableBuilder(
            listenable: AvatarStore.instance,
            builder: (context, _) {
              final file = AvatarStore.instance.currentFile(_conversation.id);
              return Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(11),
                ),
                child:
                    file != null
                        ? Image(
                          image: ResizeImage(FileImage(file), width: 128),
                          width: 34,
                          height: 34,
                          fit: BoxFit.cover,
                        )
                        : Image.asset(
                          'assets/icons/cat.png',
                          height: 17,
                          color: scheme.primary,
                        ),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
              Text(
                online ? '在线 · $count 条' : '未配置模型 · $count 条',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: online ? fgColor.withValues(alpha: 0.6) : scheme.error,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 圆形的玻璃底片。
  ///
  /// 顶栏那两个图标（搜索、三点）原来是**裸图标 + 一圈黑色投影**——投影是为了
  /// 让它在深浅不定的壁纸上都看得见。那是补丁：图标本身没有落脚的地方，
  /// 只好靠阴影把自己从背景里抠出来，深色壁纸上就成了一团脏影子。
  ///
  /// 给它一个圆形玻璃底之后，图标是站在一个面上的，不用再靠阴影自证存在。
  ///
  /// [glass] 为 false 时直接返回原样——主操作（发送键）不该退到背景里。
  Widget _maybeGlassCircle({
    required Widget child,
    required double size,
    bool glass = true,
  }) {
    if (!glass) return child;
    return AppSurface(
      borderRadius: BorderRadius.circular(size / 2),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  /// 玻璃菜单里的一行。
  ///
  /// 外层那个 PopupMenuItem 是 `enabled: false`（不然它会自己画一层高亮，
  /// 盖在玻璃上），所以点击和关闭都由这里自己来。
  Widget _menuRow(BuildContext ctx, String label, String value) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: SizedBox(
        height: 46,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(label, style: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    );
  }

  Widget _topBarIcon(
    IconData icon, {
    required VoidCallback onPressed,
    String? tooltip,
    Color? color,
  }) {
    // ⚠️ 外面这层 Center 不能删。
    //
    // AppBar 的 `leading` 槽位给的是**紧约束**（56×64 全占满），玻璃底会被
    // 撑成一个圆角方块；而 `actions:` 里的不受这个约束，是正圆。同一个函数、
    // 两种长相——Cleo 的原话是「左边的方框看着有点突兀」。
    //
    // Center 给子组件松约束，两边就都按 36 收缩成圆了。
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: _maybeGlassCircle(
          size: 36,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 19,
            // 投影去掉了：现在有底片撑着，不用再靠阴影把自己从壁纸里抠出来。
            icon: Icon(icon, color: color),
            onPressed: onPressed,
            tooltip: tooltip,
          ),
        ),
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    String part;
    if (hour < 5) {
      part = '夜深了';
    } else if (hour < 9) {
      part = '早上好';
    } else if (hour < 12) {
      part = '上午好';
    } else if (hour < 14) {
      part = '中午好';
    } else if (hour < 18) {
      part = '下午好';
    } else if (hour < 23) {
      part = '晚上好';
    } else {
      part = '夜深了';
    }
    return _userName.trim().isEmpty ? part : '$part，$_userName';
  }

  String _homeDateStr() {
    final today = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${today.month}月${today.day}日 · ${weekdays[today.weekday - 1]}';
  }

  Widget _buildDrawer(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final who = _userName.trim().isEmpty ? 'Cleo' : _userName.trim();
    final ta = _aiName.trim().isEmpty ? 'TA' : _aiName.trim();

    return Drawer(
      width: 296,
      // 实底：半透明会让背后花花绿绿的内容透上来，压低菜单文字的可读性
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(26),
          bottomRight: Radius.circular(26),
        ),
      ),
      child: SafeArea(
        child: Column(
          // 默认是 center：底部寄语那块比较窄，不拉满就会被居中，
          // 和上面所有左对齐的东西错开
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 身份区：打开抽屉第一眼应该知道这是谁的地方
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Row(
                children: [
                  Image.asset(
                    'assets/mark-simple.png',
                    width: 46,
                    color: dark ? scheme.onSurface : scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          who,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'NotoSerifSC',
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '和$ta一起，$_totalMessages 条消息',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                children: [
                  _drawerGroup(theme, [
                    _drawerItem(
                      theme,
                      asset: 'star',
                      label: '新对话',
                      primary: true,
                      onTap: () {
                        Navigator.of(context).pop();
                        _newConversation();
                      },
                    ),
                    _drawerItem(
                      theme,
                      icon: PhosphorIconsRegular.clockCounterClockwise,
                      label: '对话历史',
                      trailing: '${_savedConversations.length}',
                      onTap: () {
                        Navigator.of(context).pop();
                        _showConversationList();
                      },
                    ),
                    _drawerItem(
                      theme,
                      asset: 'flower',
                      label: '收藏的话',
                      trailing: '$_favoriteCount',
                      onTap: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const MusingCornerScreen(),
                          ),
                        );
                      },
                    ),
                  ]),
                  // 「书架」不放这里：底部导航已经有了，同一个目的地两个入口
                  // 只会让人多想一秒。「工具」是诊断页，收在设置里。
                  _drawerGroup(theme, [
                    _drawerItem(
                      theme,
                      asset: 'waves',
                      label: '聊天背景',
                      onTap: () {
                        Navigator.of(context).pop();
                        _openBackgroundSheet();
                      },
                    ),
                    _drawerItem(
                      theme,
                      icon: PhosphorIconsRegular.gear,
                      label: '设置',
                      onTap: () async {
                        Navigator.of(context).pop();
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                        _loadUserName();
                      },
                    ),
                  ]),
                  _drawerGroup(theme, [
                    _drawerItem(
                      theme,
                      icon: PhosphorIconsRegular.trashSimple,
                      label: '回收站',
                      trailing: _trashCount == 0 ? null : '$_trashCount',
                      onTap: () {
                        Navigator.of(context).pop();
                        _showTrashSheet();
                      },
                    ),
                  ]),
                ],
              ),
            ),
            // 下半部分本来是大片空白。空白不是靠加功能填，是靠给它一个收尾。
            Padding(
              // 左边距 24 = 分组卡外边距 14 + 条目内边距 10，
              // 和上面那排图标底座对齐
              padding: const EdgeInsets.fromLTRB(24, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Opacity(
                    opacity: 0.3,
                    child: Image.asset(
                      'assets/icons/paw.png',
                      height: 16,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '愿你在所有的奔波里，\n都有一个可以回来的小角落。',
                    style: TextStyle(
                      fontFamily: 'NotoSerifSC',
                      fontSize: 13,
                      height: 1.95,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerGroup(ThemeData theme, List<Widget> items) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        boxShadow: AppShadow.soften(dark),
      ),
      child: Column(children: items),
    );
  }

  Widget _drawerItem(
    ThemeData theme, {
    IconData? icon,
    String? asset,
    required String label,
    String? trailing,
    bool primary = false,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    final fg = primary ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    primary
                        ? scheme.primary.withValues(alpha: 0.11)
                        : scheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child:
                  asset != null
                      ? Image.asset(
                        'assets/icons/$asset.png',
                        height: asset == 'waves' ? 13 : 16,
                        color: fg,
                      )
                      : Icon(icon, size: 16, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTrashSheet() async {
    var trashed = await StorageService.listTrashedConversations();
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setSheet) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '回收站',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      if (trashed.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            '回收站是空的',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: trashed.length,
                            itemBuilder: (_, i) {
                              final conv = trashed[i];
                              return ListTile(
                                title: Text(
                                  conv.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${conv.messages.length} 条消息 · ${_shortTime(conv.updatedAt)}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                leading: Icon(
                                  PhosphorIconsRegular.trash,
                                  color: scheme.onSurfaceVariant,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextButton(
                                      onPressed: () async {
                                        await StorageService.restoreConversation(
                                          conv.id,
                                        );
                                        if (ctx.mounted) {
                                          Navigator.of(ctx).pop();
                                        }
                                        _loadConversations();
                                      },
                                      child: const Text('恢复'),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        PhosphorIconsRegular.trashSimple,
                                      ),
                                      tooltip: '彻底删除',
                                      onPressed: () async {
                                        await StorageService.permanentlyDeleteConversation(
                                          conv.id,
                                        );
                                        setSheet(
                                          () =>
                                              trashed =
                                                  trashed
                                                      .where(
                                                        (c) => c.id != conv.id,
                                                      )
                                                      .toList(),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
          ),
    );
  }

  /// 选完背景通知外层重画。真正拿路径画底的是 home_shell，
  /// 这一屏自己不持有背景状态。
  Future<void> _openBackgroundSheet() async {
    final changed = await showBackgroundSheet(context);
    if (changed && mounted) widget.onBackgroundChanged?.call();
  }

  Widget _buildEmptyChatHint(ThemeData theme) {
    final bg = context.watch<BackgroundProvider>();
    final darkFg = bg.darkForeground ?? (theme.brightness == Brightness.light);
    final fgColor = darkFg ? const Color(0xFF171717) : Colors.white;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsRegular.chatCircle,
            size: 56,
            color: fgColor.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            '给 AI 发第一条消息吧',
            style: TextStyle(color: fgColor.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }

  Widget _buildHome(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    // 平时只露置顶的和最近那条；其余收在「展开」后面，见 [homeConversations]。
    final shownConvs = homeConversations(
      _savedConversations,
      expanded: _homeExpanded,
    );

    return ListView(
      // 底部 96 是给悬浮导航条让的位（它现在浮在内容上面，见 HomeShell）。
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
      // 关掉每项的 RepaintBoundary：玻璃卡片要用 BackdropFilter 采样身后的
      // 背景图，而 RepaintBoundary 把卡片和背景隔进了两个图层，滚动时采样
      // 跟不上位移——症状是卡片「先透明一下再变模糊」。
      addRepaintBoundaries: false,
      children: [
        // 我想说
        AppSurface(
          borderRadius: AppRadius.xlAll,
          child: Stack(
            children: [
              // 右上角压一枚徽标淡印。全 App 就这里和聊天页底层两处有材质，
              // 「缺质感」补的就是这个——注意别让它吃掉点击。
              Positioned(
                top: -8,
                right: -6,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: dark ? 0.09 : 0.07,
                    child: Transform.rotate(
                      angle: -0.10472, // -6°
                      child: Image.asset(
                        'assets/mark-simple.png',
                        width: 92,
                        color:
                            dark
                                ? const Color(0xFFF2EAE0)
                                : const Color(0xFF8B5E34),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '我想说',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_musingLoading)
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.primary,
                                ),
                              )
                            else
                              Tooltip(
                                message: '戳戳ta',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    _refreshMusing();
                                  },
                                  child: Icon(
                                    PhosphorIconsRegular.handTap,
                                    size: 18,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 10),
                            InkWell(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              onTap:
                                  _musingContent == null
                                      ? null
                                      : _toggleFavoriteMusing,
                              // 收藏是花，不是星——星归「新对话 / 进度」，
                              // 品牌图标里一个元素只认一件事。
                              //
                              // 收了是主色，没收是次级灰；两种状态必须一眼分得出，
                              // 原来两个分支是同一个 star 图标，点了看不出有没有收上。
                              child: Image.asset(
                                'assets/icons/flower.png',
                                height: 18,
                                color:
                                    _musingFavorited
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _musingContent ??
                          (_musingLoading
                              ? '在想点什么…'
                              : '开始新对话吧，我可以帮你拍照、查位置、聊书、找文件。'),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 快捷入口
        Row(
          children: [
            _quickActionCard(
              theme,
              asset: 'star',
              label: '新对话',
              primary: true,
              onTap: _newConversation,
            ),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              asset: 'books',
              label: '书架',
              onTap: () => widget.onSwitchTab?.call(AppTab.bookshelf),
            ),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              icon: PhosphorIconsRegular.desktop,
              label: '电脑',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PcChatScreen()),
                  ),
            ),
            const SizedBox(width: 10),
            // 跟电脑上的小克（Claude Code 会话）直接聊，不经过 App 里的模型。
            // 和「电脑」分开放：那个是每条消息起一个一次性的助手，不是同一个人。
            _quickActionCard(
              theme,
              icon: PhosphorIconsRegular.chatCircleDots,
              label: '小克',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const XiaokeChatScreen()),
                  ),
            ),
          ],
        ),
        if (_savedConversations.isNotEmpty) ...[
          const SizedBox(height: 26),
          Row(
            children: [
              Expanded(
                child: Text(
                  '最近对话',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // 这儿原来是个垃圾桶（回收站）。2026-09-16 Cleo 指出它不对：
              // 抽屉里已经有「回收站」入口、还带数量角标，这是同一个弹层的
              // 第二个门；而且「最近对话」是个分区标题，右边跟一个删除图标
              // 读起来像「清空这些」，意思正好拧着。
              //
              // 这个位置该管的是这份列表本身，于是换成展开 / 收起。
              if (_homeExpanded ||
                  _savedConversations.take(20).length > shownConvs.length)
                TextButton(
                  onPressed: () {
                    setState(() => _homeExpanded = !_homeExpanded);
                    StorageService.setHomeConversationsExpanded(_homeExpanded);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _homeExpanded
                        ? '收起'
                        // 数的是「展开之后会多出来几条」，所以按同一个上限算，
                        // 不能拿总数减——超过 20 条的那些展开也不会出现。
                        : '展开 ${_savedConversations.take(20).length - shownConvs.length}',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ...shownConvs.map((conv) => _conversationTile(theme, conv)),
        ],
      ],
    );
  }

  /// 会话列表项：左滑出「置顶 / 重命名 / 删除」三个操作。
  ///
  /// 原来三个动作散在三处——左滑删除、右侧图钉按钮置顶、长按重命名，得记住
  /// 哪个动作藏在哪个手势里。现在统一收进左滑面板，右侧只留一个图钉**状态**
  /// 标记（不再可点），置顶与否主要靠整行底色区分。
  Widget _conversationTile(ThemeData theme, ConversationSummary conv) {
    final scheme = theme.colorScheme;
    final pinned = conv.isPinned;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Slidable(
          key: ValueKey('conv_${conv.id}'),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            // 三个按钮要放得下文字，比默认宽一些
            extentRatio: 0.62,
            children: [
              SlidableAction(
                onPressed: (_) async {
                  HapticFeedback.selectionClick();
                  await StorageService.setConversationPinned(conv.id, !pinned);
                  _loadConversations();
                },
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                icon:
                    pinned
                        ? PhosphorIconsFill.pushPin
                        : PhosphorIconsRegular.pushPin,
                label: pinned ? '取消置顶' : '置顶',
              ),
              SlidableAction(
                onPressed: (_) {
                  HapticFeedback.selectionClick();
                  _showRenameConversationDialog(conv);
                },
                backgroundColor: scheme.surfaceContainerHighest,
                foregroundColor: scheme.onSurface,
                icon: PhosphorIconsRegular.pencilSimple,
                label: '重命名',
              ),
              SlidableAction(
                onPressed: (_) async {
                  HapticFeedback.mediumImpact();
                  await StorageService.deleteConversation(conv.id);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('已移到回收站'),
                      behavior: SnackBarBehavior.floating,
                      action: SnackBarAction(
                        label: '撤销',
                        onPressed: () async {
                          await StorageService.restoreConversation(conv.id);
                          _loadConversations();
                        },
                      ),
                    ),
                  );
                  _loadConversations();
                },
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
                icon: PhosphorIconsRegular.trash,
                label: '删除',
              ),
            ],
          ),
          // 置顶那档的淡底跟着背景走：贴了背景图时用从图里取的色相，
          // 没有就回落到主题的 primaryContainer（徽标棕）。
          //
          // 不这么做的话，粉色背景上会冒出一块棕色的置顶卡——整屏最重的
          // 一块，比「我想说」还抢。真机上一眼就看出来了。
          child: AppSurface(
            borderRadius: AppRadius.mdAll,
            solidColor: pinned ? _pinnedTint(context, scheme) : null,
            child: Material(
              color:
                  pinned
                      ? _pinnedTint(context, scheme).withValues(alpha: 0.55)
                      : Colors.transparent,
              elevation: 0,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                title: Text(
                  conv.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color:
                        pinned ? scheme.onPrimaryContainer : scheme.onSurface,
                  ),
                ),
                subtitle: Text(
                  '${conv.messageCount} 条消息 · ${_shortTime(conv.updatedAt)}',
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        pinned
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
                            : scheme.onSurfaceVariant,
                  ),
                ),
                // 只做状态标记，操作都在左滑里，所以不再可点
                trailing:
                    pinned
                        ? Icon(
                          PhosphorIconsFill.pushPin,
                          size: 16,
                          color: scheme.onPrimaryContainer.withValues(
                            alpha: 0.8,
                          ),
                        )
                        : null,
                onTap: () => _openConversation(conv.id),
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  _showRenameConversationDialog(conv);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 置顶卡片的淡底。贴了背景图就用从图里取的色相，否则回落到主题的
  /// primaryContainer（徽标棕）。
  ///
  /// 强调色只借背景的**色相**，饱和度和明度锁在固定档位（见
  /// `BackgroundProvider._analyze`）——这样换任何背景，它的视觉重量都一样，
  /// 不会有的图上跳出来、有的图上看不见。
  Color _pinnedTint(BuildContext context, ColorScheme scheme) {
    final accent = context.watch<BackgroundProvider>().backgroundAccent;
    if (accent == null) return scheme.primaryContainer;
    return accent.withValues(alpha: 0.22);
  }

  String _shortTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final isToday =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (isToday) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}/${local.day}';
  }

  Widget _buildInputArea(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_pendingImages.isNotEmpty) _pendingStrip(scheme),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: _buildTextField(theme)),
              const SizedBox(width: 8),
              // 右侧加号：拍照 / 相册 / 文件
              _circleToolButton(
                scheme,
                icon: PhosphorIconsRegular.plus,
                tooltip: '更多功能',
                onTap: _isLoading ? null : _showAttachmentMenu,
              ),
              const SizedBox(width: 6),
              // Send button
              _circleToolButton(
                scheme,
                icon:
                    _isLoading
                        ? PhosphorIconsRegular.hourglass
                        : PhosphorIconsRegular.paperPlaneTilt,
                tooltip: '发送',
                active: true,
                onTap: _isLoading ? null : _sendMessage,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 待发的图，横着排在输入框上方，每张右上角一个叉。
  ///
  /// 这条要在**发送之前**看得见、去得掉。没有它，「先选后发」只是把发送延后了，
  /// 用户还是没法确认自己选了什么、选错了也撤不回来。
  Widget _pendingStrip(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pendingImages.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            return Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Image.file(
                    File(_pendingImages[i].path),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  top: -6,
                  right: -6,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _pendingImages.removeAt(i)),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        // 半透明压在图上，比实色圆片轻——它是个次要动作，
                        // 不该比缩略图本身还抢眼。
                        color: scheme.surface.withValues(alpha: 0.82),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.outline.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Icon(
                        PhosphorIconsLight.x,
                        size: 11,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _circleToolButton(
    ColorScheme scheme, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: _maybeGlassCircle(
          size: 38,
          // 发送键是这一行唯一的主操作，实心强调色，不走玻璃——
          // 玻璃是「退到背景里」，而它要跳出来。
          glass: !active,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              // 「+」原来写死 Colors.white，深色模式下就是一颗白球——
              // 整屏最亮的东西是个次要按钮。交回给 scheme。
              color: active ? scheme.primary : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 20,
              color: active ? scheme.onPrimary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(ThemeData theme) {
    // 外面套一层 AppSurface：有背景图且开了玻璃就是毛玻璃，否则回落到实心卡片色。
    // TextField 自己不再上色（filled: false），不然玻璃上会盖一层不透明的底，
    // 白做一次模糊。
    return AppSurface(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: TextField(
        controller: _textController,
        focusNode: _focusNode,
        maxLines: 5,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        decoration: InputDecoration(
          hintText: '输入消息...',
          // 输入框只靠填充色成形，不描边。
          // 之前描边 + 聚焦态的深色粗边让一个空输入框成了整屏最重的元素，
          // 而这一行里真正该被强调的是右边的发送键。键盘弹起本身已经说明了聚焦。
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            borderSide: BorderSide.none,
          ),
          // 底色交给外面那层 AppSurface，这里必须透明。
          filled: false,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 10,
          ),
        ),
      ),
    );
  }
}
