/// 网易云歌单模型（source 字段区分音源：'netease' / 'kugou'）
library;

class Playlist {
  final int id;
  final String name;
  final String cover;
  final int trackCount;
  final int playCount;
  final String creator;
  /// 音源：'netease'（网易云）| 'kugou'（酷狗）| 'qq'（QQ音乐）
  final String source;

  /// 云端音源（酷狗/QQ）歌单原始字符串 id：
  /// 酷狗如 collection_3_2532143314_2_0；QQ 为 dissid（如 7256913312）。
  /// 云端歌单 id 无法可靠转 int（fromJson 里 _asInt 可能得 0），
  /// 跳转详情必须用它。网易云歌单此字段为 null。
  final String? kugouId;

  const Playlist({
    required this.id,
    required this.name,
    required this.cover,
    required this.trackCount,
    required this.playCount,
    required this.creator,
    this.source = 'netease',
    this.kugouId,
  });

  /// 详情跳转用 id：云端音源（酷狗/QQ）一律用原始字符串 kugouId，网易云用数字 id
  String get detailId =>
      source == 'netease' ? id.toString() : (kugouId ?? '');

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
      // QQ 后端歌单曲数字段叫 songCount，兜底兼容
      trackCount: _asInt(j['trackCount'] ?? j['songCount']),
      playCount: _asInt(j['playCount']),
      creator: creator,
      source: j['source']?.toString() ?? 'netease',
      kugouId: j['source'] != 'netease' ? j['id']?.toString() : null,
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
