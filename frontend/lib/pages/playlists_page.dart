/// 我的歌单页：网易云歌单（登录后）+ 本地收藏 + 播放历史
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
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

  // ---------- 酷狗歌单 ----------
  List<Playlist> _kgPlaylists = const [];
  bool _kgLoading = false;
  String? _kgError;
  bool? _lastKgLoggedIn;

  // ---------- QQ 歌单 ----------
  List<Playlist> _qqPlaylists = const [];
  bool _qqLoading = false;
  String? _qqError;
  bool? _lastQQLoggedIn;
  // QQ「我喜欢」收藏歌单（红心入口）
  List<Song> _qqLikedSongs = const [];
  String _qqLikedCover = '';
  bool _qqLikedLoading = false;

  // ---------- 汽水歌单 ----------
  List<Playlist> _sodaPlaylists = const [];
  bool _sodaLoading = false;
  String? _sodaError;
  bool? _lastSodaLoggedIn;

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
    _maybeLoadKugou();
    _maybeLoadQQ();
    _maybeLoadSoda();
  }

  @override
  void didUpdateWidget(covariant PlaylistsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从其他 tab 切回本页时强制刷新一次（IndexedStack 常驻不重建，
    // 避免 DB 已变而列表显示旧数据）
    if (!oldWidget.isActive && widget.isActive) {
      _reload();
      _maybeLoadCloud();
      _maybeLoadKugou();
      _maybeLoadQQ();
      _maybeLoadSoda();
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

  void _maybeLoadKugou() {
    final auth = context.read<AuthState>();
    final kgLoggedIn = auth.kugouLoggedIn;
    if (_lastKgLoggedIn != kgLoggedIn) {
      _lastKgLoggedIn = kgLoggedIn;
      if (kgLoggedIn) {
        _loadKugouPlaylists();
      } else {
        setState(() {
          _kgPlaylists = const [];
          _kgError = null;
        });
      }
    }
  }

  void _maybeLoadQQ() {
    final auth = context.read<AuthState>();
    final qqLoggedIn = auth.qqLoggedIn;
    if (_lastQQLoggedIn != qqLoggedIn) {
      _lastQQLoggedIn = qqLoggedIn;
      if (qqLoggedIn) {
        _loadQQPlaylists();
      } else {
        setState(() {
          _qqPlaylists = const [];
          _qqError = null;
        });
      }
    }
  }

  void _maybeLoadSoda() {
    final auth = context.read<AuthState>();
    final sodaLoggedIn = auth.sodaLoggedIn;
    if (_lastSodaLoggedIn != sodaLoggedIn) {
      _lastSodaLoggedIn = sodaLoggedIn;
      if (sodaLoggedIn) {
        _loadSodaPlaylists();
      } else {
        setState(() {
          _sodaPlaylists = const [];
          _sodaError = null;
        });
      }
    }
  }

  Future<void> _loadQQPlaylists() async {
    setState(() {
      _qqLoading = true;
      _qqError = null;
      _qqLikedLoading = true;
    });
    try {
      final list = await ApiService.qqUserPlaylist();
      List<Song> liked = const [];
      String likedCover = '';
      try {
        final likedData = await ApiService.qqLikePlaylist();
        liked = likedData.songs;
        likedCover = likedData.cover;
      } catch (_) {
        // 我喜欢加载失败不影响歌单区
      }
      if (!mounted) return;
      await Future.wait([
        for (final pl in list)
          if (pl.cover.isNotEmpty) CachedNetworkImage.evictFromCache(pl.cover),
      ]);
      if (!mounted) return;
      setState(() {
        _qqPlaylists = list;
        _qqLikedSongs = liked;
        _qqLikedCover = likedCover;
        _qqLoading = false;
        _qqLikedLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qqLoading = false;
        _qqLikedLoading = false;
        _qqError = e is NotLoggedInException
            ? 'QQ 登录态已失效，请重新登录'
            : 'QQ 歌单加载失败：$e';
      });
    }
  }

  Future<void> _loadKugouPlaylists() async {
    setState(() {
      _kgLoading = true;
      _kgError = null;
    });
    try {
      final list = await ApiService.kugouUserPlaylist();
      if (!mounted) return;
      await Future.wait([
        for (final pl in list)
          if (pl.cover.isNotEmpty) CachedNetworkImage.evictFromCache(pl.cover),
      ]);
      if (!mounted) return;
      setState(() {
        _kgPlaylists = list;
        _kgLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _kgLoading = false;
        _kgError = e is NotLoggedInException ? '酷狗登录态已失效，请重新登录' : '酷狗歌单加载失败：$e';
      });
    }
  }

  Future<void> _loadSodaPlaylists() async {
    setState(() {
      _sodaLoading = true;
      _sodaError = null;
    });
    try {
      final list = await ApiService.sodaUserPlaylists();
      if (!mounted) return;
      await Future.wait([
        for (final pl in list)
          if (pl.cover.isNotEmpty) CachedNetworkImage.evictFromCache(pl.cover),
      ]);
      if (!mounted) return;
      setState(() {
        _sodaPlaylists = list;
        _sodaLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sodaLoading = false;
        _sodaError = e is NotLoggedInException
            ? '汽水登录态已失效，请重新登录'
            : '汽水歌单加载失败：$e';
      });
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
      // 先清旧封面缓存（此前加载失败的结果可能被缓存）再渲染卡片：
      // 若先 setState 触发图片下载、后 evict，会删掉下载中的缓存文件，
      // 导致全部封面加载失败回退占位图
      await Future.wait([
        for (final pl in list)
          if (pl.cover.isNotEmpty) CachedNetworkImage.evictFromCache(pl.cover),
      ]);
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
    _maybeLoadKugou();
    _maybeLoadQQ();
    _maybeLoadSoda();
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

    // 分类排序：已登录（含检查中）的音源排上面，未登录的（登录提示卡片）排下面
    final auth = context.read<AuthState>();
    final cloudLogged = auth.loggedIn || auth.checking;
    final kgLogged = auth.kugouLoggedIn || auth.kugouChecking;
    final qqLogged = auth.qqLoggedIn || auth.qqChecking;
    final sodaLogged = auth.sodaLoggedIn || auth.sodaChecking;
    final topSections = <Widget>[];
    final bottomSections = <Widget>[];
    if (cloudLogged) {
      topSections.add(_buildCloudSection());
    } else {
      bottomSections.add(_buildCloudSection());
    }
    if (kgLogged) {
      topSections.add(_buildKugouSection());
    } else {
      bottomSections.add(_buildKugouSection());
    }
    if (qqLogged) {
      topSections.add(_buildQQSection());
    } else {
      bottomSections.add(_buildQQSection());
    }
    if (sodaLogged) {
      topSections.add(_buildSodaSection());
    } else {
      bottomSections.add(_buildSodaSection());
    }
    final sections = [...topSections, ...bottomSections];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      children: [
        // 已登录音源分类在上，未登录（登录提示卡片）在下
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0) const SizedBox(height: 16),
          sections[i],
        ],
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
                    _tab == 0 ? '还没有收藏歌曲\n点击列表右侧 ♥ 添加收藏' : '暂无播放历史\n去听几首歌吧',
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
              heartMode: _tab == 0 ? HeartMode.local : HeartMode.global,
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
              color: Colors.white70,
              strokeWidth: 2,
            ),
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
            Icon(
              Icons.cloud_download,
              color: Colors.white.withOpacity(0.7),
              size: 22,
            ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
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
            Icon(
              Icons.library_music,
              color: Colors.white.withOpacity(0.75),
              size: 18,
            ),
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
                  color: Colors.white70,
                  strokeWidth: 2,
                ),
              )
            else if (_cloudError != null)
              GestureDetector(
                onTap: _loadCloudPlaylists,
                child: Icon(
                  Icons.refresh,
                  color: Colors.white.withOpacity(0.6),
                  size: 18,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_cloudError != null)
          Text(
            _cloudError!,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          )
        else if (_cloudPlaylists.isEmpty && !_cloudLoading)
          Text(
            '暂无歌单',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 12,
            ),
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

  // ---------- 酷狗歌单区 ----------

  Widget _buildKugouSection() {
    final auth = context.read<AuthState>();
    if (auth.kugouChecking) {
      return const SizedBox.shrink(); // 检查中不占位，避免闪烁
    }
    if (!auth.kugouLoggedIn) {
      // 未登录：显示「登录酷狗音乐同步歌单」按钮
      return GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        borderRadius: 18,
        color: const Color(0xFF4FA0E0).withOpacity(0.14),
        child: Row(
          children: [
            Icon(
              Icons.library_music,
              color: Colors.white.withOpacity(0.7),
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '登录酷狗音乐后可同步你的歌单',
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
                builder: (_) => const LoginDialog(source: 'kugou'),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
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
            Icon(
              Icons.graphic_eq,
              color: Colors.white.withOpacity(0.75),
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              '我的酷狗歌单',
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            // 酷狗来源徽标
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withOpacity(0.25)),
              ),
              child: Text(
                '酷狗',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            if (_kgLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  color: Colors.white70,
                  strokeWidth: 2,
                ),
              )
            else if (_kgError != null)
              GestureDetector(
                onTap: _loadKugouPlaylists,
                child: Icon(
                  Icons.refresh,
                  color: Colors.white.withOpacity(0.6),
                  size: 18,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_kgError != null)
          Text(
            _kgError!,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          )
        else if (_kgPlaylists.isEmpty && !_kgLoading)
          Text(
            '暂无歌单',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 12,
            ),
          )
        else
          SizedBox(
            height: 156,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _kgPlaylists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) =>
                  _PlaylistCard(playlist: _kgPlaylists[i]),
            ),
          ),
      ],
    );
  }

  // ---------- QQ 歌单区 ----------

  Widget _buildQQSection() {
    final auth = context.read<AuthState>();
    if (auth.qqChecking) {
      return const SizedBox.shrink(); // 检查中不占位，避免闪烁
    }
    if (!auth.qqLoggedIn) {
      // 未登录：显示「登录 QQ 音乐同步歌单」按钮
      return GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        borderRadius: 18,
        color: const Color(0xFF12B7F5).withOpacity(0.14),
        child: Row(
          children: [
            Icon(
              Icons.music_note,
              color: Colors.white.withOpacity(0.7),
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '登录 QQ 音乐后可同步你的歌单',
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
                builder: (_) => const LoginDialog(source: 'qq'),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
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
            Icon(
              Icons.queue_music,
              color: Colors.white.withOpacity(0.75),
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              '我的 QQ 音乐歌单',
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            // QQ 来源徽标
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withOpacity(0.25)),
              ),
              child: Text(
                'QQ',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            if (_qqLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  color: Colors.white70,
                  strokeWidth: 2,
                ),
              )
            else if (_qqError != null)
              GestureDetector(
                onTap: _loadQQPlaylists,
                child: Icon(
                  Icons.refresh,
                  color: Colors.white.withOpacity(0.6),
                  size: 18,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // QQ「我喜欢」收藏入口（红心图标 + 歌曲数，点击进收藏歌单）
        GestureDetector(
          onTap: () {
            if (_qqLikedSongs.isEmpty && !_qqLikedLoading) return;
            // 透明路由（与歌单卡片一致），刷新 = 重新拉后端
            Navigator.of(context).push(
              PageRouteBuilder(
                opaque: false,
                transitionDuration: const Duration(milliseconds: 300),
                pageBuilder: (_, anim, __) => SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(0, 1),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(parent: anim, curve: Curves.easeOut),
                      ),
                  child: PlaylistDetailPage(
                    title: 'QQ 我喜欢',
                    cover: _qqLikedCover,
                    initialSongs: _qqLikedSongs,
                    onRefresh: () async {
                      final d = await ApiService.qqLikePlaylist();
                      return d.songs;
                    },
                  ),
                ),
              ),
            );
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFFFF4D6D).withOpacity(0.22),
                  const Color(0xFF12B7F5).withOpacity(0.10),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: Row(
              children: [
                const Icon(Icons.favorite, color: Color(0xFFFF4D6D), size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'QQ 我喜欢',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.92),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_qqLikedLoading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      color: Colors.white54,
                      strokeWidth: 2,
                    ),
                  )
                else if (_qqLikedSongs.isNotEmpty)
                  Text(
                    '${_qqLikedSongs.length} 首',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  color: Colors.white.withOpacity(0.5),
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        if (_qqError != null)
          Text(
            _qqError!,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          )
        else if (_qqPlaylists.isEmpty && !_qqLoading)
          Text(
            '暂无歌单',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 12,
            ),
          )
        else
          SizedBox(
            height: 156,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _qqPlaylists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) =>
                  _PlaylistCard(playlist: _qqPlaylists[i]),
            ),
          ),
      ],
    );
  }

  // ---------- 汽水歌单区 ----------

  Widget _buildSodaSection() {
    final auth = context.read<AuthState>();
    if (auth.sodaChecking) {
      return const SizedBox.shrink(); // 检查中不占位，避免闪烁
    }
    if (!auth.sodaLoggedIn) {
      // 未登录：显示「登录汽水音乐同步歌单」按钮
      return GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        borderRadius: 18,
        color: const Color(0xFF46C9B6).withOpacity(0.14),
        child: Row(
          children: [
            Icon(
              Icons.water_drop_outlined,
              color: Colors.white.withOpacity(0.7),
              size: 22,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '登录汽水音乐后可同步你的歌单',
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
                builder: (_) => const LoginDialog(source: 'soda'),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
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
            Icon(
              Icons.library_music,
              color: Colors.white.withOpacity(0.75),
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              '我的汽水歌单',
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            // 汽水来源徽标
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withOpacity(0.25)),
              ),
              child: Text(
                '汽水',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Spacer(),
            if (_sodaLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  color: Colors.white70,
                  strokeWidth: 2,
                ),
              )
            else if (_sodaError != null)
              GestureDetector(
                onTap: _loadSodaPlaylists,
                child: Icon(
                  Icons.refresh,
                  color: Colors.white.withOpacity(0.6),
                  size: 18,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (_sodaError != null)
          Text(
            _sodaError!,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          )
        else if (_sodaPlaylists.isEmpty && !_sodaLoading)
          Text(
            '暂无歌单',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 12,
            ),
          )
        else
          SizedBox(
            height: 156,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _sodaPlaylists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) =>
                  _PlaylistCard(playlist: _sodaPlaylists[i]),
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

/// 稳定渐变色板：按歌单 id 取色，刷新/重进颜色不变
const _coverPalettes = <List<Color>>[
  [Color(0xFF6C4FE0), Color(0xFF3A2A80)],
  [Color(0xFFE05A8A), Color(0xFF8A3A5C)],
  [Color(0xFF4FA0E0), Color(0xFF2A5A8A)],
  [Color(0xFFE0A34F), Color(0xFF8A5F2A)],
  [Color(0xFF50C8A0), Color(0xFF2A7A5C)],
  [Color(0xFF9A6CE0), Color(0xFF5A3A8A)],
  [Color(0xFFE07A5A), Color(0xFF8A4430)],
  [Color(0xFF5AC8E0), Color(0xFF2A7A8A)],
];

List<Color> _paletteForId(int id) {
  final i = id <= 0 ? 0 : id % _coverPalettes.length;
  return _coverPalettes[i];
}

/// 歌单名第一个字符（处理 emoji 等多字节字符）
String _firstChar(String name) {
  if (name.isEmpty) return '♪';
  return String.fromCharCodes([name.runes.first]);
}

/// 封面占位：渐变背景 + 歌单名首字（白 24sp 加粗）
class _CoverFallback extends StatelessWidget {
  final int id;
  final String name;
  const _CoverFallback({required this.id, required this.name});

  @override
  Widget build(BuildContext context) {
    final colors = _paletteForId(id);
    return Container(
      width: 110,
      height: 110,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        _firstChar(name),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 网易云歌单卡片：封面 + 名称 + 曲数
///
/// 封面渲染：非空 → CachedNetworkImage（失败回退首字渐变占位）；
/// 为空 → 首字渐变占位，并异步取歌单详情用第一首歌的专辑封面兜底。
class _PlaylistCard extends StatefulWidget {
  final Playlist playlist;
  const _PlaylistCard({required this.playlist});

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  String? _resolvedCover; // 空封面兜底异步获取到的封面
  bool _fetchTried = false;

  String get _cover => _resolvedCover ?? widget.playlist.cover;

  @override
  void initState() {
    super.initState();
    _maybeFetchFallbackCover();
  }

  @override
  void didUpdateWidget(covariant _PlaylistCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.detailId != widget.playlist.detailId) {
      _resolvedCover = null;
      _fetchTried = false;
      _maybeFetchFallbackCover();
    }
  }

  /// 空封面兜底：取歌单详情，用第一首歌的专辑封面替换（按音源选详情接口）
  Future<void> _maybeFetchFallbackCover() async {
    if (_fetchTried || widget.playlist.cover.isNotEmpty) return;
    _fetchTried = true;
    try {
      // 汽水详情 record 多 creator 字段，与其余音源 record 类型不同，单独处理
      String c;
      if (widget.playlist.source == 'soda') {
        final s = await ApiService.sodaPlaylistDetail(
          widget.playlist.detailId,
        );
        c = s.tracks.isNotEmpty ? s.tracks.first.cover : '';
      } else {
        final r = switch (widget.playlist.source) {
          'kugou' => await ApiService.kugouPlaylistDetail(
            widget.playlist.detailId,
          ),
          'qq' => await ApiService.qqPlaylistDetail(widget.playlist.detailId),
          _ => await ApiService.playlistDetail(widget.playlist.id.toString()),
        };
        c = r.tracks.isNotEmpty ? r.tracks.first.cover : '';
      }
      if (!mounted || c.isEmpty) return;
      setState(() => _resolvedCover = c);
    } catch (_) {
      // 兜底失败保持首字占位
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
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
                id: playlist.detailId,
                title: playlist.name,
                cover: _cover,
                // 酷狗歌单详情走 /kugou/playlist/detail
                source: playlist.source,
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
                border: Border.all(
                  color: Colors.white.withOpacity(0.3),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: _cover.isEmpty
                        ? _CoverFallback(
                            // 云端歌单（酷狗/QQ/汽水）int id 多为 0，
                            // 用原始字符串 id 哈希做渐变种子
                            id: playlist.source == 'netease'
                                ? playlist.id
                                : playlist.detailId.hashCode,
                            name: playlist.name,
                          )
                        : CachedNetworkImage(
                            imageUrl: _cover,
                            fit: BoxFit.cover,
                            width: 110,
                            height: 110,
                            // p1.music.126.net 拒绝 Dart 默认 UA（403），必须带浏览器 UA
                            httpHeaders: kImageHttpHeaders,
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
                                      Colors.white.withOpacity(0.5),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // 加载失败 → 歌单名首字渐变占位（不再用唱片图标）
                            errorWidget: (context, url, error) {
                              debugPrint(
                                '[PlaylistCover] 加载失败 url=$url error=$error',
                              );
                              return _CoverFallback(
                                id: playlist.source == 'netease'
                                    ? playlist.id
                                    : playlist.detailId.hashCode,
                                name: playlist.name,
                              );
                            },
                          ),
                  ),
                  // 云端音源来源徽标（左上角小标签，酷狗/QQ/汽水）
                  if (playlist.source == 'kugou' ||
                      playlist.source == 'qq' ||
                      playlist.source == 'soda')
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.3),
                          ),
                        ),
                        child: Text(
                          switch (playlist.source) {
                            'kugou' => '酷狗',
                            'qq' => 'QQ',
                            'soda' => '汽水',
                            _ => '',
                          },
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
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
