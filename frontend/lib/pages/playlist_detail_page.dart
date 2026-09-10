/// 歌单 / 榜单详情页：大封面 + 榜单名/简介 + 曲目列表（带排名序号）
library;

import 'dart:ui' as ui show Image;
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../widgets/glass_background.dart';
import '../widgets/song_tile.dart';

class PlaylistDetailPage extends StatefulWidget {
  /// 歌单 id（为 null 时直接展示 [initialSongs]，不发网络请求）
  final String? id;
  final String? title;
  final String? cover;

  /// 预置歌曲（如"每日推荐"详情：非歌单接口数据，直接展示）
  final List<Song>? initialSongs;

  /// 音源：'netease'（默认）| 'kugou'（酷狗歌单走 /kugou/playlist/detail）
  /// | 'qq'（QQ 歌单走 /qq/playlist/detail）| 'soda'（汽水歌单走 /soda/playlist/detail）
  final String source;

  /// 换一批回调（"猜你喜欢"流式推荐用；提供后刷新按钮调用它替换歌曲列表）
  final Future<List<Song>> Function()? onRefetch;

  /// 刷新回调（预置歌曲列表用，如 QQ 我喜欢：刷新时重新拉后端）
  /// 提供后刷新按钮调用它替换歌曲列表；为空时预置模式刷新仅重设状态
  final Future<List<Song>> Function()? onRefresh;

  const PlaylistDetailPage({
    super.key,
    this.id,
    this.title,
    this.cover,
    this.initialSongs,
    this.source = 'netease',
    this.onRefetch,
    this.onRefresh,
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

  bool get _rankMode =>
      widget.initialSongs == null &&
      (widget.id != AppConfig.kHotPlaylistId ||
          (_name.contains('榜') || _desc.contains('榜')));

  /// 网易云"我喜欢的音乐"歌单（含用户改名的 *喜欢的音乐）：
  /// 红心 = 仅云端喜欢，取消后从列表移除（酷狗/QQ歌单无云端喜欢，不适用）
  bool get _isCloudLikedList =>
      widget.source == 'netease' && _name.contains('喜欢的音乐');

  @override
  void initState() {
    super.initState();
    _name = widget.title ?? '';
    _cover = widget.cover ?? '';
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    // 「换一批」模式（猜你喜欢）：回调拉新一批替换列表
    if (widget.onRefetch != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final songs = await widget.onRefetch!();
        if (!mounted) return;
        setState(() {
          _songs = songs;
          _loading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '加载失败：$e';
        });
      }
      return;
    }
    // 预置歌曲模式（每日推荐详情）：直接展示，不发网络请求
    if (widget.initialSongs != null) {
      // 提供 onRefresh（如 QQ 我喜欢）时刷新 = 重新拉后端，否则仅重设
      if (widget.onRefresh != null) {
        setState(() {
          _loading = true;
          _error = null;
        });
        try {
          final songs = await widget.onRefresh!();
          if (!mounted) return;
          setState(() {
            _songs = songs;
            _loading = false;
          });
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _error = e is NotLoggedInException ? '登录态已失效，请重新登录' : '加载失败：$e';
          });
        }
        return;
      }
      setState(() {
        _songs = widget.initialSongs!;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.source == 'soda') {
        // 汽水详情返回创建者（creator），若没简介则显示"创建者：xxx"
        final s = await ApiService.sodaPlaylistDetail(widget.id!);
        _songs = s.tracks;
        if (s.name.isNotEmpty) _name = s.name;
        if (s.cover.isNotEmpty) _cover = s.cover;
        _desc = s.description.isNotEmpty
            ? s.description
            : (s.creator.isNotEmpty ? '创建者：${s.creator}' : '');
      } else {
        final r = switch (widget.source) {
          'kugou' => await ApiService.kugouPlaylistDetail(widget.id!),
          'qq' => await ApiService.qqPlaylistDetail(widget.id!),
          _ => await ApiService.playlistDetail(widget.id!),
        };
        _songs = r.tracks;
        if (r.name.isNotEmpty) _name = r.name;
        if (r.cover.isNotEmpty) _cover = r.cover;
        _desc = r.description;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is NotLoggedInException ? '登录态已失效，请重新登录' : '加载失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 全透明背景：透出下层页面
        Scaffold(
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
        ),
      ],
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
                border: Border.all(
                  color: Colors.white.withOpacity(0.28),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.arrow_back,
                color: Colors.white.withOpacity(0.9),
                size: 20,
              ),
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
                border: Border.all(
                  color: Colors.white.withOpacity(0.28),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.refresh,
                color: Colors.white.withOpacity(0.9),
                size: 18,
              ),
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
            delegate: SliverChildBuilderDelegate((context, i) {
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
            }, childCount: _songs.length),
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
              border: Border.all(
                color: Colors.white.withOpacity(0.3),
                width: 1,
              ),
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
                      child: Icon(
                        Icons.album,
                        color: Colors.white.withOpacity(0.6),
                        size: 40,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: cover,
                      fit: BoxFit.cover,
                      // p1.music.126.net 拒绝 Dart 默认 UA（403），必须带浏览器 UA
                      httpHeaders: kImageHttpHeaders,
                      placeholder: (_, __) =>
                          Container(color: Colors.white.withOpacity(0.10)),
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.white.withOpacity(0.10),
                        child: Icon(
                          Icons.album,
                          color: Colors.white.withOpacity(0.6),
                          size: 40,
                        ),
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
