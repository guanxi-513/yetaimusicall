/// 播放页：大封面 + 玻璃控制按钮 + 纤细磨砂进度条 + 歌词自动滚动
library;

import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/song.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../widgets/glass_background.dart';
import '../widgets/glass_button.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with TickerProviderStateMixin {
  final ScrollController _lyricController = ScrollController();
  int _lastLyricIndex = -1;
  bool _userScrolling = false;

  // ---------- 下拉关闭 ----------
  double _dy = 0; // 当前下拉偏移（只增不减，拖动中跟随手指）

  /// 关闭动画：继续下移 500 + 淡出（easeInCubic 模拟重力加速）
  late final AnimationController _closeCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: 0,
  );
  // 弹回动画：松手不足阈值时回到原位（easeOutBack 弹性）
  late final AnimationController _returnCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 0,
  );
  Animation<double>? _returnTween;

  void _onDragUpdate(DragUpdateDetails details) {
    if (_closeCtrl.isAnimating) return;
    if (details.delta.dy <= 0) return; // 只响应向下拖动
    setState(() => _dy += details.delta.dy);
  }

  void _onDragEnd(DragEndDetails details) {
    if (_closeCtrl.isAnimating) return;
    final h = MediaQuery.of(context).size.height;
    if (_dy > h * 0.15) {
      // 触发关闭：向下滑出 + 淡出，然后 pop
      _closeCtrl.forward().then((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      // 弹回原位（弹性动画）
      _returnTween = Tween(begin: _dy, end: 0.0).animate(
        CurvedAnimation(parent: _returnCtrl, curve: Curves.easeOutBack),
      );
      _returnCtrl.forward(from: 0).whenComplete(() {
        if (mounted) setState(() => _dy = 0);
      });
    }
  }

  @override
  void dispose() {
    _lyricController.dispose();
    _closeCtrl.dispose();
    _returnCtrl.dispose();
    super.dispose();
  }

  void _autoScrollLyrics(int index, int total) {
    if (index < 0 || total == 0 || index == _lastLyricIndex) return;
    _lastLyricIndex = index;
    if (_userScrolling || !_lyricController.hasClients) return;
    // 每行高度约 44，滚动让当前行处于中间偏上
    final target = (index * 44.0 - 120).clamp(0.0, double.maxFinite);
    _lyricController.animateTo(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerState>();
    final song = player.currentDetail ?? player.current;
    _autoScrollLyrics(player.currentLyricIndex, player.lyrics.length);

    // 下拉关闭：手指拖动整页下移 + 透明度渐降 + 微缩放
    return GestureDetector(
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: AnimatedBuilder(
        animation: Listenable.merge([_closeCtrl, _returnCtrl]),
        // child 缓存：拖动/关闭动画只重算变换，不重建页面内容
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 全透明背景：透出下层页面（路由 opaque:false）
            Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                centerTitle: true,
                leading: IconButton(
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white,
                    size: 32,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
                title: Text(
                  song?.name ?? '未在播放',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                actions: [
                  if (song != null) ...[
                    // 音质选择按钮
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: IconButton(
                        icon: Icon(
                          Icons.high_quality,
                          color: Colors.white.withOpacity(0.85),
                          size: 24,
                        ),
                        tooltip: '音质：${_qualityLabel(AppConfig.audioQuality)}',
                        onPressed: () => _showQualitySheet(context),
                      ),
                    ),
                    // 播放队列按钮
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: IconButton(
                        icon: Icon(
                          Icons.queue_music,
                          color: Colors.white.withOpacity(0.85),
                          size: 24,
                        ),
                        onPressed: () => _showQueueSheet(context, player),
                      ),
                    ),
                    // 爱心（点击弹跳 + 收藏切换）
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _BouncingHeart(player: player, song: song),
                    ),
                  ],
                ],
              ),
              body: SafeArea(
                bottom: false,
                child: song == null
                    ? const Center(
                        child: Text(
                          '没有正在播放的歌曲',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : OrientationBuilder(
                        builder: (context, orientation) =>
                            orientation == Orientation.landscape
                            ? Row(
                                children: [
                                  Expanded(
                                    child: _CoverDisc(
                                      song: song,
                                      player: player,
                                    ),
                                  ),
                                  Expanded(child: _buildRightPanel(player)),
                                ],
                              )
                            : _buildPortrait(player, song),
                      ),
              ),
            ),
          ],
        ),
        builder: (context, child) {
          // 关闭动画时弹回动画不存在 → 用 _dy；弹回动画播放中 → 用插值
          final dy = _returnCtrl.isAnimating ? (_returnTween?.value ?? 0) : _dy;
          final progress = (dy / 400).clamp(0.0, 1.0); // 下拉进度
          final totalDy = dy + _closeCtrl.value * 500; // 关闭时继续下移出屏
          final opacity = (1.0 - progress - _closeCtrl.value * 0.5).clamp(
            0.0,
            1.0,
          );
          final scale = 1.0 - progress * 0.05;
          return Transform.translate(
            offset: Offset(0, totalDy),
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(scale: scale, child: child),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPortrait(PlayerState player, Song song) {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          _CoverDisc(song: song, player: player),
          const SizedBox(height: 20),
          _SongInfo(song: song, quality: player.currentQuality),
          const SizedBox(height: 16),
          _ProgressSection(player: player),
          const SizedBox(height: 8),
          _PlayModeBar(player: player),
          const SizedBox(height: 8),
          _Controls(player: player),
          const SizedBox(height: 16),
          _LyricsPanel(
            player: player,
            controller: _lyricController,
            onUserScrollStart: () => _userScrolling = true,
            onUserScrollEnd: () {
              _userScrolling = false;
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildRightPanel(PlayerState player) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _SongInfo(
            song: player.currentDetail ?? player.current!,
            quality: player.currentQuality,
          ),
          const SizedBox(height: 16),
          _ProgressSection(player: player),
          const SizedBox(height: 8),
          _PlayModeBar(player: player),
          const SizedBox(height: 8),
          _Controls(player: player),
          const SizedBox(height: 16),
          _LyricsPanel(
            player: player,
            controller: _lyricController,
            onUserScrollStart: () => _userScrolling = true,
            onUserScrollEnd: () => _userScrolling = false,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 音质显示名
  String _qualityLabel(String q) {
    switch (q) {
      case 'standard':
        return '标准 128k';
      case 'lossless':
        return '无损 FLAC';
      case 'high':
      default:
        return '高品 320k';
    }
  }

  /// 音质选择弹层（玻璃质感底部弹层）
  void _showQualitySheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.18),
                Colors.white.withOpacity(0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Text(
                      '播放音质',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _qualityOption(ctx, 'standard', '标准 128k', '省流量，加载最快'),
                  _qualityOption(ctx, 'high', '高品 320k', '音质与流量平衡（默认）'),
                  _qualityOption(ctx, 'lossless', '无损 FLAC', '音质最佳，体积大'),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 单个音质选项行
  Widget _qualityOption(
    BuildContext sheetCtx,
    String q,
    String label,
    String desc,
  ) {
    final selected = AppConfig.audioQuality == q;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      title: Text(
        label,
        style: TextStyle(
          color: selected ? const Color(0xFFE05A8A) : Colors.white,
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      subtitle: Text(
        desc,
        style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11),
      ),
      trailing: selected
          ? const Icon(Icons.check_circle, color: Color(0xFFE05A8A), size: 20)
          : null,
      onTap: () {
        AppConfig.saveAudioQuality(q);
        Navigator.pop(sheetCtx);
        setState(() {});
      },
    );
  }

  /// 播放队列弹窗（玻璃质感底部弹层）
  void _showQueueSheet(BuildContext context, PlayerState player) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final queue = player.queue;
        return Container(
          height: MediaQuery.of(ctx).size.height * 0.6,
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withOpacity(0.18),
                    Colors.white.withOpacity(0.06),
                  ],
                ),
                border: Border.all(
                  color: Colors.white.withOpacity(0.25),
                  width: 1,
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                children: [
                  // 拖拽指示条
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  // 标题行
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.queue_music,
                          color: Colors.white.withOpacity(0.8),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '播放队列',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '共 ${queue.length} 首',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(color: Colors.white.withOpacity(0.12), height: 1),
                  // 列表
                  Expanded(
                    child: queue.isEmpty
                        ? Center(
                            child: Text(
                              '队列为空',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: queue.length,
                            itemBuilder: (ctx, i) {
                              final s = queue[i];
                              final isCurrent = i == player.index;
                              return GestureDetector(
                                onTap: () {
                                  player.playAt(i);
                                  Navigator.pop(ctx);
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  color: isCurrent
                                      ? Colors.white.withOpacity(0.10)
                                      : null,
                                  child: Row(
                                    children: [
                                      // 小封面
                                      Container(
                                        width: 36,
                                        height: 36,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          border: Border.all(
                                            color: Colors.white.withOpacity(
                                              0.25,
                                            ),
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: s.cover.isEmpty
                                              ? Container(
                                                  color: Colors.white
                                                      .withOpacity(0.08),
                                                  child: Icon(
                                                    Icons.music_note,
                                                    color: Colors.white
                                                        .withOpacity(0.4),
                                                    size: 16,
                                                  ),
                                                )
                                              : CachedNetworkImage(
                                                  imageUrl: s.cover,
                                                  fit: BoxFit.cover,
                                                  width: 36,
                                                  height: 36,
                                                  placeholder: (_, __) =>
                                                      Container(
                                                        color: Colors.white
                                                            .withOpacity(0.08),
                                                      ),
                                                  errorWidget: (_, __, ___) =>
                                                      Container(
                                                        color: Colors.white
                                                            .withOpacity(0.08),
                                                        child: Icon(
                                                          Icons.music_note,
                                                          color: Colors.white
                                                              .withOpacity(0.4),
                                                          size: 16,
                                                        ),
                                                      ),
                                                ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              s.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? Colors.white
                                                    : Colors.white.withOpacity(
                                                        0.75,
                                                      ),
                                                fontSize: 13,
                                                fontWeight: isCurrent
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              s.artistText,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white.withOpacity(
                                                  0.45,
                                                ),
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (isCurrent)
                                        Icon(
                                          Icons.graphic_eq,
                                          color: Colors.white.withOpacity(0.8),
                                          size: 18,
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 大圆形专辑封面悬浮在磨砂玻璃圆盘上
class _CoverDisc extends StatelessWidget {
  final Song song;
  final PlayerState player;
  const _CoverDisc({required this.song, required this.player});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.58;

    return SizedBox(
      height: size + 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 外圈磨砂玻璃圆盘（比封面大一圈）
          Container(
            width: size + 36,
            height: size + 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.45),
                  blurRadius: 40,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: ClipOval(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.20),
                      Colors.white.withOpacity(0.05),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.32),
                    width: 1.2,
                  ),
                ),
              ),
            ),
          ),
          // 唱片中轴
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.25),
                width: 1,
              ),
            ),
            child: ClipOval(
              child: song.cover.isEmpty
                  ? Container(
                      color: const Color(0xFF2A2050),
                      child: Icon(
                        Icons.music_note,
                        color: Colors.white.withOpacity(0.5),
                        size: size / 3,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: song.cover,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: const Color(0xFF2A2050),
                        child: Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(
                                Colors.white.withOpacity(0.6),
                              ),
                            ),
                          ),
                        ),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: const Color(0xFF2A2050),
                        child: Icon(
                          Icons.music_note,
                          color: Colors.white.withOpacity(0.5),
                          size: size / 3,
                        ),
                      ),
                    ),
            ),
          ),
          // 唱机中心小圆点
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1A1233),
              border: Border.all(color: Colors.white.withOpacity(0.5)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌名 / 歌手
class _SongInfo extends StatelessWidget {
  final Song song;
  final String quality;
  const _SongInfo({required this.song, this.quality = ''});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Text(
            song.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            song.artistText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withOpacity(0.60),
              fontSize: 14,
            ),
          ),
          if (quality.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              quality,
              style: TextStyle(
                color: Colors.white.withOpacity(0.42),
                fontSize: 11,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 纤细磨砂进度条（可拖动 seek）+ 当前/总时长
class _ProgressSection extends StatefulWidget {
  final PlayerState player;
  const _ProgressSection({required this.player});

  @override
  State<_ProgressSection> createState() => _ProgressSectionState();
}

class _ProgressSectionState extends State<_ProgressSection> {
  double? _dragValue; // 拖动中的本地值（毫秒）

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final totalMs = player.duration.inMilliseconds;
    final posMs = _dragValue ?? player.position.inMilliseconds;
    final bufferedMs = player.buffered.inMilliseconds;
    final ratio = totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0;
    final bufferedRatio = totalMs > 0
        ? (bufferedMs / totalMs).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) => setState(
                  () => _dragValue = _posFromDx(
                    d.localPosition.dx,
                    width,
                    totalMs,
                  ),
                ),
                onHorizontalDragUpdate: (d) => setState(
                  () => _dragValue = _posFromDx(
                    d.localPosition.dx,
                    width,
                    totalMs,
                  ),
                ),
                onHorizontalDragEnd: (_) {
                  if (_dragValue != null && totalMs > 0) {
                    player.seek(Duration(milliseconds: _dragValue!.round()));
                  }
                  setState(() => _dragValue = null);
                },
                onTapUp: (d) {
                  if (totalMs > 0) {
                    player.seek(
                      Duration(
                        milliseconds: _posFromDx(
                          d.localPosition.dx,
                          width,
                          totalMs,
                        ).round(),
                      ),
                    );
                  }
                },
                child: SizedBox(
                  height: 28,
                  child: Center(
                    child: SizedBox(
                      height: 10,
                      width: double.infinity,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: Stack(
                          children: [
                            // 底轨（磨砂）
                            Container(color: Colors.white.withOpacity(0.14)),
                            // 缓冲
                            FractionallySizedBox(
                              widthFactor: bufferedRatio,
                              child: Container(
                                color: Colors.white.withOpacity(0.28),
                              ),
                            ),
                            // 已播放
                            FractionallySizedBox(
                              widthFactor: ratio,
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Colors.white70, Colors.white],
                                  ),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmt(posMs),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  fontSize: 11,
                ),
              ),
              if (player.loading)
                Text(
                  '缓冲中…',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.45),
                    fontSize: 11,
                  ),
                ),
              if (player.error != null)
                Flexible(
                  child: Text(
                    player.error!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFE05A8A),
                      fontSize: 11,
                    ),
                  ),
                ),
              Text(
                _fmt(totalMs),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _posFromDx(double dx, double width, int totalMs) {
    final ratio = (dx / width).clamp(0.0, 1.0);
    return ratio * totalMs;
  }

  String _fmt(num ms) {
    final d = Duration(milliseconds: ms.round());
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// 玻璃圆形控制按钮：上一首 / 播放暂停 / 下一首
class _Controls extends StatelessWidget {
  final PlayerState player;
  const _Controls({required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlassIconButton(
            icon: Icons.skip_previous,
            size: 58,
            iconSize: 30,
            onTap: player.previous,
          ),
          const SizedBox(width: 28),
          GlassButton(
            size: 78,
            onTap: player.togglePlay,
            child: player.loading
                ? const SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                // 播放/暂停图标切换：缩放过渡
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: Icon(
                      player.playing ? Icons.pause : Icons.play_arrow,
                      key: ValueKey(player.playing),
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
          ),
          const SizedBox(width: 28),
          GlassIconButton(
            icon: Icons.skip_next,
            size: 58,
            iconSize: 30,
            onTap: player.next,
          ),
        ],
      ),
    );
  }
}

/// 歌词面板：当前句高亮 + 自动滚动
class _LyricsPanel extends StatefulWidget {
  final PlayerState player;
  final ScrollController controller;
  final VoidCallback onUserScrollStart;
  final VoidCallback onUserScrollEnd;

  const _LyricsPanel({
    required this.player,
    required this.controller,
    required this.onUserScrollStart,
    required this.onUserScrollEnd,
  });

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  bool _hasNotified = false;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final lyrics = player.lyrics;

    Widget panelChild;
    if (lyrics.isEmpty) {
      // 匹配不到时统一提示（多源兜底已覆盖酷狗/B站）
      final msg = player.translation.isEmpty ? '暂无歌词' : '';
      panelChild = Center(
        child: Text(
          msg,
          style: TextStyle(color: Colors.white.withOpacity(0.30), fontSize: 13),
        ),
      );
    } else {
      final current = player.currentLyricIndex;
      panelChild = NotificationListener<UserScrollNotification>(
        onNotification: (n) {
          if (n.direction == ScrollDirection.idle) return false;
          if (!_hasNotified) {
            _hasNotified = true;
            widget.onUserScrollStart();
            // 用户手动滚动 4 秒后恢复自动跟随
            Future.delayed(const Duration(seconds: 4), () {
              _hasNotified = false;
              widget.onUserScrollEnd();
            });
          }
          return false;
        },
        child: ListView.builder(
          controller: widget.controller,
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
          itemExtent: 44,
          itemCount: lyrics.length,
          itemBuilder: (context, i) {
            final active = i == current;
            final trans = player.translationAt(i);
            return GestureDetector(
              onTap: () => player.seek(lyrics[i].time),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      lyrics[i].text.isEmpty ? '♪' : lyrics[i].text,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: active
                            ? Colors.white
                            : Colors.white.withOpacity(0.35),
                        fontSize: active ? 16 : 14,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                        height: 1.4,
                      ),
                    ),
                    if (trans != null && trans.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        trans,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active
                              ? Colors.white.withOpacity(0.75)
                              : Colors.white.withOpacity(0.28),
                          fontSize: active ? 11 : 10,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      height: 280,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withOpacity(0.10),
                Colors.white.withOpacity(0.04),
              ],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.20), width: 1),
            borderRadius: BorderRadius.circular(24),
          ),
          child: panelChild,
        ),
      ),
    );
  }
}

/// 播放模式切换按钮（顺序/随机/单曲循环）
class _PlayModeBar extends StatelessWidget {
  final PlayerState player;
  const _PlayModeBar({required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: () {
              player.togglePlayMode();
              final label = switch (player.playMode) {
                PlayMode.order => '顺序播放',
                PlayMode.shuffle => '随机播放',
                PlayMode.repeatOne => '单曲循环',
              };
              _toast(context, label);
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.10),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.22)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    switch (player.playMode) {
                      PlayMode.order => Icons.repeat,
                      PlayMode.shuffle => Icons.shuffle,
                      PlayMode.repeatOne => Icons.repeat_one,
                    },
                    color: Colors.white.withOpacity(0.8),
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    switch (player.playMode) {
                      PlayMode.order => '顺序播放',
                      PlayMode.shuffle => '随机播放',
                      PlayMode.repeatOne => '单曲循环',
                    },
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.75),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用 toast 提示
void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white)),
      backgroundColor: Colors.black.withOpacity(0.6),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// 播放页转场：从底部向上滑入（迷你播放条 / 首页一键播放共用）
Route<T> playerRoute<T>() {
  return PageRouteBuilder(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, anim, __) => const PlayerPage(),
    transitionsBuilder: (_, anim, __, child) {
      final tween = Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).chain(CurveTween(curve: Curves.easeOutCubic));
      return SlideTransition(position: anim.drive(tween), child: child);
    },
  );
}

/// 播放页红心：点击弹跳脉冲 + 收藏切换（双写语义）
class _BouncingHeart extends StatefulWidget {
  final PlayerState player;
  final Song song;
  const _BouncingHeart({required this.player, required this.song});

  @override
  State<_BouncingHeart> createState() => _BouncingHeartState();
}

class _BouncingHeartState extends State<_BouncingHeart> {
  bool _pulse = false;
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    _busy = true;
    // 弹跳脉冲：1.0 → 1.3 → 1.0
    if (mounted) setState(() => _pulse = true);
    Future.delayed(const Duration(milliseconds: 130), () {
      if (mounted) setState(() => _pulse = false);
    });
    final loggedIn = context.read<AuthState>().loggedIn;
    final result = await widget.player.toggleFavorite(
      widget.song,
      loggedIn: loggedIn,
    );
    _busy = false;
    if (!mounted) return;
    // B站/酷狗歌只做本地收藏，无提示；'ok' 已同步网易云，静默
    if (widget.song.isBilibili || widget.song.isKugou || result == 'ok') {
      return;
    }
    if (result == 'local') {
      _toast(context, '未登录，仅本地收藏');
    } else if (result == 'error') {
      _toast(context, '网络异常，仅本地收藏');
    }
  }

  @override
  Widget build(BuildContext context) {
    final fav = widget.player.isFavorite(widget.song);
    return GestureDetector(
      onTap: _toggle,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pulse ? 1.3 : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: _pulse ? Curves.easeOut : Curves.easeOutBack,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            fav ? Icons.favorite : Icons.favorite_border,
            color: fav ? const Color(0xFFE05A8A) : Colors.white70,
            size: 24,
          ),
        ),
      ),
    );
  }
}
