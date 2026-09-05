/// 我的歌单页：网易云歌单（登录后）+ 本地收藏 + 播放历史
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/db_service.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../widgets/glass_card.dart';
import '../widgets/song_tile.dart';
import 'login_dialog.dart';
import 'playlist_detail_page.dart';

class PlaylistsPage extends StatefulWidget {
  /// 是否为当前可见 tab（IndexedStack 常驻，切回时强制刷新一次）
  final bool isActive;
  const PlaylistsPage({super.key, this.isActive = true});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage>
    with AutomaticKeepAliveClientMixin {
  int _tab = 0; // 0 收藏 1 历史
  List<Song> _favorites = const [];
  List<Song> _history = const [];

  List<Playlist> _cloudPlaylists = const [];
  bool _cloudLoading = false;
  String? _cloudError;
  bool? _lastLoggedIn;

  /// 上次见到的播放歌曲 ID（用于检测变化触发历史刷新）
  int? _lastSongId;

  /// 上次见到的收藏版本号（用于检测本地收藏增删触发收藏列表刷新）
  int? _lastFavVersion;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
    _maybeLoadCloud();
  }

  @override
  void didUpdateWidget(covariant PlaylistsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其他 tab 切回本页时强制刷新一次（IndexedStack 常驻不重建，
    // 避免 DB 已变而列表显示旧数据）
    if (!oldWidget.isActive && widget.isActive) {
      _reload();
      _maybeLoadCloud();
    }
  }

  Future<void> _reload() async {
    final favs = await DbService.favorites();
    final hist = await DbService.history(limit: 50);
    if (!mounted) return;
    setState(() {
      _favorites = favs;
      _history = hist;
    });
  }

  void _maybeLoadCloud() {
    final auth = context.read<AuthState>();
    final loggedIn = auth.loggedIn;
    if (_lastLoggedIn != loggedIn) {
      _lastLoggedIn = loggedIn;
      if (loggedIn) {
        _loadCloudPlaylists();
      } else {
        setState(() {
          _cloudPlaylists = const [];
          _cloudError = null;
        });
      }
    }
  }

  Future<void> _loadCloudPlaylists() async {
    setState(() {
      _cloudLoading = true;
      _cloudError = null;
    });
    try {
      final list = await ApiService.userPlaylists();
      if (!mounted) return;
      setState(() {
        _cloudPlaylists = list;
        _cloudLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cloudLoading = false;
        _cloudError = '歌单加载失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    context.watch<AuthState>();
    _maybeLoadCloud();
    final player = context.watch<PlayerState>();
    // 收藏状态变化触发重建（列表内爱心图标）
    player.favoriteIds;
    // 本地收藏增删 → 自动重载收藏列表
    final favVersion = player.favoritesVersion;
    if (_lastFavVersion != favVersion) {
      _lastFavVersion = favVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reload();
      });
    }
    // 播放新歌时自动刷新历史
    final currentId = player.current?.id;
    if (currentId != _lastSongId) {
      _lastSongId = currentId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reload();
      });
    }
    final songs = _tab == 0 ? _favorites : _history;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      children: [
        // 网易云歌单区
        _buildCloudSection(),
        const SizedBox(height: 16),
        // 收藏 / 历史 分段
        Row(
          children: [
            _seg('❤️ 我的收藏', 0, _favorites.length),
            const SizedBox(width: 10),
            _seg('🕘 播放历史', 1, _history.length),
          ],
        ),
        const SizedBox(height: 6),
        if (songs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _tab == 0 ? Icons.favorite_border : Icons.history,
                    color: Colors.white.withOpacity(0.28),
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _tab == 0
                        ? '还没有收藏歌曲\n点击列表右侧 ♥ 添加收藏'
                        : '暂无播放历史\n去听几首歌吧',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.35),
                      fontSize: 13,
                      height: 1.7,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...songs.map(
            (s) => SongTile(
              song: s,
              queue: songs,
              // 收藏 tab：红心 = 仅本地收藏；历史 tab：全局语义
              heartMode:
                  _tab == 0 ? HeartMode.local : HeartMode.global,
            ),
          ),
      ],
    );
  }

  // ---------- 网易云歌单区 ----------

  Widget _buildCloudSection() {
    final auth = context.read<AuthState>();
    if (auth.checking) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                color: Colors.white70, strokeWidth: 2),
          ),
        ),
      );
    }
    if (!auth.loggedIn) {
      return GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        borderRadius: 18,
        color: const Color(0xFF6C4FE0).withOpacity(0.14),
        child: Row(
          children: [
            Icon(Icons.cloud_download,
                color: Colors.white.withOpacity(0.7), size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '登录网易云音乐后可导入你的歌单',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => showDialog(
                context: context,
                builder: (_) => const LoginDialog(),
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.22),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.4)),
                ),
                child: const Text(
                  '去登录',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.library_music,
                color: Colors.white.withOpacity(0.75), size: 18),
            const SizedBox(width: 6),
            Text(
              '我的网易云歌单',
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            if (_cloudLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    color: Colors.white70, strokeWidth: 2),
              )
            else if (_cloudError != null)
              GestureDetector(
                onTap: _loadCloudPlaylists,
                child: Icon(Icons.refresh,
                    color: Colors.white.withOpacity(0.6), size: 18),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_cloudError != null)
          Text(
            _cloudError!,
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
          )
        else if (_cloudPlaylists.isEmpty && !_cloudLoading)
          Text(
            '暂无歌单',
            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
          )
        else
          SizedBox(
            height: 156,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _cloudPlaylists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) =>
                  _PlaylistCard(playlist: _cloudPlaylists[i]),
            ),
          ),
      ],
    );
  }

  Widget _seg(String label, int value, int count) {
    final selected = _tab == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _tab = value);
          _reload();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: selected
                ? LinearGradient(
                    colors: [
                      Colors.white.withOpacity(0.22),
                      Colors.white.withOpacity(0.08),
                    ],
                  )
                : null,
            color: selected ? null : Colors.white.withOpacity(0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? Colors.white.withOpacity(0.35)
                  : Colors.white.withOpacity(0.14),
            ),
          ),
          child: Center(
            child: Text(
              count > 0 ? '$label ($count)' : label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white.withOpacity(0.55),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 网易云歌单卡片：封面 + 名称 + 曲数
class _PlaylistCard extends StatelessWidget {
  final Playlist playlist;
  const _PlaylistCard({required this.playlist});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          PageRouteBuilder(
            opaque: false,
            transitionDuration: const Duration(milliseconds: 300),
            pageBuilder: (_, anim, __) => SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: PlaylistDetailPage(
                id: playlist.id.toString(),
                title: playlist.name,
                cover: playlist.cover,
              ),
            ),
          ),
        );
      },
      child: SizedBox(
        width: 110,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border:
                    Border.all(color: Colors.white.withOpacity(0.3), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: playlist.cover.isEmpty
                    ? Container(
                        color: Colors.white.withOpacity(0.10),
                        child: Icon(Icons.album,
                            color: Colors.white.withOpacity(0.6), size: 32),
                      )
                    : CachedNetworkImage(
                        imageUrl: playlist.cover,
                        fit: BoxFit.cover,
                        width: 110,
                        height: 110,
                        placeholder: (_, __) => Container(
                          width: 110,
                          height: 110,
                          color: Colors.white.withOpacity(0.10),
                          child: Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(
                                    Colors.white.withOpacity(0.5)),
                              ),
                            ),
                          ),
                        ),
                        errorWidget: (_, __, ___) => Container(
                          width: 110,
                          height: 110,
                          color: Colors.white.withOpacity(0.10),
                          child: Icon(Icons.album,
                              color: Colors.white.withOpacity(0.6), size: 32),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: Text(
                '${playlist.trackCount}首',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.45),
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
