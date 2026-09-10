/// 点击缩放反馈组件：按下缩到 [pressScale]，松开弹回 1.0
///
/// - [onTap] 为点击回调（可为 null，仅做按压视觉反馈）
/// - [pulseOnTap] 为 true 时点击后做一次 1.0 → 1.25 → 1.0 的弹跳
///   （点赞/爱心效果），与按压缩放叠加
library;

import 'package:flutter/material.dart';

class TapScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  /// 按下时的缩放比例
  final double pressScale;

  /// 点击后是否播放弹跳脉冲（爱心点赞效果）
  final bool pulseOnTap;

  const TapScale({
    super.key,
    required this.child,
    this.onTap,
    this.pressScale = 0.92,
    this.pulseOnTap = false,
  });

  @override
  State<TapScale> createState() => _TapScaleState();
}

class _TapScaleState extends State<TapScale> {
  bool _pressed = false;
  bool _pulsing = false;

  double get _scale {
    if (_pulsing) return 1.25;
    if (_pressed) return widget.pressScale;
    return 1.0;
  }

  void _handleTap() {
    widget.onTap?.call();
    if (!widget.pulseOnTap) return;
    // 1.0 → 1.25 → 1.0 脉冲
    setState(() => _pulsing = true);
    Future.delayed(const Duration(milliseconds: 130), () {
      if (!mounted) return;
      setState(() => _pulsing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 130),
        curve: _pulsing ? Curves.easeOut : Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
