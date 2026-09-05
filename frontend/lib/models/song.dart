/// 歌曲数据模型
import 'dart:convert';

class Song {
  final int id;
  final String name;
  final List<String> artists;
  final String album;
  final String cover;
  /// 时长（毫秒）
  final int duration;
  /// 音源：'netease'（网易云）| 'bilibili'（B站）
  final String source;
  /// B站视频 bvid（仅 source=='bilibili' 时有值；网易云歌为 null）
  final String? bvid;

  const Song({
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.cover,
    required this.duration,
    this.source = 'netease',
    this.bvid,
  });

  String get artistText => artists.isEmpty ? '未知歌手' : artists.join(' / ');

  /// 时长格式化 mm:ss
  String get durationText {
    final d = Duration(milliseconds: duration);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 判断是否 B站源
  bool get isBilibili => source == 'bilibili';

  /// B站歌的唯一标识（用于收藏/历史去重，网易云歌返回 null）
  String? get uniqueKey => isBilibili ? bvid : null;

  factory Song.fromJson(Map<String, dynamic> json) {
    final source = _asString(json['source']) ?? 'netease';
    final isBili = source == 'bilibili';
    final bvid = _asString(json['bvid']);

    // B站歌没有数字 id，用 bvid hashCode 生成稳定正整数作为主键
    final id = isBili
        ? (bvid != null && bvid.isNotEmpty ? bvid.hashCode & 0x7FFFFFFF : 0)
        : _asInt(json['id']);

    // B站返回 duration 单位是秒，统一转毫秒
    final rawDuration = _asInt(json['duration']);
    final duration = isBili ? rawDuration * 1000 : rawDuration;

    return Song(
      id: id,
      name: _asString(json['name']) ?? '未知歌曲',
      artists: _parseArtists(json['artists']),
      album: _parseAlbum(json['album']),
      cover: _asString(json['cover']) ?? '',
      duration: duration,
      source: source,
      bvid: bvid,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'artists': artists,
        'album': album,
        'cover': cover,
        'duration': duration,
        'source': source,
        'bvid': bvid,
      };

  factory Song.fromDb(Map<String, dynamic> row) {
    return Song(
      id: row['id'] as int,
      name: row['name'] as String? ?? '',
      artists: _parseDbArtists(row['artists']),
      album: row['album'] as String? ?? '',
      cover: row['cover'] as String? ?? '',
      duration: row['duration'] as int? ?? 0,
      source: row['source'] as String? ?? 'netease',
      bvid: row['bvid'] as String?,
    );
  }

  /// 数据库 artists 列容错解析：正常是 "|" 分隔字符串；兼容历史脏数据
  /// （sqflite 曾把 List 存成 BLOB / JSON 数组），任何类型都不抛异常。
  static List<String> _parseDbArtists(dynamic raw) {
    if (raw == null) return [];
    // 旧脏数据：List 被 sqflite 存成 BLOB（Uint8List），先还原成字符串
    if (raw is List<int>) {
      try {
        raw = String.fromCharCodes(raw);
      } catch (_) {
        return [];
      }
    }
    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return [];
      // 兼容 JSON 数组格式（如 "[\"a\",\"b\"]"）
      if (s.startsWith('[')) {
        try {
          final l = jsonDecode(s);
          if (l is List) {
            return l.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
          }
        } catch (_) {}
      }
      return s.split('|').where((e) => e.isNotEmpty).toList();
    }
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return [];
  }

  static List<String> _parseArtists(dynamic raw) {
    if (raw is List) {
      return raw.map((e) {
        if (e is Map) return _asString(e['name']) ?? '';
        return e.toString();
      }).where((e) => e.isNotEmpty).toList();
    }
    if (raw is String && raw.isNotEmpty) return [raw];
    return [];
  }

  static String _parseAlbum(dynamic raw) {
    if (raw is Map) return _asString(raw['name']) ?? '';
    if (raw is String) return raw;
    return '';
  }

  static String? _asString(dynamic v) => v?.toString();
  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

/// 歌词行
class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}
