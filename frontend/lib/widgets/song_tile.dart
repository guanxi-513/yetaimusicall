/// 通用歌曲行：玻璃卡片（圆形小封面 + 歌名 + 歌手 + 心形收藏）
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../state/ui_settings.dart';
import 'glass_card.dart';
import 'tap_scale.dart';

/// 红心语义（三种独立收藏体系）
enum HeartMode {
  /// 全局（本地或云端任一）：播放页/搜索页/普通歌单/播放历史，双写
  global,

  /// 仅本地收藏：「我的收藏」tab，只翻转本地
  local,

  /// 仅云端喜欢：网易云"我喜欢的音乐"详情，只翻转云端
  cloud,
}

class SongTile extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int? index;

  /// 是否以"榜单排名"样式渲染序号（第 1 名金色大号、2-3 名银白、其余常规）
  final bool rankMode;

  /// 红心语义，默认全局双写
  final HeartMode heartMode;

  /// cloud 模式下取消喜欢成功后回调（用于把歌曲从列表移除）
  final VoidCallback? onCloudUnlike;

  const SongTile({
    super.key,
    required this.song,
    required this.queue,
    this.index,
    this.rankMode = false,
    this.heartMode = HeartMode.global,
    this.onCloudUnlike,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerState>();
    final isCurrent = player.current?.id == song.id;
    // 按红心语义读取对应的收藏集合
    final isFav = switch (heartMode) {
      HeartMode.local => player.isLocalFavorite(song),
      HeartMode.cloud => player.isCloudFavorite(song),
      HeartMode.global => player.isFavorite(song),
    };

    // 列表项 stagger 淡入：按 index 递延 40ms，只在首次构建时播一次
    // 卡片毛玻璃开关在设置页「自定义界面」可调，默认关闭（省性能）
    final card = ValueListenableBuilder<bool>(
      valueListenable: songCardBlur,
      builder: (_, blur, __) => GlassCard(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        borderRadius: 16,
        blur: blur,
        color: isCurrent ? fgPrimary.withOpacity(0.20) : null,
        onTap: () => player.play(song, queue: queue),
        child: Row(
        children: [
          // 序号（可选）
          if (index != null) ...[
            SizedBox(
              width: rankMode ? 30 : 26,
              child: _RankNumber(
                rank: index!,
                rankMode: rankMode,
                highlight: isCurrent,
              ),
            ),
          ],
          // 圆形小封面
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: fgPrimary.withOpacity(0.3), width: 1),
            ),
            child: ClipOval(
              child: song.cover.isEmpty
                  ? Container(
                      color: fgPrimary.withOpacity(0.10),
                      child: Icon(
                        Icons.music_note,
                        color: fgPrimary.withOpacity(0.6),
                        size: 20,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: song.cover,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: fgPrimary.withOpacity(0.10),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: fgPrimary.withOpacity(0.10),
                        child: Icon(
                          Icons.music_note,
                          color: fgPrimary.withOpacity(0.6),
                          size: 20,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          // 歌名 + 歌手
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fgPrimary,
                    fontSize: 15,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  song.artistText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fgPrimary.withOpacity(0.55),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          // 时长
          if (song.duration > 0) ...[
            const SizedBox(width: 6),
            Text(
              song.durationText,
              style: TextStyle(
                color: fgPrimary.withOpacity(0.40),
                fontSize: 11,
              ),
            ),
          ],
          // 心形收藏
          const SizedBox(width: 4),
          _FavoriteButton(
            song: song,
            isFav: isFav,
            heartMode: heartMode,
            onCloudUnlike: onCloudUnlike,
          ),
          // 播放中动效
          if (isCurrent && player.playing) ...[
            const SizedBox(width: 2),
            Icon(
              Icons.graphic_eq,
              color: fgPrimary.withOpacity(0.8),
              size: 16,
            ),
          ],
        ],
      ),
    ),
    );

    // 按压缩放反馈（不接管点击，点击仍由 GlassCard 内部处理）
    final scaled = TapScale(pressScale: 0.98, child: card);
    if (index == null) return scaled;
    // 列表递进开关：关闭时立即显示，不建任何动画
    return ValueListenableBuilder<bool>(
      valueListenable: transitionStagger,
      builder: (_, stagger, __) {
        if (!stagger) return scaled;
        // stagger：从下方 16px 上浮 + 淡入 + 轻微缩放，间隔 40ms。
        // TweenAnimationBuilder 只在首次构建播一次（滚动新建的项会各自播）
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 300),
          curve: Interval(
            (index! * 0.04).clamp(0.0, 0.6),
            1.0,
            curve: Curves.easeOutCubic,
          ),
          builder: (context, v, child) => Opacity(
            opacity: v,
            child: Transform.translate(
              offset: Offset(0, (1 - v) * 16),
              child: Transform.scale(scale: 0.98 + 0.02 * v, child: child),
            ),
          ),
          child: scaled,
        );
      },
    );
  }
}

/// 序号/排名样式
class _RankNumber extends StatelessWidget {
  final int rank;
  final bool rankMode;
  final bool highlight;
  const _RankNumber({
    required this.rank,
    required this.rankMode,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    if (!rankMode) {
      return Text(
        '$rank',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: highlight ? fgPrimary : fgPrimary.withOpacity(0.45),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    // 榜单排名：第 1 名金色大号，2-3 名银白，其余常规
    Color color;
    double fontSize;
    FontWeight weight;
    if (rank == 1) {
      color = const Color(0xFFFFD54A);
      fontSize = 20;
      weight = FontWeight.w800;
    } else if (rank <= 3) {
      color = const Color(0xFFE0E0E0);
      fontSize = 17;
      weight = FontWeight.w700;
    } else {
      color = highlight ? fgPrimary : fgPrimary.withOpacity(0.45);
      fontSize = 14;
      weight = FontWeight.w600;
    }
    return Text(
      '$rank',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: weight,
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  final Song song;
  final bool isFav;
  final HeartMode heartMode;
  final VoidCallback? onCloudUnlike;
  const _FavoriteButton({
    required this.song,
    required this.isFav,
    required this.heartMode,
    this.onCloudUnlike,
  });

  @override
  Widget build(BuildContext context) {
    // TapScale：按压缩放 + 点击弹跳脉冲（爱心点赞效果）
    return TapScale(
      pulseOnTap: true,
      pressScale: 0.85,
      onTap: () async {
        final player = context.read<PlayerState>();
        String result;
        switch (heartMode) {
          case HeartMode.local:
            // 「我的收藏」tab：只翻转本地，无云端提示
            result = await player.toggleFavoriteLocal(song);
            break;
          case HeartMode.cloud:
            // 网易云喜欢列表：只翻转云端
            result = await player.toggleFavoriteCloud(song);
            if (!context.mounted) return;
            if (result == 'ok' && !player.isCloudFavorite(song)) {
              onCloudUnlike?.call(); // 取消成功 → 从列表移除
            }
            break;
          case HeartMode.global:
            final loggedIn = context.read<AuthState>().loggedIn;
            result = await player.toggleFavorite(song, loggedIn: loggedIn);
            break;
        }
        if (!context.mounted) return;
        if (heartMode == HeartMode.global) {
          // B站/酷狗/QQ歌只做本地收藏，无提示；'ok' 已同步网易云，静默
          if (song.isBilibili || song.isKugou || song.isQQ || result == 'ok') {
            return;
          }
          if (result == 'local') {
            _toast(context, '未登录，仅本地收藏');
          } else if (result == 'error') {
            _toast(context, '网络异常，仅本地收藏');
          }
        } else if (heartMode == HeartMode.cloud && result == 'error') {
          _toast(context, '网络异常，操作失败');
        }
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          isFav ? Icons.favorite : Icons.favorite_border,
          color: isFav ? Color(0xFFE05A8A) : fgPrimary.withOpacity(0.5),
          size: 20,
        ),
      ),
    );
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: TextStyle(color: fgPrimary)),
        backgroundColor: isLight
            ? const Color(0xFFEDECE7)
            : Colors.black.withOpacity(0.6),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

