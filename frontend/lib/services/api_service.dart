/// 音源服务 API 封装
///
/// 接口全部为 GET，返回 JSON：
/// - /search?keywords=&limit=&offset=         （网易云搜索）
/// - /search/bili?keywords=&limit=20         （B站搜索）
/// - /recommend
/// - /playlist
/// - /song/detail?ids=
/// - /song/url?id=                            （网易云取流）
/// - /song/url/bili?bvid=xxx                  （B站取流）
/// - /stream?url=  /stream/bili?bvid=         （音频代理，播放必走这里）
/// - /lyric?id=
/// - /login/qr  /login/qr/check?key=  /status  /logout  /user/playlist
/// - /like  /likelist
/// - /kugou/*（酷狗音源：search/song/url/login/qr/login/qr/check/user/playlist/
///   playlist/detail/recommend/daily/recommend/fm/status/logout）
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/app_user.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import 'lrc_parser.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => 'ApiException: $message';
}

/// 未登录（酷狗需登录接口返回 HTTP 301 + {code:301, message:'未登录'}）
///
/// 页面捕获后应隐藏对应入口或弹出登录，而不是当普通错误提示。
class NotLoggedInException implements Exception {
  const NotLoggedInException();
  @override
  String toString() => 'NotLoggedInException: 未登录';
}

/// /like 接口结构化返回：区分「HTTP/JSON 成功」「服务端登录态」
///
/// - [ok]：HTTP 200 且 JSON code==200
/// - [loggedIn]：服务端当前是否已登录（未登录时服务端不执行喜欢操作）
/// - [liked]：服务端最终喜欢状态（取消喜欢成功时为 false）
class LikeResult {
  final bool ok;
  final bool loggedIn;
  final bool liked;
  const LikeResult({
    required this.ok,
    required this.loggedIn,
    required this.liked,
  });
}

/// 网易云扫码登录结果
/// code: 800=过期 801=等待 802=已扫 803=成功
/// cookie: 登录成功后后端回传的登录态整串（可能为空）
class NeteaseQrCheckResult {
  final int code;
  final String cookie;
  const NeteaseQrCheckResult(this.code, this.cookie);
}

class ApiService {
  ApiService._();

  static final http.Client _client = http.Client();

  // ---- Cookie 管理 ----
  // Dart http.Client 不会自动管理 Set-Cookie / Cookie header，
  // 需要手动存储服务端返回的 cookie 并在后续请求中回传。
  // cookie 会持久化到本地：登录态跟随本设备，多设备各用各的账号，互不覆盖。
  static final Map<String, String> _cookies = {};
  static const String _cookiePrefsKey = 'netease_cookie';

  // ---- 酷狗 Cookie 管理（与网易云完全独立，整串保存整串回传） ----
  // 格式：token=xxx; userid=xxx; vip_token=xxx; vip_type=xxx; mid=xxx
  static const String _kugouCookiePrefsKey = 'kugou_cookie';
  static String _kugouCookie = '';

  // ---- QQ Cookie 管理（三音源完全独立，整串保存整串回传） ----
  // 格式：uin=o1234567890; qqmusic_key=xxx; skey=xxx; p_skey=xxx; ...
  static const String _qqCookiePrefsKey = 'qq_cookie';
  static String _qqCookie = '';

  /// 当前酷狗登录态 cookie 串（整串，含 mid）
  static String get kugouCookie => _kugouCookie;

  /// 当前 QQ 登录态 cookie 串（整串，含 uin/qqmusic_key/p_skey）
  static String get qqCookie => _qqCookie;

  /// 启动时从本地读取持久化的登录 cookie（登录态不丢失）
  static Future<void> loadCookies() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cookiePrefsKey) ?? '';
    if (raw.isNotEmpty) {
      for (final seg in raw.split(';')) {
        final eq = seg.indexOf('=');
        if (eq <= 0) continue;
        final name = seg.substring(0, eq).trim();
        final value = seg.substring(eq + 1).trim();
        if (name.isNotEmpty && value.isNotEmpty) _cookies[name] = value;
      }
    }
    _kugouCookie = prefs.getString(_kugouCookiePrefsKey) ?? '';
    _qqCookie = prefs.getString(_qqCookiePrefsKey) ?? '';
    _sodaCookie = prefs.getString(_sodaCookiePrefsKey) ?? '';
  }

  /// 保存酷狗登录态 cookie（扫码成功时调用，整串保存）
  static Future<void> setKugouCookie(String cookie) async {
    _kugouCookie = cookie;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kugouCookiePrefsKey, cookie);
  }

  /// 清除酷狗登录态（酷狗退出登录时调用，不影响网易云）
  static Future<void> clearKugouCookie() async {
    _kugouCookie = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kugouCookiePrefsKey);
  }

  /// 保存 QQ 登录态 cookie（扫码成功时调用，整串保存）
  static Future<void> setQQCookie(String cookie) async {
    _qqCookie = cookie;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_qqCookiePrefsKey, cookie);
  }

  /// 清除 QQ 登录态（QQ 退出登录时调用，不影响网易云/酷狗）
  static Future<void> clearQQCookie() async {
    _qqCookie = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_qqCookiePrefsKey);
  }

  // ---- 汽水音乐 Cookie 管理（四音源完全独立，整串保存整串回传） ----
  static const String _sodaCookiePrefsKey = 'soda_cookie';
  static String _sodaCookie = '';

  /// 当前汽水登录态 cookie 串
  static String get sodaCookie => _sodaCookie;

  /// 保存汽水登录态 cookie（扫码成功时调用，整串保存）
  static Future<void> setSodaCookie(String cookie) async {
    _sodaCookie = cookie;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sodaCookiePrefsKey, cookie);
  }

  /// 清除汽水登录态（汽水退出登录时调用，不影响其他音源）
  static Future<void> clearSodaCookie() async {
    _sodaCookie = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sodaCookiePrefsKey);
  }

  /// 把当前 cookie 持久化到本地（登录成功后 / 收到 Set-Cookie 后调用）
  static Future<void> _persistCookies() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cookiePrefsKey, _cookieHeader());
  }

  static String _cookieHeader() {
    if (_cookies.isEmpty) return '';
    return _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 从响应头中提取 Set-Cookie 并存储
  static void _saveCookies(Map<String, String> headers) {
    // http 包将多个 Set-Cookie 合并为一个字符串（用 ", " 分隔）
    final raw = headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;

    // 将 cookie 分隔符（", " 后跟 cookie 名=）统一替换为 "; "
    final unified = raw.replaceAllMapped(
      RegExp(r',\s+(?=[A-Za-z0-9_-]+=)'),
      (_) => '; ',
    );

    for (final seg in unified.split(';')) {
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      final lower = name.toLowerCase();
      // 跳过 cookie 属性
      if (lower == 'path' ||
          lower == 'domain' ||
          lower == 'expires' ||
          lower == 'max-age' ||
          lower == 'httponly' ||
          lower == 'secure' ||
          lower == 'samesite') {
        continue;
      }
      _cookies[name] = value;
    }
    // 收到新 cookie 后持久化到本地（登录态重启不丢失）
    // ignore: unawaited_futures
    _persistCookies();
  }

  /// 保存网易云登录态 cookie（扫码成功时调用，整串保存整串回传）
  /// 覆盖式写入：先 clear 再写入，避免新旧账号 cookie 混合
  static Future<void> setNeteaseCookie(String cookie) async {
    _cookies.clear();
    for (final seg in cookie.split(';')) {
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) _cookies[name] = value;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cookiePrefsKey, _cookieHeader());
  }

  /// 清除所有存储的 cookie（退出登录时调用），并清除本地持久化
  static Future<void> clearCookies() async {
    _cookies.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cookiePrefsKey);
  }

  static Uri _uri(String path, [Map<String, String>? query]) {
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  static Future<Map<String, dynamic>> _getJson(
    String path, [
    Map<String, String>? query,
  ]) async {
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      // Cookie 按音源分发：/kugou/* 用酷狗登录态、/qq/* 用 QQ 登录态，其余用网易云
      if (path.startsWith('/kugou/')) {
        // 酷狗 cookie 整串回传；未登录时也带占位对，让后端走"客户端模式"
        // 不污染服务端全局 kugou-cookie.json
        headers['Cookie'] = _kugouCookie.isNotEmpty ? _kugouCookie : 'kg_app=1';
      } else if (path.startsWith('/qq/')) {
        // QQ cookie 整串回传；为空时不带（后端按匿名处理）
        if (_qqCookie.isNotEmpty) headers['Cookie'] = _qqCookie;
      } else if (path.startsWith('/soda/')) {
        // 汽水 cookie 整串回传；为空时不带（后端按匿名处理）
        if (_sodaCookie.isNotEmpty) headers['Cookie'] = _sodaCookie;
      } else {
        final cookie = _cookieHeader();
        if (cookie.isNotEmpty) headers['Cookie'] = cookie;
      }

      final resp = await _client
          .get(_uri(path, query), headers: headers)
          .timeout(const Duration(seconds: 15));

      // 网易云请求才处理 Set-Cookie（酷狗/QQ/汽水登录态走响应体，不走 Set-Cookie）
      if (!path.startsWith('/kugou/') &&
          !path.startsWith('/qq/') &&
          !path.startsWith('/soda/')) {
        _saveCookies(resp.headers);
      }

      // 未登录约定：酷狗 HTTP 301、QQ HTTP 401
      if (resp.statusCode == 301 || resp.statusCode == 401) {
        throw const NotLoggedInException();
      }
      if (resp.statusCode != 200) {
        // 透传后端业务错误消息（如酷狗 502 "该歌曲无可用播放地址（可能为 VIP 或无版权）"）
        String msg = 'HTTP ${resp.statusCode}: $path';
        try {
          final body =
              jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
          final serverMsg = body['message']?.toString();
          if (serverMsg != null && serverMsg.isNotEmpty) msg = serverMsg;
        } catch (_) {}
        throw ApiException(msg);
      }
      final json =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      if (json['code'] == 301 || json['code'] == 401) {
        // QQ 需登录接口未登录返回 {code:401, message:'QQ 未登录'}
        throw const NotLoggedInException();
      }
      return json;
    } on ApiException {
      rethrow;
    } on NotLoggedInException {
      rethrow;
    } catch (e) {
      throw ApiException('网络请求失败（$path）：$e');
    }
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  /// 搜索歌曲（支持分页：首次 limit=50，后续 offset 累加）
  static Future<List<Song>> search(
    String keywords, {
    int limit = AppConfig.kSearchPageLimit,
    int offset = 0,
  }) async {
    final q = <String, String>{'keywords': keywords, 'limit': limit.toString()};
    if (offset > 0) q['offset'] = offset.toString();
    final data = await _getJson('/search', q);
    final songs = (data['songs'] as List?) ?? const [];
    return songs.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 每日推荐（未登录可能为空或报错，调用方需 try/catch 兜底）
  static Future<List<Song>> recommend() async {
    final data = await _getJson('/recommend');
    final songs = (data['songs'] as List?) ?? const [];
    return songs.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 私人雷达歌单（需登录；未登录/失败时抛 ApiException，调用方隐藏分区）
  /// 返回歌曲列表 + 歌单 id/名称（详情页跳转用）
  static Future<({List<Song> songs, String playlistId, String playlistName})>
  radar() async {
    final data = await _getJson('/radar');
    if (data['loggedIn'] == false || data['code'] != 200) {
      throw ApiException(data['message']?.toString() ?? '雷达歌单不可用（需登录）');
    }
    final songs = ((data['songs'] as List?) ?? const [])
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
    if (songs.isEmpty) throw ApiException('雷达歌单为空');
    return (
      songs: songs,
      playlistId: data['playlistId']?.toString() ?? '',
      playlistName: data['playlistName']?.toString() ?? '私人雷达',
    );
  }

  /// 热门歌单（每日推荐兜底，仅返回曲目）
  static Future<List<Song>> playlist([
    String id = AppConfig.kHotPlaylistId,
  ]) async {
    final data = await _getJson('/playlist', {'id': id});
    final tracks = (data['tracks'] as List?) ?? const [];
    return tracks.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 歌单/榜单详情（含元数据：名称、封面、简介 + 曲目列表）
  static Future<
    ({String name, String cover, String description, List<Song> tracks})
  >
  playlistDetail(String id) async {
    final data = await _getJson('/playlist', {'id': id});
    final p = data['playlist'];
    String name = '', cover = '', description = '';
    if (p is Map) {
      name = p['name']?.toString().trim() ?? '';
      // 服务端封面字段为 cover，兜底兼容 coverImgUrl / picUrl
      cover = (p['cover']?.toString().trim().isNotEmpty == true)
          ? p['cover'].toString().trim()
          : (p['coverImgUrl']?.toString().trim().isNotEmpty == true)
          ? p['coverImgUrl'].toString().trim()
          : (p['picUrl']?.toString().trim() ?? '');
      description = p['description']?.toString().trim() ?? '';
    }
    final tracks = (data['tracks'] as List?) ?? const [];
    final songs = tracks
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
    return (name: name, cover: cover, description: description, tracks: songs);
  }

  /// 歌曲详情（主要用来拿封面）
  static Future<List<Song>> songDetail(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final data = await _getJson('/song/detail', {'ids': ids.join(',')});
    final songs = (data['songs'] as List?) ?? const [];
    return songs.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 获取可直接交给播放器的流地址（走 /stream 代理，防防盗链无声）
  ///
  /// 取流信息：真实直连地址 + 实际音质/来源（用于播放页显示真实音质）
  static Future<({String url, int? br, String source, bool unblocked})>
  songStreamInfo(int id, {int br = 320000}) async {
    final data = await _getJson('/song/url', {
      'id': id.toString(),
      'br': br.toString(),
    });
    final inner = data['data'];
    final url = inner is Map ? inner['url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw ApiException('未获取到播放地址（id=$id）');
    }
    return (
      url: url,
      br: inner['br'] is int
          ? inner['br'] as int
          : int.tryParse(inner['br']?.toString() ?? ''),
      source: inner['source']?.toString() ?? '',
      unblocked: inner['unblocked'] == true,
    );
  }

  /// 获取网易云真实 CDN 直连地址（不占服务器带宽）。
  /// 返回 /song/url 返回的真实地址，如 `https://m801.music.126.net/...flac`；
  /// 直连播放失败时由调用方用 [proxyUrlOf] 回退到服务器代理。
  static Future<String> songStreamUrl(int id, {int br = 320000}) async {
    final info = await songStreamInfo(id, br: br);
    return info.url;
  }

  /// 把真实 CDN 地址包成服务器代理地址 `{base}/stream?url=...`（防盗链兜底）
  static String proxyUrlOf(String realUrl) {
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/stream?url=${Uri.encodeComponent(realUrl)}';
  }

  // ---------------- B站音源 ----------------

  /// B站搜索：GET /search/bili?keywords=&limit=20
  /// 返回 { result: { songs: [...], count }, source:'bilibili' }
  /// B站歌的 duration 单位是秒，Song.fromJson 内自动 ×1000 转毫秒
  static Future<List<Song>> searchBili(
    String keywords, {
    int limit = 20,
  }) async {
    final data = await _getJson('/search/bili', {
      'keywords': keywords,
      'limit': limit.toString(),
    });
    final result = data['result'];
    final songs = result is Map ? (result['songs'] as List?) : const [];
    return songs!.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// B站取流：GET /song/url/bili?bvid=xxx
  /// 后端返回 { data: { id, url(转发回退), directUrl(B站CDN直链), headers(直连必需), source } }
  /// directUrl 有时效（约10分钟），每次播放前实时请求；headers 含 Referer/UA/游客Cookie
  static Future<({String url, String directUrl, Map<String, String> headers})>
  biliStreamUrl(String bvid) async {
    final data = await _getJson('/song/url/bili', {'bvid': bvid});
    final inner = data['data'];
    if (inner is! Map) {
      throw ApiException('未获取到B站播放地址（bvid=$bvid）');
    }
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    String abs(String? u) {
      if (u == null || u.isEmpty) return '';
      if (u.startsWith('http')) return u;
      return '$base$u';
    }

    final headers = <String, String>{};
    final h = inner['headers'];
    if (h is Map) {
      h.forEach((k, v) {
        final vs = v?.toString() ?? '';
        if (vs.isNotEmpty) headers[k.toString()] = vs;
      });
    }
    return (
      url: abs(inner['url']?.toString()),
      directUrl: abs(inner['directUrl']?.toString()),
      headers: headers,
    );
  }

  // ---------------- 酷狗音源 ----------------
  // 登录态机制与网易云一致：客户端保存 cookie 串，请求放 Cookie 头带回。
  // 需登录接口未登录时后端返回 HTTP 301 + {code:301}，这里抛 NotLoggedInException。

  /// 酷狗扫码登录：获取二维码
  /// 返回 {key, qrimg(base64 data URL), url}
  static Future<({String key, String qrimg})> kugouLoginQr() async {
    final data = await _getJson('/kugou/login/qr');
    return (
      key: data['key']?.toString() ?? '',
      qrimg: data['qrimg']?.toString() ?? '',
    );
  }

  /// 酷狗扫码轮询：status 0=过期 1=待扫码 2=已扫码待确认 4=登录成功
  /// 登录成功时把返回的完整 cookie 串（含 mid）整串保存到本地。
  static Future<int> kugouLoginCheck(String key) async {
    final data = await _getJson('/kugou/login/qr/check', {'key': key});
    final status = _asInt(data['status']);
    if (status == 4) {
      final cookie = data['cookie']?.toString() ?? '';
      if (cookie.isNotEmpty) {
        // 整串保存（token/userid/vip_token/vip_type/mid），缺一后端识别不了设备
        await setKugouCookie(cookie);
      }
    }
    return status;
  }

  /// 酷狗登录状态（用客户端保存的 cookie 判断）
  static Future<({bool loggedIn, String userid})> kugouStatus() async {
    final data = await _getJson('/kugou/status');
    final u = data['user'];
    return (
      loggedIn: data['loggedIn'] == true,
      userid: u is Map ? (u['id']?.toString() ?? '') : '',
    );
  }

  /// 酷狗每日推荐（需登录，30 首）
  static Future<List<Song>> kugouRecommendDaily() async {
    final data = await _getJson('/kugou/recommend/daily');
    final songs = (data['songs'] as List?) ?? const [];
    return songs.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 酷狗猜你喜欢/私人FM（需登录，每次 5 首流式推荐）
  static Future<List<Song>> kugouRecommendFm() async {
    final data = await _getJson('/kugou/recommend/fm');
    final songs = (data['songs'] as List?) ?? const [];
    return songs.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 酷狗我的歌单（需登录，含封面）
  static Future<List<Playlist>> kugouUserPlaylist() async {
    final data = await _getJson('/kugou/user/playlist');
    final list = (data['playlists'] as List?) ?? const [];
    return list.map((e) {
      // 后端歌单不带 source 字段，这里注入 'kugou' 区分音源
      final m = Map<String, dynamic>.from(e as Map);
      m['source'] = 'kugou';
      return Playlist.fromJson(m);
    }).toList();
  }

  /// 酷狗歌单详情（需登录，后端自动分页拉全量）
  static Future<
    ({String name, String cover, String description, List<Song> tracks})
  >
  kugouPlaylistDetail(String id) async {
    final data = await _getJson('/kugou/playlist/detail', {'id': id});
    final p = data['playlist'];
    String name = '', cover = '', description = '';
    if (p is Map) {
      name = p['name']?.toString().trim() ?? '';
      cover = p['cover']?.toString().trim() ?? '';
      description = p['description']?.toString().trim() ?? '';
    }
    final tracks = (data['tracks'] as List?) ?? const [];
    final songs = tracks
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
    return (name: name, cover: cover, description: description, tracks: songs);
  }

  /// 酷狗取流：/kugou/song/url?hash=（免费 128k，播放地址 2-4 小时时效）
  static Future<({String url, int? br, String type})> kugouSongUrl(
    String hash,
  ) async {
    final data = await _getJson('/kugou/song/url', {'hash': hash});
    final inner = data['data'];
    final url = inner is Map ? inner['url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw ApiException('未获取到酷狗播放地址（hash=$hash）');
    }
    return (
      url: url,
      br: inner['br'] is int
          ? inner['br'] as int
          : int.tryParse(inner['br']?.toString() ?? ''),
      type: inner['type']?.toString() ?? 'mp3',
    );
  }

  /// 酷狗退出登录：清客户端本地 cookie（服务端登录态归客户端所有，无需清理）
  static Future<void> kugouLogout() async {
    try {
      await _getJson('/kugou/logout');
    } catch (_) {
      // 服务端失败也照常清本地
    }
    await clearKugouCookie();
  }

  // ---------------- QQ 音源 ----------------
  // 登录态机制与网易云/酷狗一致：客户端保存 cookie 串，请求放 Cookie 头带回。
  // 需登录接口未登录时后端返回 HTTP 401 + {code:401}，这里抛 NotLoggedInException。
  // 后端播放兜底：QQ 直链拿不到（VIP/无版权）自动走网易云解锁链 → B站兜底，
  // 返回的 source 标识实际音源，前端无感知换源。

  /// QQ 扫码登录：获取二维码
  /// 返回 {img(base64 data URL), qrsig, ptqrtoken}
  static Future<({String img, String qrsig, int ptqrtoken})> qqLoginQr() async {
    final data = await _getJson('/qq/login/qr');
    return (
      img: data['img']?.toString() ?? '',
      qrsig: data['qrsig']?.toString() ?? '',
      ptqrtoken: _asInt(data['ptqrtoken']),
    );
  }

  /// QQ 扫码轮询：status 0=过期 1=待扫码 2=已扫码待确认 4=登录成功
  /// 登录成功时把返回的完整 cookie 串（含 uin/qqmusic_key/p_skey）整串保存。
  static Future<int> qqLoginCheck(String qrsig, int ptqrtoken) async {
    final data = await _getJson('/qq/login/qr/check', {
      'key': qrsig,
      'ptqrtoken': ptqrtoken.toString(),
    });
    final status = _asInt(data['status']);
    if (status == 4) {
      final cookie = data['cookie']?.toString() ?? '';
      if (cookie.isNotEmpty) {
        // 整串保存，缺一后端识别不了登录态
        await setQQCookie(cookie);
      }
    }
    return status;
  }

  /// QQ 登录状态（用客户端保存的 cookie 判断）
  static Future<({bool loggedIn, String userid})> qqStatus() async {
    final data = await _getJson('/qq/status');
    final u = data['user'];
    return (
      loggedIn: data['loggedIn'] == true,
      userid: u is Map ? (u['id']?.toString() ?? '') : '',
    );
  }

  /// QQ 每日推荐（需登录，30 首；未登录返回空列表）
  static Future<List<Song>> qqRecommendDaily() async {
    final data = await _getJson('/qq/recommend/daily');
    final songs = (data['songs'] as List?) ?? const [];
    return songs.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// QQ 我的歌单（需登录，含封面）
  static Future<List<Playlist>> qqUserPlaylist() async {
    final data = await _getJson('/qq/user/playlist');
    final list = (data['playlists'] as List?) ?? const [];
    return list.map((e) {
      // 后端歌单不带 source 字段，这里注入 'qq' 区分音源
      final m = Map<String, dynamic>.from(e as Map);
      m['source'] = 'qq';
      return Playlist.fromJson(m);
    }).toList();
  }

  /// QQ 歌单详情（公开歌单匿名可用；元数据在响应根级，曲目在 songs）
  static Future<
    ({String name, String cover, String description, List<Song> tracks})
  >
  qqPlaylistDetail(String id) async {
    final data = await _getJson('/qq/playlist/detail', {'id': id});
    final tracks = (data['songs'] as List?) ?? const [];
    final songs = tracks
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
    return (
      name: data['name']?.toString().trim() ?? '',
      cover: data['cover']?.toString().trim() ?? '',
      description: '',
      tracks: songs,
    );
  }

  /// QQ 取流：/qq/song/url?mid=&name=&artist=&duration=
  /// 必须传 name/artist/duration（后端靠它做 VIP 歌兜底匹配）。
  /// 返回 url + 实际音源 source（qq / bilibili / 解锁源），前端无感知换源。
  static Future<({String url, int? br, String source, bool unblocked})>
  qqSongUrl({
    required String mid,
    required String name,
    required String artist,
    int duration = 0,
    int br = 128,
  }) async {
    final data = await _getJson('/qq/song/url', {
      'mid': mid,
      'name': name,
      'artist': artist,
      'duration': duration.toString(),
      'br': br.toString(),
    });
    final inner = data['data'];
    final url = inner is Map ? inner['url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw ApiException('未获取到 QQ 播放地址（mid=$mid）');
    }
    return (
      url: url,
      br: inner['br'] is int
          ? inner['br'] as int
          : int.tryParse(inner['br']?.toString() ?? ''),
      source: inner['source']?.toString() ?? 'qq',
      unblocked: inner['unblocked'] == true,
    );
  }

  /// QQ 收藏/取消收藏到「我喜欢」（dirId=201）
  /// songId：后端返回的数字歌曲 id（Song.songId）；like=true 收藏，false 取消。
  /// 未登录时后端返回 401 → NotLoggedInException。
  static Future<void> qqLikeSong(int songId, bool like) async {
    await _getJson('/qq/like', {
      'songid': '$songId',
      'act': like ? 'add' : 'del',
    });
  }

  /// QQ「我喜欢」已收藏 songId 集合（需登录；未登录抛 NotLoggedInException）
  static Future<Set<int>> qqLikedIds() async {
    final data = await _getJson('/qq/like/playlist');
    final songs = (data['songs'] as List?) ?? const [];
    return songs
        .map((e) => (e is Map) ? ((e['songId'] as num?)?.toInt() ?? 0) : 0)
        .where((id) => id > 0)
        .toSet();
  }

  /// QQ「我喜欢」收藏歌单完整数据（需登录；未登录抛 NotLoggedInException）
  /// 返回元数据 + 歌曲列表（cover 为歌单封面，songs 每首含 songId）
  static Future<({String name, String cover, int total, List<Song> songs})>
  qqLikePlaylist() async {
    final data = await _getJson('/qq/like/playlist');
    final songs = (data['songs'] as List?) ?? const [];
    return (
      name: data['name']?.toString() ?? 'QQ 我喜欢',
      cover: data['cover']?.toString() ?? '',
      total: (data['total'] as num?)?.toInt() ?? songs.length,
      songs: songs
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// QQ 退出登录：清客户端本地 cookie（不影响网易云/酷狗）
  static Future<void> qqLogout() async {
    try {
      await _getJson('/qq/logout');
    } catch (_) {
      // 服务端失败也照常清本地
    }
    await clearQQCookie();
  }

  // ---------------- 汽水音乐（soda） ----------------
  // 登录态机制与 QQ/酷狗一致：客户端保存 cookie 串，请求放 Cookie 头带回。
  // /soda/status 未登录返回 loggedIn:false（不抛异常）；
  // user/playlist 需登录，调用点仅在已登录时触发。

  /// 汽水扫码登录：获取二维码
  /// 返回 { key, qrImage, qrUrl, expires_in }。
  /// qrImage 为真正的二维码图片（data:image/png;base64,...），优先用于展示；
  /// qrUrl 是扫码内容网页链接（https://bff-pc.qishui.com/...），仅作备用字段。
  static Future<({String key, String qrImage, String qrUrl, int expiresIn})>
  sodaLoginQr() async {
    final data = await _getJson('/soda/login/qr');
    return (
      key: data['key']?.toString() ?? '',
      qrImage: data['qr_image']?.toString() ?? '',
      qrUrl: data['qr_url']?.toString() ?? '',
      expiresIn: _asInt(data['expires_in']),
    );
  }

  /// 汽水扫码轮询：status 0=过期/失败 1=等待扫码 2=已扫码待确认 4=登录成功
  /// 登录成功时后端返回完整 cookie 串，整串保存。
  static Future<
    ({int status, String message, bool needSms, String cookie, String userid})
  >
  sodaLoginQrCheck(String key) async {
    final data = await _getJson('/soda/login/qr/check', {'key': key});
    final cookie = data['cookie']?.toString() ?? '';
    if (_asInt(data['status']) == 4 && cookie.isNotEmpty) {
      await setSodaCookie(cookie);
    }
    return (
      status: _asInt(data['status']),
      message: data['message']?.toString() ?? '',
      needSms: data['need_sms'] == true,
      cookie: cookie,
      userid: data['userid']?.toString() ?? '',
    );
  }

  /// 汽水登录状态（用客户端保存的 cookie 判断）
  static Future<({bool loggedIn, AppUser? user})> sodaStatus() async {
    final data = await _getJson('/soda/status');
    final loggedIn = data['loggedIn'] == true;
    final u = data['user'];
    AppUser? user;
    if (loggedIn && u is Map)
      user = AppUser.fromJson(u as Map<String, dynamic>);
    return (loggedIn: loggedIn, user: user);
  }

  /// 汽水一键导入 PC 登录态：/soda/login/local（读电脑客户端 sessionid）
  /// 成功返回 { loggedIn:true, user:{id,nickname,avatar}, cookie }；
  /// 失败抛 ApiException（message 为后端中文提示）。
  /// 后端返回完整 cookie，必须整串存本地，否则 AuthState.refresh 会因
  /// sodaCookie 为空判定未登录，导致导入成功但歌单不显示。
  static Future<({bool loggedIn, AppUser? user})> sodaLoginLocal() async {
    final data = await _getJson('/soda/login/local');
    // 后端返回完整 cookie，必须存本地（与扫码登录的 cookie 等价）
    final cookie = data['cookie']?.toString() ?? '';
    if (cookie.isNotEmpty) await setSodaCookie(cookie);
    final loggedIn = data['loggedIn'] == true;
    final u = data['user'];
    AppUser? user;
    if (loggedIn && u is Map)
      user = AppUser.fromJson(u as Map<String, dynamic>);
    if (!loggedIn) {
      throw ApiException(data['message']?.toString() ?? '一键导入失败');
    }
    return (loggedIn: loggedIn, user: user);
  }

  /// 汽水退出登录：清客户端本地 cookie（不影响其他音源）
  static Future<void> sodaLogout() async {
    try {
      await _getJson('/soda/logout');
    } catch (_) {
      // 服务端失败也照常清本地
    }
    await clearSodaCookie();
  }

  /// 汽水我的歌单（需登录）。返回歌单列表并注入 source='soda' 区分音源。
  static Future<List<Playlist>> sodaUserPlaylists({
    int page = 1,
    int limit = 30,
  }) async {
    final data = await _getJson('/soda/user/playlist', {
      'page': '$page',
      'limit': '$limit',
    });
    final list = (data['playlists'] as List?) ?? const [];
    return list.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      m['source'] = 'soda';
      return Playlist.fromJson(m);
    }).toList();
  }

  /// 汽水歌单详情（匿名可用）。歌曲注入 source='soda'。
  static Future<
    ({
      String name,
      String cover,
      String description,
      String creator,
      List<Song> tracks,
    })
  >
  sodaPlaylistDetail(String id) async {
    final data = await _getJson('/soda/playlist/detail', {'id': id});
    final tracks = (data['songs'] as List?) ?? const [];
    final songs = tracks.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      if (m['source'] == null) m['source'] = 'soda';
      return Song.fromJson(m);
    }).toList();
    String creator = '';
    final c = data['creator'];
    if (c is Map) {
      creator =
          c['nickname']?.toString().trim() ??
          c['name']?.toString().trim() ??
          '';
    } else if (c is String) {
      creator = c.trim();
    }
    return (
      name: data['name']?.toString().trim() ?? '',
      cover: data['cover']?.toString().trim() ?? '',
      description: data['desc']?.toString().trim() ?? '',
      creator: creator,
      tracks: songs,
    );
  }

  /// 汽水取流：/soda/song/url?id=&name=&artist=&duration=
  /// 必须带 name/artist/duration（后端靠它做 VIP 歌换源匹配，链路与 QQ 一致）。
  /// 字段平级解析（后端返回 {code, url, source, br, unblocked, matched}，不在 data 里）。
  /// 返回 url + 实际音源 source（soda/netease/bilibili/解锁源），前端无感知换源。
  static Future<({String url, int? br, String source, bool unblocked})>
  sodaSongUrl({
    required String id,
    required String name,
    required String artist,
    int duration = 0,
  }) async {
    final data = await _getJson('/soda/song/url', {
      'id': id,
      'name': name,
      'artist': artist,
      'duration': duration.toString(),
    });
    final url = data['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw ApiException('未获取到汽水播放地址（id=$id）');
    }
    return (
      url: url,
      br: data['br'] is int
          ? data['br'] as int
          : int.tryParse(data['br']?.toString() ?? ''),
      source: data['source']?.toString() ?? 'soda',
      unblocked: data['unblocked'] == true,
    );
  }

  /// 汽水歌词：/soda/lyric?id=xxx
  /// 返回结构 { code, lyric } —— lyric 是标准 LRC 字符串（字段名是 lyric，不是 lrc）。
  /// 汽水歌词无翻译，translation 返回空列表。
  static Future<({List<LyricLine> main, List<LyricLine> translation})>
  sodaLyric(String id) async {
    final data = await _getJson('/soda/lyric', {'id': id});
    final main = LrcParser.parse(data['lyric']?.toString());
    return (main: main, translation: const <LyricLine>[]);
  }

  /// 歌词：返回原文与翻译两个行列表
  static Future<({List<LyricLine> main, List<LyricLine> translation})> lyric(
    int id,
  ) async {
    final data = await _getJson('/lyric', {'id': id.toString()});
    final main = LrcParser.parse(data['lrc']?.toString());
    final translation = LrcParser.parse(data['tlyric']?.toString());
    return (main: main, translation: translation);
  }

  /// 歌词多源兜底：按歌名+歌手(+时长)匹配（网易云→酷狗），酷狗/B站歌用
  static Future<({List<LyricLine> main, List<LyricLine> translation})> lyricAny(
    String name,
    String artist, {
    int duration = 0,
  }) async {
    final data = await _getJson('/lyric/any', {
      'name': name,
      'artist': artist,
      'duration': duration.toString(),
    });
    final main = LrcParser.parse(data['lrc']?.toString());
    final translation = LrcParser.parse(data['tlyric']?.toString());
    return (main: main, translation: translation);
  }

  // ---------------- 登录 ----------------

  /// 获取登录二维码：返回 unikey + qrimg（data:image/png;base64,...）
  static Future<({String unikey, String qrimg})> loginQr() async {
    final data = await _getJson('/login/qr');
    return (
      unikey: data['unikey']?.toString() ?? '',
      qrimg: data['qrimg']?.toString() ?? '',
    );
  }

  /// 轮询登录状态：801=等待扫码、802=已扫码待确认、803=登录成功、800=过期
  /// 登录成功（803）时后端返回 cookie 整串，由调用方通过 setNeteaseCookie 保存
  static Future<NeteaseQrCheckResult> loginQrCheck(String key) async {
    final data = await _getJson('/login/qr/check', {'key': key});
    final code = _asInt(data['code']);
    final cookie = data['cookie']?.toString() ?? '';
    return NeteaseQrCheckResult(code, cookie);
  }

  /// 当前登录状态 + 用户信息
  static Future<({bool loggedIn, AppUser? user})> status() async {
    final data = await _getJson('/status');
    final loggedIn = data['loggedIn'] == true;
    final u = data['user'];
    AppUser? user;
    if (u is Map) user = AppUser.fromJson(u as Map<String, dynamic>);
    return (loggedIn: loggedIn, user: user);
  }

  /// 退出登录（服务端可能无此接口，失败静默），并清除本地 cookie
  static Future<void> logout() async {
    try {
      await _getJson('/logout');
    } catch (_) {
      // 服务端可能无此接口，忽略
    }
    // 清除本地存储的 cookie（含持久化）
    await clearCookies();
  }

  // ---------------- 用户歌单 ----------------

  /// 导入登录用户的网易云歌单（服务端自动用登录 cookie）
  static Future<List<Playlist>> userPlaylists() async {
    final data = await _getJson('/user/playlist');
    final list = (data['playlists'] as List?) ?? const [];
    return list
        .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ---------------- 喜欢/同步 ----------------

  /// 喜欢/取消喜欢歌曲（同步到网易云"我喜欢的音乐"）
  /// like=true 为喜欢，false 为取消。
  /// 返回结构化结果而非 bool；网络/HTTP 异常不抛错，体现在 ok=false。
  static Future<LikeResult> like(int songId, bool like) async {
    try {
      final data = await _getJson('/like', {
        'id': songId.toString(),
        'like': like ? '1' : '0',
      });
      final ok = data['code'] == 200;
      return LikeResult(
        ok: ok,
        loggedIn: data['loggedIn'] == true,
        liked: data['liked'] == true,
      );
    } catch (_) {
      // 网络/HTTP 异常：ok=false、登录态未知（按未登录处理，UI 提示仅本地）
      return const LikeResult(ok: false, loggedIn: false, liked: false);
    }
  }

  /// 获取喜欢的歌曲 ID 列表
  /// 返回 { loggedIn, ids:[...] }；未登录时 ids 为空
  static Future<List<int>> likelist() async {
    final data = await _getJson('/likelist');
    if (data['loggedIn'] == false) return const [];
    final ids = (data['ids'] as List?) ?? const [];
    return ids.map((e) => _asInt(e)).toList();
  }
}
