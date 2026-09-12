/// 歌单 / 榜单详情页：大封面 + 榜单名/简介 + 曲目列表（带排名序号）
library;

import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../state/ui_settings.dart';
import '../widgets/song_tile.dart';

/// 歌单封面 Hero tag 拼接规则（起点 playlists_page 与终点本页必须一致）
String playlistHeroTag(String source, String detailId) =>
    'playlist-cover-$source-$detailId';

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

  /// 封面飞入 Hero tag（由 pushPlaylistDetail 传入；null = 不启用 Hero）
  final String? heroTag;

  const PlaylistDetailPage({
    super.key,
    this.id,
    this.title,
    this.cover,
    this.initialSongs,
    this.source = 'netease',
    this.onRefetch,
    this.onRefresh,
    this.heroTag,
  });

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage>
    with SingleTickerProviderStateMixin {
  List<Song> _songs = const [];
  String _name = '';
  String _cover = '';
  String _desc = '';
  bool _loading = true;
  String? _error;

  /// 背景模糊过渡：进入时 sigma 0 → 20 渐显（跟随「推入转场」开关）
  late final AnimationController _bgBlurCtrl;
  late final Animation<double> _bgBlur;

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
    // 背景模糊过渡动画（600ms，略长于路由 400ms，让模糊在页面推入后继续"糊开"）
    _bgBlurCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _bgBlur = CurvedAnimation(parent: _bgBlurCtrl, curve: Curves.easeOutCubic);
    _bgBlurCtrl.forward();
    _load();
  }

  @override
  void dispose() {
    _bgBlurCtrl.dispose();
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
    return ListenableBuilder(
      listenable: uiStyle,
      builder: (context, _) {
        final style = uiStyle.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 背景按界面风格：
            // 液态玻璃 = 实时毛玻璃（模糊透出下层）
            // 暗色透明 = 全透明（直接透出下层）
            // 极简暗色 = 纯黑；极简白色 = 暖白
            if (style == UiStyle.glass && !isLight)
              // 模糊过渡：推入转场开启时 sigma 0→20 渐显（进入时下层清晰→糊开）；
              // 关闭时保持恒定 blur 20（与旧行为一致）
              ListenableBuilder(
                listenable: Listenable.merge([_bgBlur, transitionPage]),
                builder: (_, __) {
                  final t = transitionPage.value ? _bgBlur.value : 1.0;
                  return BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: 20 * t,
                      sigmaY: 20 * t,
                    ),
                    // 黑色遮罩透明度同步 0→0.35 渐显：打开瞬间下层完全清晰，
                    // 再逐渐压暗+模糊，过渡才明显
                    child: Container(
                      color: Colors.black.withOpacity(0.35 * t),
                    ),
                  );
                },
              )
            else if (isLight)
              ColoredBox(color: Color(0xFFF9FAF4))
            else if (style == UiStyle.plain)
              ColoredBox(color: Color(0xFF000000)),
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
      },
    );
  }

  Widget _buildHeader() {
    return Container(
      margin: EdgeInsets.fromLTRB(16, 10, 16, 6),
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
                color: fgPrimary.withOpacity(0.12),
                border: Border.all(
                  color: fgPrimary.withOpacity(0.28),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.arrow_back,
                color: fgPrimary.withOpacity(0.9),
                size: 20,
              ),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              _name.isEmpty ? '歌单' : _name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fgPrimary,
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
                color: fgPrimary.withOpacity(0.12),
                border: Border.all(
                  color: fgPrimary.withOpacity(0.28),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.refresh,
                color: fgPrimary.withOpacity(0.9),
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
      return Center(child: CircularProgressIndicator(color: fgSecondary));
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
            heroTag: widget.heroTag,
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
  final String? heroTag;
  _BigHeader({
    required this.name,
    required this.cover,
    required this.desc,
    required this.count,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面（玻璃圆盘 + 圆角封面）
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fgPrimary.withOpacity(0.10),
              border: Border.all(color: fgPrimary.withOpacity(0.3), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 22,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: _coverChild(),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 6),
                Text(
                  name.isEmpty ? '歌单' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fgPrimary,
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
                      color: fgPrimary.withOpacity(0.55),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  '共 $count 首',
                  style: TextStyle(
                    color: fgPrimary.withOpacity(0.45),
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

  /// 封面：圆形裁剪；有 tag 且有封面 URL 时包 Hero（封面飞入终点）
  Widget _coverChild() {
    final oval = ClipOval(
      child: cover.isEmpty
          ? Container(
              color: fgPrimary.withOpacity(0.10),
              child: Icon(
                Icons.album,
                color: fgPrimary.withOpacity(0.6),
                size: 40,
              ),
            )
          : CachedNetworkImage(
              imageUrl: cover,
              fit: BoxFit.cover,
              // p1.music.126.net 拒绝 Dart 默认 UA（403），必须带浏览器 UA
              httpHeaders: kImageHttpHeaders,
              placeholder: (_, __) =>
                  Container(color: fgPrimary.withOpacity(0.10)),
              errorWidget: (_, __, ___) => Container(
                color: fgPrimary.withOpacity(0.10),
                child: Icon(
                  Icons.album,
                  color: fgPrimary.withOpacity(0.6),
                  size: 40,
                ),
              ),
            ),
    );
    // Hero 必须无条件挂载（只要 tag 非空）：
    // 否则打开瞬间终点无 Hero → 封面不飞；封面空时飞占位图，加载完成后原位更新
    if (heroTag == null) return oval;
    return Hero(tag: heroTag!, child: oval);
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
            Icon(Icons.cloud_off, color: fgPrimary.withOpacity(0.4), size: 48),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: fgPrimary.withOpacity(0.6),
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, color: fgPrimary, size: 18),
              label: Text('重试', style: TextStyle(color: fgPrimary)),
              style: TextButton.styleFrom(
                backgroundColor: fgPrimary.withOpacity(0.12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: fgPrimary.withOpacity(0.25)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
