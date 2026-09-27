import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'config/settings.dart';
import 'config/app_theme.dart';
import 'screens/home_shell.dart';
import 'services/app_providers.dart';
import 'services/avatar_store.dart';
import 'services/background_memory.dart';
import 'services/chat_images.dart';
import 'services/storage_service.dart';
import 'services/xiaoke_channel.dart';
import 'services/external_mcp_service.dart';
import 'services/music_service.dart';
import 'services/nudge_scheduler.dart';
import 'services/tts_service.dart';
import 'services/pet_state.dart';
import 'widgets/mochi_pet.dart';
import 'widgets/music_float.dart';
import 'widgets/nook_splash.dart';

/// 让没有 context 的工具也能弹框问用户。
///
/// 注意：MCP server 也会从电脑那边调同一批工具，那时人不在手机前面，
/// 弹框不会有人点——所以调用方必须给超时，超时按「拒绝」处理。
final appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 绘制到屏幕边缘，并让系统状态栏/导航栏透明。
  //
  // 不开这个的话，底部手势条那一条由系统用不透明色填充，背景图会被截断在
  // 它上面——于是「悬浮」的导航胶囊其实是坐在一块灰底板上，一换背景就露馅。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  await StorageService.init();

  // 超过 30 天的聊天图片清掉，见 [ChatImages]。不等它，也不让它拦住启动。
  ChatImages.sweep().ignore();
  StorageService.dropPreImageBackups().ignore();
  // 你自己的头像全局一张，先读进来，气泡里的头像一出现就是对的。
  AvatarStore.instance.load(AvatarStore.userKey).ignore();
  // 小克频道随 App 一起开：在别的页面时小克回的话也能收到、存下来。
  // 端口带连接码鉴权，见 [XiaokeChannel]。
  XiaokeChannel.instance.start().ignore();

  // 只是把后台入口注册给原生侧，不会开始跑——跑不跑由设置里那个开关决定。
  // 必须在 runApp 之前：系统唤醒时走的是另一条路径，那时候没有 widget 树。
  // 失败了不能让 App 起不来，这只是个附加功能。
  try {
    await NudgeScheduler.init();
  } catch (e) {
    debugPrint('[nudge] 后台入口没注册上：$e');
  }

  // ⚠️ 玻璃要的两样东西，必须在 runApp **之前**读出来。
  //
  // AppSurface 判断画玻璃还是实心，看的是「玻璃开关」和「有没有背景图」。
  // 这两个原来都是 runApp 之后才异步填上的——于是第一帧两个都是空，
  // 整屏先画成实心卡片，等它们到了再重画成玻璃。
  //
  // 症状就是 Cleo 说的：「每次重新打开 app 会先是卡片，过一会变成玻璃」。
  //
  // 提前读的代价是启动多等一次 SharedPreferences（毫秒级）；换来的是
  // **第一帧就是对的**。读失败也不能让 App 起不来，所以整段包在 try 里。
  AppSettings? bootSettings;
  String? bootBgPath;
  var bootBgPreset = 'none';
  try {
    bootSettings = await AppSettings.load();
    bootBgPath = await StorageService.getBackgroundImagePath();
    bootBgPreset = await StorageService.getBackgroundPreset();
  } catch (e) {
    debugPrint('[boot] 预读设置/背景失败，第一帧会先画实心：$e');
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AiClientProvider()),
        ChangeNotifierProvider(
          create: (_) => McpServerProvider()..markInitialized(),
        ),
        ChangeNotifierProvider(create: (_) => ExternalMcpProvider()),
        ChangeNotifierProvider(create: (_) => TtsService()),
        ChangeNotifierProvider(
          create: (_) {
            final p = BackgroundProvider();
            // update() 是异步的，但 `_path` 是在第一个 await 之前就赋上的——
            // 所以不 await 也能保证第一帧 `path != null`。
            // 后面那段图像分析（算亮度、busyness）慢慢跑，跑完只是微调 alpha。
            if (bootBgPath != null) p.update(bootBgPath, bootBgPreset);
            return p;
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final p = SettingsProvider();
            if (bootSettings != null) p.setSettings(bootSettings);
            return p;
          },
        ),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()..load()),
        // 「一起听」。用 .value 而不是 create：MusicService.instance 是个静态
        // 单例，原因是原生那边（系统托管的 MusicListenerService）活得比这棵
        // Provider 树长，**推事件的时候这棵树可能还不存在**——事件先落在
        // MusicBridge 里攒着，等这里起来了再取。用 create 的话 Provider 会
        // 以为自己独占这个对象，dispose 时把它丢掉，单例就断了一条腿。
        ChangeNotifierProvider.value(value: MusicService.instance),
      ],
      child: const PhoneAiApp(),
    ),
  );
}

class PhoneAiApp extends StatefulWidget {
  const PhoneAiApp({super.key});

  @override
  State<PhoneAiApp> createState() => _PhoneAiAppState();
}

class _PhoneAiAppState extends State<PhoneAiApp> with WidgetsBindingObserver {
  late Future<AppSettings> _settingsFuture;

  /// 冷启动演一次开屏，见 [NookSplash]。切回前台不演：进程还在就不算「回来」。
  bool _splash = true;

  @override
  void initState() {
    super.initState();
    _settingsFuture = AppSettings.load();
    _loadSavedApiKeys();
    _connectExternalMcpServers();
    WidgetsBinding.instance.addObserver(this);
    // 后台被系统掐掉时的兜底：攒下的事在她打开 App 时补上。
    // 不弹通知——人已经在 App 里了。门槛照走，所以不会变吵。
    NudgeScheduler.runOnStartup();
    // 换歌之后过 25 秒问一次「要不要说句话」。挂在这儿而不是让 nudge 那边去
    // 监听 MusicService：换歌这个判断只有 MusicService 自己做得准（见
    // `onTrackChanged` 的注释）。
    MusicService.instance.onTrackChanged = NudgeScheduler.onTrackChanged;
    _autoStartMcpServer();
    // 浮在界面上那只小猫露没露着。默认不露，见 [PetState.visible]。
    PetState.load();
    // 扫一遍小猫专用图（睁眼 / 闭眼），见 [PetArt]。
    PetArt.load();
    // 「一起听」：先把上次在听的那首从盘里捞出来填上，再去问原生现在在放什么。
    // 两步的顺序不能反——反了的话，冷启动会先空一下再跳出歌名。
    // warmUp 是「我们记得什么」（标着 stale），start 才是「它现在知道什么」。
    unawaited(MusicService.instance.warmUpFromDisk());
    unawaited(MusicService.instance.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ⚠️ 这里曾经有过一个 `_checkGlanceHealth`：进 App 两秒后，如果「看一眼屏幕」
  // 被系统停掉了，就在底部弹一条带「去设置」的横幅。**2026-09-20 整个删掉了。**
  //
  // 它的本意是帮她把服务接回来，实际效果是反的：横幅正好压在输入框上，每次冷启动
  // 都来一次，于是她为了不被挡住，干脆把整个无障碍服务关了——
  // 「无障碍关掉是因为她老是被系统关掉。每次打开 app 及会有提示，这个提示挡在我的
  // 输入框，所以我必须去打开一下」。
  //
  // 一个为了救功能而存在的提示，逼得用户把功能关掉，那它就是净负分。
  // 现在只剩两条路：后台那条通知（[GlanceHealth.notifyIfBroken]，12 小时最多一次，
  // 不打断她正在做的事），和设置页里那一行状态。**别再往前台加这种东西。**

  /// ⚠️ 上面那句 `runOnStartup` **只在冷启动时跑**：它在 initState 里，
  /// 而 Android 不会因为她切走就杀进程。连着用一整天的话，那条兜底一次都
  /// 不会再跑，期间唯一的检查点只剩后台周期任务——而那个在国产 ROM 上
  /// 被攒到二三十分钟一次、还会整轮跳过。
  ///
  /// 所以切回前台也走一遍。防抖在 [NudgeScheduler.shouldRunLocally] 里。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NudgeScheduler.runOnResume();
      // 同理：用户可能刚在系统设置里把「通知使用权」开了或关了，而 App 这边
      // 收不到任何通知。每次回前台都重问一遍，不然症状是「开完权限回来还是
      // 显示没开启」，看着像坏了。
      unawaited(MusicService.instance.start());
    }
    // 退到后台就把图片缓存还回去，理由见 [freeImageCacheForBackground]：
    // 系统清理的是「在后台占几百兆的空进程」，而进程一死，
    // 「看一眼屏幕」就被记成故障、要她手动接回来。
    //
    // ⚠️ 不接 inactive：下拉通知栏、来电都会触发它，人马上就回来，
    // 白白重解一遍图。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      freeImageCacheForBackground(PaintingBinding.instance.imageCache);
    }
  }

  Future<void> _autoStartMcpServer() async {
    final settings = await _settingsFuture;
    if (!settings.serverEnabled || !mounted) return;
    final provider = context.read<McpServerProvider>();
    await provider.server.start(settings.webSocketPort);
    provider.markInitialized(); // notify UI
  }

  Future<void> _loadSavedApiKeys() async {
    // 选法抽到了 buildStoredAiClient：后台推送被唤醒时没有 provider，
    // 也得挑同一个配置。两边共用一份，别各写各的。
    final client = await buildStoredAiClient();
    if (client != null && mounted) {
      context.read<AiClientProvider>().setClient(client);
    }
  }

  Future<void> _connectExternalMcpServers() async {
    final servers = await ExternalMcpServerService.load();
    for (final server in servers.where((s) => s.enabled)) {
      if (mounted) {
        await context.read<ExternalMcpProvider>().connectTo(server);
      }
    }
  }

  /// 这一轮该用什么色调建主题。
  ///
  /// 两个色源，**背景图优先**：
  ///
  /// - 贴了背景图 + 开着毛玻璃 → 配色由图决定（设计交付里的互斥规矩）。
  ///   判断条件和 `AppSurface` 画不画玻璃那几条对齐——玻璃关着却把整套配色
  ///   旋到粉色，那是第三种状态，谁也没要过。
  /// - 否则 → 用预设主题（默认 [AppThemeId.brown] = 原来那套棕，
  ///   一个像素都不变）。
  AppTone _toneFor(AppSettings s, BackgroundProvider bg) {
    if (s.glassSurface && bg.path != null) {
      // 图是黑白的（解不出色相）——退回棕色同样出戏，改用中性色调。
      final accent = bg.backgroundAccent;
      return accent == null ? AppTone.neutral : AppTone.towards(accent);
    }
    return s.themeId.tone;
  }

  /// 这一轮该用深色还是浅色。
  ///
  /// 玻璃主题下**深浅跟着背景图走，不听 ThemeMode**。
  ///
  /// 不这么做会撕开成两半：`AppSurface` 按背景图决定玻璃是白的还是黑的，
  /// 卡片里的字却按 ThemeMode 取 `scheme.onSurface`。贴一张黑底壁纸就是
  /// 深色玻璃压深色字——栖息页那个「588」大数字整个消失，实测过。
  ///
  /// 页面大标题之所以没事，是因为四个页面各自写了
  /// `bg.darkForeground ?? theme.brightness` 这么一句手接。那正说明问题：
  /// 手接只接得住写过的地方，接不住卡片里成百上千处 `scheme.onSurface`。
  /// 深浅是主题这一层的事，就该在主题这一层定。
  ///
  /// 关掉玻璃开关，ThemeMode 立刻全权说了算。
  ThemeMode _modeFor(AppSettings s, BackgroundProvider bg) {
    if (!s.glassSurface || bg.path == null) return s.themeMode;
    final darkForeground = bg.darkForeground;
    if (darkForeground == null) return s.themeMode;
    // darkForeground = 字要用深色 = 背景偏亮 = 浅色主题
    return darkForeground ? ThemeMode.light : ThemeMode.dark;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppSettings>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        final settings = snapshot.data ?? AppSettings();
        context.read<SettingsProvider>().setSettings(settings);

        // 背景图也要参与建主题：玻璃主题下整套配色跟着背景色相走。
        return Consumer2<SettingsProvider, BackgroundProvider>(
          builder: (context, sp, bg, _) {
            final s = sp.settings ?? settings;
            final titleSerif = s.titleSerif;
            final tone = _toneFor(s, bg);
            return MaterialApp(
              // 最近任务里显示的名字，和桌面上的 Nook 对上。
              title: 'Nook',
              // 工具是不带 context 的静态函数，但有些工具需要当场问用户
              // （比如读日历）。给它们一个能挂弹框的地方。
              navigatorKey: appNavigatorKey,
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightWith(titleSerif: titleSerif, tone: tone),
              darkTheme: AppTheme.darkWith(titleSerif: titleSerif, tone: tone),
              themeMode: _modeFor(s, bg),
              home: const HomeShell(),
              // 开屏盖在最上面，首页在底下同时建好：淡出时露出来的就是画完的第一帧，
              // 不会「动画完了再等首页」。
              builder: (context, child) => Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  // ⚠️ 顺序：界面 → 音乐 → 小猫 → 开屏。
                  //
                  // 小猫盖在音乐上面是有意的：猫只有 72 宽，压在卡片角上还能
                  // 看见大半张、也还摸得到按钮；反过来卡片会整个压住猫，那只
                  // 猫就再也拖不动了。让小的在上面。
                  //
                  // 开屏必须盖住这两个，否则启动那一下会看到猫和播放条飘在
                  // 动画上面。
                  const MusicFloat(),
                  const MochiPet(),
                  if (_splash)
                    NookSplash(
                      onDone: () => setState(() => _splash = false),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
