# 液态音乐 (Yetai Music)

一个**多平台音源音乐播放器**，由 Flutter 前端 App + Node 音源服务端组成。搜索网易云、B站双源歌曲，受限/会员歌曲自动解锁，深度同步网易云（登录、歌单、每日推荐、收藏），支持后台播放、通知栏控制、小米灵动岛，音质可选。

> ⚠️ 项目为个人学习用途。音源数据来自第三方平台接口，请遵守各平台服务条款，勿商用、勿绕过付费内容。

## 项目结构

```
yetaimusicall/
├── frontend/        # 手机 App（Flutter，Android）
│   ├── lib/         # Dart 源码
│   └── android/     # Android 原生层（通知/灵动岛等）
└── backend/         # 音源服务端（Node.js，HTTP + 代理）
    ├── server.js    # 主服务
    └── player.html  # 网页播放器（iPhone/其他设备直接浏览器用）
```

## 快速开始

### 后端（音源服务）

```bash
cd backend
npm install
npm start            # 默认端口 41831，可用 PORT 环境变量修改
# 验证：curl http://localhost:41831/status
```

### 前端（Android App）

```bash
cd frontend
flutter pub get
flutter run           # 调试运行
flutter build apk --release   # 出正式包
```

App 启动后在「设置」里填写音源服务地址（如 `http://服务器IP:41831`），即可使用。

## 核心功能

| 模块 | 说明 |
|---|---|
| 双源搜索 | 网易云 + B站（网易云没有版权的歌可去 B站搜） |
| 音源解锁 | 网易云受限/会员歌曲自动匹配其他平台源播放 |
| 网易云同步 | 扫码登录、导入歌单、每日推荐、官方榜单、喜欢收藏双向同步 |
| 音质选择 | 标准 128k / 高品 320k / 无损 FLAC，播放页显示真实音质 |
| 后台播放 | 后台不断播、通知栏控制（上一首/播放/下一首/收藏）、小米灵动岛 |
| 直连加速 | 网易云歌曲优先手机直连 CDN，不占服务器带宽 |
| 播放体验 | 歌词、播放历史、本地收藏、最近播放缓存、毛玻璃 UI |

## 各端文档

- [前端（App）说明](./frontend/README.md)
- [后端（服务）说明](./backend/README.md)

## 免责声明

本项目仅用于个人学习与技术交流，请遵守相关平台服务条款与法律法规。音源接口不稳定时请自行承担使用风险。
