# 液态音乐 后端（音源服务，Node.js）

多平台音乐音源 HTTP 服务：搜索（网易云 + B站）、播放地址（受限歌自动解锁）、音频代理（防盗链）、歌词、歌单、网易云登录/收藏/每日推荐。附带**网页播放器**（iPhone 等设备浏览器直接使用）。

基于 `@neteasecloudmusicapienhanced/api`（MIT 协议）与 `@unblockneteasemusic/server` 封装，个人学习用途。

## 快速启动

```bash
npm install
npm start          # 默认端口 41831，可用 PORT 环境变量修改
# 验证：curl http://localhost:41831/status
```

## 服务器部署（Linux / Ubuntu）

```bash
# 1. 安装 Node.js 18+
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. 拉取代码 + 装依赖
git clone https://github.com/guanxi-513/yetaimusicall.git
cd yetaimusicall/backend
npm install

# 3. 启动（建议 pm2 守护进程；B站源需要系统 curl）
sudo npm install -g pm2
sudo env CURL=/usr/bin/curl pm2 start server.js --name music-hook
sudo pm2 save

# 4. 防火墙/安全组放行 41831
sudo ufw allow 41831

# 5. 验证：浏览器访问 http://服务器IP:41831/status
```

**B站源说明**：Linux 用系统 `curl`（`CURL=/usr/bin/curl`），Windows 用 `curl.exe`。若服务器 B站接口返回 412（风控），通常是数据中心 IP 被 B站标记，与代码无关，可换住宅 IP。

## 网页播放器（给 iPhone / 不开 App 的设备用）

后端已内置网页播放器，浏览器直接打开即可搜索/播放/看歌词：

```
http://服务器IP:41831/
```

网页版默认使用服务端全局登录态（游客可听免费歌 + 受限歌解锁）。**注意：不要在网页版扫码登录**，会覆盖服务端全局登录态（App 端登录不受影响，App 登录态保存在手机本地）。

## 多设备独立登录态

- **App 端**：登录后 cookie 保存在手机本地，每次请求自带 Cookie 头，各设备账号独立，互不覆盖
- **网页版/未带 Cookie 的客户端**：使用服务端全局 `cookie.txt` 兜底
- 登录接口 `/login/qr/check` 登录成功会返回 `cookie` 字段给客户端保存

## 接口一览（全部 GET，支持 CORS）

| 接口 | 参数 | 说明 |
|---|---|---|
| `/search` | `keywords`、`limit`、`offset` | 网易云搜索，返回 `{id, name, artists[], album, cover, duration}` |
| `/search/bili` | `keywords`、`limit` | B站源搜索（网易云无版权歌），返回含 `bvid` |
| `/song/url` | `id`、`br`(默认999000) | 播放地址；受限歌自动解锁，响应含 `unblocked`/`source` |
| `/song/url/unblock` | `id` | 强制音源解锁（不依赖网易云） |
| `/song/url/bili` | `bvid` | B站源取播放地址（走代理 `/stream/bili`） |
| `/stream` | `url`（编码音频直链） | 音频代理：防盗链 + Range 拖动，转发给播放器 |
| `/stream/bili` | `bvid` | B站音频代理（B站 CDN 防盗链必须走代理） |
| `/lyric` | `id` | 歌词 `lrc` + 翻译 `tlyric` |
| `/song/detail` | `ids`（逗号分隔） | 歌曲详情 |
| `/playlist` | `id` | 歌单/榜单信息 + 歌曲 |
| `/user/playlist` | `uid`(可选) | 导入网易云歌单（登录后不传 uid 用当前用户） |
| `/like` | `id`、`like`(1/0) | 喜欢/取消喜欢（同步网易云，需登录） |
| `/likelist` | — | "我喜欢的音乐" id 列表 |
| `/login/qr` | — | 获取登录二维码（unikey + qrimg base64） |
| `/login/qr/check` | `key` | 轮询扫码：801=待扫 802=已扫 803=成功(返回cookie) |
| `/status` | — | 登录状态 |
| `/logout` | — | 退出登录 |
| `/recommend` | — | 每日推荐（需登录） |

## 播放器调用示例

```text
1. 搜索：GET /search?keywords=周杰伦        → 拿 id
2. 取播放地址：GET /song/url?id=xxx&br=320000 → 受限歌自动解锁
3. 播放：直连 url 或走代理 GET /stream?url=...
4. 歌词：GET /lyric?id=xxx
```

> 前端 App 已封装上述流程，见 `../frontend/README.md`。

## 免责声明

个人学习用途，请遵守网易云/B站等服务条款，勿商用、勿绕过付费内容。本项目不提供也不保存任何音乐文件。
