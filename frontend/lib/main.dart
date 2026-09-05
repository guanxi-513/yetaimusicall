import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'pages/home_page.dart';
import 'services/api_service.dart';
import 'services/audio_handler.dart';
import 'services/media_notification_bridge.dart';
import 'state/auth_state.dart';
import 'state/player_state.dart';
import 'widgets/glass_background.dart';
import 'widgets/mini_player_bar.dart';

/// 全局状态（main 中创建，Provider.value 注入）
late final PlayerState playerState;
late final AuthState authState;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 先加载用户保存过的音源地址（本地读取，很快）
  await AppConfig.load();
  // 加载本地持久化的登录 cookie（登录态跟随本设备，重启不丢失）
  await ApiService.loadCookies();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // 创建全局状态并接线（不依赖 audio_service）：
  // - MediaNotificationBridge ← PlayerState（自定义通知：歌词 + 收藏按钮）
  playerState = PlayerState();
  authState = AuthState();
  MediaNotificationBridge.init(playerState, loggedIn: () => authState.loggedIn);

  // 先显示首屏；audio_service 在后台初始化，不再阻塞启动
  runApp(const LiquidMusicApp());
  unawaited(_initAudioService());
}

/// 后台初始化 audio_service（后台播放 + 系统媒体通知）。
/// PlayerState 内部对 handler 判空，初始化完成前点播放不会崩溃。
Future<void> _initAudioService() async {
  final handler = await AudioService.init(
    builder: () => LiquidAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.nini.liquid_music.channel.audio',
      androidNotificationChannelName: '音乐播放',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  playerState.attachAudioHandler(handler);
}

class LiquidMusicApp extends StatelessWidget {
  const LiquidMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: playerState),
        ChangeNotifierProvider.value(value: authState),
      ],
      child: MaterialApp(
        title: '液态音乐',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.transparent,
          fontFamilyFallback: const [
            'PingFang SC', 'HarmonyOS Sans', 'Microsoft YaHei', 'sans-serif'
          ],
          colorScheme: const ColorScheme.dark(
            primary: Colors.white,
            secondary: Color(0xFFE05A8A),
            surface: Colors.transparent,
          ),
        ),
        home: const _HomeShell(),
      ),
    );
  }
}

class _HomeShell extends StatelessWidget {
  const _HomeShell();

  @override
  Widget build(BuildContext context) {
    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: const HomePage(),
        // 底部迷你播放条（有当前曲目时显示）
        bottomNavigationBar: const MiniPlayerBar(),
      ),
    );
  }
}
