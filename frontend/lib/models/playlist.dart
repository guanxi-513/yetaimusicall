/// 网易云歌单模型
library;

class Playlist {
  final int id;
  final String name;
  final String cover;
  final int trackCount;
  final int playCount;
  final String creator;

  const Playlist({
    required this.id,
    required this.name,
    required this.cover,
    required this.trackCount,
    required this.playCount,
    required this.creator,
  });

  /// 播放次数格式化（万 / 亿）
  String get playCountText {
    if (playCount <= 0) return '';
    if (playCount >= 100000000) {
      return '${(playCount / 100000000).toStringAsFixed(1)}亿';
    }
    if (playCount >= 10000) {
      return '${(playCount / 10000).toStringAsFixed(1)}万';
    }
    return '$playCount';
  }

  factory Playlist.fromJson(Map<String, dynamic> j) {
    final c = j['creator'];
    String creator = '';
    if (c is Map) {
      creator = c['nickname']?.toString().trim().isNotEmpty == true
          ? c['nickname'].toString().trim()
          : (c['name']?.toString().trim() ?? '');
    } else if (c is String) {
      creator = c.trim();
    }
    // 服务端歌单封面字段为 cover，兜底兼容 coverImgUrl / picUrl
    final cover = (j['cover']?.toString().trim().isNotEmpty == true)
        ? j['cover'].toString().trim()
        : (j['coverImgUrl']?.toString().trim().isNotEmpty == true)
            ? j['coverImgUrl'].toString().trim()
            : (j['picUrl']?.toString().trim() ?? '');
    return Playlist(
      id: _asInt(j['id']),
      name: j['name']?.toString().trim().isNotEmpty == true
          ? j['name'].toString().trim()
          : '未知歌单',
      cover: cover,
      trackCount: _asInt(j['trackCount']),
      playCount: _asInt(j['playCount']),
      creator: creator,
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
