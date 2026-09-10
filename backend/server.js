/**
 * 独立网易云音乐音源模块（个人学习用途）
 *
 * 轻量 HTTP 服务，封装 @neteasecloudmusicapienhanced/api，
 * 供你自己写的播放器调用：搜索 / 播放地址 / 歌词 / 歌曲详情 / 歌单 / 二维码登录
 *
 * 启动：node server.js   （默认端口 41831，可用环境变量 PORT 修改）
 */
// 酷狗 everydayrec/persnfm 等 CDN 域名的证书 SAN 与域名不匹配（ERR_TLS_CERT_ALTNAME_INVALID），
// Node fetch 默认校验证书会报 fetch failed；音源服务只访问音乐平台官方 API，统一关闭 TLS 证书校验。
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'
const http = require('http')
const { URL } = require('url')
const fs = require('fs')
const path = require('path')
const { AsyncLocalStorage } = require('async_hooks')

const NCM = require('@neteasecloudmusicapienhanced/api')
const kugou = require('./kugou-api')
const qq = require('./qq-api')
// 汽水音乐模块（第4音源）：可选加载——本地上传了 soda-api.js 才启用，
// 公开仓库暂缓汽水登录，soda-api.js 不上传时后端依旧可正常启动。
let soda = null
try {
  soda = require('./soda-api')
} catch (e) {
  console.warn('[soda] soda-api.js 未安装，汽水音乐路由暂缓（/soda/* 返回 404）')
}

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
const UNBLOCK_SOURCES = ['kugou', 'ytdlp', 'qq', 'bilibili', 'migu', 'pyncmd']

/** 从其他平台为受限歌曲匹配可用播放源；失败返回 null */
/** 从其他平台为受限歌曲匹配可用播放源；失败返回 null。sources 可传自定义顺序（酷狗链路用 qq→migu→ytdlp，B站最后兜底） */
async function unblockSong(id, sources = UNBLOCK_SOURCES, songInfo = null) {
  if (!unblockMatch) return null
  try {
    const res = songInfo
      ? await unblockMatch(Number(id), sources, songInfo)
      : await unblockMatch(Number(id), sources)
    if (res && res.url) {
      // pyncmd 是第三方网盘云 API（GD studio），曾出现串歌（不同歌返回同一资源）。
      // 只信它返回网易云官方 CDN（music.126.net）的资源，网盘/FLAC 一律拒绝。
      if (res.source === 'pyncmd' && !/music\.126\.net/.test(res.url)) {
        console.warn('[unblock] pyncmd 返回非网易云CDN资源，拒绝', id, String(res.url).slice(0, 70))
        return null
      }
      return res
    }
    return null
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
/** 网易云搜索候选：歌名完全相等+歌手命中 优先，其次 歌名互含+歌手命中，最后 仅歌手命中；过滤短时长/翻唱/钢琴等非原版。返回最多 3 个候选依次尝试 */
function artistHit(artist, arList) {
  const t = String(artist || '').trim().toLowerCase()
  if (!t) return false
  return (arList || []).some((a) => {
    const an = String(a.name || '').trim().toLowerCase()
    return an === t || an.includes(t) || t.includes(an)
  })
}
function neteaseCandidates(songs, name, artist) {
  const BAD = /钢琴|翻唱|cover|Live|现场|伴奏|remix|AI|纯音乐|演奏|吉他|尤克里里|合唱|童声|片段|串烧|架子鼓|萨克斯|女声版|男声版|深情|DJ|Beat|Trap|说唱|小提琴|笛子|二胡|古筝|口琴/i
  const clean = (s) => String(s || '').replace(/\s+/g, '').toLowerCase()
  const tn = clean(name)
  const list = (songs || []).filter((s) => {
    const d = Number(s.dt || 0)
    if (d > 0 && d < 60000) return false
    if (BAD.test(String(s.name || ''))) return false
    return true
  })
  const nameHit = list.filter((s) => {
    const sn = clean(s.name)
    return sn === tn || sn.includes(tn) || tn.includes(sn)
  })
  const withArtist = nameHit.filter((s) => artistHit(artist, s.ar))
  // direct：歌名强匹配 + 歌手命中 + 正版 id（<20亿，网易云官方发行；≥20亿是用户上传 UGC，内容不可信，不直取）
  const direct = withArtist.filter((s) => Number(s.id) < 2000000000)
  // unblock：优先歌手命中，其次仅歌名命中（unblock 拿歌名去 QQ/咪咕 搜，不限网易云侧歌手）
  // unblock 候选强制歌名+歌手双命中（unblock 在 QQ/咪咕 侧匹配同歌正版，不匹配翻唱）
  const unblockList = withArtist.slice(0, 3)
  return { direct: direct.slice(0, 3), unblock: unblockList }
}

/** B站结果强匹配：歌名含目标歌名，且歌手字段或视频标题含目标歌手 */

/** 通用换源：按 歌名+歌手+时长 在网易云强匹配 → 免费直链 → 解锁源 → B站兜底。
 *  与 QQ 音乐链路完全一致（分层匹配 + 解锁 + B站强匹配）。返回统一结构或 null。 */
async function fallbackSong(name, artist, duration, fromLabel, host) {
  if (!name) return null
  const stripPunct = (s) => String(s || '').replace(/[\s!！?？.。·、,，\-—:：'"“”‘’()（）[\]【】×*＊/+]/g, '').toLowerCase()
  const pick = (songs, durRef) => {
    const tn = String(name || '').replace(/\s+/g, '').toLowerCase()
    const tokens = String(artist || '').split(/[/、,&，;；\s]+/).filter(Boolean).map((t) => t.toLowerCase())
    const dur = Number(durRef) || 0
    const durOk = (s) => dur <= 0 || s.duration <= 0 || Math.abs(dur - s.duration) / dur <= 0.25
    const artistHitOf = (s) => {
      const sa = String(s.artist || '').toLowerCase()
      return tokens.length === 0 || tokens.some((t) => sa.includes(t))
    }
    const tiers = [[], [], [], []]
    for (let i = 0; i < songs.length; i++) {
      const s = songs[i]
      const sn = String(s.name || '').replace(/\s+/g, '').toLowerCase()
      if (!sn || !tn || !(sn.includes(tn) || tn.includes(sn))) continue
      const nameEq = stripPunct(s.name) === stripPunct(name)
      if (nameEq && durOk(s)) tiers[0].push({ s, i })
      else if (artistHitOf(s) && durOk(s)) tiers[1].push({ s, i })
      else if (durOk(s)) tiers[2].push({ s, i })
      else tiers[3].push({ s, i })
    }
    for (const tier of tiers) {
      if (!tier.length) continue
      const hit = tier.find((x) => artistHitOf(x.s))
      return (hit || tier[0]).s
    }
    return null
  }
  try {
    const searchKw = [name, artist].filter(Boolean).join(' ')
    let body = await call('cloudsearch', { keywords: searchKw, limit: 10, type: 1 })
    let songs = ((body.result && body.result.songs) || []).map((s) => ({
      id: s.id, name: s.name, artist: (s.ar || []).map((a) => a.name).join(' / '), duration: s.dt || 0,
    }))
    let hit = pick(songs, Number(duration || 0))
    if (!hit && artist) {
      body = await call('cloudsearch', { keywords: name, limit: 10, type: 1 })
      songs = ((body.result && body.result.songs) || []).map((s) => ({
        id: s.id, name: s.name, artist: (s.ar || []).map((a) => a.name).join(' / '), duration: s.dt || 0,
      }))
      hit = pick(songs, Number(duration || 0))
    }
    if (hit) {
      try {
        const freeBody = await call('song_url', { id: hit.id, br: 320000 })
        const freeData = (freeBody.data || [])[0] || {}
        if (freeData.url && freeData.freeTrialInfo === null) {
          return { url: freeData.url, br: 320000, type: 'mp3', source: 'netease', unblocked: false, fallbackFrom: fromLabel, matched: { name: hit.name, artist: hit.artist } }
        }
      } catch (e) { console.error('[' + fromLabel + '] 网易云官方直链失败', e && e.message) }
      const un = await unblockSong(hit.id, UNBLOCK_SOURCES)
      if (un && un.url) {
        return { url: un.url, br: un.br || null, type: 'mp3', source: un.source || 'unblock', unblocked: true, fallbackFrom: fromLabel, matched: { name: hit.name, artist: hit.artist } }
      }
    }
  } catch (e) { console.error('[' + fromLabel + '] 解锁兜底失败', e && e.message) }
  try {
    const bs = await biliSearch([name, artist].filter(Boolean).join(' '))
    const hit = strongPickBili(bs, name, artist, Number(duration || 0) ? [Number(duration)] : [])
    if (hit) {
      const h = host || ('127.0.0.1:' + PORT)
      return { url: 'http://' + h + '/stream/bili?bvid=' + encodeURIComponent(hit.bvid), type: 'mp3', source: 'bilibili', unblocked: true, fallbackFrom: fromLabel, matched: { name: hit.name, artist: hit.artist || '' } }
    }
  } catch (e) { console.error('[' + fromLabel + '] B站兜底失败', e && e.message) }
  return null
}

function strongPickBili(songs, name, artist, refDurations = []) {
  const clean = (s) => String(s || '').replace(/\s+/g, '').toLowerCase()
  const tn = clean(name)
  const ta = clean(artist)
  // 非音乐版本黑名单（B站常见鼓谱/伴奏/教学/Live/remix 等错版）
  const BAD = /(伴奏|鼓谱|琴谱|乐谱|歌谱|教学|教程|钢琴|remix|bootleg|live|现场|翻唱|cover|演奏|无人声|纯伴奏|和声|乐评|素材|转场|1\.1x|1\.2x|指弹|串烧|模仿|动态|教学视频|讲解|开箱|鬼畜)/
  // 质量优先级：Q1 无损音质/视听版本（用户点名最高）→ Q2 官方/原版/MV/完整/4K
  const Q1 = /(无损|hi-res|hires|视听)/
  const Q2 = /(官方|原版|mv|完整|4k)/
  // 参考正版时长（毫秒→秒）：来自 QQ 音乐正版或酷狗音乐正版
  const refs = (refDurations || []).map(Number).filter((d) => d > 0).map((d) => d / 1000)
  const hit = (s) => {
    const sn = clean(s.name)
    const sa = clean(s.artist || '')
    if (BAD.test(sn)) return false
    if (tn && !(sn.includes(tn) || tn.includes(sn))) return false
    if (ta && !(sa.includes(ta) || sn.includes(ta))) return false
    return true
  }
  const matched = (songs || []).filter(hit)
  if (!matched.length) return null
  const dur = (s) => Number(s.duration || 0)
  if (refs.length) {
    // 时长与任一正版参考相差 <= 25s 才采信（排除 Live/剪辑/翻唱等错版）
    const within = matched.filter((s) => {
      const d = dur(s)
      if (!d) return false
      return refs.some((r) => Math.abs(d - r) <= 35)
    })
    if (within.length) {
      // 时长相近前提下：无损音质/视听 优先 → 官方/原版/MV → 普通；同层按时长最接近
      const qrank = (n) => (Q1.test(n) ? 0 : Q2.test(n) ? 1 : 2)
      return within.sort((a, b) => {
        const ra = qrank(clean(a.name))
        const rb = qrank(clean(b.name))
        if (ra !== rb) return ra - rb
        const da = Math.min(...refs.map((r) => Math.abs(dur(a) - r)))
        const db = Math.min(...refs.map((r) => Math.abs(dur(b) - r)))
        return da - db
      })[0]
    }
    // 歌名/歌手命中但时长差太远（Live/剪辑/翻唱）→ 宁缺毋滥
    return null
  }
  // 无参考时长：黑名单过滤后取第一条
  return matched[0]
}

/** 用 QQ 音乐正版时长作 B站兜底的参考时长（毫秒数组，取前3候选；失败返回空） */
async function qqSearchDurations(name, artist) {
  try {
    const query = [name, artist].filter(Boolean).join(' ').trim()
    if (!query) return []
    const url = 'https://u.y.qq.com/cgi-bin/musicu.fcg?data=' + encodeURIComponent(JSON.stringify({
      search: {
        method: 'DoSearchForQQMusicDesktop',
        module: 'music.search.SearchCgiService',
        param: { num_per_page: 3, page_num: 1, query, search_type: 0 },
      },
    }))
    const { stdout } = await execFileAsync(CURL, ['-s', '--compressed', '-A', 'Mozilla/5.0', '-H', 'Referer: http://y.qq.com/', url], { maxBuffer: 5 * 1024 * 1024, timeout: 20000 })
    const j = JSON.parse(stdout)
    const list = (j.search && j.search.data && j.search.data.body && j.search.data.body.song && j.search.data.body.song.list) || []
    return list.map((x) => (x && x.interval ? Number(x.interval) * 1000 : 0)).filter((d) => d > 0)
  } catch (e) {
    return []
  }
}

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
      // unblock 失败 → B站强匹配兜底（网易云 VIP/无版权歌也能听完整版）
      try {
        const det = await call('song_detail', { ids: String(id) })
        const song = (det.songs || [])[0]
        if (song && song.name) {
          const artistStr = (song.ar || []).map((a) => a.name).join(' ')
          const bs = await biliSearch((song.name + ' ' + artistStr).trim())
          const hit = strongPickBili(bs, song.name, artistStr, song.duration ? [Number(song.duration)] : [])
          if (hit) {
            const host = (p && p.headers && p.headers.host) || ('127.0.0.1:' + PORT)
            return {
              code: 200,
              data: {
                id: Number(id),
                url: 'http://' + host + '/stream/bili?bvid=' + encodeURIComponent(hit.bvid),
                type: 'mp3',
                source: 'bilibili',
                unblocked: true,
                fallbackFrom: 'netease',
              },
            }
          }
        }
      } catch (e) {
        console.error('[song/url] B站兜底失败', e && e.message)
      }
      // 仍是试听：标记 trial，前端可提示或自动跳下一首
      return { code: 200, data: { id: data.id || Number(id), url: data.url || '', br: data.br || null, size: data.size || null, trial: true } }
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

  // 歌词多源兜底：按 歌名+歌手（+时长）强匹配，网易云 → 酷狗 依次取
  // 返回 {code, lrc, tlyric, source}；找不到时 lrc 为空串，前端显示"暂无歌词"
  'lyric/any': async (q, p) => {
    const name = (q.get('name') || '').trim()
    const artist = (q.get('artist') || '').trim()
    if (!name) throw Object.assign(new Error('缺少参数 name'), { status: 400 })
    const duration = Number(q.get('duration') || 0)

    // 强匹配打分：歌名互含 + 歌手 token 命中 → 返回时长差（越小越优）；不匹配返回 -1
    const pick = (songs) => {
      let best = null
      let bestDiff = Infinity
      for (const s of songs) {
        const sn = String(s.name || '').replace(/\s+/g, '').toLowerCase()
        const tn = String(name || '').replace(/\s+/g, '').toLowerCase()
        if (!sn || !tn || !(sn.includes(tn) || tn.includes(sn))) continue
        const tokens = String(artist || '').split(/[/、,&，;；\s]+/).filter(Boolean).map((t) => t.toLowerCase())
        const sa = String(s.artist || '').toLowerCase()
        if (tokens.length && !tokens.some((t) => sa.includes(t))) continue
        const diff = duration > 0 && s.duration > 0 ? Math.abs(duration - s.duration) : 0
        if (diff < bestDiff) { best = s; bestDiff = diff }
      }
      return best
    }

    // 1) 网易云：搜索 → 强匹配 → 原文 + 翻译
    try {
      const body = await call('cloudsearch', {
        keywords: [name, artist].filter(Boolean).join(' '), limit: 10, type: 1,
      })
      const songs = ((body.result && body.result.songs) || []).map((s) => ({
        id: s.id,
        name: s.name,
        artist: (s.ar || []).map((a) => a.name).join(' / '),
        duration: s.dt || 0,
      }))
      const hit = pick(songs)
      if (hit) {
        const ly = await call('lyric', { id: hit.id })
        if (ly.lrc && ly.lrc.lyric) {
          return {
            code: 200,
            lrc: ly.lrc.lyric,
            tlyric: ly.tlyric ? ly.tlyric.lyric : '',
            source: 'netease',
            matched: { name: hit.name, artist: hit.artist },
          }
        }
      }
    } catch (_) { /* 网易云失败继续酷狗 */ }

    // 2) 酷狗：搜索 → 强匹配 → 歌词服务器
    try {
      const bs = await kugou.search([name, artist].filter(Boolean).join(' '), 1, 10)
      const hit = pick((bs.songs || []))
      if (hit && hit.hash) {
        const ly = await kugou.lyric(hit.hash)
        if (ly && ly.lrc) {
          return {
            code: 200,
            lrc: ly.lrc,
            tlyric: ly.tlyric || '',
            source: 'kugou',
            matched: { name: hit.name, artist: hit.artist },
          }
        }
      }
    } catch (_) { /* 酷狗失败返回空 */ }

    return { code: 200, lrc: '', tlyric: '', source: '', matched: null }
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

  // 私人雷达歌单（需登录）：三重兜底识别（按优先级）
  // ① 固定歌单 ID 3136952023（网易云官方私人雷达，VutronMusic 等项目通用）
  // ② /recommend/resource 推荐列表中名称包含"雷达"的歌单
  // ③ 推荐列表第一个
  async radar(q, p) {
    const RADAR_PLAYLIST_ID = '3136952023'
    const st = await call('login_status')
    const account = st.data && st.data.account
    if (!account) {
      return { code: 200, loggedIn: false, playlistId: null, playlistName: '', songs: [] }
    }

    const mapTracks = (tracks) => (tracks || []).map((s) => ({
      id: s.id,
      name: s.name,
      artists: (s.ar || []).map((a) => a.name),
      album: s.al ? s.al.name : '',
      cover: resizePic(s.al ? s.al.picUrl : '', 300),
      duration: s.dt,
    }))

    const fromDetail = async (id, fallbackName) => {
      const body = await call('playlist_detail', { id: Number(id) })
      const pl = body.playlist || {}
      if (!(pl.tracks || []).length) return null
      return {
        code: 200,
        loggedIn: true,
        playlistId: String(pl.id || id),
        playlistName: pl.name || fallbackName || '私人雷达',
        songs: mapTracks(pl.tracks),
      }
    }

    // ① 固定歌单 ID 直接获取（最准确）
    try {
      const r = await fromDetail(RADAR_PLAYLIST_ID, '私人雷达')
      if (r) return r
      console.error('[radar] 固定 ID 无曲目，走兜底')
    } catch (e) {
      console.error('[radar] 固定 ID 获取失败，走兜底:', e && e.message)
    }

    // ②③ 每日推荐歌单列表：名称含"雷达"优先，否则取第一个
    try {
      const rec = await call('recommend_resource')
      const list = (rec && rec.recommend) || []
      const radar = list.find((pl) => pl.name && pl.name.includes('雷达')) || list[0]
      if (radar && radar.id) {
        const r = await fromDetail(radar.id, radar.name)
        if (r) return r
      }
    } catch (e) {
      console.error('[radar] recommend_resource 兜底失败:', e && e.message)
    }

    return { code: 404, loggedIn: true, playlistId: null, playlistName: '', songs: [], message: '获取雷达歌单失败' }
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
  'login/qr/check': async (q, req) => {
    const key = q.get('key')
    if (!key) throw Object.assign(new Error('缺少参数 key'), { status: 400 })
    const body = await call('login_qr_check', { key })
    // 登录成功（code=803）时记录日志（本地专用模块，开源版本无此功能）
    if (body.code === 803 && adminLogger) {
      try {
        const st = await call('login_status')
        const profile = st.data && st.data.profile
        const rawIp = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').toString()
        adminLogger.recordLogin({
          userId: profile ? profile.userId : '',
          nickname: profile ? profile.nickname : '未知',
          ip: rawIp.split(',')[0].trim(),
          userAgent: req.headers['user-agent'] || '',
        })
      } catch (e) { /* 记录日志失败不影响登录响应 */ }
    }
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
    // 封面字段多重兜底：coverImgUrl / picUrl / coverUrl / imgUrl
    const pickCover = (obj) => obj.coverImgUrl || obj.picUrl || obj.coverUrl || obj.imgUrl || ''
    let playlists = (body.playlist || []).map((pl) => ({
      id: pl.id,
      name: pl.name,
      cover: pickCover(pl) ? resizePic(pickCover(pl), 300) : '',
      trackCount: pl.trackCount,
      playCount: pl.playCount,
      creator: pl.creator ? pl.creator.nickname : '',
    }))
    // 对封面为空的歌单，调 /playlist/detail 补封面（批量并发，最多补 10 个避免太慢）
    const emptyList = playlists.filter((pl) => !pl.cover).slice(0, 10)
    if (emptyList.length > 0) {
      await Promise.all(emptyList.map(async (pl) => {
        try {
          const detail = await call('playlist_detail', { id: pl.id })
          if (detail && detail.playlist && pickCover(detail.playlist)) {
            pl.cover = resizePic(pickCover(detail.playlist), 300)
          }
        } catch (e) { /* 单个歌单补封面失败不影响整体 */ }
      }))
    }
    const emptyCount = playlists.filter((pl) => !pl.cover).length
    console.log(`[user/playlist] uid=${uid} 共${playlists.length}个歌单，封面为空${emptyCount}个`)
    return { code: 200, loggedIn: true, uid, playlists }
  },

  // ============ 酷狗音源（/kugou/*，与网易云独立） ============
  // 多用户登录态隔离：优先使用请求头 Cookie 里的酷狗登录态（App 扫码后自行保存并带回），
  // 不带 Cookie 的请求（网页端/旧客户端）回退全局 kugou-cookie.json。
  'kugou/search': async (q, p) => {
    const keywords = q.get('keywords') || q.get('keyword') || ''
    if (!keywords) throw Object.assign(new Error('缺少参数 keywords'), { status: 400 })
    const data = await kugou.search(keywords, Number(q.get('page') || 1), Number(q.get('pagesize') || 30))
    return Object.assign({ code: 200 }, data)
  },

  'kugou/song/url': async (q, p) => {
    const hash = q.get('hash') || ''
    if (!hash) throw Object.assign(new Error('缺少参数 hash'), { status: 400 })
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    const data = await kugou.v5Url(hash, reqCookie)
    // VIP/付费/无版权 → 按用户指定优先级兜底：网易云直取 → QQ(migu/ytdlp 补充) → B站（歌名+歌手强匹配）
    if (data && data.blocked) {
      const kw = [data.name, data.artist].filter(Boolean).join(' ')
      if (kw) {
        try {
          // 1) 网易云强匹配搜索正版（最多3候选，依次尝试直取/解锁）
          const nb = await call('cloudsearch', { keywords: kw, limit: 20, type: 1 })
          const cands = neteaseCandidates(nb.result && nb.result.songs, data.name, data.artist)
          // 1a) 网易云直取：仅信任正版 id（<20亿），歌名+歌手强匹配
          for (const first of (cands.direct || [])) {
            try {
              const nbody = await call('song_url', { id: Number(first.id), br: 320000 })
              const ndata = (nbody.data || [])[0] || {}
              if (ndata.url && ndata.freeTrialInfo === null) {
                return {
                  code: 200,
                  data: {
                    id: hash,
                    url: ndata.url,
                    br: ndata.br || null,
                    size: ndata.size || null,
                    type: 'mp3',
                    source: 'netease',
                    unblocked: false,
                    fallbackFrom: 'netease',
                    name: data.name,
                    artist: data.artist,
                  },
                }
              }
            } catch (e) { /* 该候选直取失败，继续 */ }
          }
          // 1b) 网易云受限/无正版 → unblock（QQ→migu→ytdlp），跳过酷狗（已试过）
          for (const first of (cands.unblock || [])) {
            try {
              const un = await unblockSong(first.id, ['qq', 'migu', 'ytdlp'], {
                id: Number(first.id) || 0,
                name: data.name || '',
                album: { name: data.album || '' },
                artists: data.artist ? [{ name: data.artist }] : [],
                duration: data.duration || 0,
              })
              if (un && un.url) {
                return {
                  code: 200,
                  data: {
                    id: hash,
                    url: un.url,
                    br: un.br || null,
                    size: un.size || null,
                    type: 'mp3',
                    source: un.source || 'qq',
                    unblocked: true,
                    fallbackFrom: 'netease',
                    name: data.name,
                    artist: data.artist,
                  },
                }
              }
            } catch (e) { /* 该候选解锁失败，继续 */ }
          }
        } catch (e) {
          console.error('[kugou] 网易云兜底失败', e && e.message)
        }
      }
      // 2) B站强匹配搜索（歌名+歌手）→ 代理流
      if (data.name) {
        try {
          const bs = await biliSearch((data.name + ' ' + (data.artist || '')).trim())
          // 正版时长参考：酷狗正版 + QQ音乐正版（任一相近即采信）
          const refDurs = []
          if (data.duration) refDurs.push(Number(data.duration))
          // QQ 正版前3候选时长（音频版/MV版都可能，307s官方MV可匹配306s候选）
          const qdurs = await qqSearchDurations(data.name, data.artist)
          for (const qd of qdurs) refDurs.push(qd)
          const biliHit = strongPickBili(bs, data.name, data.artist, refDurs)
          if (biliHit) {
            const host = (p && p.headers && p.headers.host) || ('127.0.0.1:' + PORT)
            return {
              code: 200,
              data: {
                id: hash,
                url: 'http://' + host + '/stream/bili?bvid=' + encodeURIComponent(biliHit.bvid),
                type: 'mp3',
                source: 'bilibili',
                unblocked: true,
                fallbackFrom: 'bilibili',
                name: data.name,
                artist: data.artist,
              },
            }
          }
        } catch (e) {
          console.error('[kugou] B站兜底失败', e && e.message)
        }
      }
      throw Object.assign(new Error('酷狗无免费音源，网易云/QQ/B站兜底均失败'), { status: 502 })
    }
    return { code: 200, data }
  },

  'kugou/login/qr': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    const key = await kugou.loginQrKey(reqCookie)
    const r = await kugou.loginQrCreate(key)
    return { code: 200, key: key, qrimg: r.qrimg, url: r.url }
  },

  'kugou/login/qr/check': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    const key = q.get('key') || q.get('qrcode') || ''
    if (!key) throw Object.assign(new Error('缺少参数 key'), { status: 400 })
    const r = await kugou.loginQrCheck(key, reqCookie)
    const msgs = { 0: '二维码已过期', 1: '等待扫码', 2: '已扫码，等待确认', 4: '登录成功' }
    const ok = r.status === 4
    return {
      code: 200,
      status: r.status,
      message: msgs[r.status] || '未知状态',
      loggedIn: ok,
      userid: r.userid,
      cookie: ok ? r.cookie : '',
    }
  },

  'kugou/user/playlist': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await kugou.userPlaylist(Number(q.get('page') || 1), Number(q.get('pagesize') || 30), reqCookie))
  },

  'kugou/playlist/detail': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    const id = q.get('id') || q.get('global_collection_id') || q.get('specialid') || ''
    if (!id) throw Object.assign(new Error('缺少参数 id'), { status: 400 })
    return Object.assign({ code: 200 }, await kugou.playlistDetail(id, reqCookie))
  },

  'kugou/recommend/daily': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await kugou.dailyRecommend(reqCookie))
  },

  'kugou/recommend/fm': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await kugou.fmRecommend(reqCookie))
  },

  'kugou/status': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, kugou.status(reqCookie))
  },

  'kugou/logout': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, kugou.logout(reqCookie))
  },

  // ---------------- QQ 音乐（扫码登录 / 歌单 / 每日推荐） ----------------
  'qq/login/qr': async (q, p) => {
    return Object.assign({ code: 200 }, await qq.loginQrKey())
  },
  'qq/login/qr/check': async (q, p) => {
    const key = q.get('key') || ''
    const ptqrtoken = q.get('ptqrtoken') || ''
    const r = await qq.loginQrCheck(key, ptqrtoken)
    return Object.assign({ code: 200 }, r)
  },
  'qq/user/playlist': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await qq.userPlaylists(reqCookie))
  },
  'qq/like/playlist': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await qq.likedPlaylist(reqCookie))
  },
  // QQ 收藏/取消收藏（act=add|del，默认 add）
  'qq/like': async (q, p) => {
    const songid = q.get('songid') || ''
    const act = q.get('act') || 'add'
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await qq.likeSong(songid, act !== 'del', reqCookie))
  },
  'qq/playlist/detail': async (q, p) => {
    const id = q.get('id') || ''
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await qq.playlistDetail(id, reqCookie))
  },
  'qq/recommend/daily': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await qq.dailyRecommend(reqCookie))
  },
  // QQ 取流：QQ 官方直链 → 失败走网易云强匹配 + 多源解锁兜底
  'qq/song/url': async (q, p) => {
    const mid = q.get('mid') || q.get('id') || ''
    if (!mid) throw Object.assign(new Error('缺少参数 mid'), { status: 400 })
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    const direct = await qq.songUrl(mid, q.get('br') === '320' ? '320' : '128', reqCookie)
    if (direct) {
      return { code: 200, data: { id: mid, url: direct.url, br: direct.br, source: 'qq' } }
    }
    // QQ 直链拿不到（VIP/无版权）→ 网易云搜索强匹配 → 解锁链
    const name = q.get('name') || ''
    const artist = q.get('artist') || ''
    if (name) {
      // 分层匹配（2026-09-08 v2，对齐"同名不同署名"场景）：
      //   第1层：歌名去标点完全一致（如 SINOSDE NATAL FUNK ↔ SINOS DE NATAL FUNK!）
      //         且时长在 ±25% 内（排除节选版）→ 层内按歌手命中 → 网易云搜索名次
      //   第2层：歌手命中 + 时长 ±25%
      //   第3层：仅时长 ±25%
      //   第4层：其余包含关系
      // 搜索名次反映网易云相关性，同名版本取排最前的（原版通常在前）
      const stripPunct = (s) => String(s || '').replace(/[\s!！?？.。·、,，\-—:：'"“”‘’()（）[\]【】×*＊/+]/g, '').toLowerCase()
      const pick = (songs, duration) => {
        const tn = String(name || '').replace(/\s+/g, '').toLowerCase()
        const tokens = String(artist || '').split(/[/、,&，;；\s]+/).filter(Boolean).map((t) => t.toLowerCase())
        const dur = Number(duration) || 0
        const durOk = (s) => dur <= 0 || s.duration <= 0 || Math.abs(dur - s.duration) / dur <= 0.25
        const artistHitOf = (s) => {
          const sa = String(s.artist || '').toLowerCase()
          return tokens.length === 0 || tokens.some((t) => sa.includes(t))
        }
        const tiers = [[], [], [], []]
        for (let i = 0; i < songs.length; i++) {
          const s = songs[i]
          const sn = String(s.name || '').replace(/\s+/g, '').toLowerCase()
          if (!sn || !tn || !(sn.includes(tn) || tn.includes(sn))) continue
          const nameEq = stripPunct(s.name) === stripPunct(name)
          if (nameEq && durOk(s)) tiers[0].push({ s, i })
          else if (artistHitOf(s) && durOk(s)) tiers[1].push({ s, i })
          else if (durOk(s)) tiers[2].push({ s, i })
          else tiers[3].push({ s, i })
        }
        for (const tier of tiers) {
          if (!tier.length) continue
          // 层内：歌手命中优先；否则取网易云搜索名次最靠前（原版/最相关版本）
          const hit = tier.find((x) => artistHitOf(x.s))
          return (hit || tier[0]).s
        }
        return null
      }
      try {
        const searchKw = [name, artist].filter(Boolean).join(' ')
        let body = await call('cloudsearch', { keywords: searchKw, limit: 10, type: 1 })
        let songs = ((body.result && body.result.songs) || []).map((s) => ({
          id: s.id, name: s.name, artist: (s.ar || []).map((a) => a.name).join(' / '), duration: s.dt || 0,
        }))
        let hit = pick(songs, Number(q.get('duration') || 0))
        // 带歌手名搜不出命中时，退化为纯歌名再搜一次（歌手署名差异常见）
        if (!hit && artist) {
          body = await call('cloudsearch', { keywords: name, limit: 10, type: 1 })
          songs = ((body.result && body.result.songs) || []).map((s) => ({
            id: s.id, name: s.name, artist: (s.ar || []).map((a) => a.name).join(' / '), duration: s.dt || 0,
          }))
          hit = pick(songs, Number(q.get('duration') || 0))
        }
        if (hit) {
          // 先试网易云官方直链：免费歌直接给官方 CDN，不折腾解锁源
          try {
            const freeBody = await call('song_url', { id: hit.id, br: 320000 })
            const freeData = (freeBody.data || [])[0] || {}
            if (freeData.url && freeData.freeTrialInfo === null) {
              return { code: 200, data: { id: mid, url: freeData.url, br: 320000, source: 'netease', matched: { name: hit.name, artist: hit.artist } } }
            }
          } catch (e) { console.error('[qq] 网易云官方直链失败', e && e.message) }
          // 官方直链拿不到（VIP/受限）→ 解锁源
          const un = await unblockSong(hit.id, UNBLOCK_SOURCES)
          if (un && un.url) {
            return { code: 200, data: { id: mid, url: un.url, br: un.br || null, source: un.source || 'unblock', unblocked: true, matched: { name: hit.name, artist: hit.artist } } }
          }
        }
      } catch (e) { console.error('[qq] 解锁兜底失败', e && e.message) }
      // B站强匹配兜底（QQ 独家 VIP 歌，网易云无版权时）
      try {
        const bs = await biliSearch([name, artist].filter(Boolean).join(' '))
        const hit = strongPickBili(bs, name, artist, Number(q.get('duration') || 0) ? [Number(q.get('duration'))] : [])
        if (hit) {
          const host = (p && p.headers && p.headers.host) || ('127.0.0.1:' + PORT)
          return {
            code: 200,
            data: {
              id: mid,
              url: 'http://' + host + '/stream/bili?bvid=' + encodeURIComponent(hit.bvid),
              type: 'mp3',
              source: 'bilibili',
              unblocked: true,
              fallbackFrom: 'qq',
              matched: { name: hit.name, artist: hit.artist || '' },
            },
          }
        }
      } catch (e) { console.error('[qq] B站兜底失败', e && e.message) }
    }
    throw Object.assign(new Error('该歌曲在 QQ 无直链且未找到可用替代源'), { status: 404 })
  },
  'qq/status': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, qq.status(reqCookie))
  },
  'qq/logout': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, qq.logout(reqCookie))
  },

  // ============ 汽水音乐音源（/soda/*，第4音源） ============
  // 多用户登录态隔离：请求带 Cookie(汽水登录态) 用该用户账号，不带则回退全局 soda-cookie.txt
  'soda/login/local': async (q, p) => {
    return Object.assign({ code: 200 }, await soda.loginLocal())
  },
  'soda/login/qr': async (q, p) => {
    return Object.assign({ code: 200 }, await soda.loginQrKey())
  },
  'soda/login/qr/check': async (q, p) => {
    const key = q.get('key') || ''
    const force = q.get('force') === '1' || q.get('force') === 'true'
    return Object.assign({ code: 200 }, await soda.loginQrCheck(key, force))
  },
  'soda/login/sms/send': async (q, p) => {
    const key = q.get('key') || ''
    return await soda.smsSend(key)
  },
  'soda/login/sms/verify': async (q, p) => {
    const key = q.get('key') || ''
    const code = q.get('code') || ''
    return await soda.smsVerify(key, code)
  },
  'soda/login/sms/code': async (q, p) => {
    const mobile = q.get('mobile') || ''
    return await soda.smsSendCode(mobile)
  },
  'soda/login/sms/login': async (q, p) => {
    const mobile = q.get('mobile') || ''
    const code = q.get('code') || ''
    return await soda.smsLoginMobile(mobile, code)
  },
  'soda/status': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await soda.status(reqCookie))
  },
  'soda/logout': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, soda.logout(reqCookie))
  },
  'soda/user/playlist': async (q, p) => {
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await soda.userPlaylists(reqCookie, Number(q.get('page') || 1), Number(q.get('limit') || 30)))
  },
  'soda/playlist/detail': async (q, p) => {
    const id = q.get('id') || ''
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await soda.playlistDetail(id, reqCookie))
  },
  'soda/song/url': async (q, p) => {
    const id = q.get('id') || q.get('track_id') || ''
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    let r = null
    let e502 = null
    try {
      r = await soda.songUrl(id, reqCookie)
    } catch (e) {
      if (e && e.status === 502) e502 = e
      else throw e
    }
    // 直链可用（排除带 #auth= 的加密流占位）→ 直接返回
    if (r && r.url && !String(r.url).includes('#auth=')) {
      return Object.assign({ code: 200 }, r)
    }
    // 直链不可用（VIP 加密流 blocked / 无音源 502）→ 按 QQ 同款链路换源
    const name = q.get('name') || (r && r.name) || ''
    const artist = q.get('artist') || (r && r.artist) || ''
    const duration = Number(q.get('duration') || 0) || (r && Number(r.duration) || 0) || 0
    if (name) {
      const host = (p && p.headers && p.headers.host) || ('127.0.0.1:' + PORT)
      const fb = await fallbackSong(name, artist, duration, 'soda', host)
      if (fb) {
        return Object.assign({ code: 200 }, { id, ...fb })
      }
    }
    if (e502) throw e502
    return Object.assign({ code: 200 }, r)
  },
  'soda/lyric': async (q, p) => {
    const id = q.get('id') || q.get('track_id') || ''
    const reqCookie = (als.getStore() && als.getStore().cookie) || ''
    return Object.assign({ code: 200 }, await soda.lyric(id, reqCookie))
  },
  'soda/search': async (q, p) => {
    const keywords = q.get('keywords') || q.get('keyword') || ''
    if (!keywords) throw Object.assign(new Error('缺少参数 keywords'), { status: 400 })
    return Object.assign({ code: 200 }, await soda.search(keywords, Number(q.get('limit') || 30)))
  },
}

// ---- 登录日志（本地专用，不上传 GitHub）----
// admin-logger.js / .admin-config.json / login-log.json 均在 .gitignore 中
// 开源版本无这些文件，try/catch 自动跳过，不影响正常运行
let adminLogger = null
try {
  adminLogger = require('./admin-logger')
  adminLogger.injectAdminRoutes(routes)
} catch (e) {
  // 文件不存在（如 GitHub 开源版本），静默跳过
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

  // 汽水音乐模块未安装（公开仓库暂缓汽水登录）时，/soda/* 统一返回 404，避免 handler 里 soda 未定义报错
  if (!soda && name.startsWith('soda/')) {
    return send(res, 404, {
      code: 404,
      message: '汽水音乐模块未安装（暂缓）'
    })
  }

  if (!handler) {
    return send(res, 404, {
      code: 404,
      message: '未知接口，可用接口: search / search/bili / song/url / song/url/unblock / song/url/bili / stream?url= / stream/bili?bvid= / lyric / lyric/any / song/detail / playlist / user/playlist / like / likelist / qq/login/qr / qq/login/qr/check / qq/user/playlist / qq/playlist/detail / qq/recommend/daily / qq/song/url / qq/status / qq/logout / kugou/* / login/qr / login/qr/check / status / logout / recommend / radar / kugou/search / kugou/song/url / kugou/login/qr / kugou/login/qr/check / kugou/user/playlist / kugou/playlist/detail / kugou/recommend/daily / kugou/recommend/fm / kugou/status / kugou/logout / soda/login/qr / soda/login/qr/check / soda/status / soda/logout / soda/user/playlist / soda/playlist/detail / soda/song/url / soda/lyric / soda/search',
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
  console.log('  GET /lyric/any?name=晴天&artist=周杰伦&duration=270000   (歌词多源兜底: 网易云→酷狗)')
  console.log('  GET /song/detail?ids=123,456')
  console.log('  GET /playlist?id=歌单id')
  console.log('  GET /user/playlist?uid=可选   (导入网易云歌单，uid留空用登录用户)')
  console.log('  GET /login/qr  → 获取二维码')
  console.log('  GET /login/qr/check?key=xxx  → 轮询登录状态')
  console.log('  GET /status  → 登录状态')
  console.log('  GET /recommend  → 每日推荐(需登录)')
  console.log(savedCookie ? '登录态: 已保存 cookie' : '登录态: 未登录（在线播放可能需要先登录）')
  const kugouStatus = kugou.status()
  console.log(kugouStatus.loggedIn ? '酷狗登录态(全局回退): 已登录 (userid=' + kugouStatus.user.id + ')' : '酷狗登录态(全局回退): 未登录')
  console.log('  酷狗: /kugou/search /kugou/song/url /kugou/login/qr /kugou/login/qr/check /kugou/user/playlist /kugou/playlist/detail /kugou/recommend/daily /kugou/recommend/fm /kugou/status /kugou/logout')
  console.log('  QQ: /qq/login/qr /qq/login/qr/check /qq/user/playlist /qq/playlist/detail /qq/recommend/daily /qq/song/url /qq/status /qq/logout')
  console.log('  汽水: /soda/login/qr /soda/login/qr/check /soda/status /soda/logout /soda/user/playlist /soda/playlist/detail /soda/song/url /soda/lyric /soda/search')
  console.log('  酷狗多用户隔离: 请求带 Cookie(酷狗登录态) 时使用该用户账号，互不覆盖')
})