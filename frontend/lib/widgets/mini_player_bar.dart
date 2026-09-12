/// 底部迷你播放条（毛玻璃，点击进播放页）
/// 极简白色档：居中「播放胶囊」（周围透出暖白背景）
/// 极简暗色档：整条扁平实色
library;

import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../pages/player_page.dart';
import '../state/player_state.dart';
import '../state/ui_settings.dart';
import 'tap_scale.dart';

class MiniPlayerBar extends StatelessWidget implements PreferredSizeWidget {
  const MiniPlayerBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerState>();
    final song = player.current;

    // 展开/收起平滑动画（无歌时收起为 0 高度）
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.bottomCenter,
      child: song == null
          ? const SizedBox(width: double.infinity)
          : _Bar(player: player, song: song),
    );
  }
}

class _Bar extends StatelessWidget {
  final PlayerState player;
  final Song song;

  const _Bar({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    // 上滑恢复：累计上滑距离（dy<0），松手超过阈值拉起播放页（与点击并存）
    double upAccum = 0;
    return GestureDetector(
      onTap: () async {
        if (!context.mounted) return;
        Navigator.of(context).push(playerRoute());
      },
      onVerticalDragUpdate: (d) {
        // 上滑累计，下滑清零
        upAccum = d.delta.dy < 0 ? upAccum - d.delta.dy : 0;
      },
      onVerticalDragEnd: (_) {
        if (upAccum > 60 && context.mounted) {
          upAccum = 0;
          Navigator.of(context).push(playerRoute());
        }
      },
      child: ListenableBuilder(
        listenable: uiStyle,
        builder: (context, _) {
          final plain = uiStyle.value == UiStyle.plain;
          final light = isLight;
          return Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              // 浅色档：外层不渲染阴影，两侧干净透出背景
              boxShadow: light
                  ? const []
                  : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: plain || light ? 12 : 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
            ),
            child: light
                // 极简白色档：透明播放胶囊（透出底下列表，左右留白）
                ? Container(
                    margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      // 胶囊本体白底；两侧区域由 Stack 悬浮露出底下列表
                      color: const Color(0xFFFFFFFF),
                      borderRadius: BorderRadius.circular(36),
                      border: Border.all(
                        color: const Color(0xFFE4E3DD),
                        width: 1,
                      ),
                    ),
                    child: _BarContent(player: player, song: song),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: plain
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            color: const Color(0xFF1A1C20),
                            child: _BarContent(player: player, song: song),
                          )
                        : BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    fgPrimary.withOpacity(0.20),
                                    fgPrimary.withOpacity(0.08),
                                  ],
                                ),
                                border: Border.all(
                                  color: fgPrimary.withOpacity(0.28),
                                  width: 1,
                                ),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: _BarContent(
                                player: player,
                                song: song,
                              ),
                            ),
                          ),
                  ),
          );
        },
      ),
    );
  }
}

/// 迷你播放条内容（封面 + 歌名 + 播放控制），各风格共用
class _BarContent extends StatelessWidget {
  final PlayerState player;
  final Song song;
  _BarContent({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // 小封面
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: fgPrimary.withOpacity(0.35),
              width: 1,
            ),
          ),
          child: ClipOval(
            child: (player.currentDetail ?? song).cover.isEmpty
                ? Container(
                    color: fgPrimary.withOpacity(0.12),
                    child: Icon(
                      Icons.music_note,
                      color: fgPrimary.withOpacity(0.7),
                      size: 20,
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: (player.currentDetail ?? song).cover,
                    fit: BoxFit.cover,
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                song.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.artistText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fgSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        // 上一首（按压缩放反馈）
        TapScale(
          pressScale: 0.85,
          onTap: player.previous,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              Icons.skip_previous,
              color: fgPrimary.withOpacity(0.85),
              size: 26,
            ),
          ),
        ),
        // 播放/暂停
        _PlayPauseIcon(player: player),
        const SizedBox(width: 8),
        // 下一首（按压缩放反馈）
        TapScale(
          pressScale: 0.85,
          onTap: player.next,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              Icons.skip_next,
              color: fgPrimary.withOpacity(0.85),
              size: 26,
            ),
          ),
        ),
      ],
    );
  }
}

/// 播放/暂停圆形按钮
class _PlayPauseIcon extends StatelessWidget {
  final PlayerState player;
  const _PlayPauseIcon({required this.player});

  @override
  Widget build(BuildContext context) {
    return TapScale(
      pressScale: 0.88,
      onTap: player.togglePlay,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fgPrimary.withOpacity(0.18),
          border: Border.all(color: fgPrimary.withOpacity(0.35), width: 1),
        ),
        child: player.loading
            ? Padding(
                padding: const EdgeInsets.all(10),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(
                    fgPrimary.withOpacity(0.9),
                  ),
                ),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, anim) =>
                    ScaleTransition(scale: anim, child: child),
                child: Icon(
                  player.playing ? Icons.pause : Icons.play_arrow,
                  key: ValueKey(player.playing),
                  color: fgPrimary,
                  size: 24,
                ),
              ),
      ),
    );
  }
}
