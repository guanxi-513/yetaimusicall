/**
 * 独立网易云音乐音源模块（个人学习用途）
 *
 * 轻量 HTTP 服务，封装 @neteasecloudmusicapienhanced/api，
 * 供你自己写的播放器调用：搜索 / 播放地址 / 歌词 / 歌曲详情 / 歌单 / 二维码登录
 *
 * 启动：node server.js   （默认端口 41831，可用环境变量 PORT 修改）
 */
const http = require('http')
const { URL } = require('url')
const fs = require('fs')
const path = require('path')
const { AsyncLocalStorage } = require('async_hooks')

const NCM = require('@neteasecloudmusicapienhanced/api')

// ---- 音源解锁（对应 VutronMusic 的 unblockNeteaseMusic 功能）----
// 网易云部分歌曲受限/无版权/仅试听时，从其他平台匹配同一首歌的可用源
process.env.ENABLE_LOCAL_VIP = process.env.ENABLE_LOCAL_VIP || 'true'
process.env.ENABLE_FLAC = process.env.ENABLE_FLAC || 'true'
const unblockMatch = (() => {
  try {
    return require('@unblockneteasemusic/server')
  } catch (e) {
    console.error('[unblock] 未安装 @unblockneteasemusic/server，音源解锁不可用')
    return null
  }
})()
// 解锁来源列表（已移除酷我 kuwo 及走酷我 CDN 的 bodian——该源不稳定）
const UNBLOCK_SOURCES = ['kugou', 'ytdlp', 'qq', 'bilibili', 'pyncmd', 'migu']

/** 从其他平台为受限歌曲匹配可用播放源；失败返回 null */
async function unblockSong(id) {
  if (!unblockMatch) return null
  try {
    const res = await unblockMatch(Number(id), UNBLOCK_SOURCES)
    return (res && res.url) ? res : null
  } catch (e) {
    console.error('[unblock] 匹配失败', id, e && e.message)
    return null
  }
}


// ---- B站音源（补充网易云没有版权的歌，如QQ音乐独家VIP曲目）----
// B站有大量完整版（官方MV/搬运），可免费播放。
// 注意：B站对 Node 原生 fetch（OpenSSL TLS 指纹）会风控 412，这里改用系统 curl.exe（Schannel TLS）访问。
// 音频流有防盗链（须带 bilibili.com 的 Referer），播放走 /stream/bili 代理。
const { execFile, spawn } = require('child_process')
const { promisify } = require('util')
const execFileAsync = promisify(execFile)
// Windows 用系统 curl.exe（Schannel TLS），Linux/macOS 用系统 curl（默认在 PATH）
const CURL = process.env.CURL || (process.platform === 'win32' ? 'C:\\Windows\\System32\\curl.exe' : 'curl')
// 丢弃输出的"空设备"：Windows 为 NUL，类 Unix 为 /dev/null
const NULL_DEV = process.platform === 'win32' ? 'NUL' : '/dev/null'
const BILI_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
const BILI_COOKIE = path.join(__dirname, '.bili_cookies.txt')
let biliCookieAt = 0

/** 用 curl 刷新 B站会话 cookie（写 cookie jar 文件，约 20 分钟一次） */
async function biliEnsureSession() {
  const now = Date.now()
  if (biliCookieAt && now - biliCookieAt < 20 * 60 * 1000) return
  try {
    await execFileAsync(CURL, ['-s', '-c', BILI_COOKIE, '-A', BILI_UA, '-o', NULL_DEV, 'https://www.bilibili.com/'], { timeout: 20000 })
    biliCookieAt = now
    console.log('[bili] 已刷新会话 cookie')
  } catch (e) {
    console.error('[bili] 刷新 cookie 失败', e && e.message)
  }
}

/** 带 UA/Referer/Cookie 的 B站 JSON 请求（走 curl.exe 绕过 Node TLS 指纹风控） */
async function biliCurlJson(url, { referer = 'https://www.bilibili.com/' } = {}) {
  await biliEnsureSession()
  const args = ['-s', '--compressed', '-b', BILI_COOKIE, '-A', BILI_UA, '-H', 'Referer: ' + referer, '-w', '\n%{http_code}']
  args.push(url)
  const { stdout } = await execFileAsync(CURL, args, { maxBuffer: 20 * 1024 * 1024, timeout: 25000 })
  const nl = stdout.lastIndexOf('\n')
  const status = Number(stdout.slice(nl + 1).trim()) || 200
  const bodyText = nl >= 0 ? stdout.slice(0, nl) : stdout
  if (status !== 200) throw Object.assign(new Error('B站请求返回 ' + status), { status: 502 })
  let json
  try {
    json = JSON.parse(bodyText)
  } catch (e) {
    throw Object.assign(new Error('B站返回非 JSON'), { status: 502 })
  }
  return json
}

/** 清洗 B站标题里的 <em> 高亮标签 */
function cleanBiliTitle(t) {
  return (t || '').replace(/<[^>]+>/g, '').trim()
}

/** "5:07" → 307 秒 */
function parseBiliDuration(d) {
  if (!d) return 0
  const parts = String(d).split(':').map(Number)
  if (parts.length === 2) return parts[0] * 60 + parts[1]
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2]
  return Number(d) || 0
}

/** B站视频搜索 → 统一歌曲格式（id 用 bvid 字符串） */
async function biliSearch(keywords, limit = 20) {
  const url = 'https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=' + encodeURIComponent(keywords)
  const body = await biliCurlJson(url, { referer: 'https://search.bilibili.com/' })
  if (body.code !== 0) throw Object.assign(new Error('B站搜索失败: ' + (body.message || body.code)), { status: 502 })
  const list = (body.data && body.data.result) || []
  return list.slice(0, limit).map((v) => ({
    id: 0,
    bvid: v.bvid,
    name: cleanBiliTitle(v.title),
    artist: v.author || 'B站UP主',
    album: '',
    cover: (v.pic || '').replace(/^\/\//, 'https://'),
    duration: parseBiliDuration(v.duration),
    source: 'bilibili',
  }))
}

// bvid → 音频流 URL 的短缓存（避免每播一次重复取流）
const biliUrlCache = new Map()

/** 获取 B站视频的 DASH 音频流地址（最高音质 m4a） */
async function biliAudioUrl(bvid) {
  const hit = biliUrlCache.get(bvid)
  if (hit && Date.now() - hit.at < 10 * 60 * 1000) return hit
  // 用 pagelist 拿 cid（view 接口对部分 IP 风控 412，pagelist 稳定）
  const plist = await biliCurlJson('https://api.bilibili.com/x/player/pagelist?bvid=' + encodeURIComponent(bvid))
  if (plist.code !== 0) throw Object.assign(new Error('B站视频信息失败: ' + (plist.message || plist.code)), { status: 502 })
  const cid = plist.data && plist.data[0] && plist.data[0].cid
  if (!cid) throw Object.assign(new Error('B站视频无 cid'), { status: 502 })
  const pu = `https://api.bilibili.com/x/player/playurl?bvid=${encodeURIComponent(bvid)}&cid=${cid}&fnval=16&platform=pc&high_quality=1`
  const pbody = await biliCurlJson(pu)
  if (pbody.code !== 0) throw Object.assign(new Error('B站取流失败: ' + (pbody.message || pbody.code)), { status: 502 })
  const audio = (pbody.data && pbody.data.dash && pbody.data.dash.audio) || []
  if (!audio.length) throw Object.assign(new Error('该视频无可用音频流（可能需登录/大会员）'), { status: 502 })
  audio.sort((a, b) => (b.bandwidth || 0) - (a.bandwidth || 0))
  const best = audio[0]
  const result = { url: best.baseUrl, duration: Math.round(best.duration || 0), size: best.size || null }
  biliUrlCache.set(bvid, { at: Date.now(), ...result })
  return result
}

/** B站音频流代理（curl.exe 抓取带防盗链的音频，支持 Range，转发给播放器） */
async function proxyBiliStream(bvid, req, res) {
  let audio
  try {
    audio = await biliAudioUrl(bvid)
  } catch (e) {
    console.error('[bili stream] 取流失败', e && e.message)
    return send(res, 502, { code: 502, message: 'B站取流失败: ' + (e && e.message) })
  }
  await biliEnsureSession()
  const args = ['-s', '--http1.1', '-b', BILI_COOKIE, '-A', BILI_UA, '-H', 'Referer: https://www.bilibili.com/', '-D', '-']
  if (req.headers.range) args.push('-H', 'Range: ' + req.headers.range)
  args.push(audio.url)
  const child = spawn(CURL, args)
  let headerBuf = Buffer.alloc(0)
  let headersDone = false
  child.stdout.on('data', (chunk) => {
    if (!headersDone) {
      headerBuf = Buffer.concat([headerBuf, chunk])
      const idx = headerBuf.indexOf('\r\n\r\n')
      if (idx >= 0) {
        headersDone = true
        const headText = headerBuf.slice(0, idx).toString('latin1')
        const rest = headerBuf.slice(idx + 4)
        const headLines = headText.split('\r\n')
        const status = Number((headLines[0].match(/\s(\d{3})/) || [0, 200])[1])
        const outHeaders = {
          'Content-Type': 'application/octet-stream',
          'Accept-Ranges': 'bytes',
          'Access-Control-Allow-Origin': '*',
          'Cache-Control': 'no-store',
        }
        for (let i = 1; i < headLines.length; i++) {
          const ci = headLines[i].indexOf(':')
          if (ci > 0) {
            const k = headLines[i].slice(0, ci).trim().toLowerCase()
            const v = headLines[i].slice(ci + 1).trim()
            if (k === 'content-type') outHeaders['Content-Type'] = v
            else if (k === 'content-length') outHeaders['Content-Length'] = v
            else if (k === 'content-range') outHeaders['Content-Range'] = v
          }
        }
        res.writeHead(status, outHeaders)
        if (rest.length) res.write(rest)
      }
    } else {
      res.write(chunk)
    }
  })
  child.stderr.on('data', () => {})
  child.on('error', (e) => {
    console.error('[bili stream] curl 启动失败', e && e.message)
    if (!res.headersSent) send(res, 502, { code: 502, message: 'B站代理失败' })
    else res.end()
  })
  child.on('close', () => {
    if (!res.writableEnded) res.end()
  })
}

const PORT = Number(process.env.PORT || 41831)
const COOKIE_FILE = path.join(__dirname, 'cookie.txt')

// ---- 简单的 Cookie 持久化（登录成功后写入文件，重启后保持登录态） ----
let savedCookie = ''
try {
  savedCookie = fs.readFileSync(COOKIE_FILE, 'utf8').trim()
} catch (e) {
  /* 首次运行无 cookie 文件，忽略 */
}

/** 从 cookie（字符串或数组，元素可能是完整 set-cookie 行）中提取干净的 name=value 对 */
function cleanCookie(cookie) {
  const items = Array.isArray(cookie) ? cookie : [cookie]
  const seen = new Map()
  for (const raw of items) {
    const segs = String(raw).split(';')
    for (const seg of segs) {
      const p = seg.trim()
      if (!p) continue
      const eq = p.indexOf('=')
      if (eq <= 0) continue
      const name = p.slice(0, eq).trim()
      const lname = name.toLowerCase()
      // 过滤 set-cookie 的属性（不是 cookie 键值）
      if (['max-age', 'expires', 'path', 'domain', 'httponly', 'samesite', 'secure', 'priority', 'partitioned', 'version', 'comment', 'discard', 'port'].includes(lname)) continue
      const value = p.slice(eq + 1).trim()
      seen.set(name, value)
    }
  }
  return [...seen.entries()].map(([k, v]) => `${k}=${v}`).join('; ')
}

/** 保存登录 cookie 到文件（只存干净的 name=value，重启后保持登录态） */
function persistCookie(cookie) {
  if (!cookie) return
  const str = cleanCookie(cookie).trim()
  if (!str) return
  const hasLogin = /(^|;\s*)MUSIC_U=/.test(str)
  // 防御：扫码过程中 801/802 阶段可能只返回 NMTID（无 MUSIC_U），
  // 不能让它覆盖已保存的完整登录态 cookie，否则登录状态会"消失"
  if (!hasLogin && /(^|;\s*)MUSIC_U=/.test(savedCookie)) {
    console.log('[cookie] 收到非登录态 cookie（无 MUSIC_U），保留现有登录态')
    return
  }
  savedCookie = str
  try {
    fs.writeFileSync(COOKIE_FILE, str, 'utf8')
    console.log('[cookie] 已保存' + (hasLogin ? '登录态' : '临时cookie') + '（' + str.split('; ').length + ' 项）')
  } catch (e) {
    console.error('[cookie 保存失败]', e.message)
  }
}

/** 调用网易云 API 的统一封装：自动带上已保存 cookie，返回 body */
// ---- 每请求上下文：客户端自带的 Cookie（多设备独立登录态） ----
// 每个 HTTP 请求进入路由时，把请求头 Cookie 存入 ALS；
// call() 里优先用请求自带的 cookie，其次才回退到全局 cookie.txt。
// 这样"谁的手机登录的就是谁的账号"，互相不覆盖。
const als = new AsyncLocalStorage()

async function call(name, params = {}) {
  const fn = NCM[name]
  if (!fn) {
    const err = new Error(`不存在的接口: ${name}`)
    err.status = 400
    throw err
  }
  const ctx = als.getStore()
  const reqCookie = (ctx && ctx.cookie) || ''
  const result = await fn({ ...params, cookie: params.cookie || reqCookie || savedCookie })
  // 接口返回了新 cookie（登录成功等）：客户端自带 cookie → 返回给客户端自行保存（不污染全局）；
  // 客户端未带 cookie（网页版/旧客户端）→ 兼容旧行为写全局（persistCookie 内部有登录态防御）
  if (result && result.cookie) {
    const clean = cleanCookie(result.cookie).trim()
    const hasLogin = /(^|;\s*)MUSIC_U=/.test(clean)
    if (!reqCookie) {
      persistCookie(clean)
    } else if (hasLogin && result.body && typeof result.body === 'object') {
      result.body.cookie = clean
    }
  }
  return result.body
}

function send(res, status, data) {
  const body = JSON.stringify(data)
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*', // 方便网页播放器跨域调用
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Cookie', // 客户端自带登录 cookie
  })
  res.end(body)
}

function fail(res, err) {
  console.error('[接口错误]', err && err.message)
  const status = err && err.status ? err.status : 500
  send(res, status, { code: status, message: err ? err.message : '未知错误' })
}

/** 图片链接尺寸处理：网易云封面 URL 追加 ?param=WxH 可裁剪 */
function resizePic(url, size = 300) {
  if (!url) return url
  // 网易云 CDN 支持 https，统一转 https：避免 http 明文在部分
  // 环境/客户端（如 Android 网络安全策略）加载失败导致封面占位
  const httpsUrl = url.replace(/^http:\/\//i, 'https://')
  return `${httpsUrl}?param=${size}y${size}`
}

// ---- 音频流代理 ----
// 解锁源（酷我/咪咕等 CDN）大多有防盗链，浏览器直连会被挡；
// 这里由服务端抓取（带 Referer/UA 等请求头、支持 Range 拖进度），再转发给浏览器播放。
async function proxyStream(target, req, res) {
  if (!/^https?:\/\//i.test(target)) {
    return send(res, 400, { code: 400, message: 'url 参数无效' })
  }
  let host = ''
  try { host = new URL(target).host } catch (e) { /* 忽略 */ }

  const upstreamHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    Accept: '*/*',
    Referer: host ? `https://${host}/` : 'https://music.163.com/', // 防盗链 Referer
  }
  if (req.headers.range) upstreamHeaders.Range = req.headers.range // 支持拖动进度条

  try {
    const upstream = await fetch(target, { headers: upstreamHeaders })
    if (!upstream.ok && upstream.status !== 206) {
      console.error('[stream] 上游返回', upstream.status, target)
      return send(res, 502, { code: 502, message: '上游返回 ' + upstream.status })
    }
    // 逐个头拼接，避免 undefined 值传给 writeHead 报错
    const outHeaders = {
      'Content-Type': upstream.headers.get('content-type') || 'application/octet-stream',
      'Accept-Ranges': 'bytes',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
    }
    const cl = upstream.headers.get('content-length')
    if (cl) outHeaders['Content-Length'] = cl
    const cr = upstream.headers.get('content-range')
    if (cr) outHeaders['Content-Range'] = cr

    res.writeHead(upstream.status, outHeaders)
    const reader = upstream.body.getReader()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      res.write(value)
    }
    res.end()
  } catch (e) {
    console.error('[stream] 代理失败', e && e.message)
    if (!res.headersSent) send(res, 502, { code: 502, message: '代理失败: ' + (e && e.message) })
    else res.end()
  }
}


// ---- 路由表 ----
const routes = {
  // 搜索歌曲
  async search(q, p) {
    const body = await call('cloudsearch', {
      keywords: q.get('keywords') || '',
      limit: Number(q.get('limit') || 20),
      offset: Number(q.get('offset') || 0),
      type: 1,
    })
    const songs = (body.result ? body.result.songs : []).map((s) => ({
      id: s.id,
      name: s.name,
      artists: (s.ar || []).map((a) => a.name),
      album: s.al ? s.al.name : '',
      cover: resizePic(s.al ? s.al.picUrl : '', 300),
      duration: s.dt,
    }))
    return { code: 200, songs }
  },

  // B站源搜索：网易云没有版权的歌（如QQ音乐独家VIP曲目），B站有完整版
  // GET /search/bili?keywords=最伟大的作品&limit=20
  'search/bili': async (q, p) => {
    const keywords = q.get('keywords') || ''
    if (!keywords) throw Object.assign(new Error('缺少参数 keywords'), { status: 400 })
    const limit = Number(q.get('limit') || 20)
    const songs = await biliSearch(keywords, limit)
    return { code: 200, result: { songs, count: songs.length }, source: 'bilibili' }
  },

  // 获取播放地址（br 为码率，不传则用 999000 取最高可用）
  // 受限/试听歌曲自动触发"音源解锁"：从其他平台匹配可用源（同 VutronMusic 逻辑）
  'song/url': async (q, p) => {
    const id = q.get('id')
    if (!id) throw Object.assign(new Error('缺少参数 id'), { status: 400 })
    const body = await call('song_url', { id: Number(id), br: Number(q.get('br') || 999000) })
    const data = (body.data || [])[0] || {}
    // 网易云返回为空或为试听片段（freeTrialInfo 非空）时，尝试解锁
    if (!data.url || data.freeTrialInfo !== null) {
      const un = await unblockSong(data.id || id)
      if (un && un.url) {
        return {
          code: 200,
          data: {
            id: data.id || Number(id),
            url: un.url,
            br: un.br || null,
            size: un.size || null,
            source: un.source || 'unblock',
            unblocked: true,
          },
        }
      }
    }
    return { code: 200, data: { id: data.id, url: data.url, br: data.br, size: data.size } }
  },

  // 强制走音源解锁：直接从其他平台匹配播放源（不依赖网易云）
  'song/url/unblock': async (q, p) => {
    const id = q.get('id')
    if (!id) throw Object.assign(new Error('缺少参数 id'), { status: 400 })
    const un = await unblockSong(id)
    if (!un) {
      return { code: 200, data: null, message: '未能从其他平台匹配到可用源' }
    }
    return { code: 200, data: { id: Number(id), url: un.url, br: un.br || null, size: un.size || null, source: un.source || 'unblock' } }
  },

  // B站源取播放地址：返回走 /stream/bili 代理的相对路径（播放器拼 base 前缀）
  // GET /song/url/bili?bvid=BV1EfwEzkEzb
  'song/url/bili': async (q, p) => {
    const bvid = q.get('bvid') || ''
    if (!bvid) throw Object.assign(new Error('缺少参数 bvid'), { status: 400 })
    const audio = await biliAudioUrl(bvid)
    return {
      code: 200,
      data: {
        id: bvid,
        url: '/stream/bili?bvid=' + encodeURIComponent(bvid),
        duration: audio.duration,
        size: audio.size,
        source: 'bilibili',
        unblocked: true,
      },
    }
  },

  // 歌词（lrc=原文歌词, tlyric=翻译）
  async lyric(q, p) {
    const id = q.get('id')
    if (!id) throw Object.assign(new Error('缺少参数 id'), { status: 400 })
    const body = await call('lyric', { id: Number(id) })
    return {
      code: 200,
      lrc: body.lrc ? body.lrc.lyric : '',
      tlyric: body.tlyric ? body.tlyric.lyric : '',
    }
  },

  // 歌曲详情（ids 逗号分隔；返回封面、名称、歌手、专辑）
  'song/detail': async (q, p) => {
    const ids = (q.get('ids') || '').split(',').map(Number).filter(Boolean)
    if (!ids.length) throw Object.assign(new Error('缺少参数 ids'), { status: 400 })
    const body = await call('song_detail', { ids: ids.join(',') })
    const songs = (body.songs || []).map((s) => ({
      id: s.id,
      name: s.name,
      artists: (s.ar || []).map((a) => a.name),
      album: s.al ? s.al.name : '',
      cover: resizePic(s.al ? s.al.picUrl : '', 300),
      duration: s.dt,
    }))
    return { code: 200, songs }
  },

  // 歌单详情（返回歌单信息 + 前 1000 首）
  async playlist(q, p) {
    const id = q.get('id')
    if (!id) throw Object.assign(new Error('缺少参数 id'), { status: 400 })
    const body = await call('playlist_detail', { id: Number(id) })
    const pl = body.playlist || {}
    const tracks = (pl.tracks || []).map((s) => ({
      id: s.id,
      name: s.name,
      artists: (s.ar || []).map((a) => a.name),
      album: s.al ? s.al.name : '',
      cover: resizePic(s.al ? s.al.picUrl : '', 300),
      duration: s.dt,
    }))
    return {
      code: 200,
      playlist: {
        id: pl.id,
        name: pl.name,
        cover: resizePic(pl.coverImgUrl, 300),
        trackCount: pl.trackCount,
        playCount: pl.playCount,
      },
      tracks,
    }
  },

  // 创建二维码登录（返回 unikey + 二维码 base64 + 扫码链接）
  'login/qr': async (q, p) => {
    const keyBody = await call('login_qr_key')
    const unikey = keyBody.data ? keyBody.data.unikey : ''
    const qrBody = await call('login_qr_create', { key: unikey, qrimg: true })
    return {
      code: 200,
      unikey,
      qrimg: qrBody.data ? qrBody.data.qrimg : '',
      url: qrBody.data ? qrBody.data.url : '',
    }
  },

  // 轮询二维码登录状态：code 800=过期 801=待扫码 802=已扫码待确认 803=登录成功(已保存 cookie)
  'login/qr/check': async (q, p) => {
    const key = q.get('key')
    if (!key) throw Object.assign(new Error('缺少参数 key'), { status: 400 })
    const body = await call('login_qr_check', { key })
    return { code: body.code, message: body.message }
  },

  // 当前登录状态
  async status(q, p) {
    const body = await call('login_status')
    const account = body.data ? body.data.account : null
    const profile = body.data ? body.data.profile : null
    return {
      code: 200,
      loggedIn: !!profile,
      user: profile ? { id: profile.userId, nickname: profile.nickname, avatar: profile.avatarUrl } : null,
    }
  },

  // 退出登录：客户端自带 cookie 时，只登出"该客户端"的网易云账号，
  // 不清全局 cookie.txt（避免影响其他设备）；未带 cookie 才清全局
  async logout(q, p) {
    const ctx = als.getStore()
    const reqCookie = (ctx && ctx.cookie) || ''
    if (reqCookie) {
      try {
        await call('logout')
      } catch (e) {
        /* 登出失败不阻塞 */
      }
      return { code: 200, loggedIn: false }
    }
    try {
      await call('logout')
    } catch (e) {
      /* 登出失败不阻塞：本地 cookie 照常清空 */
    }
    savedCookie = ''
    try {
      fs.writeFileSync(COOKIE_FILE, '', 'utf8')
    } catch (e) {
      /* 忽略 */
    }
    return { code: 200, loggedIn: false }
  },

  // 喜欢/取消喜欢一首歌（同步网易云"我喜欢的音乐"，需登录）
  // GET /like?id=歌曲id&like=1    like 省略或 1=喜欢，0/false=取消
  async like(q, p) {
    const id = q.get('id')
    if (!id) throw Object.assign(new Error('缺少参数 id'), { status: 400 })
    const likeVal = !(q.get('like') === '0' || q.get('like') === 'false')
    // 先查登录态：未登录直接返回（不要依赖 call('like') 抛错），
    // 避免服务端把"未登录"当成 500 处理、App 误判为网络失败
    const st = await call('login_status')
    const profile = st.data && st.data.profile
    if (!profile) return { code: 200, loggedIn: false, liked: false, like: likeVal }
    // 已登录：只要 call('like') 不抛异常即视为成功，
    // 成功判定不用 body.code === 200 这种可能误判的硬条件
    // 注意：@neteasecloudmusicapienhanced/api 的 like 接口用
    // `query.like == 'false' ? false : true` 判断，传 boolean false 会被
    // 宽松比较误判为 true（取消变"再喜欢一次"），必须传字符串 'true'/'false'
    await call('like', { id: Number(id), like: likeVal ? 'true' : 'false' })
    return { code: 200, loggedIn: true, liked: likeVal, like: likeVal }
  },

  // 我喜欢的音乐 id 列表（用于展示歌曲是否已喜欢，需登录）
  async likelist(q, p) {
    const st = await call('login_status')
    const account = st.data && st.data.account
    if (!account) return { code: 200, loggedIn: false, ids: [] }
    const body = await call('likelist', { uid: account.id })
    return { code: 200, loggedIn: true, ids: body.ids || [] }
  },

  // 每日推荐（需登录）
  async recommend(q, p) {
    const body = await call('recommend_songs')
    const songs = (body.data && body.data.dailySongs) || []
    return {
      code: 200,
      songs: songs.map((s) => ({
        id: s.id,
        name: s.name,
        artists: (s.ar || []).map((a) => a.name),
        album: s.al ? s.al.name : '',
        cover: resizePic(s.al ? s.al.picUrl : '', 300),
        duration: s.dt,
      })),
    }
  },

  // 用户歌单（导入网易云歌单用）：uid 不传时自动用当前登录用户；未登录返回 loggedIn:false
  'user/playlist': async (q, p) => {
    let uid = q.get('uid')
    if (!uid) {
      const st = await call('login_status')
      const profile = st.data && st.data.profile
      if (!profile) return { code: 200, loggedIn: false, playlists: [] }
      uid = String(profile.userId)
    }
    const body = await call('user_playlist', {
      uid: Number(uid),
      limit: Number(q.get('limit') || 50),
      offset: Number(q.get('offset') || 0),
    })
    const playlists = (body.playlist || []).map((p) => ({
      id: p.id,
      name: p.name,
      cover: resizePic(p.coverImgUrl, 300),
      trackCount: p.trackCount,
      playCount: p.playCount,
      creator: p.creator ? p.creator.nickname : '',
    }))
    return { code: 200, loggedIn: true, uid, playlists }
  },
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Cookie',
    })
    return res.end()
  }

  const u = new URL(req.url, `http://localhost:${PORT}`)
  const name = u.pathname.replace(/^\/+/, '').replace(/\/+$/, '')

  // 音频流代理（二进制转发，不走 JSON 路由）
  if (name === 'stream') {
    return proxyStream(u.searchParams.get('url'), req, res)
  }

  // B站音频流代理（带 bilibili Referer 防盗链 + Range）
  if (name === 'stream/bili') {
    const bvid = u.searchParams.get('bvid')
    if (!bvid) return send(res, 400, { code: 400, message: '缺少参数 bvid' })
    return proxyBiliStream(bvid, req, res)
  }

  // 网页播放器（iPhone/其他设备 Safari 直接访问，无需安装 App）
  if (name === '' || name === 'player' || name === 'player.html') {
    fs.readFile(path.join(__dirname, 'player.html'), (err, buf) => {
      if (err) {
        return send(res, 404, { code: 404, message: 'player.html 不存在' })
      }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
      res.end(buf)
    })
    return
  }

  const handler = routes[name]

  if (!handler) {
    return send(res, 404, {
      code: 404,
      message: '未知接口，可用接口: search / search/bili / song/url / song/url/unblock / song/url/bili / stream?url= / stream/bili?bvid= / lyric / song/detail / playlist / user/playlist / like / likelist / login/qr / login/qr/check / status / logout / recommend',
    })
  }

  // 以请求自带的 Cookie 为上下文执行 handler（多设备独立登录态）
  als.run({ cookie: req.headers.cookie || '' }, async () => {
    try {
      const data = await handler(u.searchParams, req)
      send(res, 200, data)
    } catch (e) {
      fail(res, e)
    }
  })
})

server.listen(PORT, () => {
  console.log(`网易云音源服务已启动: http://localhost:${PORT}`)
  console.log('可用接口:')
  console.log('  GET /search?keywords=周杰伦&limit=20')
  console.log('  GET /search/bili?keywords=最伟大的作品&limit=20   (B站源，网易云没有的歌)')
  console.log('  GET /song/url?id=123&br=320000   (受限歌曲自动解锁)')
  console.log('  GET /lyric?id=123')
  console.log('  GET /song/detail?ids=123,456')
  console.log('  GET /playlist?id=歌单id')
  console.log('  GET /user/playlist?uid=可选   (导入网易云歌单，uid留空用登录用户)')
  console.log('  GET /login/qr  → 获取二维码')
  console.log('  GET /login/qr/check?key=xxx  → 轮询登录状态')
  console.log('  GET /status  → 登录状态')
  console.log('  GET /recommend  → 每日推荐(需登录)')
  console.log(savedCookie ? '登录态: 已保存 cookie' : '登录态: 未登录（在线播放可能需要先登录）')
})