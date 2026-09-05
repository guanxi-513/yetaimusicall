/// 网易云登录用户信息
library;

class AppUser {
  final int id;
  final String nickname;
  final String avatar;

  const AppUser({
    required this.id,
    required this.nickname,
    required this.avatar,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) {
    return AppUser(
      id: _asInt(j['id']),
      nickname: j['nickname']?.toString().trim().isNotEmpty == true
          ? j['nickname'].toString().trim()
          : j['name']?.toString().trim().isNotEmpty == true
              ? j['name'].toString().trim()
              : '网易云音乐用户',
      avatar: j['avatar']?.toString().trim().isNotEmpty == true
          ? j['avatar'].toString().trim()
          : (j['avatarUrl']?.toString().trim() ?? ''),
    );
  }

  static int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
