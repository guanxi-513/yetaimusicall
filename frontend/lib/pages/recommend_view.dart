/// 首页推荐视图：每日推荐 + 雷达歌单 + 酷狗每日推荐 + 猜你喜欢 + QQ 每日推荐
///
/// 每个分区 = 标题行（图标 + 标题 + 一键播放 ▶ + > 箭头）+ 横向滚动歌曲卡片。
/// - 每日推荐：/recommend，失败或为空回退 /playlist?id=3778678（热歌榜）
/// - 雷达歌单：/radar（需登录；未登录或失败时整个分区隐藏）
/// - 酷狗每日推荐：/kugou/recommend/daily（需酷狗登录；未登录整个分区隐藏）
/// - 猜你喜欢：/kugou/recommend/fm（需酷狗登录；详情页支持"换一批"）
/// - QQ 每日推荐：/qq/recommend/daily（需 QQ 登录；未登录整个分区隐藏）
/// 下拉刷新同时刷新所有分区。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../widgets/glass_card.dart';
import 'login_dialog.dart';
import 'player_page.dart';
import 'playlist_detail_page.dart';

class RecommendView extends StatefulWidget {
  const RecommendView({super.key});

  @override
  State<RecommendView> createState() => _RecommendViewState();
}

class _RecommendViewState extends State<RecommendView>
    with AutomaticKeepAliveClientMixin {
  // ---------- 每日推荐 ----------
  List<Song> _songs = [];
  bool _fromFallback = false;
  bool _needLoginHint = false;

  // ---------- 雷达歌单 ----------
  List<Song> _radarSongs = [];
  String _radarPlaylistId = '';
  String _radarPlaylistName = '私人雷达';
  bool _radarLoaded = false; // 获取成功才显示分区（未登录/失败隐藏）

  // ---------- 酷狗每日推荐 ----------
  List<Song> _kgDailySongs = [];
  bool _kgDailyLoaded = false; // 酷狗未登录/失败时整个分区隐藏

  // ---------- 酷狗猜你喜欢 ----------
  List<Song> _kgFmSongs = [];
  bool _kgFmLoaded = false;

  // ---------- QQ 每日推荐 ----------
  List<Song> _qqDailySongs = [];
  bool _qqDailyLoaded = false; // QQ 未登录/失败时整个分区隐藏

  // ---------- 全局 ----------
  bool _loading = true;
  String? _error;
  bool? _lastLoggedIn;
  bool? _lastKgLoggedIn;
  bool? _lastQQLoggedIn;
  int _playingSection = 0; // 0 无 / 1 每日推荐 / 2 雷达歌单 / 3 酷狗每日 / 4 猜你喜欢 / 5 QQ每日

  /// 每个分区默认展示的歌曲数（横向滚动看这些；一键播放播全部）
  static const int _previewCount = 10;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 延迟到首帧后加载，确保 AuthState 可用
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final auth = context.read<AuthState>();
    final loggedIn = auth.loggedIn;
    final kgLoggedIn = auth.kugouLoggedIn;
    final qqLoggedIn = auth.qqLoggedIn;
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    // ---- 每日推荐（失败/为空回退热歌榜） ----
    List<Song> songs = const [];
    bool recommendOk = false;
    try {
      songs = await ApiService.recommend();
      if (songs.isNotEmpty) recommendOk = true;
    } catch (_) {
      songs = const [];
    }
    bool fallback = false;
    if (songs.isEmpty) {
      try {
        songs = await ApiService.playlist();
        fallback = true;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '加载失败：$e\n请检查音源服务是否已启动';
        });
        return;
      }
    }

    // ---- 雷达歌单（需登录，失败隐藏分区不阻塞首页） ----
    List<Song> radarSongs = const [];
    String radarId = '';
    String radarName = '私人雷达';
    bool radarOk = false;
    if (loggedIn) {
      try {
        final r = await ApiService.radar();
        radarSongs = r.songs;
        radarId = r.playlistId;
        radarName = r.playlistName;
        radarOk = true;
      } catch (_) {
        // 未登录/接口失败：隐藏雷达分区
      }
    }

    // ---- 酷狗每日推荐 + 猜你喜欢（需酷狗登录，失败隐藏分区） ----
    List<Song> kgDaily = const [];
    bool kgDailyOk = false;
    List<Song> kgFm = const [];
    bool kgFmOk = false;
    if (kgLoggedIn) {
      try {
        kgDaily = await ApiService.kugouRecommendDaily();
        kgDailyOk = kgDaily.isNotEmpty;
      } catch (_) {
        // 未登录（301）/接口失败：隐藏酷狗分区
      }
      try {
        kgFm = await ApiService.kugouRecommendFm();
        kgFmOk = kgFm.isNotEmpty;
      } catch (_) {
        // 未登录（301）/接口失败：隐藏酷狗分区
      }
    }

    // ---- QQ 每日推荐（需 QQ 登录，失败/为空隐藏分区） ----
    List<Song> qqDaily = const [];
    bool qqDailyOk = false;
    if (qqLoggedIn) {
      try {
        qqDaily = await ApiService.qqRecommendDaily();
        qqDailyOk = qqDaily.isNotEmpty;
      } catch (_) {
        // 未登录（401）/接口失败：隐藏 QQ 分区
      }
    }

    if (!mounted) return;
    setState(() {
      _songs = songs;
      _fromFallback = fallback;
      _needLoginHint = !loggedIn && !recommendOk;
      _radarSongs = radarSongs;
      _radarPlaylistId = radarId;
      _radarPlaylistName = radarName;
      _radarLoaded = radarOk;
      _kgDailySongs = kgDaily;
      _kgDailyLoaded = kgDailyOk;
      _kgFmSongs = kgFm;
      _kgFmLoaded = kgFmOk;
      _qqDailySongs = qqDaily;
      _qqDailyLoaded = qqDailyOk;
      _loading = false;
    });
  }

  void _maybeReloadOnAuthChange() {
    final auth = context.read<AuthState>();
    final loggedIn = auth.loggedIn;
    final kgLoggedIn = auth.kugouLoggedIn;
    final qqLoggedIn = auth.qqLoggedIn;
    // 任一音源登录态变化都触发重载（酷狗/QQ 退出后入口立即消失）
    if (_lastLoggedIn != loggedIn ||
        _lastKgLoggedIn != kgLoggedIn ||
        _lastQQLoggedIn != qqLoggedIn) {
      _lastLoggedIn = loggedIn;
      _lastKgLoggedIn = kgLoggedIn;
      _lastQQLoggedIn = qqLoggedIn;
      _load();
    }
  }

  // ---------- 一键播放 ----------

  Future<void> _playSection(int section) async {
    final songs = switch (section) {
      1 => _songs,
      2 => _radarSongs,
      3 => _kgDailySongs,
      4 => _kgFmSongs,
      5 => _qqDailySongs,
      _ => const <Song>[],
    };
    if (songs.isEmpty || _playingSection != 0) return;
    setState(() => _playingSection = section);
    try {
      // 清空队列 → 全部按顺序加入 → 从第一首播放
      await context.read<PlayerState>().playAll(songs);
      if (!mounted) return;
      // 播放页从底部向上滑入（与迷你播放条一致）
      Navigator.of(context).push(playerRoute());
    } finally {
      if (mounted) setState(() => _playingSection = 0);
    }
  }

  // ---------- ">" 箭头跳转 ----------

  void _openDailyDetail() {
    if (_songs.isEmpty) return;
    Navigator.of(context).push(
      _detailRoute(
        _fromFallback
            ? const PlaylistDetailPage(
                id: AppConfig.kHotPlaylistId,
                title: '云音乐热歌榜',
              )
            : PlaylistDetailPage(title: '每日推荐', initialSongs: _songs),
      ),
    );
  }

  void _openRadarDetail() {
    if (_radarPlaylistId.isEmpty || _radarSongs.isEmpty) return;
    Navigator.of(context).push(
      _detailRoute(
        PlaylistDetailPage(id: _radarPlaylistId, title: _radarPlaylistName),
      ),
    );
  }

  /// 酷狗每日推荐详情（预置歌曲直显；进入时 301 已在 _load 阶段过滤）
  void _openKgDailyDetail() {
    if (_kgDailySongs.isEmpty) return;
    Navigator.of(context).push(
      _detailRoute(
        PlaylistDetailPage(title: '酷狗每日推荐', initialSongs: _kgDailySongs),
      ),
    );
  }

  /// 猜你喜欢详情：流式推荐，刷新按钮 = 再调 /kugou/recommend/fm 换一批
  void _openKgFmDetail() {
    if (_kgFmSongs.isEmpty) return;
    Navigator.of(context).push(
      _detailRoute(
        PlaylistDetailPage(
          title: '猜你喜欢',
          initialSongs: _kgFmSongs,
          onRefetch: () async {
            final songs = await ApiService.kugouRecommendFm();
            if (songs.isEmpty) throw ApiException('没有更多推荐了');
            _kgFmSongs = songs; // 同步回首页缓存
            return songs;
          },
        ),
      ),
    );
  }

  /// QQ 每日推荐详情（预置歌曲直显）
  void _openQQDailyDetail() {
    if (_qqDailySongs.isEmpty) return;
    Navigator.of(context).push(
      _detailRoute(
        PlaylistDetailPage(title: 'QQ 每日推荐', initialSongs: _qqDailySongs),
      ),
    );
  }

  PageRouteBuilder _detailRoute(Widget page) {
    return PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, anim, __) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: page,
      ),
    );
  }

  void _playSong(Song song, List<Song> queue) {
    context.read<PlayerState>().play(song, queue: queue);
  }

  void _showLogin(BuildContext context) {
    showDialog(context: context, builder: (_) => const LoginDialog());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 监听登录态变化，触发重载
    context.watch<AuthState>();
    _maybeReloadOnAuthChange();

    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }

    return RefreshIndicator(
      color: Colors.white,
      backgroundColor: const Color(0xFF2A2044),
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 16),
        children: [
          // ---- 第一分区：每日推荐 ----
          _SectionHeader(
            icon: '📅',
            title: _fromFallback ? '热门歌单' : '每日推荐',
            busy: _playingSection == 1,
            onPlay: () => _playSection(1),
            onMore: _openDailyDetail,
          ),
          if (_needLoginHint)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _LoginHintBanner(onLogin: () => _showLogin(context)),
            ),
          _HorizontalSongList(
            songs: _songs.take(_previewCount).toList(),
            onTap: _playSong,
          ),

          const SizedBox(height: 16),

          // ---- 第二分区：雷达歌单（获取成功才显示） ----
          if (_radarLoaded) ...[
            _SectionHeader(
              icon: '📡',
              title: '雷达歌单',
              busy: _playingSection == 2,
              onPlay: () => _playSection(2),
              onMore: _openRadarDetail,
            ),
            _HorizontalSongList(
              songs: _radarSongs.take(_previewCount).toList(),
              onTap: _playSong,
            ),
          ],

          // ---- 第三分区：酷狗每日推荐（需酷狗登录，未登录不渲染） ----
          if (_kgDailyLoaded) ...[
            const SizedBox(height: 16),
            _SectionHeader(
              icon: '🎧',
              title: '酷狗每日推荐',
              busy: _playingSection == 3,
              onPlay: () => _playSection(3),
              onMore: _openKgDailyDetail,
            ),
            _HorizontalSongList(
              songs: _kgDailySongs.take(_previewCount).toList(),
              onTap: _playSong,
            ),
          ],

          // ---- 第四分区：猜你喜欢（酷狗私人FM，未登录不渲染） ----
          if (_kgFmLoaded) ...[
            const SizedBox(height: 16),
            _SectionHeader(
              icon: '💫',
              title: '猜你喜欢',
              busy: _playingSection == 4,
              onPlay: () => _playSection(4),
              onMore: _openKgFmDetail,
            ),
            _HorizontalSongList(
              songs: _kgFmSongs.take(_previewCount).toList(),
              onTap: _playSong,
            ),
          ],

          // ---- 第五分区：QQ 每日推荐（需 QQ 登录，未登录完全不渲染） ----
          if (_qqDailyLoaded) ...[
            const SizedBox(height: 16),
            _SectionHeader(
              icon: '🐧',
              title: 'QQ 每日推荐',
              busy: _playingSection == 5,
              onPlay: () => _playSection(5),
              onMore: _openQQDailyDetail,
            ),
            _HorizontalSongList(
              songs: _qqDailySongs.take(_previewCount).toList(),
              onTap: _playSong,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------- 分区标题行 ----------

/// 标题行（高 44）：分区图标 + 标题（16sp 加粗）+ 一键播放 ▶ + ">" 箭头
class _SectionHeader extends StatelessWidget {
  final String icon;
  final String title;
  final bool busy; // 一键播放进行中 → ▶ 变 loading 转圈
  final VoidCallback onPlay;
  final VoidCallback onMore;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.busy,
    required this.onPlay,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$icon $title',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _PlayButton(busy: busy, onTap: onPlay),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onMore,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Icon(
                  Icons.chevron_right,
                  color: Colors.white.withOpacity(0.6),
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一键播放按钮：直径 32 圆形毛玻璃，点击 0.9 缩放反馈；busy 时 ▶ 变转圈
class _PlayButton extends StatefulWidget {
  final bool busy;
  final VoidCallback onTap;
  const _PlayButton({required this.busy, required this.onTap});

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.busy ? null : widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.15),
            border: Border.all(color: Colors.white.withOpacity(0.25)),
          ),
          child: Center(
            child: widget.busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Icon(Icons.play_arrow, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

// ---------- 横向滚动歌曲卡片 ----------

class _HorizontalSongList extends StatelessWidget {
  final List<Song> songs;
  final void Function(Song song, List<Song> queue) onTap;

  const _HorizontalSongList({required this.songs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 166,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) =>
            _SongCard(song: songs[i], onTap: () => onTap(songs[i], songs)),
      ),
    );
  }
}

/// 歌曲卡片：封面 1:1（120）+ 歌名 + 歌手
class _SongCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  const _SongCard({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // 只监听收藏状态（isFavorite 变化才重建卡片），避免播放进度
    // 高频 notifyListeners 导致整卡 rebuild、封面图片加载被打断
    final isFav = context.select<PlayerState, bool>((p) => p.isFavorite(song));
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面 1:1 + 右下角爱心
            Stack(
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.25),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: song.cover.isEmpty
                        ? Container(
                            color: Colors.white.withOpacity(0.10),
                            child: Icon(
                              Icons.album,
                              color: Colors.white.withOpacity(0.6),
                              size: 32,
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: song.cover,
                            fit: BoxFit.cover,
                            width: 120,
                            height: 120,
                            // 图片 CDN 可能拒绝 Dart 默认 UA（403），统一带浏览器 UA
                            httpHeaders: kImageHttpHeaders,
                            placeholder: (_, __) => Container(
                              color: Colors.white.withOpacity(0.10),
                            ),
                            errorWidget: (_, __, ___) => Container(
                              color: Colors.white.withOpacity(0.10),
                              child: Icon(
                                Icons.album,
                                color: Colors.white.withOpacity(0.6),
                                size: 32,
                              ),
                            ),
                          ),
                  ),
                ),
                // 爱心：封面右下角毛玻璃圆钮；点击收藏/取消（QQ 歌同步 QQ 云端）
                Positioned(
                  right: 5,
                  bottom: 5,
                  child: GestureDetector(
                    onTap: () =>
                        context.read<PlayerState>().toggleFavorite(song),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.40),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withOpacity(0.30),
                          width: 1,
                        ),
                      ),
                      child: Icon(
                        isFav ? Icons.favorite : Icons.favorite_border,
                        color: isFav ? const Color(0xFFFF4D6D) : Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 歌名
            SizedBox(
              width: double.infinity,
              child: Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // 歌手
            SizedBox(
              width: double.infinity,
              child: Text(
                song.artistText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.45),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未登录提示 banner：登录后查看专属每日推荐
class _LoginHintBanner extends StatelessWidget {
  final VoidCallback onLogin;
  const _LoginHintBanner({required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 18,
      color: const Color(0xFF6C4FE0).withOpacity(0.18),
      child: Row(
        children: [
          Icon(Icons.login, color: Colors.white.withOpacity(0.85), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '当前为热歌榜，登录后可查看你的专属每日推荐',
              style: TextStyle(
                color: Colors.white.withOpacity(0.85),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onLogin,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              color: Colors.white.withOpacity(0.4),
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, color: Colors.white, size: 18),
              label: const Text('重试', style: TextStyle(color: Colors.white)),
              style: TextButton.styleFrom(
                backgroundColor: Colors.white.withOpacity(0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: Colors.white.withOpacity(0.25)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
