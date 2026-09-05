/// 每日推荐视图：先 /recommend，失败或为空回退 /playlist?id=3778678（热歌榜）
///
/// 登录后 /recommend 返回网易云官方每日推荐（个性化）；
/// 未登录或接口报错/为空时回退热歌榜，并在顶部提示扫码登录。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../services/api_service.dart';
import '../state/auth_state.dart';
import '../widgets/glass_card.dart';
import '../widgets/song_tile.dart';
import 'login_dialog.dart';

class RecommendView extends StatefulWidget {
  const RecommendView({super.key});

  @override
  State<RecommendView> createState() => _RecommendViewState();
}

class _RecommendViewState extends State<RecommendView>
    with AutomaticKeepAliveClientMixin {
  List<Song> _songs = [];
  bool _loading = true;
  String? _error;
  bool _fromFallback = false;
  bool? _lastLoggedIn;
  bool _needLoginHint = false;

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
    setState(() {
      _loading = true;
      _error = null;
    });
    List<Song> songs = const [];
    bool recommendOk = false;
    // 1. 每日推荐（未登录可能为空或报错）
    try {
      songs = await ApiService.recommend();
      if (songs.isNotEmpty) recommendOk = true;
    } catch (_) {
      songs = const [];
    }
    // 2. 空 → 回退热歌榜
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
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _fromFallback = fallback;
      _needLoginHint = !loggedIn && !recommendOk;
      _loading = false;
    });
  }

  void _maybeReloadOnAuthChange() {
    final auth = context.read<AuthState>();
    final loggedIn = auth.loggedIn;
    if (_lastLoggedIn != loggedIn) {
      _lastLoggedIn = loggedIn;
      _load();
    }
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
    if (_songs.isEmpty) {
      return _ErrorView(message: '没有拿到歌曲数据', onRetry: _load);
    }
    return RefreshIndicator(
      color: Colors.white,
      backgroundColor: const Color(0xFF2A2044),
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
        itemCount: _songs.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) {
            // 顶部标题
            return Padding(
              padding: const EdgeInsets.only(bottom: 10, left: 4),
              child: Text(
                _fromFallback ? '☁️ 热门歌单 · 云音乐热歌榜' : '✨ 每日推荐 · 为你而生',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 12,
                  letterSpacing: 0.5,
                ),
              ),
            );
          }
          if (i == 1 && _needLoginHint) {
            return _LoginHintBanner(onLogin: () => _showLogin(context));
          }
          final songIndex = _needLoginHint ? i - 2 : i - 1;
          if (songIndex < 0 || songIndex >= _songs.length) {
            return const SizedBox.shrink();
          }
          return SongTile(
            song: _songs[songIndex],
            queue: _songs,
            index: songIndex + 1,
          );
        },
      ),
    );
  }

  void _showLogin(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const LoginDialog(),
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
      margin: const EdgeInsets.only(bottom: 12),
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
            Icon(Icons.cloud_off, color: Colors.white.withOpacity(0.4), size: 48),
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
