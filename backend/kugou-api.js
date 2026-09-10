/**
 * 酷狗音乐音源模块（个人学习用途）
 *
 * 封装酷狗 API：搜索 / 播放地址 / 扫码登录 / 用户歌单 / 歌单详情 / 每日推荐 / 猜你喜欢。
 * 与网易云音源完全独立。
 *
 * 【多用户登录态隔离】与网易云保持一致：
 *   - 客户端（App）扫码登录成功后，后端把完整登录态（token/userid/vip_token/vip_type/mid）
 *     以 cookie 字符串形式返回给客户端，由客户端自行保存（如 shared_preferences）；
 *   - 客户端后续请求把该字符串放在 Cookie 请求头里，后端优先使用请求自带的登录态，
 *     因此"谁的手机登录的就是谁的账号"，互不覆盖；
 *   - 只有网页端/旧客户端（不带 Cookie 头）才回退到全局 kugou-cookie.json。
 *
 * 依赖：Node 内置 fetch + crypto(md5)；二维码图片用 qrcode 包（可选）。
 */

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')

const md5 = (s) => crypto.createHash('md5').update(s, 'utf8').digest('hex')

// ---- 常量（与酷狗安卓/网页端一致）----
const APPID = 1005
const SRCAPPID = 2919
const CLIENTVER = 20489
const ANDROID_SALT = 'OIlwieks28dk2k092lksi2UIkp' // 安卓签名盐
const WEB_SALT = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt' // 网页签名盐
const ANDROID_UA = 'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi'
const WEB_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'

// ---- 二维码图片库（可选，未安装时只返回扫码链接）----
let qrcode = null
try { qrcode = require('qrcode') } catch (e) { /* 忽略 */ }

const COOKIE_FILE = path.join(__dirname, 'kugou-cookie.json')

function err(status, message) {
  const e = new Error(message)
  e.status = status
  return e
}

// ---- 设备指纹（UUID → md5 → mid），首次生成后持久化，保证登录态稳定 ----
function getGuid() {
  const e = () => ((65536 * (1 + Math.random())) | 0).toString(16).substring(1)
  return `${e()}${e()}-${e()}-${e()}-${e()}-${e()}${e()}${e()}`
}

// 全局回退登录态（仅网页端/旧客户端使用）；App 请求一律优先请求头 Cookie
let savedCookie = { KUGOU_API_MID: '' }
try {
  const raw = JSON.parse(fs.readFileSync(COOKIE_FILE, 'utf8') || '{}')
  if (raw && typeof raw === 'object') savedCookie = raw
} catch (e) { /* 首次运行无文件 */ }

if (!savedCookie.KUGOU_API_MID) {
  savedCookie.KUGOU_API_MID = BigInt('0x' + md5(md5(getGuid()))).toString()
  saveCookie()
}

function saveCookie() {
  try { fs.writeFileSync(COOKIE_FILE, JSON.stringify(savedCookie), 'utf8') } catch (e) {
    console.error('[kugou] cookie 保存失败', e && e.message)
  }
}

// =====================================================================
// 多用户登录态隔离：Cookie 头解析
// =====================================================================
// 客户端保存的酷狗登录态 cookie 串形如：
//   token=xxx; userid=xxx; vip_token=xxx; vip_type=xxx; mid=xxx
const AUTH_KEYS = ['token', 'userid', 'vip_token', 'vip_type', 'mid']
function parseKugouCookie(cookieStr) {
  const out = {}
  if (!cookieStr) return out
  String(cookieStr).split(';').forEach((pair) => {
    const idx = pair.indexOf('=')
    if (idx < 0) return
    const k = pair.slice(0, idx).trim()
    const v = pair.slice(idx + 1).trim()
    if (!k || !v) return
    if (AUTH_KEYS.includes(k)) out[k] = v
  })
  return out
}

// 请求级登录态：优先请求 Cookie 头里的值，缺失字段回退全局（兼容网页端）
function resolveAuth(cookieStr) {
  const req = parseKugouCookie(cookieStr)
  const pick = (k) => (req[k] !== undefined ? req[k] : savedCookie[k])
  return {
    token: pick('token') || '',
    userid: pick('userid') || 0,
    vip_token: pick('vip_token') || '',
    vip_type: pick('vip_type') || '',
    KUGOU_API_MID: pick('mid') || savedCookie.KUGOU_API_MID || '',
  }
}

// ---- 签名算法 ----
// 网页签名：每个 key 先拼成 "k=v"，再整体排序后拼接，首尾加盐
function webSig(params) {
  const ps = Object.keys(params).map((k) => `${k}=${params[k]}`).sort().join('')
  return md5(WEB_SALT + ps + WEB_SALT)
}
// 安卓签名：key 先排序，再拼 "k=v"，首尾加盐；POST 时把 body JSON 追加到末尾参与签名
function andSig(params, data = '') {
  const ps = Object.keys(params).sort()
    .map((k) => `${k}=${typeof params[k] === 'object' ? JSON.stringify(params[k]) : params[k]}`)
    .join('')
  return md5(ANDROID_SALT + ps + data + ANDROID_SALT)
}
// 私人FM key：md5(appid + 盐 + clientver + data)
function signParamsKey(data) {
  return md5(`${APPID}${ANDROID_SALT}${CLIENTVER}${data}`)
}

// ---- 统一请求（酷狗 gateway 与登录域通用）----
async function kgFetch({ baseURL = 'https://gateway.kugou.com', url, method = 'GET', params = {}, data, encryptType = 'android', headers = {}, cookie = {} }) {
  const dfid = cookie.dfid || '-'
  const mid = cookie.KUGOU_API_MID || savedCookie.KUGOU_API_MID
  const uuid = '-'
  const token = cookie.token || savedCookie.token || ''
  const userid = cookie.userid || savedCookie.userid || 0
  const clienttime = Math.floor(Date.now() / 1000)

  const defaultParams = { dfid, mid, uuid, appid: APPID, clientver: CLIENTVER, clienttime }
  if (token) defaultParams.token = token
  if (userid && Number(userid) !== 0) defaultParams.userid = userid

  const merged = Object.assign({}, defaultParams, params)

  const bodyJson = (typeof data === 'object' && data !== null) ? JSON.stringify(data) : (data || '')

  if (!merged.signature) {
    if (encryptType === 'web') merged.signature = webSig(merged)
    else merged.signature = andSig(merged, bodyJson)
  }

  const fullHeaders = Object.assign({
    'User-Agent': ANDROID_UA,
    dfid,
    clienttime: String(clienttime),
    mid,
    'kg-rc': '1',
    'kg-thash': '5d816a0',
    'kg-rec': '1',
    'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
  }, headers)

  const query = new URLSearchParams(merged).toString()
  const fullUrl = baseURL + url + (query ? '?' + query : '')

  const fetchOpts = { method, headers: fullHeaders }
  if (method.toUpperCase() === 'POST' && bodyJson) {
    fetchOpts.body = bodyJson
    fetchOpts.headers['Content-Type'] = 'application/json'
  }

  const r = await fetch(fullUrl, fetchOpts)
  const text = await r.text()
  let body
  try { body = JSON.parse(text) } catch (e) { body = text }
  return body
}

/** 酷狗图片 URL：http→https，并把 {size} 占位符替换为指定尺寸 */
function kgImage(url, size = 300) {
  if (!url) return url
  let u = String(url).replace(/^http:\/\//i, 'https://')
  if (u.includes('{size}')) u = u.replace('{size}', String(size))
  return u
}

/** 校验接口返回；酷狗用 error_code / errcode / status 表达结果 */
function assertOk(body) {
  if (body == null) return
  if (body.error_code && body.error_code !== 0) throw err(502, `酷狗接口返回错误 ${body.error_code}: ${body.errmsg || body.msg || body.error || ''}`)
  if (body.errcode != null && body.errcode !== 0) throw err(502, `酷狗接口返回错误 ${body.errcode}: ${body.error || body.errmsg || ''}`)
  if (body.status === 0) throw err(502, `酷狗接口返回失败: ${body.error || body.msg || ''}`)
}

// ---- 歌曲归一化：酷狗字段 → 统一字段（与网易云一致）----
// 酷狗歌名常为 "歌手 - 歌名" 或 "歌手1、歌手2 - 歌名"，剥离歌手前缀
function normalizeSong(s) {
  if (!s) return null
  const singers = (s.singerinfo || []).map((x) => x.name).filter(Boolean)
  let name = s.name || s.songname || s.FileName || ''
  if (singers.length) {
    const idx = name.indexOf(' - ')
    if (idx > 0 && name.slice(0, idx).includes(singers[0])) {
      name = name.slice(idx + 3)
    }
  }
  // 时长单位：time_length(每日推荐/猜你喜欢) 是秒；timelen(歌单详情) 是毫秒
  const tl = Number(s.time_length || 0)
  const dur = tl > 0 ? tl * 1000 : Number(s.timelen || s.duration || 0)
  return {
    id: s.hash || s.FileHash || s.song_id || '',
    name,
    artist: singers.join(' / ') || s.author_name || s.singername || s.SingerName || '',
    album: (s.albuminfo && s.albuminfo.name) || s.album_name || s.AlbumName || '',
    cover: kgImage(s.cover || s.sizable_cover || (s.trans_param && s.trans_param.union_cover) || '', 300) || '',
    duration: dur, // 毫秒
    hash: s.hash || s.FileHash || '',
    albumId: s.album_id || (s.albuminfo && s.albuminfo.id) || s.AlbumID || '',
    source: 'kugou',
  }
}

/** 从多种酷狗返回结构中提取歌曲数组（daily/fm/歌单详情通用） */
function extractSongs(data) {
  if (!data || typeof data !== 'object') return []
  let arr = data.song_list || data.songs || data.info || data.lists || data.list || data.data || []
  if (!Array.isArray(arr)) {
    if (arr && Array.isArray(arr.info)) arr = arr.info
    else if (arr && Array.isArray(arr.songs)) arr = arr.songs
    else arr = []
  }
  return arr.map(normalizeSong).filter(Boolean)
}

// =====================================================================
// 接口 1：歌曲搜索（无需登录）
// =====================================================================
async function search(keywords, page = 1, pagesize = 30) {
  if (!keywords) throw err(400, '缺少参数 keywords')
  const url = 'https://songsearch.kugou.com/song_search_v2?' + new URLSearchParams({
    keyword: keywords, page, pagesize, platform: 'WebFilter', format: 'json',
  }).toString()
  const r = await fetch(url, { headers: { 'User-Agent': WEB_UA } })
  const body = await r.json()
  assertOk(body)
  const data = body.data || {}
  const list = data.lists || data.info || []
  const songs = list.map((s) => ({
    id: s.FileHash || s.hash || '',
    name: s.SongName || s.FileName || '',
    artist: s.SingerName || '',
    album: s.AlbumName || '',
    cover: kgImage(s.Image || s.AlbumImg || '', 300),
    duration: Number(s.Duration || 0) * 1000, // 秒 → 毫秒，与网易云 dt 对齐
    hash: s.FileHash || s.hash || '',
    albumId: s.AlbumID || '',
    source: 'kugou',
  }))
  return { total: data.total || songs.length, songs }
}

// =====================================================================
// 接口 2：扫码登录（多用户隔离：App 登录态返回给客户端保存）
// =====================================================================
// 生成二维码 key（调用 /v2/qrcode，返回 data.qrcode）
async function loginQrKey(cookie = '') {
  const auth = resolveAuth(cookie)
  const clienttime = Math.floor(Date.now() / 1000)
  const params = {
    appid: 1014, type: 1, plat: 4,
    qrcode_txt: `https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=${APPID}&`,
    srcappid: SRCAPPID, dfid: '-', mid: auth.KUGOU_API_MID, uuid: '-',
    clientver: CLIENTVER, clienttime,
  }
  // 注意：不要在这里手动算 signature——kgFetch 会对合并后的完整参数（含默认参数）重新签名，
  // 手动签名与最终 URL 参数不一致会导致酷狗返回 20006 参数错误。
  const body = await kgFetch({
    baseURL: 'https://login-user.kugou.com', url: '/v2/qrcode', params, encryptType: 'web',
  })
  assertOk(body)
  return body.data && body.data.qrcode
}

// 生成扫码链接与二维码图片
async function loginQrCreate(key) {
  if (!key) throw err(400, '缺少参数 key')
  const url = `https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=${encodeURIComponent(key)}`
  let qrimg = ''
  if (qrcode) {
    try { qrimg = await qrcode.toDataURL(url) } catch (e) { qrimg = '' }
  }
  return { key, url, qrimg }
}

// 轮询登录状态：0 过期 / 1 待扫码 / 2 已扫码待确认 / 4 登录成功（返回 token）
// cookie 参数 = 请求头 Cookie。登录成功时：
//   - 请求带了 cookie（App 扫码）→ 完整登录态以 cookie 字符串返回，由客户端保存（不写全局，多用户隔离）
//   - 请求没带 cookie（网页端）→ 写全局 kugou-cookie.json
async function loginQrCheck(key, cookie = '') {
  if (!key) throw err(400, '缺少参数 key')
  const auth = resolveAuth(cookie)
  const clienttime = Math.floor(Date.now() / 1000)
  const params = {
    plat: 4, appid: APPID, srcappid: SRCAPPID, qrcode: key,
    dfid: '-', mid: auth.KUGOU_API_MID, uuid: '-',
    clientver: CLIENTVER, clienttime,
  }
  // 同 loginQrKey：不手动算 signature，交给 kgFetch 对合并后完整参数签名
  const body = await kgFetch({
    baseURL: 'https://login-user.kugou.com', url: '/v2/get_userinfo_qrcode', params, encryptType: 'web',
  })
  assertOk(body)
  const d = body.data || {}
  const status = Number(d.status)
  const token = d.token || ''
  const userid = d.userid || ''
  if (status === 4 && token) {
    if (cookie) {
      // App 扫码：登录态归客户端所有，不写全局（多用户隔离）
    } else {
      savedCookie.token = token
      savedCookie.userid = userid
      savedCookie.vip_token = d.vip_token || ''
      savedCookie.vip_type = d.vip_type || ''
      saveCookie()
    }
  }
  // 完整登录态 cookie 串（含 mid 设备指纹），App 保存后下次请求带回即可
  const sessionCookie = (status === 4 && token)
    ? ['token=' + token, 'userid=' + userid, 'vip_token=' + (d.vip_token || ''), 'vip_type=' + (d.vip_type || ''), 'mid=' + auth.KUGOU_API_MID].join('; ')
    : ''
  return { status, token, userid, cookie: sessionCookie }
}

// =====================================================================
// 接口 3：用户歌单列表（需登录，含封面）
// =====================================================================
async function userPlaylist(page = 1, pagesize = 30, cookie = '') {
  const auth = resolveAuth(cookie)
  const token = auth.token || ''
  const userid = auth.userid || 0
  if (!token || !userid) throw err(301, '未登录')

  // body 字段顺序与酷狗端一致（安卓签名依赖 JSON 序列化结果）
  const data = {
    userid: String(userid),
    token,
    total_ver: 979,
    type: 2,
    page,
    pagesize,
  }
  const body = await kgFetch({
    url: '/v7/get_all_list',
    method: 'POST',
    encryptType: 'android',
    params: { plat: 1, userid: Number(userid), token },
    data,
    headers: { 'x-router': 'cloudlist.service.kugou.com' },
    cookie: auth,
  })
  assertOk(body)
  const d = body.data || {}
  const list = d.info || d.list || d.lists || []
  // 封面字段多重兜底
  const pickCover = (o) => o.imgurl || o.img || o.pic || o.imgUrl || o.cover || o.pic_url || o.imgurl2 || ''
  const playlists = list.map((pl) => {
    const id = pl.global_collection_id || pl.listid || pl.specialid || pl.id
    return {
      id: String(id),
      globalCollectionId: pl.global_collection_id || '',
      name: pl.name || pl.title || pl.listname || '',
      cover: kgImage(pickCover(pl), 300),
      trackCount: Number(pl.count || pl.song_count || pl.song_num || 0),
      creator: pl.list_create_username || pl.username || '',
      createTime: pl.create_time || pl.collecttime || '',
    }
  })
  // get_all_list 的 pic 通常为空（is_custom_pic=0 时不返回歌单封面），
  // 回退调详情接口拿 list_info.pic（默认取第一首歌封面）。批量并发，最多补 10 个避免太慢。
  const emptyList = playlists.filter((pl) => !pl.cover).slice(0, 10)
  if (emptyList.length > 0) {
    await Promise.all(emptyList.map(async (pl) => {
      try {
        const detail = await playlistDetail(pl.globalCollectionId || pl.id, cookie)
        if (detail && detail.playlist && detail.playlist.cover) {
          pl.cover = detail.playlist.cover
        }
      } catch (e) { /* 单个歌单补封面失败不影响整体 */ }
    }))
  }
  return { loggedIn: true, userid: String(userid), total: list.length, playlists }
}

// =====================================================================
// 接口 4：歌单详情（歌曲列表，自动分页拉全量）
// =====================================================================
async function playlistDetail(id, cookie = '') {
  if (!id) throw err(400, '缺少参数 id')
  const auth = resolveAuth(cookie)
  const gid = String(id).trim()
  const pagesize = 30
  let beginIdx = 0
  let allSongs = []
  let listInfo = null
  let total = 0

  for (;;) {
    const params = {
      area_code: 1, begin_idx: beginIdx, plat: 1, type: 1, mode: 1,
      personal_switch: 1, extend_fields: 'abtags,hot_cmt,popularization',
      pagesize, global_collection_id: gid,
    }
    const body = await kgFetch({
      url: '/pubsongs/v2/get_other_list_file_nofilt',
      method: 'GET',
      encryptType: 'android',
      params,
      cookie: auth,
    })
    assertOk(body)
    const data = body.data || {}
    const songs = data.songs || []
    listInfo = data.list_info || data.info || listInfo
    total = Number(data.count || total)
    allSongs = allSongs.concat(songs)
    if (!songs.length || allSongs.length >= total) break
    beginIdx += pagesize
  }

  const li = listInfo || {}
  const pickCover = (o) => o.pic || o.imgurl || o.img || o.cover || ''
  const songs = allSongs.map(normalizeSong).filter(Boolean)

  return {
    playlist: {
      id: String(gid),
      name: li.name || '',
      cover: kgImage(pickCover(li), 300),
      trackCount: Number(li.count || allSongs.length || 0),
      creator: li.list_create_username || '',
    },
    tracks: songs,
  }
}

// =====================================================================
// 接口 5：每日推荐（需登录，个性化）
// =====================================================================
async function dailyRecommend(cookie = '') {
  const auth = resolveAuth(cookie)
  const token = auth.token || ''
  const userid = auth.userid || 0
  if (!token || !userid) throw err(301, '未登录')
  const body = await kgFetch({
    baseURL: 'https://everydayrec.service.kugou.com',
    url: '/everyday_song_recommend',
    method: 'POST',
    encryptType: 'android',
    params: { platform: 'ios' },
    headers: { 'x-router': 'everydayrec.service.kugou.com' },
    cookie: auth,
  })
  assertOk(body)
  const songs = extractSongs(body.data)
  return { loggedIn: true, total: songs.length, songs }
}

// =====================================================================
// 接口 6：猜你喜欢（私人FM，需登录，个性化歌曲流）
// =====================================================================
async function fmRecommend(cookie = '') {
  const auth = resolveAuth(cookie)
  const token = auth.token || ''
  const userid = auth.userid || 0
  const vipType = auth.vip_type || 0
  if (!token || !userid) throw err(301, '未登录')

  const clienttime = Date.now()
  const dataMap = {
    appid: APPID,
    clienttime,
    mid: auth.KUGOU_API_MID,
    action: 'play',
    recommend_source_locked: 0,
    song_pool_id: 0,
    callerid: 0,
    m_type: 1,
    platform: 'ios',
    area_code: 1,
    remain_songcnt: 0,
    clientver: CLIENTVER,
    is_overplay: 0,
    mode: 'normal',
    fakem: 'ca981cfc583a4c37f28d2d49000013c16a0a',
    key: signParamsKey(clienttime),
  }
  if (userid) {
    dataMap.userid = userid
    dataMap.kguid = userid
  }
  if (token) dataMap.token = token
  if (vipType) dataMap.vip_type = vipType

  const body = await kgFetch({
    baseURL: 'https://persnfm.service.kugou.com',
    url: '/v2/personal_recommend',
    method: 'POST',
    encryptType: 'android',
    data: dataMap,
    headers: { 'x-router': 'persnfm.service.kugou.com' },
    cookie: auth,
  })
  assertOk(body)
  const songs = extractSongs(body.data)
  return { loggedIn: true, total: songs.length, songs }
}

// =====================================================================
// 接口 7：歌曲播放地址（移动端 getSongInfo，免费歌曲直出，需 hash）
// =====================================================================
async function songUrl(hash) {
  if (!hash) throw err(400, '缺少参数 hash')
  const url = 'https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=' + encodeURIComponent(String(hash).toLowerCase())
  const r = await fetch(url, { headers: { 'User-Agent': MOBILE_UA } })
  const body = await r.json()
  if (body.errcode && body.errcode !== 0) {
    throw err(502, body.errMsg || body.error || body.errmsg || `播放地址获取失败(errcode ${body.errcode})`)
  }
  const playUrl = body.url || (body.backup_url && body.backup_url[0]) || ''
  if (!playUrl) throw err(502, '该歌曲无可用播放地址（可能为 VIP 或无版权）')
  return {
    url: playUrl,
    br: Number(body.bitRate || 128),
    type: body.extName || 'mp3',
    duration: Number(body.timeLength || body.time_length || 0) * 1000,
    name: body.songName || '',
    artist: body.author_name || '',
    expireAt: null,
    source: 'kugou',
  }
}

// =====================================================================
// v5/url 完整取流（安卓签名 + encryptKey）——免费歌拿完整 url；
// VIP/付费歌酷狗服务端不给 url，返回 blocked 标记 + 歌曲信息，供上层兜底到网易云/B站。
// =====================================================================
const V5_KEY_SALT = '57ae12eb6890223e355ccfcb74edf70d'
function signV5Key(hash, mid, userid, appid) {
  return md5(`${String(hash).toLowerCase()}${V5_KEY_SALT}${appid}${mid}${userid || 0}`)
}
async function v5Url(hash, cookie = '') {
  if (!hash) throw err(400, '缺少参数 hash')
  const auth = resolveAuth(cookie)
  // 1) playInfo 拿元数据（VIP 歌也返回歌名/歌手/albumid/album_audio_id）
  const metaUrl = 'https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=' + encodeURIComponent(String(hash).toLowerCase())
  const metaResp = await fetch(metaUrl, { headers: { 'User-Agent': MOBILE_UA } })
  const meta = await metaResp.json()
  const name = meta.songName || ''
  const artist = meta.author_name || ''
  const albumId = Number(meta.albumid || 0)
  const albumAudioId = Number(meta.album_audio_id || 0)
  if (!meta.hash && !name) {
    throw err(502, `酷狗歌曲信息获取失败（hash=${hash}）`)
  }
  // 2) v5/url 完整取流
  const clienttime = Math.floor(Date.now() / 1000)
  const dfid = crypto.randomBytes(12).toString('hex').slice(0, 24)
  const mid = auth.KUGOU_API_MID || crypto.randomUUID()
  const p = {
    area_code: 1, ssa_flag: 'is_fromtrack', version: 11436, page_id: 151369488,
    quality: 128, behavior: 'play', pid: 2, cmd: 26, pidversion: 3001, IsFreePart: 0,
    ppage_id: '463467626,350369493,788954147', cdnBackup: 1, kcard: 0, module: '',
    appid: APPID, clientver: CLIENTVER, dfid, mid, uuid: '-', clienttime,
    album_id: albumId, hash: String(hash).toLowerCase(), album_audio_id: albumAudioId,
  }
  if (auth.token) p.token = auth.token
  if (auth.userid && Number(auth.userid) !== 0) p.userid = auth.userid
  p.key = signV5Key(p.hash, p.mid, p.userid || 0, APPID)
  p.signature = andSig(p)
  const qs = new URLSearchParams(p).toString()
  const resp = await fetch('https://gateway.kugou.com/v5/url?' + qs, {
    headers: { 'User-Agent': ANDROID_UA, 'x-router': 'trackercdn.kugou.com' },
  })
  const body = await resp.json()
  const urls = body.play_url || body.url || []
  const firstUrl = Array.isArray(urls) ? urls[0] : (urls || '')
  if (firstUrl) {
    return {
      url: firstUrl,
      br: Number(body.bitRate || 128),
      type: 'mp3',
      duration: Number(meta.timeLength || 0) * 1000,
      name, artist,
      source: 'kugou',
      full: true,
    }
  }
  // 被拦（VIP/付费/无版权）：返回歌曲信息供上层兜底
  return {
    blocked: true,
    name, artist,
    hash: String(hash),
    duration: Number(meta.timeLength || 0) * 1000,
  }
}

// =====================================================================
// 登录态 / 退出（多用户隔离：App 退出只清客户端本地，网页端清全局）
// =====================================================================
function status(cookie = '') {
  const auth = resolveAuth(cookie)
  const token = auth.token || ''
  const userid = auth.userid || ''
  return { loggedIn: !!(token && userid), user: { id: String(userid) } }
}

function logout(cookie = '') {
  if (!cookie) {
    // 网页端/旧客户端：清全局
    savedCookie.token = ''
    savedCookie.userid = ''
    savedCookie.vip_token = ''
    savedCookie.vip_type = ''
    saveCookie()
  }
  // App 请求：登录态在客户端本地，后端无需清理，返回未登录即可
  return { loggedIn: false }
}

// =====================================================================
// 歌词（lyrics.kugou.com 官方歌词服务器，无需登录）
// 1) search 按 hash 查歌词 id + accesskey；2) download 拿 base64 LRC
// =====================================================================
async function lyric(hash) {
  if (!hash) throw err(400, '缺少参数 hash')
  const sUrl = 'https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=' +
    encodeURIComponent(hash) + '&hash=' + encodeURIComponent(hash)
  const sResp = await fetch(sUrl, { headers: { 'User-Agent': WEB_UA } })
  const sBody = await sResp.json()
  // 官方推荐歌词优先，其次取第一个有 accesskey 的候选
  const all = (sBody.candidates || []).filter((c) => c.id && c.accesskey)
  if (!all.length) return null
  const cand = all.find((c) => String(c.product_from || '').includes('官方')) || all[0]
  const dUrl = 'https://lyrics.kugou.com/download?ver=1&client=pc&id=' + encodeURIComponent(cand.id) +
    '&accesskey=' + encodeURIComponent(cand.accesskey) + '&fmt=lrc&charset=utf8'
  const dResp = await fetch(dUrl, { headers: { 'User-Agent': WEB_UA } })
  const dBody = await dResp.json()
  let lrc = ''
  try { lrc = Buffer.from(dBody.content || '', 'base64').toString('utf8') } catch (_) { lrc = '' }
  if (!lrc || !lrc.includes('[')) return null
  // 酷狗 LRC 头部带 [ti:]/[ar:]/[al:]/[by:] 元信息，保留原样由前端解析
  return { lrc, tlyric: '' }
}

module.exports = {
  search,
  songUrl,
  v5Url,
  lyric,
  loginQrKey,
  loginQrCreate,
  loginQrCheck,
  userPlaylist,
  playlistDetail,
  dailyRecommend,
  fmRecommend,
  status,
  logout,
  kgImage,
}
