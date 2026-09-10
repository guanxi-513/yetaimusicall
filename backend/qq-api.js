/**
 * QQ 音乐音源模块（个人学习用途）
 *
 * 封装 QQ 音乐 API：扫码登录 / 用户歌单 / 歌单详情 / 每日推荐。
 * 逆向参考：github.com/sansenjian/qq-music-api（Rain120 的持续维护 fork）
 *
 * 【多用户登录态隔离】与网易云/酷狗一致：
 *   - App 扫码登录成功后，后端把完整 cookie 串返回给客户端，由客户端自行保存（shared_preferences）；
 *   - 客户端后续请求把该字符串放在 Cookie 请求头里，后端优先使用请求自带的登录态，
 *     因此"谁的手机登录的就是谁的账号"，互不覆盖；
 *   - 只有网页端/旧客户端（不带 Cookie 头）才回退到全局 qq-cookie.txt。
 *
 * 依赖：Node 内置 fetch（Node 18+，含 FormData）。
 */

const fs = require('fs')
const path = require('path')

// ---- 常量（QQ 音乐网页端逆向值，来自 sansenjian/qq-music-api）----
const WEB_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
const COOKIE_FILE = path.join(__dirname, 'qq-cookie.txt')

// 扫码登录（ptlogin2 开放平台）
const PT_APPID = '716027609'
const PT_DAID = '383'
const PT_3RD_AID = '100497308'
const PT_U1 = 'https%3A%2F%2Fgraph.qq.com%2Foauth2.0%2Flogin_jump'
const PTQRLOGIN_SIG = 'du-YS1h8*0GqVqcrru0pXkpwVg2DYw-DtbFulJ62IgPf6vfiJe*4ONVrYc5hMUNE'
const PTQRLOGIN_O1VID = '3674fc47871e9c407d8838690b355408'
// OAuth 换 code
const CLIENT_ID = '100497308'
const REDIRECT_URI = 'https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/'

function err(status, message) {
  const e = new Error(message)
  e.status = status
  return e
}

// ---- 全局回退登录态（仅网页端/旧客户端）；App 请求一律优先请求头 Cookie ----
let savedCookie = ''
try { savedCookie = fs.readFileSync(COOKIE_FILE, 'utf8').trim() } catch (e) { /* 首次运行无文件 */ }
function saveCookie() {
  try { fs.writeFileSync(COOKIE_FILE, savedCookie, 'utf8') } catch (e) {
    console.error('[qq] cookie 保存失败', e && e.message)
  }
}

// 取流用的设备 guid（模块加载时生成一次即可，QQ 用随机数）
const GUID = String((Math.round(2147483647 * Math.random()) * new Date().getUTCMilliseconds()) % 1e10)

// ---- 请求级登录态：优先请求 Cookie 头，空则回退全局 ----
function resolveAuth(cookieStr) {
  const c = (cookieStr || '').trim()
  return c || savedCookie
}

// ---- 工具函数（原样移植自 research 项目）----
function hash33(t) {
  let e = 0
  for (let n = 0, o = t.length; n < o; ++n) e += (e << 5) + t.charCodeAt(n)
  return 2147483647 & e
}
function getGtk(p_skey) {
  let h = 5381
  for (let i = 0, len = p_skey.length; i < len; ++i) h += (h << 5) + p_skey.charCodeAt(i)
  return h & 0x7fffffff
}
function getGuid() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    .replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0
      const v = c === 'x' ? r : (r & 0x3) | 0x8
      return v.toString(16)
    })
    .toUpperCase()
}
function parseSetCookie(setCookieHeader) {
  if (!setCookieHeader) return []
  const cookies = []
  for (const part of String(setCookieHeader).split(/,(?=\s*[a-zA-Z_]+=)/)) {
    const pair = part.split(';')[0].trim()
    if (pair && pair.includes('=') && pair.split('=')[1]) cookies.push(pair)
  }
  return cookies
}
async function fetchTO(url, opts = {}, timeout = 15000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeout)
  try { return await fetch(url, { ...opts, signal: ctrl.signal }) } finally { clearTimeout(t) }
}

// ---- HTTP 封装 ----
/** musicu.fcg POST（u.y.qq.com 统一网关），data 为对象 */
async function musicu(data, cookie = '') {
  const resp = await fetchTO('https://u.y.qq.com/cgi-bin/musicu.fcg', {
    method: 'POST',
    body: JSON.stringify(data),
    headers: {
      'Content-Type': 'application/json',
      Referer: 'https://y.qq.com/portal/player.html',
      'User-Agent': WEB_UA,
      ...(cookie ? { Cookie: cookie } : {}),
    },
  })
  const text = await resp.text()
  let j
  try { j = JSON.parse(text) } catch (e) { throw err(502, 'QQ 接口返回非 JSON: ' + text.slice(0, 120)) }
  return j
}
/** c.y.qq.com GET；referer 可覆盖（歌单详情接口需要 n/yqq/playlist） */
async function yGet(urlPath, params = {}, cookie = '', referer = 'https://y.qq.com/') {
  const qs = new URLSearchParams(params).toString()
  const url = 'https://c.y.qq.com' + urlPath + (qs ? '?' + qs : '')
  const resp = await fetchTO(url, {
    headers: {
      Referer: referer,
      'User-Agent': WEB_UA,
      ...(cookie ? { Cookie: cookie } : {}),
    },
  })
  const text = await resp.text()
  let j
  try { j = JSON.parse(text) } catch (e) { throw err(502, 'QQ 接口返回非 JSON: ' + text.slice(0, 120)) }
  return j
}

// =====================================================================
// 扫码登录
// =====================================================================

/** 1) 获取登录二维码：返回 base64 图片 + qrsig + ptqrtoken */
async function loginQrKey() {
  const url = `https://ssl.ptlogin2.qq.com/ptqrshow?appid=${PT_APPID}&e=2&l=M&s=3&d=72&v=4&t=${Math.random()}&daid=${PT_DAID}&pt_3rd_aid=${PT_3RD_AID}&u1=${PT_U1}`
  const resp = await fetchTO(url, { headers: { 'User-Agent': WEB_UA } })
  const buf = Buffer.from(await resp.arrayBuffer())
  const img = 'data:image/png;base64,' + buf.toString('base64')
  const match = (resp.headers.get('Set-Cookie') || '').match(/qrsig=([^;]+)/)
  if (!match) throw err(502, '获取 QQ 二维码失败（无 qrsig）')
  const qrsig = match[1]
  return { img, qrsig, ptqrtoken: hash33(qrsig) }
}

/** 从登录响应文本里取回调 URL */
function extractRedirectUrl(text) {
  const m = text.match(/(?:'((?:https?|ftp):\/\/[^\s/$.?#].[^\s]*)')/g)
  return (m && m[0]) ? m[0].replace(/'/g, '') : ''
}

/**
 * 2) 轮询扫码状态
 * @returns {status:0已过期|1等待扫码|2已扫码|4登录成功, message, cookie, userid, nickname}
 * 登录成功时 cookie 为完整登录态串（含 qqmusic_key），由客户端保存
 */
async function loginQrCheck(qrsig, ptqrtoken) {
  if (!qrsig || !ptqrtoken) throw err(400, '缺少参数 qrsig/ptqrtoken')
  const url = `https://ssl.ptlogin2.qq.com/ptqrlogin?u1=${PT_U1}&ptqrtoken=${ptqrtoken}&ptredirect=0&h=1&t=1&g=1&from_ui=1&ptlang=2052&action=0-0-${Date.now()}&js_ver=23111510&js_type=1&login_sig=${PTQRLOGIN_SIG}&pt_uistyle=40&aid=${PT_APPID}&daid=${PT_DAID}&pt_3rd_aid=${PT_3RD_AID}&&o1vId=${PTQRLOGIN_O1VID}&pt_js_version=v1.48.1`
  const resp = await fetchTO(url, { headers: { Cookie: `qrsig=${qrsig}`, 'User-Agent': WEB_UA } })
  const data = await resp.text()

  const cookieMap = new Map()
  const collect = (h) => { for (const c of parseSetCookie(h)) cookieMap.set(c.split('=')[0], c) }
  collect(resp.headers.get('Set-Cookie'))

  const refresh = data.includes('已失效')
  if (!data.includes('登录成功')) {
    return { status: refresh ? 0 : 1, message: refresh ? '二维码已过期' : '等待扫码', cookie: '', userid: '', nickname: '' }
  }

  try {
    // 1) 拿 p_skey
    const checkSigUrl = extractRedirectUrl(data)
    if (!checkSigUrl) throw new Error('无回调 URL')
    const sigRes = await fetchTO(checkSigUrl, { redirect: 'manual', headers: { Cookie: Array.from(cookieMap.values()).join('; ') } })
    const sigCookie = sigRes.headers.get('Set-Cookie') || ''
    const pSkey = (sigCookie.match(/p_skey=([^;]+)/) || [])[1]
    if (!pSkey) throw new Error('无 p_skey')
    const gtk = getGtk(pSkey)
    collect(sigCookie)

    // 2) OAuth authorize 换 code
    const fd = new FormData()
    fd.append('response_type', 'code')
    fd.append('client_id', CLIENT_ID)
    fd.append('redirect_uri', REDIRECT_URI)
    fd.append('scope', 'get_user_info,get_app_friends')
    fd.append('state', 'state')
    fd.append('switch', '')
    fd.append('from_ptlogin', '1')
    fd.append('src', '1')
    fd.append('update_auth', '1')
    fd.append('openapi', '1010_1030')
    fd.append('g_tk', String(gtk))
    fd.append('auth_time', new Date().toString())
    fd.append('ui', getGuid())
    const authRes = await fetchTO('https://graph.qq.com/oauth2.0/authorize', {
      redirect: 'manual',
      method: 'POST',
      body: fd,
      headers: { Cookie: Array.from(cookieMap.values()).join('; ') },
    })
    collect(authRes.headers.get('Set-Cookie'))
    const location = authRes.headers.get('Location') || ''
    const codeMatch = location.match(/[?&]code=([^&]+)/)
    if (!codeMatch) throw new Error('authorize 无 code')

    // 3) QQLogin 换 QQ 音乐站 cookie
    const loginRes = await fetchTO('https://u.y.qq.com/cgi-bin/musicu.fcg', {
      method: 'POST',
      body: JSON.stringify({
        comm: { g_tk: gtk, platform: 'yqq', ct: 24, cv: 0 },
        req: { module: 'QQConnectLogin.LoginServer', method: 'QQLogin', param: { code: codeMatch[1] } },
      }),
      headers: {
        'Content-Type': 'application/json',
        Referer: 'https://y.qq.com/',
        Cookie: Array.from(cookieMap.values()).join('; '),
      },
    })
    collect(loginRes.headers.get('Set-Cookie'))
    await loginRes.text()

    const cookie = Array.from(cookieMap.values()).join('; ')
    const uinMatch = cookie.match(/(?:^|;\s*)uin=o?(\d+)/)
    const userid = uinMatch ? uinMatch[1] : ''
    return { status: 4, message: '登录成功', cookie, userid, nickname: '' }
  } catch (e) {
    throw err(502, 'QQ 登录完成失败: ' + (e && e.message))
  }
}

// =====================================================================
// 歌单 / 推荐
// =====================================================================

/** 歌曲归一化：QQ 字段 → 统一字段（与网易云/酷狗一致） */
function normalizeSong(s) {
  if (!s) return null
  const singers = (s.singer || []).map((x) => x.name).filter(Boolean)
  // 歌单详情接口的专辑字段是 albumid/albummid（无 album 对象/pmid）；
  // 搜索等接口是 album.pmid，两种都兼容
  const albumMid =
    (s.album && (s.album.pmid || s.album.mid)) || s.albummid || s.albumpic || ''
  return {
    id: s.songmid || s.mid || '',
    songId: Number(s.songid || 0) || 0, // 数字 id，收藏接口用
    name: s.songname || s.name || s.title || '',
    artist: singers.join(' / ') || s.singerName || '',
    album: (s.album && s.album.name) || s.albumname || s.albumName || '',
    cover: albumMid
      ? `https://y.gtimg.cn/music/photo_new/T002R300x300M000${albumMid}.jpg`
      : '',
    duration: Number(s.interval || 0) * 1000, // 秒 → 毫秒
    source: 'qq',
  }
}

/**
 * 歌单详情（公开歌单匿名可用；私密歌单如"今日私享/我喜欢"需登录 cookie）
 * 参数组合对齐 mebest100：type/utf8/disstid/loginUin，Referer 用 n/yqq/playlist
 * （实测带 new_format=1 时"我喜欢"歌单的 songname/songmid 会缺失，勿加）
 */
async function playlistDetail(disstid, cookie = '') {
  if (!disstid) throw err(400, '缺少参数 disstid')
  const j = await yGet('/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg', {
    type: 1, utf8: 1, disstid, loginUin: 0, format: 'json',
  }, resolveAuth(cookie), 'https://y.qq.com/n/yqq/playlist')
  const cd = (j.cdlist || [])[0] || {}
  if (!cd.dissname && !(cd.songlist || []).length) throw err(502, '歌单不存在或已下架')
  const songs = (cd.songlist || []).map(normalizeSong).filter(Boolean)
  return {
    id: String(disstid),
    name: cd.dissname || '',
    cover: cd.logo || '',
    total: (cd.songnum || songs.length),
    songs,
  }
}

/** QQ「我喜欢」收藏歌单（需登录）：主页接口解析 mymusic 里"我喜欢"的 id → 歌单详情 */
async function likedPlaylist(cookie = '') {
  const auth = resolveAuth(cookie)
  if (!auth) throw err(401, 'QQ 未登录')
  const uinMatch = auth.match(/(?:^|;\s*)uin=o?(\d+)/)
  const uin = uinMatch ? uinMatch[1] : ''
  if (!uin) throw err(401, 'QQ cookie 缺少 uin')
  const j = await yGet('/rsc/fcgi-bin/fcg_get_profile_homepage.fcg', {
    _: Date.now(), cv: 4747474, ct: 24, format: 'json', inCharset: 'utf-8', outCharset: 'utf-8',
    notice: 0, platform: 'yqq.json', needNewCode: 0, uin: Number(uin), g_tk_new_20200303: 0, g_tk: 0,
    cid: 205360838, userid: Number(uin), reqfrom: 1, reqtype: 0, hostUin: 0, loginUin: Number(uin),
  }, auth)
  const mymusic = (j.data && j.data.mymusic) || []
  const fav = mymusic.find((x) => x.title === '我喜欢') || mymusic[0] || {}
  const idMatch = String(fav.jumpurl || '').match(/id=(\d+)/)
  if (!idMatch) throw err(502, '未找到「我喜欢」歌单')
  return playlistDetail(idMatch[1], auth)
}

/**
 * 收藏/取消收藏歌曲到「我喜欢」（dirId=201）
 * @param {number|string} songId 数字歌曲 id
 * @param {boolean} like true=收藏 false=取消
 */
async function likeSong(songId, like = true, cookie = '') {
  const auth = resolveAuth(cookie)
  if (!auth) throw err(401, 'QQ 未登录')
  const id = Number(songId)
  if (!id) throw err(400, '缺少参数 songid')
  const body = {
    'music.musicasset.PlaylistDetailWrite': {
      method: like ? 'AddSonglist' : 'DelSonglist',
      module: 'music.musicasset.PlaylistDetailWrite',
      param: { dirId: 201, v_songInfo: [{ songType: 0, songId: id }] },
    },
  }
  const j = await musicu(body, auth)
  const r = j['music.musicasset.PlaylistDetailWrite']
  if (!r || r.code !== 0) throw err(502, 'QQ 收藏操作失败: ' + JSON.stringify(r || j).slice(0, 150))
  return { liked: like }
}

/** 用户创建的歌单列表（需登录 cookie） */
async function userPlaylists(cookie = '') {
  const auth = resolveAuth(cookie)
  if (!auth) throw err(401, 'QQ 未登录')
  const uinMatch = auth.match(/(?:^|;\s*)uin=o?(\d+)/)
  const uin = uinMatch ? uinMatch[1] : ''
  if (!uin) throw err(401, 'QQ cookie 缺少 uin')
  const j = await yGet('/rsc/fcgi-bin/fcg_get_profile_homepage.fcg', {
    _: Date.now(), cv: 4747474, ct: 24, format: 'json', inCharset: 'utf-8', outCharset: 'utf-8',
    notice: 0, platform: 'yqq.json', needNewCode: 0, uin: Number(uin), g_tk_new_20200303: 0, g_tk: 0,
    cid: 205360838, userid: Number(uin), reqfrom: 1, reqtype: 0, hostUin: 0, loginUin: Number(uin),
  }, auth)
  // 容错解析歌单列表（多字段兜底）
  const list =
    (j.data && j.data.mydiss && j.data.mydiss.list) ||
    (j.data && j.data.createdDissList) ||
    (j.data && j.data.createdList) ||
    (j.data && j.data.creator && (j.data.creator.playlist || j.data.creator.playlists)) ||
    (j.data && (j.data.playlist || j.data.playlists)) || []
  if (!list.length) return { total: 0, playlists: [] }
  const playlists = list.map((p) => {
    // 歌曲数：优先数字字段，否则从 subtitle 里解析（"8首    0次播放" / "74首歌曲"）
    let songCount = Number(p.songnum || p.song_count || p.total_song_num || 0)
    if (!songCount) {
      const m = String(p.subtitle || '').match(/(\d+)首/)
      songCount = m ? Number(m[1]) : 0
    }
    return {
      id: String(p.dissid || p.tid || p.id || ''),
      name: p.title || p.dissname || p.name || '',
      cover: p.picurl || p.logo || p.imgurl || p.cover || '',
      songCount,
    }
  }).filter((p) => p.id)
  return { total: playlists.length, playlists }
}

/**
 * 每日推荐（每日30首；需登录）
 * 实现：抓 QQ 音乐 Mac 客户端首页 HTML → 解析「今日私享」歌单 id → 歌单详情接口取 30 首。
 * （get_recommend musicu 接口实测返回 500003 已失效，改用此方案，mebest100 同款）
 */
async function dailyRecommend(cookie = '') {
  const auth = resolveAuth(cookie)
  if (!auth) throw err(401, 'QQ 未登录')
  const resp = await fetchTO('https://c.y.qq.com/node/musicmac/v6/index.html', {
    headers: { 'User-Agent': WEB_UA, Cookie: auth, Referer: 'https://y.qq.com/' },
  })
  const html = await resp.text()
  // 「今日私享」歌单：data-type="10014" 的 playlist__item，名字为今日私享
  const m = html.match(/data-rid="(\d+)"[^>]*>[\s\S]{0,400}?今日私享/)
  if (!m) throw err(401, 'QQ 未登录或每日推荐不可用')
  const detail = await playlistDetail(m[1], auth)
  return { id: m[1], name: detail.name, total: detail.songs.length, songs: detail.songs }
}

/** 登录态检查：cookie 里同时有 uin 和 qqmusic_key 视为已登录 */
function status(cookie = '') {
  const auth = resolveAuth(cookie)
  if (!auth) return { loggedIn: false }
  const hasUin = /(?:^|;\s*)uin=/.test(auth)
  const hasKey = /(?:^|;\s*)qqmusic_key=/.test(auth)
  const uinMatch = auth.match(/(?:^|;\s*)uin=o?(\d+)/)
  return { loggedIn: hasUin && hasKey, user: { id: uinMatch ? uinMatch[1] : '', nickname: '' } }
}

const QUALITY_FILE = { m4a: ['C400', '.m4a'], 128: ['M500', '.mp3'], 320: ['M800', '.mp3'], flac: ['F000', '.flac'] }

/**
 * QQ 官方取流（CgiGetVkey）
 * @param {string} songmid
 * @param {string} quality 128|320|flac|m4a
 * @returns {{url,br}|null} 免费歌返回直链；VIP/无版权返回 null
 */
async function songUrl(songmid, quality = '128', cookie = '') {
  if (!songmid) throw err(400, '缺少参数 mid')
  const auth = resolveAuth(cookie)
  const uinMatch = auth.match(/(?:^|;\s*)uin=o?(\d+)/)
  const uin = uinMatch ? uinMatch[1] : '0'
  const authstMatch = auth.match(/(?:^|;\s*)qqmusic_key=([^;]+)/)
  const authst = authstMatch ? authstMatch[1] : ''
  const q = QUALITY_FILE[quality] ? quality : '128'
  const [prefix, suffix] = QUALITY_FILE[q]
  const filename = prefix + songmid + songmid + suffix

  const payload = {
    req_0: {
      module: 'vkey.GetVkeyServer',
      method: 'CgiGetVkey',
      param: {
        filename: [filename],
        guid: GUID,
        songmid: [songmid],
        songtype: [0],
        uin: String(uin),
        loginflag: 1,
        platform: '20',
        ...(authst ? { authst } : {}),
      },
    },
    loginUin: String(uin),
    comm: { uin: String(uin), format: 'json', ct: 24, cv: 0 },
  }
  const j = await musicu(payload, auth)
  const d = (j.req_0 && j.req_0.data) || {}
  const sip = (d.sip || []).filter((x) => typeof x === 'string' && x)
  const domain = sip.find((u) => !u.startsWith('http://ws')) || sip.find((u) => u.startsWith('https://')) || sip[0] || ''
  const info = (d.midurlinfo || [])[0] || {}
  const url = info.purl ? domain + (domain.endsWith('/') ? '' : '/') + info.purl : ''
  if (!url) return null
  return { url, br: q === '320' ? 320000 : q === 'flac' ? 999000 : q === 'm4a' ? 128000 : 128000 }
}

/** 退出登录（App 清除客户端 cookie；网页端清全局） */
function logout(cookie = '') {
  if (!cookie) { savedCookie = ''; saveCookie() }
  return { loggedIn: false }
}

module.exports = {
  loginQrKey,
  loginQrCheck,
  playlistDetail,
  likedPlaylist,
  likeSong,
  userPlaylists,
  dailyRecommend,
  songUrl,
  status,
  logout,
}
