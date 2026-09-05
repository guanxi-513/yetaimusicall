/// 音源服务 API 封装
///
/// 接口全部为 GET，返回 JSON：
/// - /search?keywords=&limit=&offset=         （网易云搜索）
/// - /search/bili?keywords=&limit=20         （B站搜索）
/// - /recommend
/// - /playlist?id=
/// - /song/detail?ids=
/// - /song/url?id=                            （网易云取流）
/// - /song/url/bili?bvid=xxx                  （B站取流）
/// - /stream?url=  /stream/bili?bvid=         （音频代理，播放必走这里）
/// - /lyric?id=
/// - /login/qr  /login/qr/check?key=  /status  /logout  /user/playlist
/// - /like  /likelist
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

class ApiService {
  ApiService._();

  static final http.Client _client = http.Client();

  // ---- Cookie 管理 ----
  // Dart http.Client 不会自动管理 Set-Cookie / Cookie header，
  // 需要手动存储服务端返回的 cookie 并在后续请求中回传。
  // cookie 会持久化到本地：登录态跟随本设备，多设备各用各的账号，互不覆盖。
  static final Map<String, String> _cookies = {};
  static const String _cookiePrefsKey = 'netease_cookie';

  /// 启动时从本地读取持久化的登录 cookie（登录态不丢失）
  static Future<void> loadCookies() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cookiePrefsKey) ?? '';
    if (raw.isEmpty) return;
    for (final seg in raw.split(';')) {
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) _cookies[name] = value;
    }
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
    final unified =
        raw.replaceAllMapped(RegExp(r',\s+(?=[A-Za-z0-9_-]+=)'), (_) => '; ');

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
      final cookie = _cookieHeader();
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;

      final resp = await _client
          .get(_uri(path, query), headers: headers)
          .timeout(const Duration(seconds: 15));

      // 存储 Set-Cookie 响应头中的 cookie
      _saveCookies(resp.headers);

      if (resp.statusCode != 200) {
        throw ApiException('HTTP ${resp.statusCode}: $path');
      }
      return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    } on ApiException {
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
    final q = <String, String>{
      'keywords': keywords,
      'limit': limit.toString(),
    };
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

  /// 热门歌单（每日推荐兜底，仅返回曲目）
  static Future<List<Song>> playlist(
      [String id = AppConfig.kHotPlaylistId]) async {
    final data = await _getJson('/playlist', {'id': id});
    final tracks = (data['tracks'] as List?) ?? const [];
    return tracks.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 歌单/榜单详情（含元数据：名称、封面、简介 + 曲目列表）
  static Future<({String name, String cover, String description, List<Song> tracks})>
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
    final songs = tracks.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
    return (name: name, cover: cover, description: description, tracks: songs);
  }

  /// 歌曲详情（主要用来拿封面）
  static Future<List<Song>> songDetail(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final data = await _getJson('/song/detail', {
      'ids': ids.join(','),
    });
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
  static Future<List<Song>> searchBili(String keywords, {int limit = 20}) async {
    final data = await _getJson('/search/bili', {
      'keywords': keywords,
      'limit': limit.toString(),
    });
    final result = data['result'];
    final songs = result is Map ? (result['songs'] as List?) : const [];
    return songs!
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// B站取流地址：GET /song/url/bili?bvid=xxx
  /// 返回 { data: { id: bvid, url: '/stream/bili?bvid=xxx', source:'bilibili' } }
  /// data.url 是相对路径，需拼接 apiBaseUrl 前缀
  static Future<String> biliStreamUrl(String bvid) async {
    final data = await _getJson('/song/url/bili', {'bvid': bvid});
    final inner = data['data'];
    final url = inner is Map ? inner['url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw ApiException('未获取到B站播放地址（bvid=$bvid）');
    }
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    // url 可能是相对路径 (/stream/bili?bvid=xxx) 或绝对路径
    if (url.startsWith('http')) return url;
    return '$base$url';
  }

  /// 歌词：返回原文与翻译两个行列表
  static Future<({List<LyricLine> main, List<LyricLine> translation})> lyric(
      int id) async {
    final data = await _getJson('/lyric', {'id': id.toString()});
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
  /// 登录成功（803）时，服务端会返回登录 cookie，这里存入本地（独立登录态）。
  static Future<int> loginQrCheck(String key) async {
    final data = await _getJson('/login/qr/check', {'key': key});
    final code = _asInt(data['code']);
    if (code == 803) {
      final cookie = data['cookie']?.toString();
      if (cookie != null && cookie.isNotEmpty) {
        _saveCookies({'set-cookie': cookie});
      }
    }
    return code;
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
    return list.map((e) => Playlist.fromJson(e as Map<String, dynamic>)).toList();
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
