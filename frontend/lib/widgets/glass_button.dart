/// 通用玻璃按钮组件（圆形悬浮玻璃质感）
library;

import 'dart:ui';

import 'package:flutter/material.dart';

class GlassButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double size;
  final double blurSigma;
  final double borderWidth;
  final Color? iconColor;
  final Color? background;

  const GlassButton({
    super.key,
    required this.child,
    this.onTap,
    this.size = 56,
    this.blurSigma = 20,
    this.borderWidth = 1,
    this.iconColor,
    this.background,
  });

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 点击缩放反馈：按下 0.92，松开弹回 1.0
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          child: InkResponse(
            onTap: widget.onTap,
            radius: widget.size * 0.75,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipOval(
                child: BackdropFilter(
                  filter:
                      ImageFilter.blur(sigmaX: widget.blurSigma, sigmaY: widget.blurSigma),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          (widget.background ?? Colors.white).withOpacity(0.28),
                          (widget.background ?? Colors.white).withOpacity(0.08),
                        ],
                      ),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.35),
                        width: widget.borderWidth,
                      ),
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 玻璃图标按钮（快捷封装）
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? color;

  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 48,
    this.iconSize = 24,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GlassButton(
      onTap: onTap,
      size: size,
      child: Icon(icon, size: iconSize, color: color ?? Colors.white),
    );
  }
}
