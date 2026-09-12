/// 全局配置：API 基础地址等常量
///
/// - Android 模拟器访问宿主机服务：http://82.157.146.105:41831
/// - 真机 / 局域网访问：http://<电脑局域网IP>:41831
/// - 服务器部署：http://<服务器公网IP>:41831
/// 修改 [kApiBaseUrl] 后热重启即可生效；也可以在设置页运行时修改（见 SettingsDialog）。
/// 修改后的地址会通过 SharedPreferences 持久化，重启 App 不丢失。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 网易云图片 CDN 请求头
///
/// p1.music.126.net 等节点会拒绝 Dart 默认 UA（HttpClient "Dart/x.x" → 403），
/// 加载网易云图片（封面/头像）时必须带上浏览器 UA。
const Map<String, String> kImageHttpHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
};

class AppConfig {
  AppConfig._();

  /// 默认 API 基础地址（Android 模拟器 → 宿主机）
  static const String kDefaultApiBaseUrl = 'http://82.157.146.105:41831';

  /// SharedPreferences 中保存音源地址的 key
  static const String _kApiBaseUrlKey = 'api_base_url';

  /// SharedPreferences 中保存音质的 key
  static const String _kAudioQualityKey = 'audio_quality';

  /// 运行时可变的基础地址（设置页可改）
  static String apiBaseUrl = kDefaultApiBaseUrl;

  /// 播放音质：standard=标准(128k) / high=高品(320k) / lossless=无损(FLAC)
  static String audioQuality = 'high';

  /// 当前音质对应的码率 br 参数（传给 /song/url）
  static int get audioBitrate {
    switch (audioQuality) {
      case 'standard':
        return 128000;
      case 'lossless':
        return 999000;
      case 'high':
      default:
        return 320000;
    }
  }

  /// 启动时加载已保存的音源地址与音质（在 main() 里 runApp 前调用一次）
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kApiBaseUrlKey);
      if (saved != null && saved.trim().isNotEmpty) {
        apiBaseUrl = saved.trim();
      }
      final q = prefs.getString(_kAudioQualityKey);
      if (q != null && q.isNotEmpty) {
        audioQuality = q;
      }
    } catch (_) {
      // 读取失败保持默认，不影响启动
    }
  }

  /// 修改音源地址并持久化（设置页保存时调用）
  static Future<void> saveApiBaseUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) return;
    apiBaseUrl = u;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kApiBaseUrlKey, u);
    } catch (_) {
      // 保存失败不影响本次运行
    }
  }

  /// 修改音质并持久化（设置页选择时调用）
  static Future<void> saveAudioQuality(String q) async {
    audioQuality = q;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAudioQualityKey, q);
    } catch (_) {
      // 保存失败不影响本次运行
    }
  }

  /// 热歌榜歌单 ID（每日推荐兜底）
  static const String kHotPlaylistId = '3778678';

  /// 搜索默认返回条数（历史遗留，保留兼容）
  static const int kSearchLimit = 20;

  /// 搜索分页单页条数（滚动加载更多用）
  static const int kSearchPageLimit = 50;

  /// 搜索历史最多保留条数
  static const int kMaxSearchHistory = 20;

  /// 固定榜单表（仿网易云排行榜）
  static const List<BoardChart> kCharts = [
    BoardChart(id: '3778678', name: '热歌榜', desc: '云音乐热歌榜'),
    BoardChart(id: '19723756', name: '飙升榜', desc: '云音乐飙升榜'),
    BoardChart(id: '3779629', name: '新歌榜', desc: '云音乐新歌榜'),
    BoardChart(id: '2884035', name: '原创榜', desc: '云音乐原创榜'),
    BoardChart(id: '991319582', name: '说唱榜', desc: '云音乐说唱榜'),
    BoardChart(id: '1978921795', name: '电音榜', desc: '云音乐电音榜'),
    BoardChart(id: '71385702', name: '抖音榜', desc: '抖音热歌排行榜'),
    BoardChart(id: '2250011882', name: '民谣榜', desc: '云音乐民谣榜'),
  ];
}

/// 榜单条目
class BoardChart {
  final String id;
  final String name;
  final String desc;
  const BoardChart({required this.id, required this.name, required this.desc});
}
