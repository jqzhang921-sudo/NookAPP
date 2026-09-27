import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../services/backup_service.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/settings.dart';
import '../config/build_info.dart';
import '../services/ai_client.dart';
import '../services/external_mcp_service.dart';
import '../services/phone_tools/search_tool.dart';
import '../services/period_forecast.dart';
import '../services/period_log.dart';
import '../services/self_notes.dart';
import '../services/tts_service.dart';
import '../services/vision_service.dart';
import '../services/weread_service.dart';
import 'app_usage_screen.dart';
import 'music_screen.dart';
import 'tools_screen.dart';
import 'musing_corner_screen.dart';
import 'persona_screen.dart';
import '../widgets/background_sheet.dart';
import '../services/storage_service.dart';
import '../config/app_shape.dart';
import '../services/app_providers.dart';
import '../services/nudge_gate.dart';
import '../services/nudge_scheduler.dart';
import '../services/nudge_service.dart';
import '../services/screen_glance.dart';
import '../services/notify_name.dart';
import '../services/pet_state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<ApiKeyConfig> _configs = [];
  AppSettings _settings = AppSettings();
  bool _loading = true;
  String? _selectedProvider;

  /// 「对话模型」那一行该显示谁——**存下来的那个**，不是这页上正选着的那个。
  ///
  /// 两者不是一回事：点 chip 只是把输入框填上，没按「保存」就什么都没落地
  /// （见 [_selectConfig]）。原来那一行读的是输入框，于是光点一下 chip 就能
  /// 让它显示成 Claude，可真正发请求的客户端还是 MIMO——他看到的那行在骗他。
  /// 只在 [_load] 里更新：进了这页、或者按过保存之后，它才该变。
  String? _activeProvider;

  /// 有多少段对话设了自己的性格。
  ///
  /// 露出来是必须的：全局那个开关**管不到**这些对话（对话自己的优先级更高）。
  /// 不说的话，用户打开全局开关、发现有几段没跟着变，会以为是坏了。
  int _ownPersonaCount = 0;
  final _keyController = TextEditingController();
  final _endpointController = TextEditingController();
  final _modelController = TextEditingController();
  final _elevenKeyController = TextEditingController();
  final _elevenVoiceController = TextEditingController();
  final _tavilyKeyController = TextEditingController();
  final _visionKeyController = TextEditingController();
  bool _visionSectionExpanded = false;
  final _wereadKeyController = TextEditingController();
  final _userNameController = TextEditingController();
  final _aiNameController = TextEditingController();
  final _notifyRemarkController = TextEditingController();

  /// 通知里怎么称呼 TA，她自己起的备注。见 [NotifyName]。
  String _notifyRemark = '';

  /// 浮在界面上那只小猫露没露着。存在偏好设置里，不在 AppSettings——
  /// 它和「配色」「字体」不是一类东西，见 [PetState]。
  bool _petVisible = false;

  // 密钥默认打码，点小眼睛才明文——设置页经常被截图/投屏。
  bool _showApiKey = false;
  bool _showElevenKey = false;
  bool _showTavilyKey = false;
  bool _showWereadKey = false;

  bool _backupBusy = false;

  /// 「收藏的话」右侧那个计数，异步取一次
  int? _favoriteCount;

  /// 「聊天背景」右侧显示的当前档位
  String _backgroundLabel = '';

  Future<void> _exportBackup() async {
    setState(() => _backupBusy = true);
    try {
      final file = await BackupService.exportToFile();
      final size = (await file.length() / 1024).toStringAsFixed(0);
      await Share.shareXFiles([
        XFile(file.path),
      ], text: '手机 AI 助手数据备份（${size}KB，不含密钥）');
    } catch (e) {
      if (mounted) _snack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Future<void> _importBackup() async {
    final picked = await FilePicker.platform.pickFiles(withData: false);
    final path = picked?.files.single.path;
    if (path == null) return;

    if (!mounted) return;
    final replace = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('怎么导入？'),
            content: const Text(
              '合并：只补进本机没有的内容，现有的一律不动（推荐）。\n\n'
              '覆盖：同一条内容以备份里的为准，本机改动会被冲掉。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('覆盖'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('合并'),
              ),
            ],
          ),
    );
    if (replace == null) return;

    setState(() => _backupBusy = true);
    try {
      final raw = await File(path).readAsString();
      final summary = await BackupService.importBackup(
        jsonDecode(raw) as Map<String, dynamic>,
        replace: replace,
      );
      if (mounted) {
        _snack(
          '导入完成：对话 ${summary.conversations}、'
          '讨论 ${summary.bookConversations}、'
          '日记 ${summary.diaryEntries}、一隅 ${summary.musings}、'
          '书 ${summary.books}、信 ${summary.letters}。'
          '封面图和密钥需要重新加。',
        );
      }
    } on FormatException catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
    );
  }

  /// 密钥输入框右侧的「显示/隐藏」按钮。
  Widget _revealButton(bool visible, VoidCallback onToggle) {
    return IconButton(
      icon: Icon(
        visible ? PhosphorIconsRegular.eyeSlash : PhosphorIconsRegular.eye,
      ),
      tooltip: visible ? '隐藏' : '显示',
      onPressed: onToggle,
    );
  }

  // External MCP server state
  List<ExternalMcpServer> _externalServers = [];
  bool _showAddMcp = false;
  final _mcpNameController = TextEditingController();
  final _mcpUrlController = TextEditingController();
  final _mcpTokenController = TextEditingController();

  NudgePrefs _nudgePrefs = const NudgePrefs();
  // 「现在试一次」的结果原样显示出来。点了没反应的话，用户只会以为功能坏了——
  // 被门槛拦下、模型说没什么可说、没权限，这三种得分得清楚。
  String? _nudgeResult;
  bool _nudgeBusy = false;

  /// 「上次醒来 14:02 · 这会儿他手上没有事」。见 `NudgeService.lastRun`。
  String? _nudgeLastRun;

  /// 经期记录给不给它看。默认关着，见 [PeriodLog]。
  bool _periodShared = false;

  /// **预测**给不给它看。和上面那个是两件事，也默认关着。
  bool _periodForecastShared = false;

  /// 算出来的那份预测，给设置页显示。
  PeriodForecast _periodForecast = const PeriodForecast();

  /// 最近作废的便签。**过期是静默删除**，不摆出来的话，「过期了」和
  /// 「压根没触发」在她那边长得一模一样。
  List<String> _nudgeExpired = const [];

  /// 「好久没说话时，允许它看一眼屏幕」。见 [ScreenGlance]。
  bool _glanceAllowed = false;
  GlanceStatus? _glanceStatus;

  /// 「5 秒后试截一张」截到的图和说明。**只在这页上给她看**，不发给模型——
  /// 要试的是「它到底能看到什么」，不是「它会说什么」。
  Uint8List? _glanceTestBytes;
  String? _glanceTestNote;
  bool _glanceTesting = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadFavoriteCount();
    _loadOwnPersonaCount();
    _loadBackgroundLabel();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _endpointController.dispose();
    _modelController.dispose();
    _elevenKeyController.dispose();
    _elevenVoiceController.dispose();
    _tavilyKeyController.dispose();
    _visionKeyController.dispose();
    _wereadKeyController.dispose();
    _userNameController.dispose();
    _aiNameController.dispose();
    _notifyRemarkController.dispose();
    _mcpNameController.dispose();
    _mcpUrlController.dispose();
    _mcpTokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // await 之前先把 provider 取出来——之后 context 就可能失效了
    final settingsProvider = context.read<SettingsProvider>();
    _configs = await ApiKeyService.loadKeys();
    // ⚠️ 用 provider 手上那一份，不要自己再 load 一份。
    //
    // 原来这里是 `await AppSettings.load()`，于是设置页和 provider 拿着
    // **两个不同的对象**。改本地那份只写进 SharedPreferences，provider 和
    // MaterialApp 的主题都不知道——「主题预设」和「毛玻璃」按下去毫无反应，
    // 重启 App 才生效。改完还要叫一声 [SettingsProvider.touch]。
    _settings = settingsProvider.settings ?? await AppSettings.load();
    _elevenKeyController.text = _settings.elevenLabsApiKey;
    _elevenVoiceController.text = _settings.elevenLabsVoiceId;
    _tavilyKeyController.text = await SearchTool.getStoredKey() ?? '';
    _visionKeyController.text = await VisionService.getKey() ?? '';
    _wereadKeyController.text = await WereadService.getKey() ?? '';
    _userNameController.text = _settings.userName;
    _aiNameController.text = _settings.aiName;
    _notifyRemark = await NotifyName.remark();
    _petVisible = await PetState.visible();
    _notifyRemarkController.text = _notifyRemark;
    _externalServers = await ExternalMcpServerService.load();
    _nudgePrefs = await NudgeService.loadPrefs();
    _periodShared = await PeriodLog.sharedWithAi();
    _periodForecastShared = await PeriodLog.forecastSharedWithAi();
    _periodForecast = forecastFrom(await PeriodLog.list());

    // 「现在用的是哪一个」只问一次，下面两处都用这一个答案。
    //
    // 挑法和 [buildStoredAiClient] 用的是同一个函数——上面「对话模型」那一行
    // 显示的是它，真正拿去发请求的也是它，三处必须是同一个答案。所以这里存
    // 下来给 [_modelSummary] 用，别让它自己去猜「选中的那个」。
    final active = await ApiKeyService.pickActive(_configs);
    _activeProvider = active?.provider;

    // 只在首次打开时自动选中一个（避免每次保存后被跳走）。
    // 原来这里挑的是「第一个**没填** key 的」，本意是提醒他补上；可内置格式
    // 现在四个一直在，那样一进这页就跳到空白的那一项上去了。
    if (_selectedProvider == null && _configs.isNotEmpty) {
      _selectConfig(active ?? _configs.first);
    }

    setState(() => _loading = false);
  }

  void _selectConfig(ApiKeyConfig config) {
    _selectedProvider = config.provider;
    _keyController.text = config.apiKey ?? '';
    _endpointController.text = config.endpoint ?? '';
    _modelController.text = config.model ?? '';
    setState(() {});
  }

  Future<void> _saveCurrent() async {
    if (_selectedProvider == null) return;
    final config = ApiKeyConfig(
      provider: _selectedProvider!,
      name: _configs.firstWhere((c) => c.provider == _selectedProvider!).name,
      apiKey: _keyController.text.trim(),
      endpoint: _endpointController.text.trim(),
      model: _modelController.text.trim(),
    );
    await ApiKeyService.saveKey(config);
    await _load();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );

      // Update AI client in provider
      if (_keyController.text.trim().isNotEmpty) {
        final aiClient = AiClient(config: config);
        context.read<AiClientProvider>().setClient(aiClient);
      }
    }
  }

  Future<void> _pasteInto(TextEditingController c) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim();
    if (t != null && t.isNotEmpty) {
      c.text = t;
      setState(() {});
    }
  }

  Future<void> _saveTts() async {
    _settings.elevenLabsApiKey = _elevenKeyController.text.trim();
    _settings.elevenLabsVoiceId = _elevenVoiceController.text.trim();
    await _settings.save();
  }

  Future<void> _saveSettings() async {
    await _settings.save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设置已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          _group(theme, '我们', [
            _row(
              theme,
              asset: 'paw',
              title: '我',
              value: _settings.userName.isEmpty ? '未设置' : _settings.userName,
              primary: true,
              onTap:
                  () => _editName(
                    title: '你叫什么',
                    hint: '首页问候语怎么称呼你（留空则不带名字）',
                    controller: _userNameController,
                    apply: (v) => _settings.userName = v,
                  ),
            ),
            _row(
              theme,
              asset: 'cat',
              title: '你',
              value: _settings.aiName.isEmpty ? '未设置' : _settings.aiName,
              primary: true,
              onTap:
                  () => _editName(
                    title: 'TA 叫什么',
                    hint: '留空则信里不落款',
                    controller: _aiNameController,
                    apply: (v) => _settings.aiName = v,
                  ),
            ),
            // 通知标题上的称呼。和上面「你」分开：那个是它的名字、会进人设；
            // 这个只是她这边看通知的备注，像给联系人改备注。
            _row(
              theme,
              icon: PhosphorIconsRegular.bellSimple,
              title: '通知里怎么称呼 TA',
              value:
                  _notifyRemark.isNotEmpty
                      ? _notifyRemark
                      : (_settings.aiName.isNotEmpty ? _settings.aiName : '未设置'),
              onTap:
                  () => _editName(
                    title: '通知里怎么称呼 TA',
                    hint: '像给联系人改备注，留空就用 TA 的名字',
                    controller: _notifyRemarkController,
                    apply: (v) {
                      _notifyRemark = v;
                      NotifyName.setRemark(v);
                    },
                  ),
            ),
            _switchRow(
              theme,
              icon: PhosphorIconsRegular.textAa,
              title: '标题用宋体',
              subtitle: '关掉是黑体',
              value: _settings.titleSerif,
              onChanged: (v) {
                setState(() => _settings.titleSerif = v);
                context.read<SettingsProvider>().setTitleSerif(v);
              },
            ),
          ]),

          _group(theme, '模型与密钥', [
            _row(
              theme,
              icon: PhosphorIconsRegular.key,
              title: '对话模型',
              value: _modelSummary,
              primary: true,
              onTap: () => _openDetail('对话模型', _secModel),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.speakerHigh,
              title: '语音朗读',
              value:
                  _settings.ttsProvider == TtsProvider.elevenlabs
                      ? 'ElevenLabs'
                      : '系统',
              onTap: () => _openDetail('语音朗读', _secTts),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.eye,
              title: '视觉识图 · 联网搜索',
              value: _visionSearchSummary,
              onTap:
                  () => _openDetail(
                    '视觉识图 · 联网搜索',
                    (t, set) => [
                      ..._secVision(t, set),
                      const SizedBox(height: 24),
                      ..._secTavily(t, set),
                    ],
                  ),
            ),
          ]),

          _group(theme, '外观与陪伴', [
            // 2026-09-20 Cleo 要的「住在手机上的小生命」。**只在 App 里浮着**，
            // 不是系统悬浮窗——所以不要权限、不被后台策略管、也挡不到别的 App。
            // 默认关着：会一直挡在屏幕上的东西，得她自己打开。
            _switchRow(
              theme,
              icon: PhosphorIconsRegular.pawPrint,
              title: '那只小猫',
              subtitle: _petVisible ? '拖着换位置，长按收起来' : 'Mochi 浮在界面上陪着你',
              value: _petVisible,
              onChanged: (v) async {
                setState(() => _petVisible = v);
                await PetState.setVisible(v);
              },
            ),
            _row(
              theme,
              asset: 'cat',
              title: 'TA 的性格',
              subtitle:
                  _settings.persona.trim().isEmpty
                      ? '想让 TA 是什么样的'
                      : _clipOneLine(_settings.persona, 28),
              value:
                  _settings.persona.trim().isEmpty
                      ? ''
                      : (_settings.personaEnabled ? '开着' : '没启用'),
              onTap: _editGlobalPersona,
            ),
            // 开关只在写了东西之后才出现——空着的时候给一个开关，
            // 开了也什么都不会发生。
            if (_settings.persona.trim().isNotEmpty)
              _switchRow(
                theme,
                icon: PhosphorIconsRegular.usersThree,
                title: '所有对话都用这个',
                subtitle:
                    _ownPersonaCount > 0
                        ? '有 $_ownPersonaCount 段对话设了自己的性格，不受这里影响'
                        : '关掉的话，写的内容还留着',
                value: _settings.personaEnabled,
                onChanged: (v) async {
                  setState(() => _settings.personaEnabled = v);
                  await _settings.save();
                },
              ),
            _row(
              theme,
              icon: PhosphorIconsRegular.bellSimple,
              title: '主动说话',
              subtitle: '它自己想起什么的时候，发一条通知',
              value: _nudgePrefs.enabled ? '开着' : '关着',
              onTap:
                  () => _openDetail('主动说话', (t, set) => _secNudge(t, set)),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.drop,
              title: '经期记录',
              subtitle: '记在日子那一页上，长按某天标记',
              value:
                  !_periodShared
                      ? '只有你看得到'
                      : _periodForecastShared
                      ? '它知道，也知道快到了'
                      : '它知道',
              onTap: () => _openDetail('经期记录', _secPeriod),
            ),
            _themePicker(theme),
            _row(
              theme,
              asset: 'waves',
              title: '聊天背景',
              value: _backgroundLabel,
              primary: true,
              onTap: () async {
                // 在任何 await 之前取——之后 context 就可能失效了。
                final bgProvider = context.read<BackgroundProvider>();
                final changed = await showBackgroundSheet(context);
                await _loadBackgroundLabel();
                // 改完必须通知 BackgroundProvider 重新解析——它算的
                // darkForeground / 强调色 / busyness 全靠这一下。
                //
                // 原来这里只刷新了本页那行标签，provider 完全不知道背景变了：
                // 图存进去了，但 bg.path 还是 null，玻璃表面据此判定「没有背景图」
                // 一直走实心分支。症状是「设了背景却毫无反应」，重启 App 才生效
                // （home_shell.initState 会重读一次）。
                //
                // 聊天页那条路径一直是对的（onBackgroundChanged 回调），
                // 只有设置页这条漏了。
                if (!changed || !mounted) return;
                final path = await StorageService.getBackgroundImagePath();
                final preset = await StorageService.getBackgroundPreset();
                await bgProvider.update(path, preset);
              },
            ),
            _row(
              theme,
              asset: 'flower',
              title: '收藏的话',
              value: _favoriteCount == null ? '' : '$_favoriteCount 条',
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MusingCornerScreen()),
                );
                _loadFavoriteCount();
              },
            ),
            _switchRow(
              theme,
              asset: 'flower',
              // 名字跟着设置走。写死一个名字的话，用户在上面「你」那一栏
              // 改了称呼，这个开关的标题还停在旧名字上。
              title:
                  _settings.aiName.trim().isEmpty
                      ? '让 TA 自己收藏'
                      : '让${_settings.aiName.trim()}自己收藏',
              subtitle: '它回看对话时，挑一两句留下',
              value: _settings.aiSelfFavorite,
              onChanged: (v) async {
                setState(() => _settings.aiSelfFavorite = v);
                await _settings.save();
              },
            ),
            _row(
              theme,
              asset: 'sun',
              title: '深色模式',
              value: _themeModeLabel,
              onTap: _pickThemeMode,
            ),
            // 玻璃不是「深色模式」的第四档——深浅和「表面透不透」是两个维度，
            // 玻璃可以配深色也可以配浅色，所以单独一个开关。
            //
            // 副标题按有没有背景图分两种说法：没图的时候必须把前提讲在前面，
            // 否则用户打开之后会觉得「怎么没变化」——那时候底下是一整块纯色，
            // 糊它得到的还是同一个颜色。
            _switchRow(
              theme,
              icon: PhosphorIconsRegular.drop,
              title: '毛玻璃',
              subtitle:
                  context.watch<BackgroundProvider>().path == null
                      ? '要先选一张背景图才看得出效果'
                      : '卡片半透明，透出底下的背景',
              value: _settings.glassSurface,
              onChanged: (v) async {
                setState(() => _settings.glassSurface = v);
                await _settings.save();
                if (context.mounted) {
                  context.read<SettingsProvider>().touch();
                }
              },
            ),
          ]),

          _group(theme, '手机能力', [
            _row(
              theme,
              icon: PhosphorIconsRegular.wrench,
              title: '已注册的工具',
              subtitle: 'AI 能调用哪些手机能力',
              primary: true,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ToolsScreen()),
                  ),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.hourglassMedium,
              title: '它能知道你在用什么',
              subtitle: '只有 app 名字和时长，没有内容',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AppUsageScreen()),
                  ),
            ),
            // 紧挨着上面那条放：两条都是「感知」类，而且都是**系统权限要不来、
            // 得你自己去设置里开**的那种。放一起她一眼能看明白这一组是什么。
            _row(
              theme,
              icon: PhosphorIconsRegular.musicNotes,
              title: '一起听',
              subtitle: '能看到你在放什么歌，也能帮你切',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MusicScreen()),
                  ),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.wifiHigh,
              title: 'MCP 服务器',
              value:
                  _settings.serverEnabled
                      ? '端口 ${_settings.webSocketPort}'
                      : '已关闭',
              onTap:
                  () => _openDetail(
                    'MCP 服务器',
                    (t, set) => [
                      ..._secMcp(t, set),
                      const SizedBox(height: 24),
                      ..._secMcpExt(t, set),
                    ],
                  ),
            ),
            _row(
              theme,
              icon: PhosphorIconsRegular.calendarBlank,
              title: '查看日历',
              subtitle: '日历内容会发给模型',
              value: switch (_settings.calendarAccess) {
                CalendarAccess.ask => '每次询问',
                CalendarAccess.always => '一直允许',
                CalendarAccess.never => '不允许',
              },
              onTap: _pickCalendarAccess,
            ),
            _row(
              theme,
              asset: 'books',
              title: '微信读书',
              value: _wereadKeyController.text.isEmpty ? '未配置' : '已配置',
              onTap: () => _openDetail('微信读书', _secWeread),
            ),
          ]),

          _group(theme, '数据', [
            _row(
              theme,
              icon: PhosphorIconsRegular.floppyDisk,
              title: '备份与恢复',
              subtitle: '导出 / 导入 json，不含密钥',
              onTap: () => _openDetail('备份与恢复', _secBackup),
            ),
          ]),

          const SizedBox(height: 28),
          Center(
            child: Text(
              '手机 AI 助手 · v1.0.0 · build $buildCommit',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 分组容器与行 ──────────────────────────────────────────────
  //
  // 原来是 11 个平铺的 _sectionHeader 一路铺到底，1000 行直筒清单，
  // 找一个开关得从头滚到尾。现在收成几组：主列表只放「叫什么名字、
  // 用哪个模型、开没开」这种一眼要看的结论，密钥、endpoint、端口这些
  // 填一次就不再动的，全收进二级页。

  /// 组标题在容器外，容器本身是圆角白卡 + 柔光。

  /// 主题四格。每格是那套主题的一个缩影：底色 = surface，左上一枚主色方块，
  /// 底部两条色带。
  ///
  /// 贴了背景图（且开着毛玻璃）时配色由图决定，这时四格**灰掉但不隐藏**——
  /// 藏起来用户会以为功能没了，灰掉才看得出「它还在，只是现在不生效」。
  /// 这条是设计交付里写死的互斥规矩。
  Widget _themePicker(ThemeData theme) {
    final scheme = theme.colorScheme;
    final byImage =
        _settings.glassSurface &&
        context.watch<BackgroundProvider>().path != null;

    final grid = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final id in AppThemeId.values) ...[
          if (id != AppThemeId.values.first) const SizedBox(width: 9),
          Expanded(child: _themeCell(theme, id)),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          byImage
              ? Opacity(opacity: 0.42, child: IgnorePointer(child: grid))
              : grid,
          if (byImage) ...[
            const SizedBox(height: 10),
            Text(
              '配色由背景图决定，移除背景可回到预设',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _themeCell(ThemeData theme, AppThemeId id) {
    // 格子预览的是**当前深浅下**那套主题长什么样，所以跟着 theme.brightness。
    final s = AppTheme.schemeOf(theme.brightness, id.tone);
    final selected = _settings.themeId == id;

    // 设计稿写的两条色带是 primaryContainer / surfaceContainerLow。
    // 但浅色下 surfaceContainerLow 是纯白、surface 是奶白，两条几乎一样，
    // 摆在格子里等于只有一条。第二条改用 secondary，看得出这套主题的性格。
    Widget band(Color c) => Container(
      height: 6,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(3),
      ),
    );

    return GestureDetector(
      onTap:
          selected
              ? null
              : () async {
                setState(() => _settings.themeId = id);
                await _settings.save();
                if (mounted) context.read<SettingsProvider>().touch();
              },
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: s.surface,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: selected ? s.primary : theme.colorScheme.outlineVariant,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Stack(
                children: [
                  Container(
                    width: 15,
                    height: 15,
                    decoration: BoxDecoration(
                      color: s.primary,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  if (selected)
                    Align(
                      alignment: Alignment.topRight,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: s.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          PhosphorIconsBold.check,
                          size: 11,
                          color: s.onPrimary,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Column(
                      children: [
                        band(s.primaryContainer),
                        const SizedBox(height: 4),
                        band(s.secondary),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            id.label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color:
                  selected
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 「主动说话」详情页。
  ///
  /// 这一版**没有接后台唤醒**，只有开关、几个数、和一个「现在试一次」。
  /// 顺序是故意的：先在手动触发下把内容和分寸调顺，再谈让它自己跑——
  /// ColorOS 上后台本来就不保证准时，内容这层必须能独立成立。
  /// 经期那一页只有一个开关：给不给它看。**记录本身在日子那一页上做**——
  /// 设置管开关，页面管操作，这个分工全项目一致。
  List<Widget> _secPeriod(ThemeData theme, StateSetter set) {
    final scheme = theme.colorScheme;
    return [
      Text(
        '在「日子」那一页长按某天，标记这天来了或者结束了。'
        '记完那几天的格子上会有个印子。第一版只记不测——'
        '周期规律要三四个月才看得出来，这之前的预测基本是瞎猜，'
        '而瞎猜的日期画在日历上比不画更烦。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 20),
      Text('下次大概什么时候', style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      Text(
        _forecastLine(),
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        '日历上那几天画成**空心圈**，和实际记录的实底色分得开——'
        '实心是发生过的，空心是算出来的。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      ),
      const SizedBox(height: 20),
      _switchRow(
        theme,
        icon: PhosphorIconsRegular.chatCircle,
        title: '让它知道',
        subtitle: '只在正当口那几天，只在聊天里',
        value: _periodShared,
        onChanged: (v) async {
          await PeriodLog.setSharedWithAi(v);
          if (!v) await PeriodLog.setForecastSharedWithAi(false);
          set(() {
            _periodShared = v;
            if (!v) _periodForecastShared = false;
          });
        },
      ),
      // 单独一个开关，不跟着上面那个一起开：「她这几天不舒服」和
      // 「她还有三天要来」是两个量级——后者是它拿着一份关于她身体的日程表。
      _switchRow(
        theme,
        icon: PhosphorIconsRegular.calendarDots,
        title: '也让它知道快到了',
        subtitle:
            _periodShared ? '只提前三天，再往前就是日程表了' : '要先打开上面那个',
        value: _periodForecastShared,
        onChanged:
            !_periodShared
                ? (_) {}
                : (v) async {
                  await PeriodLog.setForecastSharedWithAi(v);
                  set(() => _periodForecastShared = v);
                },
      ),
      const SizedBox(height: 10),
      Text(
        '开着的时候，它在聊天里知道你这几天不舒服，说话的分寸会软一点。'
        '不在经期的日子它什么都看不到，也看不到「上次是什么时候」。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text(
          '⚠️ 这件事**不会进通知**。主动推送那句话是它现写的，原样上锁屏——'
          '所以写通知的时候它手上根本没有这个数据，漏不了。'
          '这是代码里切开的，不是叮嘱它别说。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        '备份里带着这些记录（换手机不至于从头记），但**开关不带**——'
        '恢复之后默认是关的，要不要给它看，换台机器就重新决定一次。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      ),
    ];
  }

  /// 预测那一行说什么。**每种情况都要说得清为什么**——
  /// 「没算出来」和「算出来了但估不准」是两回事，下一步动作也不一样。
  String _forecastLine() {
    final f = _periodForecast;
    if (f.notEnough) {
      return '记满三个周期才开始估——两次之间只有一个间隔，'
          '看不出你晃不晃，而晃的幅度恰恰是这里最有用的那个数。';
    }
    if (f.irregular) {
      return '最近几次的间隔差得比较多（中位数 ${f.medianCycle} 天），'
          '推出来的区间已经宽到没什么用，就不画了。'
          '这是在说这份数据没法推，不是在说你怎么了。';
    }
    if (f.stale) {
      return '上一次记录之后已经过了预计的那几天了。'
          '是漏记了还是这次晚了，这儿分不出来——记一下就接着算。';
    }
    if (!f.hasWindow) return '还没有可以推的记录。';

    final a = f.from!;
    final b = f.to!;
    final range =
        a == b
            ? '${a.month} 月 ${a.day} 日'
            : a.month == b.month
                ? '${a.month} 月 ${a.day}–${b.day} 日'
                : '${a.month} 月 ${a.day} 日 到 ${b.month} 月 ${b.day} 日';
    final len = f.medianLength == null ? '' : '，一次大概 ${f.medianLength} 天';
    return '大概 $range。周期中位数 ${f.medianCycle} 天$len'
        '（按最近 ${f.cycles.length} 次算的）。';
  }

  /// 「主动说话」里的一段：好久没说话时，允许它看一眼屏幕。
  ///
  /// 两道开关，**缺一道都不看**：系统无障碍里的服务（权限）和这里的开关（意愿）。
  /// 状态每次重建都重读——她从系统设置页回来，这页得立刻对上。
  List<Widget> _secGlance(ThemeData theme, StateSetter set) {
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    Future<void> refresh() async {
      final s = await ScreenGlance.status();
      final a = await ScreenGlance.allowed();
      if (!mounted) return;
      final old = _glanceStatus;
      if (a != _glanceAllowed ||
          old == null ||
          old.supported != s.supported ||
          old.enabled != s.enabled ||
          old.bound != s.bound) {
        set(() {
          _glanceAllowed = a;
          _glanceStatus = s;
        });
      }
    }

    refresh();

    final s = _glanceStatus;
    final String statusLine;
    if (s == null) {
      statusLine = '正在看无障碍那边开没开…';
    } else if (!s.supported) {
      statusLine = '这台手机的系统版本不支持（要安卓 11 以上）';
    } else if (!s.enabled) {
      statusLine = '无障碍里的「让它看一眼屏幕」还没开';
    } else if (!s.bound) {
      statusLine = '无障碍里开着，但系统这会儿没把它拉起来——关掉再打开一次试试';
    } else {
      statusLine = '无障碍那边开好了';
    }

    return [
      const SizedBox(height: 24),
      Text('看一眼屏幕', style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      _switchRow(
        theme,
        icon: PhosphorIconsRegular.eye,
        title: '好久没说话时，允许它看一眼',
        subtitle: statusLine,
        value: _glanceAllowed,
        onChanged: (v) async {
          // 无障碍还没开就先把她送过去。开关照样打开：回来不用再点一次，
          // 没开好之前反正也看不了（原生那边查得到）。
          if (v && !(_glanceStatus?.ready ?? false)) {
            await ScreenGlance.openSettings();
          }
          await ScreenGlance.setAllowed(v);
          set(() => _glanceAllowed = v);
        },
      ),
      const SizedBox(height: 6),
      Text(
        '你们 3 个小时没说话、手机亮着没锁、你不在排除名单里的 App 里时，'
        '它醒来会自己决定要不要看。看了，那张图一定会留在对话里；'
        '看了不想说、或者没看成，都记在上面「上次」那一行。'
        '支付、输密码这类页面系统本来就不让截。',
        style: muted,
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            icon: const Icon(PhosphorIconsRegular.gearSix, size: 16),
            label: const Text('无障碍设置'),
            onPressed: ScreenGlance.openSettings,
          ),
          OutlinedButton.icon(
            icon: const Icon(PhosphorIconsRegular.eyeSlash, size: 16),
            label: const Text('排除名单'),
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AppUsageScreen()),
                ),
          ),
          FilledButton.tonalIcon(
            icon:
                _glanceTesting
                    ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(PhosphorIconsRegular.camera, size: 16),
            label: Text(_glanceTesting ? '5 秒后截…' : '5 秒后试截一张'),
            onPressed:
                _glanceTesting
                    ? null
                    : () async {
                      set(() {
                        _glanceTesting = true;
                        _glanceTestBytes = null;
                        _glanceTestNote = null;
                      });
                      // 5 秒给她切到别的 App——在这页上截，截到的只会是设置页，
                      // 而且会被「你就在 App 里」那条拦下。
                      await Future.delayed(const Duration(seconds: 5));
                      final shot = await ScreenGlance.capture();
                      if (!mounted) return;
                      final bytes = shot.bytes;
                      set(() {
                        _glanceTesting = false;
                        _glanceTestBytes = bytes;
                        _glanceTestNote =
                            shot.ok && bytes != null
                                ? '截到了${shot.appName == null ? '' : '（${shot.appName}）'}，'
                                    '${(bytes.length / 1024).round()}KB。'
                                    '这张只在这里给你看，没发给它。'
                                : '没截到：${(shot.miss ?? GlanceMiss.failed).label}';
                      });
                    },
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text('点完切到别的 App，等 5 秒再回来，就能看到它会看到什么。', style: muted),
      if (_glanceTestNote != null) ...[
        const SizedBox(height: 10),
        Text(_glanceTestNote!, style: theme.textTheme.bodySmall),
      ],
      if (_glanceTestBytes != null) ...[
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(
            _glanceTestBytes!,
            height: 360,
            fit: BoxFit.contain,
          ),
        ),
      ],
    ];
  }

  List<Widget> _secNudge(ThemeData theme, StateSetter set) {
    final scheme = theme.colorScheme;

    // 每次重建这一页都重读一次：后台可能在她没看的时候跑过好几轮。
    // 只在内容真变了时才 set，否则会自己触发自己。
    NudgeService.lastRun().then((r) {
      if (r == null || !mounted) return;
      final (at, outcome) = r;
      final t =
          '${at.hour.toString().padLeft(2, '0')}:'
          '${at.minute.toString().padLeft(2, '0')}';
      final next = '$t · $outcome';
      if (_nudgeLastRun != next) set(() => _nudgeLastRun = next);
    });

    SelfNoteStore.recentlyExpired().then((rows) {
      if (!mounted) return;
      final next = [
        for (final (at, about) in rows)
          '${at.month}/${at.day} '
              '${at.hour.toString().padLeft(2, '0')}:'
              '${at.minute.toString().padLeft(2, '0')} · $about',
      ];
      if (_nudgeExpired.join('|') != next.join('|')) {
        set(() => _nudgeExpired = next);
      }
    });

    Future<void> save(NudgePrefs next) async {
      _nudgePrefs = next;
      await NudgeService.savePrefs(next);
      set(() {});
      if (mounted) setState(() {});
    }

    return [
      _switchRow(
        theme,
        icon: PhosphorIconsRegular.bellSimple,
        title: '让它主动说话',
        subtitle: '关着的时候，下面这些设置都不起作用',
        value: _nudgePrefs.enabled,
        onChanged: (v) async {
          // 开之前先要权限。先存后要的话，开关是开的、通知发不出去，
          // 看起来就像功能坏了。
          if (v && !await NudgeService.ensurePermission()) {
            set(() => _nudgeResult = '系统没给通知权限，得去系统设置里打开');
            return;
          }
          await save(_nudgePrefs.copyWith(enabled: v));
          // 开关同时管后台那条周期任务。只存偏好不动任务的话，关掉之后
          // 后台还在跑，只是每次都在第一步返回——白耗电。
          try {
            v ? await NudgeScheduler.enable() : await NudgeScheduler.disable();
          } catch (e) {
            set(() => _nudgeResult = '后台任务没排上：$e');
          }
        },
      ),
      const SizedBox(height: 8),
      // 这里**故意没有「一天最多几条」**。配额会倒过来变成产出指标：
      // 今天还剩两条没用，就凑两条出来。频率该由「有没有事情发生」决定。
      Text(
        '他写完一封信、记了一篇日记，或者翻到板上你贴的一张纸条，'
        '那才是他想说话的时候。没有这样的事，就什么都不会发生——'
        '所以这里没有「一天几条」可以调。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 16),
      Text('这段时间里不打扰', style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      Row(
        children: [
          _hourPicker(
            _nudgePrefs.quietStartHour,
            (h) => save(_nudgePrefs.copyWith(quietStartHour: h)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('到'),
          ),
          _hourPicker(
            _nudgePrefs.quietEndHour,
            (h) => save(_nudgePrefs.copyWith(quietEndHour: h)),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        '跨零点没问题（比如 23 点到 8 点）。两个数一样 = 不设静默。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      const SizedBox(height: 16),
      // 上面那些管的是「要不要打扰你」，这条管的是「别人会不会看见」。
      _switchRow(
        theme,
        icon: PhosphorIconsRegular.eyeSlash,
        title: '通知里不显示内容',
        subtitle: '锁屏上只写「说了句话」。话本身照常在对话里，一个字不少',
        value: _nudgePrefs.hideContent,
        onChanged: (v) => save(_nudgePrefs.copyWith(hideContent: v)),
      ),

      ..._secGlance(theme, set),

      const SizedBox(height: 24),
      Text('试一次', style: theme.textTheme.labelLarge),
      const SizedBox(height: 6),
      Text(
        '跳过时间限制，但不跳过「有没有事发生」——手动点也不会凭空造一条出来，'
        '否则试出来的东西和它平时的行为对不上。'
        '多半会告诉你「没有由头」，那是对的，不是坏了。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        icon:
            _nudgeBusy
                ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(PhosphorIconsRegular.paperPlaneTilt, size: 16),
        label: Text(_nudgeBusy ? '问它…' : '现在试一次'),
        onPressed:
            _nudgeBusy
                ? null
                : () async {
                  // await 之前取，之后 context 可能已经失效。
                  final client =
                      context.read<AiClientProvider>().currentClient;
                  if (client == null) {
                    set(() => _nudgeResult = '还没配好模型');
                    return;
                  }
                  set(() {
                    _nudgeBusy = true;
                    _nudgeResult = null;
                  });
                  final r = await NudgeService.run(
                    aiClient: client,
                    force: true,
                  );
                  set(() {
                    _nudgeBusy = false;
                    _nudgeResult = r.sent ? '推出去了：${r.text}' : r.message;
                  });
                },
      ),
      // 后台那条路看不到日志（国产 ROM 封了非调试包的 logcat），而聊天里那个
      // 模型看不到后台、你问它它会顺着话编一个原因。所以这一行是这个功能
      // 唯一的证据：它上次醒来到底干了什么。
      if (_nudgeLastRun != null) ...[
        const SizedBox(height: 16),
        Text('上次醒来', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Text(
          _nudgeLastRun!,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
      // 到点了没人来取，便签就作废了——这条路以前不留任何痕迹，
      // 于是「过期了」和「压根没醒过」看起来一模一样。
      if (_nudgeExpired.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('没等到就作废的便签', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Text(
          _nudgeExpired.reversed.join('\n'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '这些是它记下来、到点却没赶上说出口的。'
          '偶尔一条正常；老是这样就是后台被系统掐得太狠了。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ],
      if (_nudgeResult != null) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(_nudgeResult!, style: theme.textTheme.bodySmall),
        ),
      ],

      const SizedBox(height: 24),
      Text(
        '开着的时候，系统大约每 15 分钟给它一次「看看有没有事」的机会，'
        '关着 App 也算。绝大多数次什么都不会发生。\n\n'
        '⚠️ 手机的省电策略会掐后台任务，所以这条不保证准时——'
        '要它靠谱，得在系统设置里给这个 App 开「自启动」和「后台运行」。'
        '就算被掐了也不会丢：攒下的事会在你下次打开 App 时补上。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  Widget _hourPicker(int value, ValueChanged<int> onChanged) {
    return DropdownButton<int>(
      value: value,
      onChanged: (v) => v == null ? null : onChanged(v),
      items: [
        for (var h = 0; h < 24; h++)
          DropdownMenuItem(value: h, child: Text('$h 点')),
      ],
    );
  }

  Widget _group(ThemeData theme, String title, List<Widget> rows) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(
          Divider(
            height: 1,
            thickness: 1,
            // 从底座右缘起，不通栏——通栏的线会把一组切成几块
            indent: 56,
            endIndent: 14,
            color: scheme.outlineVariant,
          ),
        );
      }
      children.add(rows[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              boxShadow: AppShadow.soften(dark),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  /// 品牌图标按视觉重量给高度，不要统一成一个数。
  static const Map<String, double> _assetHeight = {
    'cat': 17,
    'books': 15,
    'mountain': 13,
    'flower': 17,
    'waves': 13,
    'star': 16,
    'paw': 14,
    'sun': 15,
  };

  Widget _iconBase(
    ThemeData theme, {
    String? asset,
    IconData? icon,
    required bool primary,
  }) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fg =
        primary
            ? scheme.primary
            : (dark ? scheme.onSurface : const Color(0xFF463F37));
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            primary
                ? scheme.primary.withValues(alpha: 0.11)
                : scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(11),
      ),
      child:
          asset != null
              ? Image.asset(
                'assets/icons/$asset.png',
                height: _assetHeight[asset] ?? 16,
                color: fg,
              )
              : Icon(icon, size: 17, color: fg),
    );
  }

  Widget _row(
    ThemeData theme, {
    String? asset,
    IconData? icon,
    required String title,
    String? subtitle,
    String? value,
    bool primary = false,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
        child: Row(
          children: [
            _iconBase(theme, asset: asset, icon: icon, primary: primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (value != null && value.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Icon(
              PhosphorIconsRegular.caretRight,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow(
    ThemeData theme, {
    IconData? icon,
    String? asset,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
      child: Row(
        children: [
          _iconBase(theme, asset: asset, icon: icon, primary: false),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  /// 二级页。内容还是原来那些 widget，只是搬进了自己的一屏。
  ///
  /// `set` 同时刷新二级页和主列表——主列表右侧要显示当前值，
  /// 在二级页里改完退回来必须是新的。
  void _openDetail(
    String title,
    List<Widget> Function(ThemeData, StateSetter) body,
  ) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder:
                (_) => Scaffold(
                  appBar: AppBar(title: Text(title)),
                  body: StatefulBuilder(
                    builder:
                        (ctx, set) => ListView(
                          padding: const EdgeInsets.all(16),
                          children: body(Theme.of(ctx), (fn) {
                            set(fn);
                            if (mounted) setState(() {});
                          }),
                        ),
                  ),
                ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  Future<void> _editName({
    required String title,
    required String hint,
    required TextEditingController controller,
    required void Function(String) apply,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    if (result == null) return;
    apply(result);
    await _settings.save();
    if (mounted) setState(() {});
  }

  String get _themeModeLabel => switch (_settings.themeMode) {
    ThemeMode.light => '常关',
    ThemeMode.dark => '常开',
    ThemeMode.system => '跟随系统',
  };

  Future<void> _pickCalendarAccess() async {
    const labels = {
      CalendarAccess.ask: ('每次询问', '每次它想看日历都问你一句'),
      CalendarAccess.always: ('一直允许', '不再打扰，它随时能看'),
      CalendarAccess.never: ('不允许', '工具直接拒绝，看不到'),
    };
    final picked = await showModalBottomSheet<CalendarAccess>(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in labels.entries)
                  ListTile(
                    title: Text(entry.value.$1),
                    subtitle: Text(entry.value.$2),
                    trailing:
                        _settings.calendarAccess == entry.key
                            ? const Icon(PhosphorIconsRegular.check, size: 20)
                            : null,
                    onTap: () => Navigator.of(ctx).pop(entry.key),
                  ),
              ],
            ),
          ),
    );
    if (picked == null) return;
    setState(() => _settings.calendarAccess = picked);
    await _settings.save();
  }

  Future<void> _pickThemeMode() async {
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in ThemeMode.values)
                  ListTile(
                    title: Text(switch (m) {
                      ThemeMode.light => '常关',
                      ThemeMode.dark => '常开',
                      ThemeMode.system => '跟随系统',
                    }),
                    trailing:
                        _settings.themeMode == m
                            ? const Icon(PhosphorIconsRegular.check, size: 20)
                            : null,
                    onTap: () => Navigator.of(ctx).pop(m),
                  ),
              ],
            ),
          ),
    );
    if (picked == null) return;
    setState(() => _settings.themeMode = picked);
    await _settings.save();
    if (mounted) context.read<SettingsProvider>().setThemeMode(picked);
  }

  /// 「对话模型」那一行显示什么。
  ///
  /// 读的是**存下来的那个**（[_activeProvider]），不是这页上正选着的那个。
  /// 点一下 chip 只是把输入框填上，不落盘（见 [_selectConfig]），拿输入框当
  /// 答案的话，光点一下就能让这一行显示成 Claude，可真正发请求的还是原来那个
  /// ——这一行在骗他，而且骗法很难发现：重新进一次设置页又变回去了。
  String get _modelSummary {
    final active =
        _configs.where((c) => c.provider == _activeProvider).firstOrNull;
    if (active == null) return '未选择';
    // 模型名优先，没填过才退回格式名。原来那条兜底给的是 `_selectedProvider`
    // （`openai` 这种内部代号），摆给用户看不如「OpenAI」。
    final name = (active.model ?? '').isNotEmpty ? active.model! : active.name;
    return (active.apiKey ?? '').isEmpty ? '$name · 缺密钥' : name;
  }

  String get _visionSearchSummary {
    final vision = _visionKeyController.text.isNotEmpty;
    final search = _tavilyKeyController.text.isNotEmpty;
    if (vision && search) return '都已配置';
    if (search) return '仅联网';
    if (vision) return '仅识图';
    return '未配置';
  }

  Future<void> _loadBackgroundLabel() async {
    final path = await StorageService.getBackgroundImagePath();
    final preset = await StorageService.getBackgroundPreset();
    if (!mounted) return;
    setState(() {
      _backgroundLabel =
          path != null
              ? '自定义图片'
              : switch (preset) {
                'light' => '浅色',
                'dark' => '深色',
                _ => '跟随主题',
              };
    });
  }

  Future<void> _editGlobalPersona() async {
    final result = await Navigator.of(context).push<PersonaResult>(
      MaterialPageRoute(
        builder:
            (_) => PersonaScreen(initial: _settings.persona, isGlobal: true),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _settings.persona = result.text;
      // 清空了就顺手关掉开关：留着一个开着、但底下什么都没有的开关，
      // 用户会以为还在生效。
      if (result.text.isEmpty) _settings.personaEnabled = false;
    });
    await _settings.save();
  }

  Future<void> _loadOwnPersonaCount() async {
    try {
      // 索引里只留了「有没有人格」这一个布尔值——这里就是那个唯一的用处，
      // 没必要为它把每段对话的 systemPrompt 全文都读进内存。
      final convs = await StorageService.listConversationSummaries();
      final n = convs.where((c) => c.hasSystemPrompt).length;
      if (!mounted) return;
      setState(() => _ownPersonaCount = n);
    } catch (e) {
      debugPrint('[settings] 数不出有几段对话设了自己的性格：$e');
    }
  }

  Future<void> _loadFavoriteCount() async {
    final list = await StorageService.listFavoritedMusings();
    if (mounted) setState(() => _favoriteCount = list.length);
  }

  List<Widget> _secModel(ThemeData theme, StateSetter set) {
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            _configs.map((config) {
              final selected = config.provider == _selectedProvider;
              return ChoiceChip(
                label: Text(config.name),
                selected: selected,
                onSelected: (_) {
                  _selectConfig(config);
                  // 这一页是 push 出来的独立路由，`_selectConfig` 里那句
                  // setState 只重建设置页自己——**勾不会跟着走**。下面三个
                  // 输入框是 controller 直接改文字的，照常会变，于是看起来
                  // 就像「点是点动了，但选中的还是原来那个」。得叫一声这一层
                  // 的 set，这页才会重画。
                  set(() {});
                },
              );
            }).toList(),
      ),
      const SizedBox(height: 16),

      if (_selectedProvider != null) ...[
        _buildConfigFields(),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saveCurrent,
          icon: const Icon(PhosphorIconsRegular.floppyDisk),
          label: const Text('保存 API 配置'),
        ),
      ],
    ];
  }

  List<Widget> _secVision(ThemeData theme, StateSetter set) {
    return [
      // 视觉识图（可选）——默认收起，只有当前主模型不支持看图时才需要
      Card(
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(PhosphorIconsRegular.eye),
              title: const Text('视觉识图（可选）'),
              subtitle: const Text(
                '如果你的对话模型本身就支持看图（比如 GPT-4o、Claude 等），不用配置这个',
              ),
              trailing: Icon(
                _visionSectionExpanded
                    ? PhosphorIconsRegular.caretUp
                    : PhosphorIconsRegular.caretDown,
              ),
              onTap: () {
                set(() => _visionSectionExpanded = !_visionSectionExpanded);
              },
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState:
                  _visionSectionExpanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '只有当前主模型不认识图片、需要单独一个能看图的模型来帮忙描述时，才需要填这里。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _visionKeyController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '视觉模型 API Key',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await VisionService.saveKey(
                          _visionKeyController.text.trim(),
                        );
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('已保存'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      icon: const Icon(PhosphorIconsRegular.floppyDisk),
                      label: const Text('保存视觉模型 Key'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _secTavily(ThemeData theme, StateSetter set) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: TextField(
          controller: _tavilyKeyController,
          obscureText: !_showTavilyKey,
          decoration: InputDecoration(
            labelText: 'Tavily API Key',
            hintText: 'tavily.com → Dashboard → API Keys',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _revealButton(
                  _showTavilyKey,
                  () => set(() => _showTavilyKey = !_showTavilyKey),
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.floppyDisk),
                  tooltip: '保存',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await SearchTool.saveKey(_tavilyKeyController.text.trim());
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('Tavily Key 已保存'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _secTts(ThemeData theme, StateSetter set) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Text('语音来源'),
            const Spacer(),
            SegmentedButton<TtsProvider>(
              segments: const [
                ButtonSegment(value: TtsProvider.system, label: Text('系统(免费)')),
                ButtonSegment(
                  value: TtsProvider.elevenlabs,
                  label: Text('ElevenLabs'),
                ),
              ],
              selected: {_settings.ttsProvider},
              onSelectionChanged: (s) {
                set(() => _settings.ttsProvider = s.first);
                _settings.save();
              },
            ),
          ],
        ),
      ),
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: const Text('自动朗读 AI 回复'),
        subtitle: const Text('收到回复后自动播放语音'),
        value: _settings.ttsAutoPlay,
        onChanged: (v) {
          set(() => _settings.ttsAutoPlay = v);
          _settings.save();
        },
      ),
      if (_settings.ttsProvider == TtsProvider.elevenlabs) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _elevenKeyController,
            obscureText: !_showElevenKey,
            decoration: InputDecoration(
              labelText: 'ElevenLabs API Key',
              hintText: 'sk_ 开头，创建时仅显示一次，官网复制完整 key（列表里的是 ID 不能用）',
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _revealButton(
                    _showElevenKey,
                    () => set(() => _showElevenKey = !_showElevenKey),
                  ),
                  IconButton(
                    icon: const Icon(PhosphorIconsRegular.clipboardText),
                    tooltip: '从剪贴板粘贴',
                    onPressed: () => _pasteInto(_elevenKeyController),
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _elevenVoiceController,
            decoration: InputDecoration(
              labelText: '音色 ID (Voice ID)',
              hintText: '留空用默认 Rachel；elevenlabs.io → Voices 复制 ID',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(PhosphorIconsRegular.clipboardText),
                tooltip: '从剪贴板粘贴',
                onPressed: () => _pasteInto(_elevenVoiceController),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(PhosphorIconsRegular.floppyDisk),
              label: const Text('保存'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await _saveTts();
                if (mounted) {
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('已保存'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
            ),
          ),
        ),
      ],
      SwitchListTile(
        title: const Text('自动朗读'),
        subtitle: Text(
          _settings.ttsProvider == TtsProvider.elevenlabs
              ? 'AI 回复后自动朗读（ElevenLabs 会按量扣费）'
              : 'AI 回复后自动朗读',
        ),
        value: _settings.autoTts,
        onChanged: (v) {
          set(() => _settings.autoTts = v);
          _settings.save();
        },
      ),
      ListTile(
        leading: const Icon(PhosphorIconsRegular.playCircle),
        title: const Text('测试语音'),
        subtitle: Text(
          _settings.ttsProvider == TtsProvider.elevenlabs
              ? '用 ElevenLabs 试读一句（会消耗少量额度）'
              : '用系统引擎试读一句（需手机已装 TTS 引擎）',
        ),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          final tts = context.read<TtsService>();
          await _saveTts();
          try {
            await tts.toggle('__tts_test__', '你好，这是语音测试');
          } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text('$e')));
          }
        },
      ),
    ];
  }

  List<Widget> _secWeread(ThemeData theme, StateSetter set) {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: TextField(
          controller: _wereadKeyController,
          obscureText: !_showWereadKey,
          decoration: InputDecoration(
            labelText: '微信读书 API Key',
            hintText: 'wrk- 开头；是登录凭证，会过期，失效后重新获取',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _revealButton(
                  _showWereadKey,
                  () => set(() => _showWereadKey = !_showWereadKey),
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.floppyDisk),
                  tooltip: '保存',
                  onPressed: () async {
                    await WereadService.saveKey(
                      _wereadKeyController.text.trim(),
                    );
                    if (mounted) _snack('微信读书 Key 已保存');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _secMcp(ThemeData theme, StateSetter set) {
    return [
      SwitchListTile(
        title: const Text('启用 MCP Server'),
        subtitle: Text('允许其他设备通过端口 ${_settings.webSocketPort} 连接'),
        value: _settings.serverEnabled,
        onChanged: (v) async {
          set(() => _settings.serverEnabled = v);
          final messenger = ScaffoldMessenger.of(context);
          final server = context.read<McpServerProvider>().server;
          if (v) {
            final ok = await server.start(_settings.webSocketPort);
            if (!ok && mounted) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('启动 MCP Server 失败，请检查端口'),
                  backgroundColor: Colors.red,
                ),
              );
              set(() => _settings.serverEnabled = false);
            }
          } else {
            await server.stop();
          }
          await _saveSettings();
        },
      ),
      if (_settings.serverEnabled) ...[
        ListTile(
          leading: const Icon(PhosphorIconsRegular.wifiHigh),
          title: const Text('端口'),
          trailing: SizedBox(
            width: 80,
            child: TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              controller: TextEditingController(
                text: _settings.webSocketPort.toString(),
              ),
              onSubmitted: (v) {
                _settings.webSocketPort = int.tryParse(v) ?? 8765;
                _saveSettings();
              },
            ),
          ),
        ),
      ],
    ];
  }

  List<Widget> _secMcpExt(ThemeData theme, StateSetter set) {
    return [
      Consumer<ExternalMcpProvider>(
        builder: (context, mcpProv, _) {
          if (mcpProv.clients.isNotEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已连接 ${mcpProv.clients.length} 个服务器',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.green,
                  ),
                ),
                const SizedBox(height: 4),
                ...mcpProv.clients.map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(
                          PhosphorIconsRegular.checkCircle,
                          size: 14,
                          color: Colors.green,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${c.config.name} (${c.config.displayUrl})',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          c.skippedTools > 0
                              ? '${c.tools.length} 工具 · ${c.skippedTools} 个没读懂'
                              : '${c.tools.length} 工具',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            );
          }
          return const SizedBox.shrink();
        },
      ),

      // Server list
      ..._externalServers.map(
        (server) => Card(
          margin: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            dense: true,
            leading: Icon(
              PhosphorIconsRegular.database,
              color: server.enabled ? theme.colorScheme.primary : Colors.grey,
            ),
            title: Text(server.name, style: const TextStyle(fontSize: 14)),
            subtitle: Text(
              server.displayUrl,
              style: const TextStyle(fontSize: 11),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: server.enabled,
                  onChanged: (v) async {
                    final mcp = context.read<ExternalMcpProvider>();
                    server.enabled = v;
                    await ExternalMcpServerService.save(_externalServers);
                    if (v) {
                      mcp.connectTo(server);
                    } else {
                      mcp.disconnect(server.url);
                    }
                    set(() {});
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                IconButton(
                  icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                  onPressed: () async {
                    final mcp = context.read<ExternalMcpProvider>();
                    await ExternalMcpServerService.remove(server.id);
                    mcp.disconnect(server.url);
                    _externalServers = await ExternalMcpServerService.load();
                    set(() {});
                  },
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),

      // Add new server
      if (_showAddMcp)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _mcpNameController,
                  decoration: const InputDecoration(
                    labelText: '服务器名称',
                    hintText: '我的 MCP Server',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mcpUrlController,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: 'https://example.com/mcp',
                    helperText: 'https:// 为标准 MCP 服务器，ws:// 为本机自带服务器',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mcpTokenController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Token（没有就留空）',
                    helperText: '需要鉴权的服务器才填。存在手机本地，不加密',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        _showAddMcp = false;
                        set(() {});
                      },
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      icon: const Icon(PhosphorIconsRegular.link, size: 16),
                      label: const Text('添加并连接'),
                      onPressed: () async {
                        final name = _mcpNameController.text.trim();
                        final url = _mcpUrlController.text.trim();
                        final token = _mcpTokenController.text.trim();
                        if (name.isEmpty || url.isEmpty) return;

                        // Show loading
                        final messenger = ScaffoldMessenger.of(context);
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('⏳ 连接中...'),
                            duration: Duration(seconds: 30),
                          ),
                        );

                        final server = ExternalMcpServer(
                          id: const Uuid().v4(),
                          name: name,
                          url: url,
                          token: token.isEmpty ? null : token,
                        );

                        // Try to connect first
                        final provider = context.read<ExternalMcpProvider>();
                        final error = await provider.connectTo(server);

                        if (mounted) {
                          messenger.hideCurrentSnackBar();
                          if (error == null) {
                            // Success: save and clear
                            await ExternalMcpServerService.add(server);
                            _mcpNameController.clear();
                            _mcpUrlController.clear();
                            _mcpTokenController.clear();
                            _showAddMcp = false;
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('✅ 已连接到 $name'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          } else {
                            // Failure: keep form, show error
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('❌ $error'),
                                backgroundColor: Colors.orange,
                                duration: Duration(seconds: 5),
                              ),
                            );
                          }
                        }
                        _externalServers =
                            await ExternalMcpServerService.load();
                        set(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        )
      else
        OutlinedButton.icon(
          onPressed: () {
            _showAddMcp = true;
            set(() {});
          },
          icon: const Icon(PhosphorIconsRegular.plus, size: 16),
          label: const Text('添加 MCP 服务器'),
        ),
    ];
  }

  List<Widget> _secBackup(ThemeData theme, StateSetter set) {
    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          '导出对话、讨论、日记、一隅。不含任何 API 密钥，'
          '也不含书籍封面——导入后密钥需要重新填一次。',
          style: TextStyle(fontSize: 12, height: 1.5),
        ),
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: const Icon(PhosphorIconsRegular.export),
        title: const Text('导出备份'),
        subtitle: const Text('生成 json 文件，可发到微信或存网盘'),
        enabled: !_backupBusy,
        onTap: _backupBusy ? null : _exportBackup,
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: const Icon(PhosphorIconsRegular.downloadSimple),
        title: const Text('导入备份'),
        subtitle: const Text('从 json 文件恢复，可选合并或覆盖'),
        enabled: !_backupBusy,
        onTap: _backupBusy ? null : _importBackup,
      ),
    ];
  }

  Widget _buildConfigFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _keyController,
          decoration: InputDecoration(
            labelText: 'API Key',
            border: const OutlineInputBorder(),
            hintText: 'sk-...',
            suffixIcon: _revealButton(
              _showApiKey,
              () => setState(() => _showApiKey = !_showApiKey),
            ),
          ),
          obscureText: !_showApiKey,
          maxLines: 1,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _endpointController,
          decoration: const InputDecoration(
            labelText: 'API Endpoint（可选，留空用默认）',
            border: OutlineInputBorder(),
            hintText: 'https://api.openai.com/v1',
          ),
          maxLines: 1,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            labelText: '模型（可选，留空用默认）',
            border: OutlineInputBorder(),
            hintText: 'gpt-4o / claude-sonnet-5',
          ),
          maxLines: 1,
        ),
      ],
    );
  }
}

/// 副标题里显示性格的头一句。折行会把设置项撑高，这里只要一眼认出「设过了」。
String _clipOneLine(String s, int max) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > max ? '${one.substring(0, max)}…' : one;
}
