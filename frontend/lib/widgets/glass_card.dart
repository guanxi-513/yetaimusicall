/// 通用玻璃卡片组件：BackdropFilter 毛玻璃 + 半透明白 + 高光描边
/// 极简暗色档：扁平实色卡片（无模糊、小圆角）
/// 极简白色档：白底浅边卡片（无模糊）
library;

import 'dart:ui';

import 'package:flutter/material.dart';

import '../state/ui_settings.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double blurSigma;

  /// 是否渲染 BackdropFilter 背景模糊；false 时只画半透明卡片（省性能）
  final bool blur;
  final Color? color;
  final VoidCallback? onTap;
  final double borderWidth;

  const GlassCard({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.blurSigma = 20,
    this.blur = true,
    this.color,
    this.onTap,
    this.borderWidth = 1,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: uiStyle,
      builder: (context, _) {
        final plain = uiStyle.value == UiStyle.plain;
        final light = isLight;
        final radius = plain ? 12.0 : borderRadius;
        final inner = Container(
          padding: padding,
          decoration: BoxDecoration(
            color: light ? bgCard : (plain ? Color(0xFF1A1C20) : color),
            gradient: !plain && !light && color == null
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      fgPrimary.withOpacity(0.18),
                      fgPrimary.withOpacity(0.06),
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: light
                  ? const Color(0xFFE4E3DD)
                  : plain
                      ? fgPrimary.withOpacity(0.08)
                      : fgPrimary.withOpacity(0.25),
              width: light || plain ? 1 : borderWidth,
            ),
            boxShadow: light || plain
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          child: child,
        );
        final body = Container(
          margin: margin,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: (blur && !plain && !light)
                ? BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: blurSigma,
                      sigmaY: blurSigma,
                    ),
                    child: inner,
                  )
                : inner,
          ),
        );
        if (onTap == null) return body;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            child: body,
          ),
        );
      },
    );
  }
}
