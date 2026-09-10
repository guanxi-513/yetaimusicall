# 网易云音源模块（netease-music-source）

独立网易云音乐音源 HTTP 服务，供你自己写的播放器调用。
基于开源包 `@neteasecloudmusicapienhanced/api`（MIT 协议）封装，个人学习用途，请遵守网易云服务条款，勿商用、勿绕过付费内容。

## 启动

```bash
npm install     # 只需一次
npm start       # 启动，默认端口 41831（可用环境变量 PORT 修改）
```

## 服务器部署（Linux / Ubuntu）

```bash
# 1. 安装 Node.js 18+（https://nodejs.org 或 apt install nodejs npm）
# 2. 拉取代码
git clone https://github.com/guanxi-513/music-hook.git && cd music-hook
npm install
# 3. 启动（建议用 pm2 守护进程）
npm install -g pm2
CURL=curl pm2 start server.js --name music-hook
pm2 save
# 4. 防火墙/安全组放行 41831 端口
# 5. 验证：浏览器访问 http://服务器IP:41831/status
```

**B站源在 Linux 的说明**：B站源改用系统 `curl`（`CURL=curl`），跨平台已适配（Windows 仍用
系统 curl.exe，无需配置）。Linux 发行版一般自带 curl，如缺失先 `apt install curl`。
若服务器上 B站接口返回 412（风控），通常是服务器 IP 被 B站标记（数据中心 IP 常见），
可换住宅 IP 或换代理后重试，与代码无关。

**登录态**：登录 cookie 保存在服务端同目录 `cookie.txt`，换服务器后需在 App 里重新扫码一次。

## 接口一览（全部 GET，支持跨域 CORS）

| 接口 | 参数 | 说明 |
|---|---|---|
| `/search` | `keywords`、`limit`、`offset` | 搜索歌曲，返回 `{ id, name, artists[], album, cover, duration }` |
| `/search/bili` | `keywords`、`limit` | **B站源搜索**：网易云没有版权的歌（如QQ独家VIP曲目）可在B站搜到完整版，返回 `{ result: { songs, count }, source: 'bilibili' }`，歌曲含 `bvid` |
| `/song/url/bili` | `bvid` | **B站源取播放地址**：返回 `{ data: { id: bvid, url: '/stream/bili?bvid=...', source: 'bilibili' } }`，播放器拼 base 前缀走代理 |
| `/stream/bili` | `bvid` | **B站音频代理**：服务端用系统 curl（Windows 为 curl.exe / Schannel TLS，Linux 为 curl / 环境变量 CURL 可指定）抓取带防盗链的音频流，支持 Range 拖动，转发给播放器。B站音频 CDN 有防盗链必须走此代理 |
| `/song/url` | `id`、`br`(可选,默认999000) | 获取播放地址。网易云受限/试听歌曲**自动解锁**（从其他平台匹配可用源），响应含 `unblocked`/`source` 字段 |
| `/song/url/unblock` | `id` | 强制音源解锁：不依赖网易云，直接从其他平台匹配播放源 |
| `/stream` | `url`（编码后的音频直链） | **音频代理**：服务端抓取音频流（带防盗链 Referer/UA，支持 Range 拖动），转发给播放器。播放器应统一走此接口，避免解锁源防盗链导致无声 |
| `/lyric` | `id` | 返回歌词 `lrc` + 翻译 `tlyric` |
| `/song/detail` | `ids`（逗号分隔） | 歌曲详情：封面、歌手、专辑、时长 |
| `/playlist` | `id` | 歌单信息 + 全部歌曲（榜单/歌单通用） |
| `/user/playlist` | `uid`(可选) | **导入网易云歌单**：登录后不传 uid 自动用当前登录用户，返回 `{loggedIn, playlists[]}` |
| `/like` | `id`、`like`(1/0) | **喜欢/取消喜欢**：同步网易云"我喜欢的音乐"（需登录，未登录返回 301） |
| `/likelist` | — | 我喜欢的音乐 id 列表（用于展示爱心状态，需登录） |
| `/login/qr` | — | 获取登录二维码（返回 `unikey` + `qrimg` base64） |
| `/login/qr/check` | `key` | 轮询扫码状态：801=待扫码 802=已扫码 803=登录成功(自动保存cookie) |
| `/status` | — | 当前登录状态 |
| `/logout` | — | 退出登录（清空已保存 cookie） |
| `/recommend` | — | 每日推荐（需登录） |

## 播放器使用流程（示例）

1. **搜索**：`GET /search?keywords=周杰伦` → 拿到 `id`
2. **拿封面**：`GET /song/detail?ids=<id>` → `cover`
3. **拿播放地址**：`GET /song/url?id=<id>` → `url`（受限歌曲会自动解锁）
4. **播放**：把 `url` 传给 `/stream?url=<编码后的url>` 作为 `<audio>` 的 src（走代理，避免防盗链无声）
5. **拿歌词**：`GET /lyric?id=<id>` → `lrc`
6. **（可选）登录**：`GET /login/qr` 得到二维码 → 用户扫码 → 轮询 `/login/qr/check` 直到 803 → cookie 自动保存到本目录 `cookie.txt`，之后高音质/需登录歌曲、`/recommend` 每日推荐、`/user/playlist` 导入歌单均可用

## 登录态说明

- 登录成功后 cookie 会自动写入同目录 `cookie.txt`，重启服务后仍保持登录
- 未登录也能搜索和播放大部分歌曲（部分歌曲/高音质需登录）

## 音源解锁（unblock）

与 VutronMusic 的 `unblockNeteaseMusic` 功能一致：当网易云某首歌**无版权 / 受限 / 仅试听**时，
自动从酷狗、QQ、咪咕、B 站等平台匹配同一首歌的可用播放源（最高无损）。
（已移除酷我 `kuwo` 及其 CDN 源 `bodian`，该源不稳定。）

- `/song/url` 已内置自动解锁逻辑（响应含 `unblocked: true` 和 `source` 来源）
- 也可显式调用 `/song/url/unblock?id=xxx` 强制解锁
- 依赖包：`@unblockneteasemusic/server`（LGPL-3.0，开源项目 UnblockNeteaseMusic）

> 仅供个人学习使用，请遵守各音乐平台服务条款。

## 项目结构

```
netease-music-source/
├── package.json     # 依赖声明
├── .npmrc           # 国内镜像源
├── server.js        # 音源 HTTP 服务（核心）
└── cookie.txt       # 登录态（自动生成）
```
