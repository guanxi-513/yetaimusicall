/// 歌单 / 榜单详情页：大封面 + 榜单名/简介 + 曲目列表（带排名序号）
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../widgets/song_tile.dart';

class PlaylistDetailPage extends StatefulWidget {
  final String id;
  final String? title;
  final String? cover;

  const PlaylistDetailPage({
    super.key,
    required this.id,
    this.title,
    this.cover,
  });

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  List<Song> _songs = const [];
  String _name = '';
  String _cover = '';
  String _desc = '';
  bool _loading = true;
  String? _error;

  bool get _rankMode => widget.id != AppConfig.kHotPlaylistId ||
      (_name.contains('榜') || _desc.contains('榜'));

  /// 网易云"我喜欢的音乐"歌单（含用户改名的 *喜欢的音乐）：
  /// 红心 = 仅云端喜欢，取消后从列表移除
  bool get _isCloudLikedList => _name.contains('喜欢的音乐');

  @override
  void initState() {
    super.initState();
    _name = widget.title ?? '';
    _cover = widget.cover ?? '';
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ApiService.playlistDetail(widget.id);
      setState(() {
        _songs = r.tracks;
        if (r.name.isNotEmpty) _name = r.name;
        if (r.cover.isNotEmpty) _cover = r.cover;
        _desc = r.description;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          // 返回
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.12),
                border:
                    Border.all(color: Colors.white.withOpacity(0.28), width: 1),
              ),
              child: Icon(Icons.arrow_back,
                  color: Colors.white.withOpacity(0.9), size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _name.isEmpty ? '歌单' : _name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          GestureDetector(
            onTap: _load,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.12),
                border:
                    Border.all(color: Colors.white.withOpacity(0.28), width: 1),
              ),
              child: Icon(Icons.refresh,
                  color: Colors.white.withOpacity(0.9), size: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }
    if (_songs.isEmpty) {
      return _ErrorView(message: '该歌单暂无曲目', onRetry: _load);
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        // 大封面 + 简介
        SliverToBoxAdapter(
          child: _BigHeader(
            name: _name,
            cover: _cover,
            desc: _desc,
            count: _songs.length,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        // 曲目列表
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final song = _songs[i];
                return SongTile(
                  song: song,
                  queue: _songs,
                  index: i + 1,
                  rankMode: _rankMode,
                  // 「我喜欢的音乐」：红心 = 仅云端，取消后移出列表
                  heartMode: _isCloudLikedList
                      ? HeartMode.cloud
                      : HeartMode.global,
                  onCloudUnlike: _isCloudLikedList
                      ? () => setState(() {
                            _songs.removeWhere((s) => s.id == song.id);
                          })
                      : null,
                );
              },
              childCount: _songs.length,
            ),
          ),
        ),
      ],
    );
  }
}

/// 大封面头部：圆形磨砂玻璃盘 + 封面 + 名称 + 简介 + 曲数
class _BigHeader extends StatelessWidget {
  final String name;
  final String cover;
  final String desc;
  final int count;
  const _BigHeader({
    required this.name,
    required this.cover,
    required this.desc,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面（玻璃圆盘 + 圆角封面）
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.10),
              border:
                  Border.all(color: Colors.white.withOpacity(0.3), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipOval(
              child: cover.isEmpty
                  ? Container(
                      color: Colors.white.withOpacity(0.10),
                      child: Icon(Icons.album,
                          color: Colors.white.withOpacity(0.6), size: 40),
                    )
                  : CachedNetworkImage(
                      imageUrl: cover,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(color: Colors.white.withOpacity(0.10)),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.white.withOpacity(0.10),
                        child: Icon(Icons.album,
                            color: Colors.white.withOpacity(0.6), size: 40),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Text(
                  name.isEmpty ? '歌单' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                if (desc.isNotEmpty)
                  Text(
                    desc,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  '共 $count 首',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.45),
                    fontSize: 12,
                  ),
                ),
              ],
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
