/// 底部迷你播放条（毛玻璃，点击进播放页）
library;

import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../pages/player_page.dart';
import '../state/player_state.dart';

class MiniPlayerBar extends StatelessWidget implements PreferredSizeWidget {
  const MiniPlayerBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerState>();
    final song = player.current;
    if (song == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        PageRouteBuilder(
          opaque: false,
          transitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (_, anim, __) => FadeTransition(
            opacity: anim,
            child: const PlayerPage(),
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withOpacity(0.20),
                    Colors.white.withOpacity(0.08),
                  ],
                ),
                border: Border.all(color: Colors.white.withOpacity(0.28), width: 1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  // 小封面
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: Colors.white.withOpacity(0.35), width: 1),
                    ),
                    child: ClipOval(
                      child: (player.currentDetail ?? song).cover.isEmpty
                          ? Container(
                              color: Colors.white.withOpacity(0.12),
                              child: Icon(Icons.music_note,
                                  color: Colors.white.withOpacity(0.7), size: 20),
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
                          style: const TextStyle(
                            color: Colors.white,
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
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 上一首
                  GestureDetector(
                    onTap: player.previous,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.skip_previous,
                        color: Colors.white.withOpacity(0.85),
                        size: 26,
                      ),
                    ),
                  ),
                  // 播放/暂停
                  _PlayPauseIcon(player: player),
                  const SizedBox(width: 8),
                  // 下一首
                  GestureDetector(
                    onTap: player.next,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.skip_next,
                        color: Colors.white.withOpacity(0.85),
                        size: 26,
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
  }
}

class _PlayPauseIcon extends StatelessWidget {
  final PlayerState player;
  const _PlayPauseIcon({required this.player});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: player.togglePlay,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.18),
          border: Border.all(color: Colors.white.withOpacity(0.35), width: 1),
        ),
        child: player.loading
            ? Padding(
                padding: const EdgeInsets.all(10),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.white.withOpacity(0.9)),
                ),
              )
            : Icon(
                player.playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 24,
              ),
      ),
    );
  }
}
