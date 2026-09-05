# 液态音乐 前端（Flutter / Android）

多平台音源音乐播放器 App。毛玻璃（液态玻璃）UI，网易云深度同步，受限歌曲自动解锁，后台播放 + 通知栏控制 + 小米灵动岛。

## 功能特性

- **双源搜索**：网易云 + B站。网易云没有版权的歌（如 QQ 独家 VIP 曲目）可在 B站搜到完整版
- **音源解锁**：网易云受限/试听/会员歌曲自动从其他平台匹配可用源播放
- **网易云深度同步**
  - 二维码扫码登录（登录态保存在本机，重启不丢失）
  - 导入网易云歌单（带封面）
  - 每日推荐、官方榜单（热歌榜/新歌榜等，每日更新）
  - 收藏双向同步：App 点爱心 ↔ 网易云"我喜欢的音乐"（登录状态下）
- **音质选择**：标准 128k / 高品 320k（默认）/ 无损 FLAC，播放页显示真实音质（受限歌解锁源固定音质会如实显示）
- **后台播放**：切后台不断播；通知栏标准媒体通知带 上一首/播放暂停/下一首/收藏 按钮；小米灵动岛可显示
- **直连加速**：网易云歌曲优先手机直连真实 CDN，加载快且不占服务器带宽；失败自动回退服务端代理
- **本地能力**：本地收藏、播放历史、最近播放缓存（最近 30 首）
- **UI**：苹果风格毛玻璃/液态玻璃质感

## 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.44 / Dart 3.12 |
| 状态管理 | provider |
| 网络 | http |
| 音频 | just_audio + audio_service（后台播放/媒体通知） |
| 图片 | cached_network_image |
| 本地存储 | sqflite（收藏/历史/缓存）、shared_preferences（配置/登录 cookie）、path_provider |

## 目录结构

```
lib/
├── main.dart                 # 入口：加载配置/登录态、初始化 audio_service
├── config.dart               # 音源地址、音质等配置（持久化）
├── models/                   # 数据模型（歌曲/歌单/用户）
├── pages/                    # 页面（首页四 Tab：推荐/搜索/榜单/我的 + 播放页等）
├── services/
│   ├── api_service.dart      # 音源服务 API 封装（含登录 cookie 持久化）
│   ├── audio_handler.dart    # audio_service 后台播放 handler
│   ├── db_service.dart       # 本地收藏/历史/缓存数据库
│   ├── music_cache.dart      # 最近播放缓存
│   └── media_notification_bridge.dart  # 通知栏控制/收藏（原生联动）
├── state/                    # 全局状态（播放器/登录态）
└── widgets/                  # 毛玻璃 UI 组件、迷你播放条等
```

## 环境要求

- Flutter SDK 3.44+（Dart 3.12+）
- Android SDK（targetSdk 34+）
- 音源服务端（见 `../backend/README.md`）

## 构建

```bash
cd frontend
flutter pub get

# 调试运行（连接手机/模拟器）
flutter run

# Release APK（产物：build/app/outputs/flutter-apk/app-release.apk）
flutter build apk --release
```

> Windows 命令行注意：若 `flutter` 命令不识别，直接调用 `D:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe --packages="D:\dev\flutter\packages\flutter_tools\.dart_tool\package_config.json" "D:\dev\flutter\bin\cache\flutter_tools.snapshot" build apk --release`（先删 `D:/dev/flutter/bin/cache/lockfile`）。

## 配置说明

- **音源服务地址**：App「设置」→ 修改 API 基础地址，如 `http://服务器IP:41831`。地址持久化，重启不重置（配置 key：`api_base_url`）
- **音质**：播放页右上角音质按钮切换，持久化（配置 key：`audio_quality`）
- **登录**：设置 → 登录，扫码网易云二维码。登录 cookie 保存在本机（shared_preferences，key：`netease_cookie`），**每台设备各自独立登录，互不覆盖**
- **B站源**：需要服务端支持（见后端 README 的 CURL 配置）

## 通知栏 / 灵动岛说明

- 通知栏为标准系统媒体通知（非自定义 RemoteViews），显示封面/歌名/歌手 + 上一首/播放暂停/下一首/收藏按钮
- 通知挂 MediaSession，Android 13+ 系统媒体卡片 / 锁屏控制 / 小米灵动岛正常
- 首次启动会请求通知权限（Android 13+），需允许

## 免责声明

个人学习项目，音源数据来自第三方平台，请遵守平台服务条款，勿商用。
