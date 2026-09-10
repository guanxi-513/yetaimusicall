/// 根背景：纯黑底 + 左侧青绿弥散光（Spotify 极简暗色风）
/// 青绿光从左边缘弥散到约 60% 宽度；仅用于 App 根外壳背景
library;

import 'package:flutter/material.dart';

class SpotifyBackground extends StatelessWidget {
  final Widget child;
  const SpotifyBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF000000), // 纯黑
            Color(0xFF0A0A0C), // 深炭灰
            Color(0xFF0D0D10),
          ],
        ),
      ),
      child: Stack(
        children: [
          // 左侧青绿弥散光（弥散到约 60% 屏宽）
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: MediaQuery.sizeOf(context).width * 0.6,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      const Color(0xFF1DB954).withOpacity(0.40),
                      const Color(0xFF1DB954).withOpacity(0.10),
                      const Color(0xFF1DB954).withOpacity(0),
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}
