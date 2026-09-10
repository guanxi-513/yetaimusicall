import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 主页面截图 key：挂在首页 RepaintBoundary 上
final GlobalKey pageSnapshotKey = GlobalKey();

/// 歌单详情页截图 key：挂在详情页 RepaintBoundary 上
/// 与 pageSnapshotKey 互斥使用——详情页打开时 capturePageSnapshot 优先用它
final GlobalKey detailSnapshotKey = GlobalKey();

/// 当前持有的背景截图（全局只允许一张）
ui.Image? cachedPageSnapshot;

/// 截取当前页面 → 半分辨率（省内存、模糊后无差别）
/// 优先尝试详情页 key（在详情页打开时截图），fallback 到首页 key
Future<ui.Image?> capturePageSnapshot() async {
  for (final key in [detailSnapshotKey, pageSnapshotKey]) {
    final ctx = key.currentContext;
    if (ctx == null) continue;
    final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) continue;
    try {
      return await boundary.toImage(pixelRatio: 0.5); // 半分辨率 ≈ 540×1170
    } catch (_) {
      continue;
    }
  }
  return null;
}

/// 进入新页面/离开播放页时调用：释放旧截图，换新截图
void updatePageSnapshot(ui.Image? newImage) {
  cachedPageSnapshot?.dispose(); // 旧图立即释放（关键，防内存累积）
  cachedPageSnapshot = newImage;
}
