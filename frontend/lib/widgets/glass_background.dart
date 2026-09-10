/// 深色弥散渐变背景（深空蓝紫 → 暗粉柔光光斑）
/// 用于播放页 / 歌单详情页的"无截图"兜底背景
library;

import 'package:flutter/material.dart';

class GlassBackground extends StatelessWidget {
  final Widget child;
  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF12102A), // 深空蓝紫
            Color(0xFF1A1233),
            Color(0xFF20122E),
          ],
        ),
      ),
      child: Stack(
        children: [
          // 柔光光斑层
          Positioned(
            top: -120,
            left: -80,
            child: _Blob(
              size: 340,
              color: const Color(0xFF6C4FE0).withOpacity(0.45), // 紫光斑
            ),
          ),
          Positioned(
            top: 80,
            right: -100,
            child: _Blob(
              size: 300,
              color: const Color(0xFFE05A8A).withOpacity(0.30), // 暗粉光斑
            ),
          ),
          Positioned(
            bottom: -140,
            left: 40,
            child: _Blob(
              size: 380,
              color: const Color(0xFF3A2E8C).withOpacity(0.40),
            ),
          ),
          Positioned(
            bottom: 60,
            right: -60,
            child: _Blob(
              size: 260,
              color: const Color(0xFF8C3F6B).withOpacity(0.28),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final double size;
  final Color color;
  const _Blob({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withOpacity(0)],
        ),
      ),
    );
  }
}
