/**
 * frontier.js — 汽水音乐扫码登录长连接（官方 FWS 协议）
 *
 * 逆向自官方 PC 客户端 3.7.0（fws.esm-ewaraAYI.js + use-frontier）：
 *  - wss://frontier100-normal.zijieapi.com/ws/v2?device_platform=web&version_code=fws_1.0.0&access_key=<md5>&fpid=971&aid=6383&device_id=<id>&...
 *  - accessKey = MD5(fpID + appKey + device_id + 'f8a69f1719916z')
 *  - 子协议 pbbp2
 *  - 扫码确认后服务端推送 protocol_type=405 消息 → 触发 check_qrconnect
 */
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const WebSocket = require('ws')

function flog(msg) {
  try {
    if (process.env.SODA_QR_DEBUG === '1') {
      fs.appendFileSync(path.join(__dirname, 'soda-qr.log'), '[' + new Date().toISOString() + '] FRONTIER ' + msg + '\n')
    }
  } catch (_) { /* 忽略 */ }
}

// fws.esm 在 Node 环境从全局取 WebSocket
if (typeof globalThis.WebSocket === 'undefined') {
  globalThis.WebSocket = WebSocket
}

const FP_ID = '971'
const APP_KEY = 'b80f8270dbb7d91cd76ed17bb19d215b'
const AID = '6383'
const SECRET = 'f8a69f1719916z'
const DEFAULT_URL = 'wss://frontier100-normal.zijieapi.com'

let fwsPromise = null
function getFWSModule() {
  if (!fwsPromise) {
    fwsPromise = import('file://' + __dirname.replace(/\\/g, '/') + '/frontier-fws.esm.js')
  }
  return fwsPromise
}

function accessKeyFor(deviceId) {
  return crypto.createHash('md5').update(FP_ID + APP_KEY + String(deviceId) + SECRET).digest('hex')
}

/** 建立 frontier 长连接；onMessage(payloadObj) 收到服务端推送（含 protocol_type=405 确认） */
async function connectFrontier(deviceId, onMessage, onError) {
  const { FWS } = await getFWSModule()
  const f = new FWS({
    fpID: FP_ID,
    aID: AID,
    appKey: APP_KEY,
    accessKey: accessKeyFor(deviceId),
    deviceID: String(deviceId),
    url: DEFAULT_URL,
    ws: WebSocket,
    debug: false,
    automaticOpen: true,
  })
  f.onmessage = (evt) => {
    try {
      const payload = (evt && evt.message && evt.message.payload) || (evt && evt.payload)
      if (!payload) { flog('msg empty payload'); return }
      const raw = payload instanceof Uint8Array ? Array.from(payload)
        : Array.isArray(payload) ? payload
        : (typeof payload === 'object' && payload !== null)
          ? Object.keys(payload).sort((a, b) => Number(a) - Number(b)).map((k) => payload[k])
          : null
      if (!raw) { flog('msg no raw'); return }
      const text = new TextDecoder('utf-8').decode(new Uint8Array(raw))
      let obj
      try { obj = JSON.parse(text) } catch (_) { obj = { text } }
      flog('msg device=' + deviceId + ' obj=' + JSON.stringify(obj).slice(0, 300))
      onMessage && onMessage(obj, text)
    } catch (e) { flog('msg err ' + e.message) }
  }
  f.onerror = (evt) => { flog('error device=' + deviceId + ' ' + JSON.stringify(evt && evt.message || evt).slice(0, 200)); onError && onError(evt) }
  f.onopen = (evt) => { flog('open device=' + deviceId + ' url=' + DEFAULT_URL) }
  return f
}

module.exports = { connectFrontier, accessKeyFor }
