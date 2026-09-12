/**
 * soda-api.js — 汽水音乐音源模块
 *
 * 逆向移植自 github.com/guohuiyuan/music-lib/soda（MIT/AGPL 项目，仅参考协议逻辑）
 * 能力：扫码登录 / 登录态 / 个人歌单 / 歌单详情 / 单曲取流 / 歌词 / 搜索
 *
 * 关键机制（与原项目一致）：
 *  - Passport 登录：api.qishui.com/passport/web/{get_qrcode,check_qrconnect}，有序表单编码 + 固定头
 *  - PC 接口：api.qishui.com/luna/pc/*，LunaPC UA + x-luna-* 头 + PC App 参数
 *  - 取流：web track_v2 → seo_track 兜底（无需签名）；video_model 递归解析 / url_player_info 视频云
 *  - 免费歌走 web/seo 返回明文 m4a（无 play_auth，直接可播）；加密流带 play_auth，需解密（暂不实现，标记 vip）
 *  - 多用户登录态隔离：请求带 Cookie(汽水登录态) 用该用户账号；不带则回退全局 soda-cookie.txt
 */
const fs = require('fs')
const path = require('path')
const qrcode = require('qrcode')
const os = require('os')
const { connectFrontier } = require('./frontier.js')

function computerName() {
  try { return os.hostname() || 'EDISON' } catch (_) { return 'EDISON' }
}

const COOKIE_FILE = path.join(__dirname, 'soda-cookie.txt')
let savedCookie = ''
try { savedCookie = fs.readFileSync(COOKIE_FILE, 'utf8').trim() } catch (_) { /* 无全局登录态 */ }

function saveCookie(c) {
  savedCookie = c || ''
  try { fs.writeFileSync(COOKIE_FILE, savedCookie, 'utf8') } catch (_) { /* 忽略 */ }
}
function err(status, message) {
  const e = new Error(message)
  e.status = status
  return e
}
function resolveAuth(cookieStr) {
  const c = (cookieStr || '').trim()
  return c || savedCookie
}

// ---- 常量（移植自 soda.go / login.go）----
const UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36'
const UA_PC = 'LunaPC/3.3.0(359450208)'
const UA_PASSPORT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) SodaMusic/3.7.0 Chrome/134.0.6998.165 TTElectron/35.7.4 Electron/35.7.4 Safari/537.36'

const PASSPORT_HEADERS = {
  'User-Agent': UA_PASSPORT,
  Accept: 'application/json, text/javascript',
  'Accept-Language': 'zh-CN,zh;q=0.9',
  Origin: 'https://luna-pc.bytedance.net',
  Referer: 'https://luna-pc.bytedance.net/login',
  'Sec-Fetch-Site': 'cross-site',
  'Sec-Fetch-Mode': 'cors',
  'Sec-Fetch-Dest': 'empty',
}
const AID = '386088'
const SEO_BASE = 'https://beta-luna.douyin.com/luna/h5/seo_track'
const QR_CREATE_API = 'https://api.qishui.com/passport/web/get_qrcode/'
const QR_CHECK_API = 'https://api.qishui.com/passport/web/check_qrconnect/'
const SEND_CODE_API = 'https://api.qishui.com/passport/web/send_code/'
const VALIDATE_API = 'https://api.qishui.com/passport/web/validate_code/'
const SMS_LOGIN_API = 'https://api.qishui.com/passport/web/sms_login/'
const UPSMS_API = 'https://api.qishui.com/passport/upsms/verify/'

// 进程级稳定 device_id（官方 ci().deviceId 是持久化随机 16 位 ID，非时间戳）
// 服务端用设备指纹建立"电脑会话"，手机确认绑定该会话；无 device_id → 确认无处绑定 → verify_time 恒 0
let sodaDevVal = ''
// stableDevice 别名（pcAppParams/passportValues 等历史调用点使用）
function stableDevice() { return stableSodaDevice() }
function stableSodaDevice() {
  if (!sodaDevVal) sodaDevVal = String(Math.floor(1000000000000000 + Math.random() * 9000000000000000))
  return sodaDevVal
}

// 进程级稳定 biz_trace_id（Go 里 sync.Once，create/check 必须一致，否则汽水不识别同一会话）
let bizTraceVal = ''
function stableBizTrace() {
  if (!bizTraceVal) bizTraceVal = (Date.now() >>> 0).toString(16).padStart(8, '0')
  return bizTraceVal
}

// ---- HTTP 工具 ----
async function fetchTO(url, opts = {}, timeout = 20000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeout)
  try { return await fetch(url, { ...opts, signal: ctrl.signal }) } finally { clearTimeout(t) }
}

/** Go url.QueryEscape 近似：JS encodeURIComponent 除空格外基本一致，这里值无空格，直接用 */
function qe(v) { return encodeURIComponent(String(v)) }

/** 有序表单编码（Go sodaEncodeOrderedForm：先按 order，剩余按 key 排序） */
function orderedForm(form, order) {
  const parts = []
  const seen = new Set()
  for (const k of order) {
    if (Object.prototype.hasOwnProperty.call(form, k)) {
      seen.add(k)
      const v = form[k]
      if (Array.isArray(v)) v.forEach((x) => parts.push(qe(k) + '=' + qe(x)))
      else parts.push(qe(k) + '=' + qe(v))
    }
  }
  const rest = Object.keys(form).filter((k) => !seen.has(k)).sort()
  for (const k of rest) {
    const v = form[k]
    if (Array.isArray(v)) v.forEach((x) => parts.push(qe(k) + '=' + qe(x)))
    else parts.push(qe(k) + '=' + qe(v))
  }
  return parts.join('&')
}

// ---- Passport 参数 ----
const PASSPORT_ORDER = ['passport_jssdk_version', 'passport_jssdk_type', 'is_from_ttaccountsdk', 'aid', 'language',
  'account_sdk_source', 'account_sdk_source_info', 'p_js_v', 'p_js_t', 'p_zt', 'p_ver', 'request_host', 'p_bd',
  'biz_trace_id', 'is_new_login', 'is_from_iesaccountsaas', 'device_id', 'install_id', 'did', 'iid',
  'device_platform', 'version_code', 'msToken', 'a_bogus']

function passportValues() {
  const d = stableDevice()
  return {
    passport_jssdk_version: '2.4.13',
    passport_jssdk_type: 'normal',
    is_from_ttaccountsdk: '1',
    aid: AID,
    language: 'zh',
    account_sdk_source: 'web',
    p_js_v: '2.4.13',
    p_js_t: 'pro',
    p_zt: '3.3.5',
    p_ver: '1.0.29',
    request_host: 'app%3A%2F%2Fresources',
    p_bd: '1.0.0.41',
    biz_trace_id: stableBizTrace(),
    is_new_login: '1',
    is_from_iesaccountsaas: '1',
    device_id: String(d),
    install_id: String(d + 1),
    did: String(d),
    iid: String(d + 1),
    device_platform: 'PC',
    version_code: '3.7.0',
  }
}
function passportQuery() { return orderedForm(passportValues(), PASSPORT_ORDER) }

// ---- Passport 官方 pro 参数集（逆向自官方 PC 客户端 3.8.0 login.ts / account-api-pro 2.4.13）----
// 3.8.0 用 pro 版 jssdk（p_js_t=pro、jssdk_version=2.4.13），且 ttwid:false、ztsdk:false、hcSwitch:false
const LITE_ORDER = ['passport_jssdk_version', 'passport_jssdk_type', 'is_from_ttaccountsdk', 'aid', 'language',
  'account_app_language', 'new_authn_sdk_version', 'is_new_login', 'is_from_iesaccountsaas', 'device_id',
  'install_id', 'did', 'iid', 'device_platform', 'version_code', 'biz_trace_id']
function liteValuesFor(deviceId, bizTraceId) {
  return {
    passport_jssdk_version: '4.2.3',
    passport_jssdk_type: 'lite',
    is_from_ttaccountsdk: '1',
    aid: AID,
    language: 'zh',
    account_app_language: 'en-US',
    new_authn_sdk_version: '1.0.0.404-web',
    is_new_login: '1',
    is_from_iesaccountsaas: '1',
    device_id: String(deviceId),
    install_id: String(deviceId + 1),
    did: String(deviceId),
    iid: String(deviceId + 1),
    device_platform: 'PC',
    version_code: '3.7.0',
    biz_trace_id: bizTraceId,
  }
}

const PRO_ORDER = ['passport_jssdk_version', 'p_js_v', 'p_js_t', 'p_zt', 'p_ver', 'request_host', 'p_bd',
  'aid', 'device_id', 'install_id', 'did', 'iid', 'device_platform', 'version_code', 'biz_trace_id']
function proValuesFor(deviceId, bizTraceId) {
  return {
    passport_jssdk_version: '2.4.13',
    p_js_v: '2.4.13',
    p_js_t: 'pro',
    p_zt: '0',
    p_ver: '0',
    request_host: encodeURIComponent('https://luna-pc.bytedance.net'),
    p_bd: '0',
    aid: AID,
    device_id: String(deviceId),
    install_id: String(deviceId + 1),
    did: String(deviceId),
    iid: String(deviceId + 1),
    device_platform: 'PC',
    version_code: '3.8.0',
    biz_trace_id: bizTraceId,
  }
}
function passportProValues() {
  return proValuesFor(stableDevice(), stableBizTrace())
}
function passportProQuery() {
  return orderedForm(passportProValues(), PRO_ORDER)
}

// ---- 官方加密工具（逆向自 account-api-pro utils）----
// writeUTF + XOR-5 hex（encryptParams 对 mobile/type/code 等字段加密）
// 官方 $O/mJ XOR-5 加密（renderer @580818）：每字符取 UTF-16 双字节（c&255, c>>8），逐字节 ^5 转 hex
// 注意：不是 UTF-8！ASCII 字符每字符输出 2 个 hex 字节（第二个恒为 05）
function encryptXor5(value) {
  // 官方 mJ（UTF-8 字节序列）+ $O（逐字节 ^5 转 hex）——逆向自 renderer-Cpp7FaSO.js @580370/@580678
  const s = String(value)
  const bytes = []
  for (let i = 0; i < s.length; i++) {
    const r = s.charCodeAt(i)
    if (r >= 0 && r <= 127) bytes.push(r)
    else if (r >= 128 && r <= 2047) {
      bytes.push(192 | (31 & (r >> 6)))
      bytes.push(128 | (63 & r))
    } else if ((r >= 2048 && r <= 55295) || (r >= 57344 && r <= 65535)) {
      bytes.push(224 | (15 & (r >> 12)))
      bytes.push(128 | (63 & (r >> 6)))
      bytes.push(128 | (63 & r))
    }
  }
  const out = []
  for (const b of bytes) out.push(((b & 255) ^ 5).toString(16).padStart(2, '0'))
  return out.join('')
}
// v4 UUID（官方 generateUUID）
function uuidV4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}
// 身份验证流水头（官方 VerifyPortraitPlugin：x-tt-passport-verify-portrait: <uuid>.login）
function newVerifyPortrait() { return uuidV4() + '.login' }

// ---- MFA（扫码确认后短信二次验证）参数提取 ----
const MFA_ALLOW = ['passport_mfa_retry_tag', 'std_verify_flow_id', 'std_verify_scene', 'std_verify_template',
  'std_verify_token', 'std_verify_type', 'std_verify_way']
function mfaKeyNorm(k) { return String(k || '').toLowerCase().replace(/[_-]/g, '') }
function collectMfaParams(value, out) {
  if (Array.isArray(value)) { value.forEach((v) => collectMfaParams(v, out)); return }
  if (value && typeof value === 'object') {
    for (const k of Object.keys(value)) {
      const v = value[k]
      if (MFA_ALLOW.some((a) => mfaKeyNorm(a) === mfaKeyNorm(k))) {
        const s = typeof v === 'string' ? v.trim() : (typeof v === 'number' ? String(v) : '')
        if (s) out[k] = s
      }
      collectMfaParams(v, out)
    }
    return
  }
  if (typeof value === 'string') {
    const s = value.trim()
    if (s && (s.includes('std_verify_') || s.includes('passport_mfa_retry_tag'))) {
      const q = s.includes('?') ? s.slice(s.indexOf('?') + 1) : s
      try {
        const parsed = new URLSearchParams(q)
        for (const [k, v] of parsed) {
          if (MFA_ALLOW.some((a) => mfaKeyNorm(a) === mfaKeyNorm(k)) && v.trim()) out[k] = v.trim()
        }
      } catch (_) { /* 忽略 */ }
    }
  }
}
function extractVerifyParams(raw) {
  const out = {}
  try { collectMfaParams(raw, out) } catch (_) { /* 忽略 */ }
  return new URLSearchParams(out).toString()
}
function deepFindString(raw, field) {
  const want = mfaKeyNorm(field)
  const walk = (v) => {
    if (Array.isArray(v)) { for (const c of v) { const r = walk(c); if (r !== undefined) return r } return undefined }
    if (v && typeof v === 'object') {
      for (const k of Object.keys(v)) {
        if (mfaKeyNorm(k) === want) {
          if (typeof v[k] === 'string') return v[k].trim()
          if (typeof v[k] === 'number') return String(v[k])
        }
        const r = walk(v[k])
        if (r !== undefined) return r
      }
      return undefined
    }
    if (typeof v === 'string') {
      const s = v.trim()
      if (s.startsWith('{')) { try { return walk(JSON.parse(s)) } catch (_) { return undefined } }
      if (s.includes('=')) {
        try {
          const parsed = new URLSearchParams(s.includes('?') ? s.slice(s.indexOf('?') + 1) : s)
          if (parsed.has(field)) return parsed.get(field).trim()
        } catch (_) { /* 忽略 */ }
      }
    }
    return undefined
  }
  const r = walk(raw)
  return r === undefined ? '' : r
}
/** 从响应+body 提取 MFA 会话参数（Go extractSodaMFARequiredResult 等价） */
function extractMfaFrom(j, merged) {
  const raw = JSON.parse(JSON.stringify(j))
  const verifyParams = extractVerifyParams(raw)
  const encryptUid = deepFindString(raw, 'encrypt_uid')
  const mobile = deepFindString(raw, 'mobile')
  const channelMobile = deepFindString(raw, 'channel_mobile')
  const smsContent = deepFindString(raw, 'sms_content')
  const upSms = channelMobile || smsContent
  const mfaToken = merged.get ? String(merged.get('passport_mfa_token') || '') : ''
  return { verifyParams, encryptUid, mobile: mobile || '', channelMobile, smsContent, upSms, mfaToken }
}

// ---- PC 接口参数 ----
const PC_ORDER = ['aid', 'app_name', 'region', 'geo_region', 'os_region', 'sim_region', 'device_id', 'cdid', 'iid',
  'version_name', 'version_code', 'channel', 'build_mode', 'network_carrier', 'ac', 'tz_name', 'resolution',
  'device_platform', 'device_type', 'os_version', 'fp']
function pcAppParams(extra = {}) {
  const d = stableDevice()
  const p = {
    aid: AID, app_name: 'luna_pc', region: 'cn', geo_region: 'cn', os_region: 'cn', sim_region: '',
    device_id: String(d), cdid: '', iid: String(d + 1), version_name: '3.3.0', version_code: '30030000',
    channel: 'official', build_mode: 'master', network_carrier: '', ac: 'wifi', tz_name: 'Asia/Shanghai',
    resolution: '', device_platform: 'windows', device_type: 'Windows', os_version: 'Windows 11', fp: String(d),
    ...extra,
  }
  return orderedForm(p, PC_ORDER)
}
function pcRequestOptions(cookie) {
  const h = {
    'User-Agent': UA_PC,
    'x-luna-background-type': 'foreground',
    'x-luna-is-background-req': '0',
    'x-luna-is-local-user': '1',
  }
  if (cookie) h.Cookie = cookie
  return h
}

// ---- 音质选择（移植 sodaQualityRank / sodaBetterStreamCandidate）----
function normalizeBitrate(br) { return Math.max(0, Math.round(Number(br) || 0)) }
function qualityRank(quality, format, bitrate) {
  const q = String(quality || '').toLowerCase().replace(/[-_\s]/g, '')
  const f = String(format || '').toLowerCase()
  const br = normalizeBitrate(bitrate)
  const isLosslessFormat = /(flac|alac|wav)/.test(f)
  const isLosslessLabel = /(lossless|flac|sq|svip)/.test(q)
  const isHiResLabel = /(hires|master)/.test(q)
  if (isHiResLabel && (isLosslessFormat || br >= 900)) return 110
  if (isLosslessLabel || isLosslessFormat || br >= 900) return 100
  if (isHiResLabel) return 90
  if (/(atmos|dolby|spatial)/.test(q)) return 88
  if (/(highest|excellent|superhigh|hq)/.test(q)) return 80
  if (/(higher|^high$|320)/.test(q)) return 70
  if (/(standard|medium|normal|128)/.test(q)) return 50
  if (/(low|preview)/.test(q)) return 10
  if (br >= 900) return 100
  if (br >= 320) return 70
  if (br >= 256) return 65
  if (br >= 192) return 55
  if (br >= 128) return 50
  if (br > 0) return 20
  return 0
}
function betterStreamCandidate(a, b) {
  const ad = Number(a.duration) || 0, bd = Number(b.duration) || 0
  if (ad > 0 || bd > 0) {
    if (ad > bd + 1) return true
    if (bd > ad + 1) return false
  }
  const ar = qualityRank(a.quality, a.format, a.bitrate)
  const br_ = qualityRank(b.quality, b.format, b.bitrate)
  if (ar !== br_) return ar > br_
  const ab = normalizeBitrate(a.bitrate), bb = normalizeBitrate(b.bitrate)
  if (ab !== bb) return ab > bb
  if ((a.size || 0) !== (b.size || 0)) return (a.size || 0) > (b.size || 0)
  return String(a.quality || '') > String(b.quality || '')
}
function pickBest(list) {
  let best = null
  for (const it of list) {
    if (!String(it.mainPlayUrl || it.backupPlayUrl || '').trim()) continue
    if (!best || betterStreamCandidate(it, best)) best = it
  }
  return best
}

/** video_model 递归解析：找出所有候选流（字段名大小写兼容） */
function collectVideoModel(value, keyHint, inheritedAuth, inheritedDuration, entries) {
  if (Array.isArray(value)) {
    value.forEach((c) => collectVideoModel(c, keyHint, inheritedAuth, inheritedDuration, entries))
    return
  }
  if (value && typeof value === 'object') {
    let auth = inheritedAuth
    let duration = inheritedDuration
    const ownAuth = String(value.play_auth || value.playAuth || value.PlayAuth || '').trim()
    if (ownAuth) auth = ownAuth
    const ownDur = Number(value.video_duration || value.duration || value.Duration || 0)
    if (ownDur > 0) duration = ownDur
    const entry = {
      mainPlayUrl: String(value.main_play_url || value.main_url || value.MainPlayURL || value.MainPlayUrl || '').trim(),
      backupPlayUrl: String(value.backup_play_url || value.backup_url || value.BackupPlayURL || value.BackupPlayUrl || '').trim(),
      playAuth: auth,
      format: String(value.format || value.Format || '').trim(),
      bitrate: normalizeBitrate(value.bitrate || value.Bitrate || value.br || 0),
      quality: String(value.quality || value.Quality || value.gear_des_key || '').trim(),
      size: Number(value.size || value.Size || 0),
      duration: Number(duration) || 0,
    }
    if (entry.mainPlayUrl || entry.backupPlayUrl) entries.push(entry)
    for (const k of Object.keys(value)) {
      collectVideoModel(value[k], k, auth, duration, entries)
    }
  }
}
function bestFromVideoModel(raw) {
  if (!raw || raw === 'null') return null
  let text = String(raw).trim()
  for (let i = 0; i < 3 && text.startsWith('"'); i++) {
    try { text = String(JSON.parse(text)).trim() } catch (_) { break }
  }
  let value
  try { value = JSON.parse(text) } catch (_) { return null }
  const entries = []
  collectVideoModel(value, '', '', 0, entries)
  let best = null
  for (const e of entries) {
    if (!e.mainPlayUrl && !e.backupPlayUrl) continue
    if (!best || betterStreamCandidate(e, best)) best = e
  }
  if (!best) return null
  const url = String(best.mainPlayUrl || best.backupPlayUrl || '').trim()
  if (!url) return null
  return { url, playAuth: best.playAuth, format: best.format, size: best.size, duration: best.duration, bitrate: best.bitrate, quality: best.quality }
}

/** 视频云 url_player_info 接口 */
async function fetchPlayerInfo(playerInfoURL, cookie) {
  const resp = await fetchTO(playerInfoURL, { headers: { 'User-Agent': UA_WEB, Cookie: cookie || '' } })
  const j = await resp.json()
  const list = ((j.Result && j.Result.Data && j.Result.Data.PlayInfoList) || []).map((x) => ({
    mainPlayUrl: String(x.MainPlayUrl || x.MainPlayURL || '').trim(),
    backupPlayUrl: String(x.BackupPlayUrl || x.BackupPlayURL || '').trim(),
    playAuth: String(x.PlayAuth || '').trim(),
    encryption: String(x.EncryptionMethod || '').trim(),
    format: String(x.Format || '').trim(),
    bitrate: normalizeBitrate(x.Bitrate),
    quality: String(x.Quality || x.Definition || '').trim(),
    size: Number(x.Size || 0),
    duration: Number(x.Duration || 0),
  }))
  if (!list.length) {
    const em = j.ResponseMetadata && j.ResponseMetadata.Error && j.ResponseMetadata.Error.Message
    throw err(502, em || '汽水播放信息接口无可用音流')
  }
  const best = pickBest(list)
  if (!best) throw err(502, '汽水播放信息接口无可播音流')
  return {
    url: String(best.mainPlayUrl || best.backupPlayUrl || '').trim(),
    playAuth: best.playAuth, format: best.format, size: best.size,
    duration: best.duration, bitrate: best.bitrate, quality: best.quality,
  }
}

// ---- 歌词转换（Go parseSodaLyric： [start_ms,dur_ms]<word> → LRC）----
function parseSodaLyric(raw) {
  const out = []
  const lineRe = /^\[(\d+),(\d+)\](.*)$/m
  for (const line of String(raw || '').split('\n')) {
    const t = line.trim()
    if (!t) continue
    const m = t.match(lineRe)
    if (m) {
      const start = Number(m[1])
      const content = String(m[3]).replace(/<[^>]+>/g, '')
      const minutes = Math.floor(start / 60000)
      const seconds = Math.floor((start % 60000) / 1000)
      const millis = Math.floor((start % 1000) / 10)
      const mm = String(minutes).padStart(2, '0')
      const ss = String(seconds).padStart(2, '0')
      const cs = String(millis).padStart(2, '0')
      out.push(`[${mm}:${ss}.${cs}]${content}`)
    }
  }
  return out.join('\n')
}

// ---- 歌曲归一化（Go sodaBuildSongFromTrack 思路）----
function songDurationSeconds(track) {
  const d = Number(track.duration || 0)
  return d > 1000 ? Math.floor(d / 1000) : d
}
function maxBitRateSize(bitRates) {
  let s = 0
  for (const br of bitRates || []) s = Math.max(s, Number(br.size || 0))
  return s
}
function isVipTrack(labelInfo) {
  const l = labelInfo || {}
  if (l.only_vip_download || l.only_vip_playable) return true
  if ((l.quality_only_vip_can_download || []).length || (l.quality_only_vip_can_play || []).length) return true
  const qm = l.quality_map || {}
  for (const k of Object.keys(qm)) {
    const p = qm[k] || {}
    if (p.play_detail && p.play_detail.need_vip) return true
    if (p.download_detail && p.download_detail.need_vip) return true
  }
  return false
}
function buildImageURL(img, suffix) {
  if (!img) return ''
  const urls = img.urls || []
  const uri = img.uri || ''
  if (urls.length && uri && !String(urls[0]).includes(uri)) return String(urls[0]) + uri + suffix
  if (urls.length) return String(urls[0]) + suffix
  if (img.template_prefix) return String(img.template_prefix) + suffix
  return ''
}
function buildSongFromTrack(track, fallbackCover) {
  let displaySize = maxBitRateSize(track.bit_rates)
  const previewSize = maxBitRateSize(track.preview && track.preview.bit_rates)
  if (previewSize > displaySize) displaySize = previewSize
  const durationSec = songDurationSeconds(track)
  let bitrate = 0
  if (durationSec > 0 && displaySize > 0) bitrate = Math.floor((displaySize * 8) / 1000 / durationSec)
  const artists = (track.artists || []).map((a) => a.name).filter(Boolean)
  const song = {
    id: String(track.id || ''),
    name: track.name || '',
    artist: artists.join('、'),
    album: (track.album && track.album.name) || '',
    duration: durationSec * 1000,
    size: displaySize,
    bitrate,
    cover: buildImageURL(track.album && track.album.url_cover, '~c5_375x375.jpg') || fallbackCover || '',
    source: 'soda',
    isVip: isVipTrack(track.label_info),
  }
  // 歌单详情直接带 audio_info.play_info_list 时优先用
  const plist = ((track.audio_info && track.audio_info.play_info_list) || []).map((x) => ({
    mainPlayUrl: String(x.main_play_url || '').trim(),
    backupPlayUrl: String(x.backup_play_url || '').trim(),
    playAuth: String(x.play_auth || '').trim(),
    format: String(x.format || '').trim(),
    bitrate: normalizeBitrate(x.bitrate),
    quality: String(x.quality || '').trim(),
    size: Number(x.size || 0),
    duration: Number(x.duration || 0),
  }))
  const best = pickBest(plist)
  if (best) {
    const u = String(best.mainPlayUrl || best.backupPlayUrl || '').trim()
    if (u) {
      song.url = u + (best.playAuth ? '#auth=' + qe(best.playAuth) : '')
      if (best.size > song.size) song.size = best.size
      if (best.format) song.ext = best.format
      if (best.bitrate > 0) song.bitrate = best.bitrate
      if (best.quality) song.quality = best.quality
    }
  }
  return song
}

// ---- 取流（web track_v2 → seo_track 兜底 → url_player_info）----
async function webTrackV2(trackId, cookie) {
  const params = orderedForm({ track_id: trackId, media_type: 'track', aid: AID, device_platform: 'web', channel: 'pc_web' }, ['track_id', 'media_type', 'aid', 'device_platform', 'channel'])
  const resp = await fetchTO('https://api.qishui.com/luna/pc/track_v2?' + params, { headers: { 'User-Agent': UA_WEB, Cookie: cookie || '' } })
  const j = await resp.json()
  if (j.status_code !== 0) throw err(502, '汽水 track_v2 接口异常: ' + (j.status_info && j.status_info.status_msg) || ('code=' + j.status_code))
  return j
}
async function seoTrack(trackId, cookie) {
  const params = orderedForm({ track_id: trackId, device_platform: 'web' }, ['track_id', 'device_platform'])
  const resp = await fetchTO(SEO_BASE + '?' + params, { headers: { 'User-Agent': UA_WEB, Cookie: cookie || '' } })
  const j = await resp.json()
  const sc = Number(j.status_code ?? 0)
  if (sc !== 0) throw err(502, '汽水 seo_track 接口异常: ' + ((j.status_info && j.status_info.status_msg) || ('code=' + sc)))
  const track = (j.seo_track && j.seo_track.track) || {}
  const lyric = ((j.seo_track && j.seo_track.lyric && j.seo_track.lyric.content) || (j.lyric && j.lyric.content) || '')
  return { track, trackPlayer: j.track_player || {}, lyric }
}
async function fetchTrackV2(trackId, cookie) {
  // web track_v2 失败/解析失败 → seo 兜底
  try {
    const w = await webTrackV2(trackId, cookie)
    const track = (w.track && w.track.id) ? w.track : (w.track_info || {})
    if (!track.id) throw new Error('track empty')
    return { track, trackPlayer: w.track_player || {}, lyric: (w.lyric && w.lyric.content) || '' }
  } catch (_) {
    return seoTrack(trackId, cookie)
  }
}
function downloadInfoFrom(track, player) {
  let info = null
  if (player && player.video_model) info = bestFromVideoModel(player.video_model)
  return info
}

// ---- 对外：登录 ----
// 官方 PC 客户端登录落地页（逆向自 SodaMusic v2.1.0 login.asar）：
// next 决定会话归属，必须用 luna-pc.bytedance.net/login，用 api.qishui.com 时确认后不下发 session
const PC_LOGIN_NEXT = 'https://api.qishui.com'
const QR_PENDING = new Map() // token -> {cookies, status, message, expiresAt}
// 轮询节流：同 token 最小间隔 2 秒（Go sodaQRPollAllowed），避免被汽水 error_code=7 限流
// 限流退避：error_code=7 时该 token 退避 60 秒（Go sodaQRRateLimitBackoff），期间不打汽水
const QR_POLL = new Map() // token -> { lastTs, backoffUntil }
function qrPollAllowed(token) {
  const now = Date.now()
  const st = QR_POLL.get(token) || { lastTs: 0, backoffUntil: 0 }
  if (now < st.backoffUntil) return false // 退避中：直接返回缓存
  if (now - st.lastTs < 2000) return false
  st.lastTs = now
  QR_POLL.set(token, st)
  return true
}
function qrPollBackoff(token, ms) {
  const st = QR_POLL.get(token) || { lastTs: 0, backoffUntil: 0 }
  st.backoffUntil = Date.now() + ms
  QR_POLL.set(token, st)
}
// 放慢轮询：把该 token 的最近查询时间往后推 ms 毫秒（等效最小间隔变大）
function qrPollSlow(token, ms) {
  const st = QR_POLL.get(token) || { lastTs: 0, backoffUntil: 0 }
  st.lastTs = Date.now() + ms
  QR_POLL.set(token, st)
}
function qrPendingKey(token) { return { cookies: new Map(), status: 1, message: '', expiresAt: Date.now() + 10 * 60 * 1000 } }

function setCookiesFromResp(resp, target) {
  // 关键：Node fetch 的 headers.get('set-cookie') 只返回第一个 Set-Cookie，
  // sessionid 等可能排在后位，必须取全部（getSetCookie 优先，兼容低版本 Node）
  let lines = []
  if (typeof resp.headers.getSetCookie === 'function') {
    lines = resp.headers.getSetCookie()
  } else {
    const raw = resp.headers.get('set-cookie') || ''
    lines = String(raw).split(/,(?=\s*[a-zA-Z_]+=)/)
  }
  for (const part of lines) {
    const pair = String(part).split(';')[0].trim()
    const idx = pair.indexOf('=')
    if (idx > 0) {
      const name = pair.slice(0, idx).trim()
      const value = pair.slice(idx + 1).trim()
      if (name && value) target.set(name, value)
    }
  }
}
function mergeCookieMaps(...maps) {
  const out = new Map()
  for (const m of maps) for (const [k, v] of m) if (v) out.set(k, v)
  return out
}
function cookiesToHeader(cookies) {
  const parts = []
  for (const [k, v] of [...cookies.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) parts.push(k + '=' + v)
  return parts.join('; ')
}
function cookiesHaveSession(cookies) {
  for (const k of ['sessionid', 'sessionid_ss', 'sid_tt', 'sid_guard']) {
    if (cookies.get(k)) return true
  }
  return false
}

// ---- ttwid 注册（官方 checkWebId 流程，逆向自 login.asar）----
// 汽水 passport 风控要求会话带 ttwid，否则 check_qrconnect / send_code 高频会被 error_code=7 限流
const TTWID_REGISTER_API = 'https://api.qishui.com/ttwid/union/register/'
async function registerTtwid(cookies) {
  if (cookies.get('ttwid')) return cookies.get('ttwid')
  const body = JSON.stringify({
    aid: 386088, service: 'api.qishui.com', host: 'https://api.qishui.com',
    unionHost: '', union: false, region: 'cn', isOversea: false,
    fid: '', migrate_info: {},
  })
  const resp = await fetchTO(TTWID_REGISTER_API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'User-Agent': UA_PASSPORT },
    body,
  })
  const cs = new Map()
  setCookiesFromResp(resp, cs)
  const ttwid = cs.get('ttwid') || ''
  if (ttwid) cookies.set('ttwid', ttwid)
  return ttwid
}

/** 获取扫码登录二维码（官方 3.8.0 完整流程：pro 参数 + verify_portrait，无 ttwid；每个登录会话独立 device_id 避免 device 级限流） */
async function loginQrKey() {
  // PopDownloader 真实验证过的 normal 极简参数集（非 lite/pro）：
  //   passport_jssdk_version=2.4.13 & passport_jssdk_type=normal & is_from_ttaccountsdk=1 & aid=386088 & next=https://api.qishui.com
  // 官方 s2 配置：scope="web"、generalParams={device_id, install_id, did, iid, device_platform:"PC", version_code}
  // get_qrcode 必须带持久化设备标识，服务端据此建立"电脑会话"（手机确认绑定该会话）
  const dev = stableSodaDevice()
  const inst = stableSodaInstall()
  const cookies = new Map()
  const sess = { deviceId: dev, installId: inst, did: dev, iid: inst }
  const query = smsLiteQuery(sess) + '&next=' + qe(PC_LOGIN_NEXT)
  const url = QR_CREATE_API + '?' + query
  const headers = { 'User-Agent': UA_PASSPORT, Accept: 'application/json', 'x-tt-passport-trace-id': stableBizTrace() }
  const resp = await fetchTO(url, { headers })
  const respCookies = new Map()
  setCookiesFromResp(resp, respCookies)
  for (const [k, v] of respCookies) cookies.set(k, v)
  const j = await resp.json()
  const d = (j.data || {})
  if (!d.token) throw err(502, '汽水二维码获取失败: ' + (j.message || 'unknown'))
  // 服务端 qrcode 原图即有效登录二维码（内容= qrcode_index_url：/ucenter_web/app/sdk-next?...&uc_sdk=scan-auth）
  // 实测手工拼的 light/invoke/scan_login 二维码手机确认不生效（verify_time=0 → check 7）
  // PopDownloader 直接用服务端 qrcode 原图，故照做
  const qrcodeIndex = String(d.qrcode_index_url || '').trim()
  const webUrl = String(d.web_url || '').trim()
  let qrImage = String(d.qrcode || '').trim()
  if (qrImage && !/^data:image\//.test(qrImage)) qrImage = 'data:image/png;base64,' + qrImage
  let qr = qrcodeIndex || webUrl || ''
  if (qr && !/^https?:/.test(qr)) qr = 'https:' + qr
  QR_PENDING.set(d.token, { cookies, deviceId: dev, installId: inst, bizTraceId: '', portrait: '', status: 1, message: '等待扫码', expiresAt: Date.now() + 10 * 60 * 1000 })
  // PopDownloader 无长连接，纯轮询（normal 参数集 scanned 后可正常 confirmed）
  return { status: 1, message: '等待扫码', key: d.token, qr_url: qr, qr_image: qrImage, expires_in: 300, risk: String(d.copywriting || '').slice(0, 160) }
}

const QR_CHECK_ORDER = ['need_logo', 'need_short_url', 'is_frontier', 'token', 'is_new_login', 'next',
  'passport_mfa_retry_tag', 'std_verify_flow_id', 'std_verify_scene', 'std_verify_template', 'std_verify_token',
  'std_verify_type', 'std_verify_way']
const QR_CHECK_FORM_ORDER = ['need_logo', 'need_short_url', 'is_frontier', 'token', 'is_new_login', 'next']

/** 轮询扫码登录 */
async function loginQrCheck(key, force) {
  const token = String(key || '').trim()
  if (!token) throw err(400, '缺少参数 key')
  const pending = QR_PENDING.get(token) || qrPendingKey(token)
  // 本地 2 秒节流：返回缓存状态，不打汽水（避免 error_code=7 限流）
  if (!force && !qrPollAllowed(token)) {
    const cached = pending.status || 1
    return { status: cached, message: pending.message || (cached === 2 ? '已扫码，请在手机上确认' : '等待扫码确认'), key: token, throttled: true }
  }
  // 官方 3.7.0 s2 配置：scope="web"（PC 客户端也是 web scope！）
  // checkQrconnectRequest: POST /passport/web/check_qrconnect/
  //   data={need_logo:false, need_short_url:false, is_frontier, token, is_new_login:"1", next}
  //   （next 字段，非 service；service 是 sso scope 用的，配 passport/web/ 会 error_code=3 缺少参数）
  // is_frontier=true 依赖 frontier 长连接推送确认，我们没有长连接 → false 纯轮询
  const form = { need_logo: 'false', need_short_url: 'false', is_frontier: 'true', token, is_new_login: '1', next: PC_LOGIN_NEXT }
  const body = orderedForm(form, QR_CHECK_FORM_ORDER)
  const qsess = { deviceId: pending.deviceId || stableSodaDevice(), installId: pending.installId || stableSodaInstall(), did: pending.deviceId || stableSodaDevice(), iid: pending.installId || stableSodaInstall() }
  const query = smsLiteQuery(qsess)
  const headers = {
    'User-Agent': UA_PASSPORT,
    Accept: 'application/json',
    'Content-Type': 'application/x-www-form-urlencoded',
    'x-tt-passport-trace-id': pending.bizTraceId || stableBizTrace(),
  }
  const cookieStr = cookiesToHeader(pending.cookies)
  if (cookieStr) headers.Cookie = cookieStr
  const csrf = pending.cookies.get('passport_csrf_token') || pending.cookies.get('passport_csrf_token_default') || ''
  if (csrf) headers['x-tt-passport-csrf-token'] = csrf
  const resp = await fetchTO(QR_CHECK_API + '?' + query, { method: 'POST', body, headers })
  const respCookies = new Map()
  setCookiesFromResp(resp, respCookies)
  const merged = mergeCookieMaps(pending.cookies, respCookies)
  const j = await resp.json()
  const d = (j.data || {})
  const result = { status: 1, message: j.message || '等待扫码确认', key: token }
  // 调试日志（SODA_QR_DEBUG=1 时写文件，便于定位扫码确认不生效）
  if (process.env.SODA_QR_DEBUG === '1') {
    try {
      const line = `[${new Date().toISOString()}] check ${token.slice(0, 12)} status=${d.status} error_code=${d.error_code} account_flow=${d.account_flow} desc=${d.description} qr=${String(d.qrcode || '').length} cookies=${[...respCookies.keys()].join(',')} raw=${JSON.stringify(j).slice(0, 400)}\n`
      fs.appendFileSync(path.join(__dirname, 'soda-qr.log'), line)
    } catch (_) { /* 忽略 */ }
  }

  // 成功：cookie 带 session
  if (cookiesHaveSession(merged)) {
    const cookie = cookiesToHeader(merged)
    saveCookie(cookie)
    QR_PENDING.delete(token)
    QR_POLL.delete(token)
    return { status: 4, message: '登录成功', cookie, userid: '' }
  }
  // 限流 error_code=7：退避 90 秒不打汽水（Go 蓝本 60s，当前汽水限流更严故加长），返回缓存状态
  if (d.error_code === 7) {
    qrPollBackoff(token, 90 * 1000)
    return { status: pending.status || 1, message: pending.message || '等待扫码确认', throttled: true, rate_limited: true }
  }
  // MFA 短信验证（扫码确认后需要短信码）——Go 蓝本：account_flow=verify 或 error_code=2046 触发
  const accountFlow = String(d.account_flow || '').toLowerCase()
  if (accountFlow === 'verify' || d.error_code === 2046) {
    const mfaInfo = extractMfaFrom(j, merged)
    QR_PENDING.set(token, {
      ...pending, cookies: merged, status: 2, message: '扫码成功，需要短信验证',
      expiresAt: Date.now() + 10 * 60 * 1000,
      encryptUid: mfaInfo.encryptUid, verifyParams: mfaInfo.verifyParams, mobile: mfaInfo.mobile,
    })
    const out = {
      status: 2, message: '扫码成功，需要短信验证', key: token, need_sms: true,
      encrypt_uid: mfaInfo.encryptUid, verify_params: mfaInfo.verifyParams, mobile: mfaInfo.mobile,
    }
    if (mfaInfo.upSms) {
      out.sms_mode = 'up'
      out.can_up_sms = 'true'
      out.up_sms_mobile = mfaInfo.channelMobile
      out.up_sms_content = mfaInfo.smsContent
    }
    return out
  }
  // 服务端返回新二维码（官方状态 4/5/refused/expired 时带 qrcode+token 刷新机制，可能是抖音验证码）
  const newQr = String(d.qrcode || '').trim()
  const newToken = String(d.token || '').trim()
  if (newQr) {
    let qrImage = newQr
    if (!/^data:image\//.test(qrImage)) qrImage = 'data:image/png;base64,' + qrImage
    const nextToken = newToken || token
    QR_PENDING.set(nextToken, {
      ...pending, cookies: merged, status: 5, message: '需要抖音APP扫码验证',
      expiresAt: Date.now() + 10 * 60 * 1000,
      deviceId: pending.deviceId, installId: pending.installId, bizTraceId: pending.bizTraceId,
    })
    if (nextToken !== token) QR_PENDING.delete(token)
    return {
      status: 5, message: '需要抖音APP扫码验证', key: nextToken,
      qr_url: d.qrcode_index_url || '', qr_image: qrImage, expires_in: 300,
    }
  }
  // 状态机
  const status = String(d.status || '').toLowerCase()
  if (status === 'confirmed' || status === 'scanned') {
    const mfaInfo = extractMfaFrom(j, merged)
    const hasMfa = mfaInfo.encryptUid || mfaInfo.verifyParams || mfaInfo.mfaToken
    QR_PENDING.set(token, {
      ...pending, cookies: merged, status: 2, message: '已扫码，请在手机上确认',
      expiresAt: Date.now() + 10 * 60 * 1000,
      encryptUid: mfaInfo.encryptUid || '', verifyParams: mfaInfo.verifyParams || '', mobile: mfaInfo.mobile || '',
    })
    // scanned 后需等用户在手机确认，拉长轮询间隔（15 秒）给确认时间，避免确认前频繁 check 触发 7 限流
    qrPollSlow(token, 15000)
    if (hasMfa) {
      const out = {
        status: 2, message: '扫码成功，需要短信验证', key: token, need_sms: true,
        encrypt_uid: mfaInfo.encryptUid, verify_params: mfaInfo.verifyParams, mobile: mfaInfo.mobile,
      }
      if (mfaInfo.upSms) {
        out.sms_mode = 'up'
        out.can_up_sms = 'true'
        out.up_sms_mobile = mfaInfo.channelMobile
        out.up_sms_content = mfaInfo.smsContent
      }
      return out
    }
    return { status: 2, message: '已扫码，请在手机上确认', key: token }
  }
  if (status === 'expired') {
    QR_PENDING.delete(token)
    QR_POLL.delete(token)
    return { status: 0, message: '二维码已过期', key: token }
  }
  if (status === 'error' || status === 'failed' || (d.error_code && d.error_code !== 0 && d.error_code !== 7)) {
    return { status: 0, message: d.description || j.message || '登录失败', key: token }
  }
  // new / 空 → 等待
  QR_PENDING.set(token, { ...pending, cookies: merged, status: 1, message: '等待扫码确认', expiresAt: Date.now() + 10 * 60 * 1000 })
  return { status: 1, message: '等待扫码确认', key: token }
}

// ---- MFA 短信验证：send_code / validate_code（Go 蓝本 lite 参数集 + type=3737）----

/** 验证码 hex 编码（Go sodaEncodeSMSCode：hex.EncodeToString([]byte(code))） */
function encodeSmsCode(code) {
  return Buffer.from(String(code || '').trim(), 'utf8').toString('hex')
}

/** 构造 send_code / validate_code 的 body（Go sodaSendCode params 等价） */
function mfaSmsParams(encryptUid, verifyParams, code) {
  const p = {
    mix_mode: '1',
    type: '3737',
    encrypt_uid: encryptUid,
    verify_ticket: '',
    copywriting_key: 'qr_connect',
    ies_safety_diversion_tag: 'mfa',
    new_verify_flow: '',
    std_verify_way: 'mobile_sms_verify',
    is6Digits: '1',
    aid: AID,
    new_authn_sdk_version: '1.0.0.404-web',
  }
  if (code !== undefined) p.code = encodeSmsCode(code)
  if (verifyParams) {
    try {
      const parsed = new URLSearchParams(verifyParams)
      for (const [k, v] of parsed) p[k] = v
    } catch (_) { /* 忽略 */ }
  }
  return orderedForm(p, Object.keys(p))
}

/** 发验证码：POST /passport/web/send_code/（lite 集 + type=3737 + encrypt_uid + verify_params） */
async function smsSend(key) {
  const token = String(key || '').trim()
  if (!token) throw err(400, '缺少参数 key')
  const pending = QR_PENDING.get(token)
  if (!pending || !pending.encryptUid) throw err(400, '缺少短信验证参数，请重新扫码')
  const body = mfaSmsParams(pending.encryptUid, pending.verifyParams)
  const headers = {
    'User-Agent': UA_PASSPORT,
    'Content-Type': 'application/x-www-form-urlencoded',
    'sec-ch-ua': '"Not.A/Brand";v="99", "Chromium";v="136"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    Accept: 'application/json, text/plain, */*',
    'x-tt-passport-verify-portrait': pending.portrait || newVerifyPortrait(),
  }
  const cookieStr = cookiesToHeader(pending.cookies)
  if (cookieStr) headers.Cookie = cookieStr
  const resp = await fetchTO(SEND_CODE_API + '?' + orderedForm(liteValuesFor(pending.deviceId || stableDevice(), pending.bizTraceId || stableBizTrace()), LITE_ORDER), { method: 'POST', body, headers })
  const respCookies = new Map()
  setCookiesFromResp(resp, respCookies)
  const merged = mergeCookieMaps(pending.cookies, respCookies)
  const j = await resp.json()
  const d = (j.data || {})
  if (process.env.SODA_QR_DEBUG === '1') {
    try {
      const line = `[${new Date().toISOString()}] sms_send ${token.slice(0, 12)} error_code=${d.error_code} desc=${d.description} retry=${d.retry_time} raw=${JSON.stringify(j).slice(0, 300)}\n`
      fs.appendFileSync(path.join(__dirname, 'soda-qr.log'), line)
    } catch (_) { /* 忽略 */ }
  }
  if (d.error_code && d.error_code !== 0) {
    if (d.error_code === 7) return { code: 429, message: d.description || '发送太频繁，请稍后再试' }
    throw err(502, d.description || j.message || '验证码发送失败')
  }
  QR_PENDING.set(token, { ...pending, cookies: merged, smsSentAt: Date.now() })
  return { code: 200, message: '验证码已发送', retry_time: d.retry_time || 60, mobile: pending.mobile || '' }
}

/** 校验验证码：POST /passport/web/validate_code/，成功后重查 check_qrconnect 拿 session */
async function smsVerify(key, code) {
  const token = String(key || '').trim()
  if (!token) throw err(400, '缺少参数 key')
  const smsCode = String(code || '').trim()
  if (!smsCode) throw err(400, '缺少验证码')
  const pending = QR_PENDING.get(token)
  if (!pending || !pending.encryptUid) throw err(400, '缺少短信验证参数，请重新扫码')
  const body = mfaSmsParams(pending.encryptUid, pending.verifyParams, smsCode)
  const headers = {
    'User-Agent': UA_PASSPORT,
    'Content-Type': 'application/x-www-form-urlencoded',
    'sec-ch-ua': '"Not.A/Brand";v="99", "Chromium";v="136"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    Accept: 'application/json, text/plain, */*',
    'x-tt-passport-verify-portrait': pending.portrait || newVerifyPortrait(),
  }
  const cookieStr = cookiesToHeader(pending.cookies)
  if (cookieStr) headers.Cookie = cookieStr
  const resp = await fetchTO(VALIDATE_API + '?' + orderedForm(liteValuesFor(pending.deviceId || stableDevice(), pending.bizTraceId || stableBizTrace()), LITE_ORDER), { method: 'POST', body, headers })
  const respCookies = new Map()
  setCookiesFromResp(resp, respCookies)
  const merged = mergeCookieMaps(pending.cookies, respCookies)
  const j = await resp.json()
  const d = (j.data || {})
  if (process.env.SODA_QR_DEBUG === '1') {
    try {
      const line = `[${new Date().toISOString()}] sms_verify ${token.slice(0, 12)} error_code=${d.error_code} desc=${d.description} ticket=${d.ticket} raw=${JSON.stringify(j).slice(0, 300)}\n`
      fs.appendFileSync(path.join(__dirname, 'soda-qr.log'), line)
    } catch (_) { /* 忽略 */ }
  }
  if (d.error_code && d.error_code !== 0) {
    if (d.error_code === 7) return { code: 429, message: d.description || '操作太频繁，请稍后再试' }
    throw err(502, d.description || j.message || '验证码错误')
  }
  // 验证通过：带 verify_params 重查 check_qrconnect 拿最终登录态（Go sodaCheckQRConnectWithState(token, pending, true)）
  const pending2 = { ...pending, cookies: merged }
  const checkForm = { need_logo: 'false', need_short_url: 'false', is_frontier: 'true', token, is_new_login: '1', next: PC_LOGIN_NEXT }
  if (pending2.verifyParams) {
    try {
      const parsed = new URLSearchParams(pending2.verifyParams)
      for (const [k, v] of parsed) checkForm[k] = v
    } catch (_) { /* 忽略 */ }
  }
  if (!Object.prototype.hasOwnProperty.call(checkForm, 'std_verify_way')) checkForm.std_verify_way = ''
  const body2 = orderedForm(checkForm, [...QR_CHECK_FORM_ORDER, 'passport_mfa_retry_tag', 'std_verify_flow_id', 'std_verify_scene', 'std_verify_template', 'std_verify_token', 'std_verify_type', 'std_verify_way'])
  const headers2 = {
    'User-Agent': UA_PASSPORT,
    'Content-Type': 'application/x-www-form-urlencoded',
    'sec-ch-ua': '"Not.A/Brand";v="99", "Chromium";v="136"',
    'sec-ch-ua-mobile': '?0',
    'sec-ch-ua-platform': '"Windows"',
    Accept: 'application/json, text/javascript',
    'bd-ticket-guard-version': '2',
    'bd-ticket-guard-iteration-version': '2',
    'bd-ticket-guard-ree-public-key': 'BAnIxKL96Jby5x+Um9i7HZ2c8O6lfZJRxm6yk73Mqcr06l2qIw2iqu2Mtm3U/6OI98usukA9dqxUlsctVWK9rKA=',
    'bd-ticket-guard-server-cert-sn': '0',
    'x-tt-passport-verify-portrait': pending.portrait || newVerifyPortrait(),
  }
  const cookieStr2 = cookiesToHeader(pending2.cookies)
  if (cookieStr2) headers2.Cookie = cookieStr2
  const resp2 = await fetchTO(QR_CHECK_API + '?' + orderedForm(liteValuesFor(pending2.deviceId || stableDevice(), pending2.bizTraceId || stableBizTrace()), LITE_ORDER), { method: 'POST', body: body2, headers: headers2 })
  const respCookies2 = new Map()
  setCookiesFromResp(resp2, respCookies2)
  const merged2 = mergeCookieMaps(pending2.cookies, respCookies2)
  const j2 = await resp2.json()
  if (process.env.SODA_QR_DEBUG === '1') {
    try {
      const line = `[${new Date().toISOString()}] sms_verify_recheck ${token.slice(0, 12)} status=${(j2.data || {}).status} error_code=${(j2.data || {}).error_code} desc=${(j2.data || {}).description} cookies=${[...respCookies2.keys()].join(',')} raw=${JSON.stringify(j2).slice(0, 300)}\n`
      fs.appendFileSync(path.join(__dirname, 'soda-qr.log'), line)
    } catch (_) { /* 忽略 */ }
  }
  if (cookiesHaveSession(merged2)) {
    const cookie = cookiesToHeader(merged2)
    saveCookie(cookie)
    QR_PENDING.delete(token)
    QR_POLL.delete(token)
    return { code: 200, message: '登录成功', cookie, userid: '' }
  }
  // 未拿到 session：可能是验证通过但需再轮询，存回 pending 让前端继续 check
  QR_PENDING.set(token, { ...pending2, cookies: merged2 })
  return { code: 200, message: '验证成功，正在完成登录...', key: token, need_recheck: true }
}

// ---- 独立短信验证码登录（官方 login.sendCode type=24 + sms_login {mobile,code}，逆向自 login.asar）----
// 已验证：type=7/3737 会被 3052 拦，type=24 是登录场景正确类型（返回限流 7 而非参数错误）
// 每个手机号独立会话（device_id + csrf cookie），互不干扰，多用户隔离
const SMS_SESSIONS = new Map() // mobile -> { deviceId, bizTraceId, cookies:Map, csrf, expiresAt }

// 进程级稳定 install_id（官方 ci().installId 与 deviceId 不同，模拟两个稳定设备标识）
let sodaInstallVal = ''
function stableSodaInstall() {
  if (!sodaInstallVal) sodaInstallVal = String(Math.floor(1000000000000000 + Math.random() * 9000000000000000))
  return sodaInstallVal
}

function smsSession(mobile) {
  const now = Date.now()
  const st = SMS_SESSIONS.get(mobile)
  if (st && st.expiresAt > now) return st
  const dev = stableSodaDevice()
  const inst = stableSodaInstall()
  const s = {
    deviceId: dev,
    installId: inst,
    did: dev,
    iid: inst,
    bizTraceId: stableBizTrace(),
    cookies: new Map(),
    csrf: '',
    expiresAt: now + 10 * 60 * 1000,
  }
  SMS_SESSIONS.set(mobile, s)
  return s
}

// 短信/登录接口按官方 SDK（WebInterfaceSdk 的 $q 拦截器）形态：
// passport_jssdk_version=4.2.3 + passport_jssdk_type=lite + language=zh + 全套设备标识
// + is_new_login/is_from_iesaccountsaas + ts（UTC 当天 12 点秒，aG 签名中间件所加）
function smsLiteQuery(sess) {
  const ts = Math.floor(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), new Date().getUTCDate(), 12, 0, 0, 0) / 1000)
  return 'passport_jssdk_version=4.2.3&passport_jssdk_type=lite&is_from_ttaccountsdk=1&aid=386088' +
    '&language=zh' +
    '&device_id=' + sess.deviceId + '&install_id=' + sess.installId + '&did=' + sess.did + '&iid=' + sess.iid +
    '&device_platform=PC&version_code=3.7.0' +
    '&is_new_login=1&is_from_iesaccountsaas=1' +
    '&biz_trace_id=' + (sess.bizTraceId || stableBizTrace()) +
    '&ts=' + ts
}

function smsHeaders(sess) {
  const h = {
    'User-Agent': UA_PASSPORT,
    'Content-Type': 'application/x-www-form-urlencoded',
    Accept: 'application/json, text/plain, */*',
    Origin: 'https://api.qishui.com',
    Referer: 'https://api.qishui.com/',
    'Sec-Fetch-Site': 'same-site',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Dest': 'empty',
    'x-tt-passport-verify-portrait': sess.portrait || (sess.portrait = newVerifyPortrait()),
    'x-tt-passport-trace-id': sess.bizTraceId || stableBizTrace(),
  }
  const cookieStr = cookiesToHeader(sess.cookies)
  if (cookieStr) h.Cookie = cookieStr
  if (sess.csrf) h['x-tt-passport-csrf-token'] = sess.csrf
  return h
}

/** 初始化会话并获取 csrf token（GET get_qrcode 会 Set-Cookie passport_csrf_token） */
async function smsEnsureCsrf(sess) {
  if (sess.csrf) return
  const url = QR_CREATE_API + '?' + smsLiteQuery(sess) + '&next=' + qe(PC_LOGIN_NEXT)
  const resp = await fetchTO(url, { method: 'GET', headers: { 'User-Agent': UA_PASSPORT, Accept: 'application/json, text/javascript', Origin: 'https://api.qishui.com', Referer: 'https://api.qishui.com/', 'x-tt-passport-verify-portrait': newVerifyPortrait() } })
  const cs = new Map()
  setCookiesFromResp(resp, cs)
  for (const [k, v] of cs) sess.cookies.set(k, v)
  sess.csrf = sess.cookies.get('passport_csrf_token') || sess.cookies.get('passport_csrf_token_default') || ''
  if (!sess.csrf) throw err(502, '汽水会话初始化失败')
}

/** 发送手机验证码：POST /passport/web/send_code/ type=24 */
async function smsSendCode(mobile) {
  const m = String(mobile || '').trim().replace(/\s+/g, '')
  if (!/^1\d{10}$/.test(m)) throw err(400, '手机号格式不正确')
  const sess = smsSession(m)
  await smsEnsureCsrf(sess)
  const body = 'is6Digits=1&mobile=' + encryptXor5('86 ' + m) + '&type=' + encryptXor5('24') + '&mix_mode=1&fixed_mix_mode=1'
  const resp = await fetchTO(SEND_CODE_API + '?' + smsLiteQuery(sess), { method: 'POST', body, headers: smsHeaders(sess) })
  const cs = new Map()
  setCookiesFromResp(resp, cs)
  for (const [k, v] of cs) sess.cookies.set(k, v)
  const j = await resp.json()
  const d = (j.data || {})
  if (process.env.SODA_QR_DEBUG === '1') {
    try {
      const line = `[${new Date().toISOString()}] sms_code ${m.slice(0, 3)}****${m.slice(-2)} error_code=${d.error_code} desc=${d.description} retry=${d.retry_time} raw=${JSON.stringify(j).slice(0, 300)}\n`
      fs.appendFileSync(path.join(__dirname, 'soda-qr.log'), line)
    } catch (_) { /* 忽略 */ }
  }
  if (d.error_code && d.error_code !== 0) {
    if (d.error_code === 7) throw err(429, d.description || '发送太频繁，请稍后再试')
    throw err(502, d.description || j.message || '验证码发送失败')
  }
  return { code: 200, message: '验证码已发送', retry_time: d.retry_time || 60, mobile: m }
}

/** 验证码登录：POST /passport/web/sms_login/ {mobile, code} */
async function smsLoginMobile(mobile, code) {
  const m = String(mobile || '').trim().replace(/\s+/g, '')
  const c = String(code || '').trim()
  if (!/^1\d{10}$/.test(m)) throw err(400, '手机号格式不正确')
  if (!c) throw err(400, '缺少验证码')
  const sess = smsSession(m)
  await smsEnsureCsrf(sess)
  const body = 'safe_mobile_register_to_login=false&service=' + qe(PC_LOGIN_NEXT) +
    '&mobile=' + encryptXor5('86 ' + m) + '&code=' + encryptXor5(c) + '&mix_mode=1&fixed_mix_mode=1'
  const resp = await fetchTO(SMS_LOGIN_API + '?' + smsLiteQuery(sess), { method: 'POST', body, headers: smsHeaders(sess) })
  const cs = new Map()
  setCookiesFromResp(resp, cs)
  const merged = mergeCookieMaps(sess.cookies, cs)
  for (const [k, v] of merged) sess.cookies.set(k, v)
  const j = await resp.json()
  const d = (j.data || {})
  if (process.env.SODA_QR_DEBUG === '1') {
    try {
      const line = `[${new Date().toISOString()}] sms_login ${m.slice(0, 3)}****${m.slice(-2)} error_code=${d.error_code} desc=${d.description} cookies=${[...cs.keys()].join(',')} raw=${JSON.stringify(j).slice(0, 300)}\n`
      fs.appendFileSync(path.join(__dirname, 'soda-qr.log'), line)
    } catch (_) { /* 忽略 */ }
  }
  if (d.error_code && d.error_code !== 0) {
    if (d.error_code === 7) throw err(429, d.description || '操作太频繁，请稍后再试')
    throw err(502, d.description || j.message || '验证码错误或已过期')
  }
  if (!cookiesHaveSession(merged)) {
    throw err(502, '登录未完成，未获取到登录态，请重试')
  }
  const cookie = cookiesToHeader(merged)
  saveCookie(cookie)
  SMS_SESSIONS.delete(m)
  return { code: 200, message: '登录成功', cookie, userid: '' }
}

/** 登录状态（请求级 cookie 优先） */
async function status(cookie = '') {  const auth = resolveAuth(cookie)
  if (!auth) return { loggedIn: false }
  try {
    const params = pcAppParams()
    const resp = await fetchTO('https://api.qishui.com/luna/pc/me?' + params, { headers: pcRequestOptions(auth) })
    const j = await resp.json()
    if (j.status_code !== 0) return { loggedIn: false }
    const mi = j.my_info || {}
    if (!mi.id) return { loggedIn: false }
    return {
      loggedIn: true,
      user: {
        id: String(mi.id),
        nickname: mi.nickname || mi.public_name || '',
        avatar: buildImageURL(mi.larger_avatar_url, '~c5_100x100.jpg') || '',
      },
    }
  } catch (_) {
    return { loggedIn: false }
  }
}

/** 退出登录 */
function logout(cookie = '') {
  if (!cookie) { saveCookie('') }
  return { loggedIn: false }
}

// ---- 个人歌单 ----

// ---- 一键登录：直接从本机汽水音乐 PC 客户端 Cookie 数据库读 sessionid（明文），绕开扫码/短信/风控 ----
// 实测唯一稳定方案：sessionid 明文存于 %APPDATA%\SodaMusic\Network\Cookies（SQLite）
function readPcSessionId() {
  return new Promise((resolve, reject) => {
    const script = path.join(__dirname, 'qr-decode', 'read-pc-cookie.py')
    require('child_process').execFile('python', [script], { timeout: 10000 }, (err, stdout) => {
      if (err) return reject(err(500, '读取 PC 客户端登录态失败: ' + String(err.message).split('\n')[0]))
      const m = String(stdout || '').match(/SESSIONID=([0-9a-zA-Z_-]{20,})/)
      if (m) return resolve(m[1])
      const em = String(stdout || '').match(/ERROR=(.*)/)
      reject(err(401, em ? em[1].trim() : '未读到有效 sessionid（请确认汽水音乐客户端已登录）'))
    })
  })
}

async function loginLocal() {
  const sessionid = await readPcSessionId()
  saveCookie('sessionid=' + sessionid)
  const st = await status()
  if (!st.loggedIn) throw err(502, 'sessionid 已失效，请在汽水音乐 PC 客户端重新登录后再试')
  return { loggedIn: true, user: st.user, cookie: 'sessionid=' + sessionid, sessionid: sessionid.slice(0, 8) + '...' }
}

async function fetchMe(cookie) {
  const params = pcAppParams()
  const resp = await fetchTO('https://api.qishui.com/luna/pc/me?' + params, { headers: pcRequestOptions(cookie) })
  const j = await resp.json()
  if (j.status_code !== 0) throw err(502, '汽水登录态校验失败: ' + ((j.status_info && j.status_info.status_msg) || ('code=' + j.status_code)))
  return j.my_info || {}
}

async function userPlaylists(cookie = '', page = 1, limit = 30) {
  const auth = resolveAuth(cookie)
  if (!auth) throw err(401, '汽水未登录')
  const me = await fetchMe(auth)
  const userId = String(me.id || '')
  if (!userId) throw err(401, '汽水未登录（无用户ID）')
  const target = Math.max(1, Number(page) || 1) * Math.max(1, Number(limit) || 30)
  const requestCount = Math.min(100, Math.max(50, target))
  let cursor = ''
  const seenCursors = new Set()
  const seen = new Set()
  const playlists = []
  for (let attempts = 0; attempts < 20 && playlists.length < target; attempts++) {
    const params = pcAppParams({ user_id: userId, cursor, count: String(requestCount) })
    const resp = await fetchTO('https://api.qishui.com/luna/pc/me/playlist?' + params, { headers: pcRequestOptions(auth) })
    const j = await resp.json()
    const stMsg = j.status_info && j.status_info.status_msg
    if ((j.status_code !== undefined && j.status_code !== 0) || (stMsg && stMsg !== 'success')) throw err(502, '汽水歌单获取失败: ' + (stMsg || ('code=' + j.status_code)))
    for (const item of j.playlists || []) {
      const id = String(item.id || '')
      if (!id || seen.has(id)) continue
      seen.add(id)
      playlists.push({
        id,
        name: item.title || item.public_title || '未命名歌单',
        cover: buildImageURL(item.url_cover, '~c5_300x300.jpg') || '',
        songCount: Number(item.count_tracks || 0) || 0,
        playCount: Number(item.stats && item.stats.count_played) || 0,
        desc: item.desc || '',
        owner: (item.owner && (item.owner.nickname || item.owner.public_name)) || me.nickname || '',
      })
    }
    const next = String(j.next_cursor || '').trim()
    if (!next || next === cursor || seenCursors.has(next)) break
    if (!j.has_more && (j.playlists || []).length < requestCount) break
    seenCursors.add(next)
    cursor = next
  }
  const start = (Math.max(1, Number(page) || 1) - 1) * Math.max(1, Number(limit) || 30)
  return { playlists: playlists.slice(start, start + Math.max(1, Number(limit) || 30)), total: playlists.length }
}

// ---- 歌单详情 ----
async function playlistDetail(id, cookie = '') {
  const auth = resolveAuth(cookie)
  const playlistId = String(id || '').trim()
  if (!playlistId) throw err(400, '缺少参数 id')
  let cursor = ''
  const seenCursors = new Set()
  const seenTracks = new Set()
  let pl = null
  const songs = []
  for (let page = 0; page < 20; page++) {
    const params = pcAppParams({ playlist_id: playlistId, cursor, count: '100' })
    const resp = await fetchTO('https://api.qishui.com/luna/pc/playlist/detail?' + params, { headers: pcRequestOptions(auth) })
    const j = await resp.json()
    if (j.status_code !== 0) {
      if (page === 0) return playlistDetailWeb(playlistId, auth)
      throw err(502, '汽水歌单详情失败: ' + ((j.status_info && j.status_info.status_msg) || ('code=' + j.status_code)))
    }
    if (!pl) {
      const p = j.playlist || {}
      pl = {
        id: String(p.id || playlistId),
        name: p.title || p.public_title || '未命名歌单',
        cover: buildImageURL(p.url_cover, '~c5_300x300.jpg') || '',
        songCount: Number(p.count_tracks || 0),
        creator: (p.owner && (p.owner.nickname || p.owner.public_name)) || '',
        desc: p.desc || '',
        source: 'soda',
      }
    }
    for (const item of j.media_resources || []) {
      if (item.type !== 'track') continue
      const track = ((item.entity || {}).track_wrapper || {}).track || {}
      const tid = String(track.id || '')
      if (!tid || seenTracks.has(tid)) continue
      seenTracks.add(tid)
      const song = buildSongFromTrack(track, pl.cover)
      songs.push(song)
    }
    const next = String(j.next_cursor || '').trim()
    if (!next || next === cursor || seenCursors.has(next)) break
    if (!j.has_more && (j.media_resources || []).length < 100) break
    seenCursors.add(next)
    cursor = next
  }
  if (!pl) pl = { id: playlistId, name: '未知歌单', cover: '', songCount: songs.length, creator: '', source: 'soda' }
  if (!pl.songCount) pl.songCount = songs.length
  return { ...pl, songs }
}

/** web 版歌单详情兜底（直接带播放 URL 与歌词源信息） */
async function playlistDetailWeb(playlistId, auth) {
  const params = orderedForm({ playlist_id: playlistId, cursor: '0', cnt: '20', aid: AID, device_platform: 'web', channel: 'pc_web' }, ['playlist_id', 'cursor', 'cnt', 'aid', 'device_platform', 'channel'])
  const resp = await fetchTO('https://api.qishui.com/luna/pc/playlist/detail?' + params, { headers: { 'User-Agent': UA_WEB, Cookie: auth || '' } })
  const j = await resp.json()
  const p = j.playlist || {}
  const pl = {
    id: String(p.id || playlistId),
    name: p.title || '未命名歌单',
    cover: buildImageURL(p.url_cover, '~c5_300x300.jpg') || '',
    songCount: Number(p.count_tracks || 0),
    creator: (p.owner && p.owner.nickname) || '',
    desc: p.desc || '',
    source: 'soda',
  }
  const songs = []
  for (const item of j.media_resources || []) {
    if (item.type !== 'track') continue
    const track = ((item.entity || {}).track_wrapper || {}).track || {}
    if (!track.id) continue
    songs.push(buildSongFromTrack(track, pl.cover))
  }
  if (!pl.songCount) pl.songCount = songs.length
  return { ...pl, songs }
}

// ---- 单曲取流 ----
async function songUrl(trackId, cookie = '') {
  const auth = resolveAuth(cookie)
  const id = String(trackId || '').trim()
  if (!id) throw err(400, '缺少参数 id')
  const { track, trackPlayer, lyric } = await fetchTrackV2(id, auth)
  const song = buildSongFromTrack(track, '')
  // 优先 audio_info 内嵌流；否则 video_model → url_player_info
  let info = null
  if (song.url && !song.url.includes('#auth=')) {
    info = { url: song.url, playAuth: '', format: song.ext || '', size: song.size, bitrate: song.bitrate, quality: song.quality || '' }
  } else {
    info = downloadInfoFrom(track, trackPlayer)
  }
  if (!info && trackPlayer && trackPlayer.url_player_info) {
    try { info = await fetchPlayerInfo(trackPlayer.url_player_info, auth) } catch (_) { /* 忽略 */ }
  }
  // 无可用流 → 尝试 PC track_v2（VIP 歌/加密流）
  if (!info && auth) {
    try {
      const body = JSON.stringify({ track_id: id, media_type: 'track', queue_type: 'favorite_track_playlist', scene_name: 'library' })
      const params = pcAppParams()
      const resp = await fetchTO('https://api.qishui.com/luna/pc/track_v2?' + params, {
        method: 'POST',
        body,
        headers: { ...pcRequestOptions(auth), 'Content-Type': 'application/json; charset=utf-8' },
      })
      const pc = await resp.json()
      const pcTrack = (pc.track && pc.track.id) ? pc.track : (pc.track_info || {})
      if (pcTrack.id) {
        let pi = null
        if (pc.track_player && pc.track_player.video_model) pi = bestFromVideoModel(pc.track_player.video_model)
        if (!pi && pc.track_player && pc.track_player.url_player_info) pi = await fetchPlayerInfo(pc.track_player.url_player_info, auth)
        if (pi) info = pi
      }
    } catch (_) { /* PC 通道失败忽略 */ }
  }
  if (!info || !info.url) {
    // 加密流（play_auth 非空）当前无法解密播放 → 标记 blocked
    if (song.isVip) {
      return { id, name: song.name, artist: song.artist, blocked: true, vip: true, message: '汽水 VIP 歌曲暂不支持播放（加密音源）', lyric }
    }
    throw err(502, '该歌曲在汽水无可用音源')
  }
  const hasAuth = Boolean(String(info.playAuth || '').trim())
  if (hasAuth) {
    return { id, name: song.name, artist: song.artist, blocked: true, vip: song.isVip, message: '汽水加密音源暂不支持播放', lyric }
  }
  return {
    id,
    url: info.url,
    br: info.bitrate || 128000,
    source: 'soda',
    duration: song.duration,
    cover: song.cover,
    name: song.name,
    artist: song.artist,
    album: song.album,
    lyric,
  }
}

// ---- 歌词 ----
async function lyric(trackId, cookie = '') {
  const auth = resolveAuth(cookie)
  const id = String(trackId || '').trim()
  if (!id) throw err(400, '缺少参数 id')
  const { lyric: raw } = await fetchTrackV2(id, auth)
  return { lyric: parseSodaLyric(raw) }
}

// ---- 搜索（Android 接口，移植 search.go / song.go）----
const UA_ANDROID = 'com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)'
const ANDROID_PARAMS = {
  device_platform: 'android', os: 'android', ssmix: 'a',
  cdid: '46556f98-1720-4248-83da-62b74b60b46a', channel: 'xiaomi_8478_64', aid: '8478',
  app_name: 'luna', version_code: '100198030', version_name: '19.8.0',
  manifest_version_code: '100198030', update_version_code: '100198030',
  resolution: '1080*1920', dpi: '480', device_type: 'ABR-AL80', device_brand: 'HUAWEI',
  language: 'zh', os_api: '35', os_version: '15', ac: 'wifi', device_model: 'ABR-AL80',
  save_power: '0', font_size: '1.00', luna_first_launch_apk_type: 'normal_apk',
  diversion_channel_name: 'xiaomi_8478_64', is_car_play: '0', battery: '0.99',
  network_speed: '10156', hybrid_version_code: '100198030', tz_name: 'Asia/Shanghai',
  tz_offset: '28800', luna_register_time: '1784311292',
  diversion_category_level_two: 'Xiaomi%E5%95%86%E5%BA%97-%E8%87%AA%E7%84%B6',
  package: 'com.luna.music', charge: '0', luna_apk_type: 'normal_apk',
  output_device_type: 'Phone', volume: '1.00', brightness: '0.08',
  need_personal_recommend: '1', is_teen_mode: '0', sim_region: 'cn',
  diversion_category_level_one: '%E5%8E%82%E5%95%86%E5%95%86%E5%BA%97-%E8%87%AA%E7%84%B6',
  android_device_type: 'default', iid: '2204957404569386', device_id: '2204957404565290',
}
async function search(keywords, limit = 30) {
  const kw = String(keywords || '').trim()
  if (!kw) throw err(400, '缺少参数 keywords')
  const pageSize = Math.min(50, Math.max(1, Number(limit) || 30))
  const params = { ...ANDROID_PARAMS, _rticket: String(Date.now()), q: kw, cursor: '0', count: String(pageSize), aid: '386088' }
  const qs = Object.keys(params).map((k) => qe(k) + '=' + qe(params[k])).join('&')
  const resp = await fetchTO('https://api.qishui.com/luna/search/track?' + qs, { headers: { 'User-Agent': UA_ANDROID, 'content-type': 'application/json; charset=UTF-8' } })
  const txt = await resp.text()
  let j
  try { j = JSON.parse(txt) } catch (_) { throw err(502, '汽水搜索返回异常: ' + String(txt).slice(0, 120)) }
  const songs = []
  const seen = new Set()
  for (const group of j.result_groups || []) {
    for (const item of group.data || []) {
      const track = ((item.entity || {}).track) || {}
      const tid = String(track.id || '')
      if (!tid || seen.has(tid)) continue
      seen.add(tid)
      songs.push(buildSongFromTrack(track, ''))
    }
  }
  return { songs, total: songs.length }
}

module.exports = {
  loginLocal,
  loginQrKey,
  loginQrCheck,
  smsSend,
  smsVerify,
  smsSendCode,
  smsLoginMobile,
  status,
  logout,
  userPlaylists,
  playlistDetail,
  songUrl,
  lyric,
  search,
  resolveAuth,
}
