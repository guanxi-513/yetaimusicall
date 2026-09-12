/// 播放页：大封面 + 玻璃控制按钮 + 纤细磨砂进度条 + 歌词自动滚动
library;

import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/song.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../state/ui_settings.dart';
import '../widgets/glass_button.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with TickerProviderStateMixin {
  final ScrollController _lyricController = ScrollController();

  /// 沉浸式歌词专用滚动控制器（与默认面板的控制器分开，
  /// 避免 AnimatedSwitcher 交叉过渡期间同一个 controller 挂到两个 ListView）
  final ScrollController _immersiveLyricController = ScrollController();
  int _lastLyricIndex = -1;
  bool _userScrolling = false;

  // ---------- 沉浸式歌词布局（仅 glass 档生效） ----------
  static const String _immersivePrefsKey = 'player_layout_immersive';
  bool _immersive = false;

  /// 沉浸式歌词字号缩放（小 0.85 / 中 1.0 / 大 1.15）
  static const String _lyricScalePrefsKey = 'immersive_lyric_font_scale';
  double _lyricScale = 1.0;

  /// 是否实际处于沉浸式（偏好开启 + 当前为 glass 档）
  bool get _immersiveActive => _immersive && uiStyle.value == UiStyle.glass;

  /// 进入/退出沉浸式的交叉过渡动画
  late final AnimationController _immerseCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
    value: 0,
  );
  late final Animation<double> _immerseCurve = CurvedAnimation(
    parent: _immerseCtrl,
    curve: Curves.easeInOutCubic,
  );

  // ---------- 下拉关闭 ----------
  /// ValueNotifier：拖动只更新变换层，不 setState 重建整页（性能优化）
  final ValueNotifier<double> _dy = ValueNotifier(0);

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

  @override
  void initState() {
    super.initState();
    // 过渡期间逐帧重建（仅 400ms），结束后不再 rebuild
    _immerseCtrl.addListener(_onImmerseTick);
    _loadImmersivePref();
  }

  Future<void> _loadImmersivePref() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_immersivePrefsKey) ?? false;
    final savedScale = prefs.getDouble(_lyricScalePrefsKey) ?? 1.0;
    if (!mounted) return;
    setState(() {
      _immersive = saved;
      _lyricScale = savedScale;
      // 仅 glass 档才直接呈现沉浸式
      if (_immersiveActive) _immerseCtrl.value = 1.0;
    });
  }

  void _onImmerseTick() {
    if (mounted) setState(() {});
  }

  /// 切换默认布局 ↔ 沉浸式布局
  Future<void> _toggleImmersive() async {
    setState(() => _immersive = !_immersive);
    if (_immersiveActive) {
      _immerseCtrl.forward();
    } else {
      _immerseCtrl.reverse();
    }
    // 重置当前歌词行，切换后把当前句重新定位到可视区域中央
    _lastLyricIndex = -1;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final p = context.read<PlayerState>();
      _autoScrollLyrics(p.currentLyricIndex, p.lyrics.length);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_immersivePrefsKey, _immersive);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_closeCtrl.isAnimating) return;
    if (details.delta.dy <= 0) return; // 只响应向下拖动
    _dy.value += details.delta.dy; // 不 setState，避免整页重建
  }

  void _onDragEnd(DragEndDetails details) {
    if (_closeCtrl.isAnimating) return;
    final h = MediaQuery.of(context).size.height;
    if (_dy.value > h * 0.15) {
      // 触发关闭：向下滑出 + 淡出，然后 pop
      _closeCtrl.forward().then((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      // 弹回原位（弹性动画）
      _returnTween = Tween(begin: _dy.value, end: 0.0).animate(
        CurvedAnimation(parent: _returnCtrl, curve: Curves.easeOutBack),
      );
      _returnCtrl.forward(from: 0).whenComplete(() {
        if (mounted) _dy.value = 0;
      });
    }
  }

  @override
  void dispose() {
    _lyricController.dispose();
    _immersiveLyricController.dispose();
    _immerseCtrl.dispose();
    _closeCtrl.dispose();
    _returnCtrl.dispose();
    _dy.dispose();
    super.dispose();
  }

  void _autoScrollLyrics(int index, int total) {
    if (index < 0 || total == 0 || index == _lastLyricIndex) return;
    _lastLyricIndex = index;
    final immersive = _immersiveActive;
    final controller = immersive ? _immersiveLyricController : _lyricController;
    if (_userScrolling || !controller.hasClients) return;
    // 默认面板每行 44，固定偏上 120；沉浸式每行固定 itemExtent（与 _ImmersiveLyrics 的
    // itemExtent 完全一致），当前行垂直居中——避免自适应行高导致滚动错位
    if (immersive) {
      final rowH = 64.0 * _lyricScale;
      final viewport = controller.position.viewportDimension;
      final bias = (viewport / 2 - rowH / 2).clamp(0.0, double.maxFinite);
      final target = (index * rowH - bias).clamp(0.0, double.maxFinite);
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      // 每行高度约 44，滚动让当前行处于中间偏上
      final target = (index * 44.0 - 120).clamp(0.0, double.maxFinite);
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerState>();
    final song = player.currentDetail ?? player.current;
    _autoScrollLyrics(player.currentLyricIndex, player.lyrics.length);

    // 下拉关闭：手指拖动整页下移 + 透明度渐降 + 微缩放
    return ListenableBuilder(
      listenable: uiStyle,
      builder: (context, _) {
        final immersiveActive = _immersiveActive;
        return GestureDetector(
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: AnimatedBuilder(
            animation: Listenable.merge([_dy, _closeCtrl, _returnCtrl]),
            // child 缓存：拖动/关闭动画只重算变换，不重建页面内容
            // RepaintBoundary：拖动时整页作为缓存图层平移，模糊背景不逐帧重算
            child: RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 背景：按界面风格渲染（液态玻璃/暗色透明 = 封面模糊；极简暗色 = 纯黑）
                  Positioned.fill(
                    child: ListenableBuilder(
                      listenable: uiStyle,
                      builder: (context, _) {
                        final style = uiStyle.value;
                        final useCoverBlur = style != UiStyle.plain && !isLight;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            AnimatedSwitcher(
                              duration: Duration(milliseconds: 400),
                              child: !useCoverBlur
                                  ? (isLight ? _LightBg() : _PlainBg())
                                  : (song?.cover ?? '').isNotEmpty
                                  ? ImageFiltered(
                                      key: ValueKey('bg-${song!.id}'),
                                      imageFilter: ImageFilter.blur(
                                        sigmaX: 32,
                                        sigmaY: 32,
                                      ),
                                      child: CachedNetworkImage(
                                        imageUrl: song.cover,
                                        fit: BoxFit.cover,
                                        errorWidget: (_, __, ___) =>
                                            _FallbackBg(),
                                      ),
                                    )
                                  : _FallbackBg(),
                            ),
                            // 黑遮罩：保证前景文字可读（极简暗色/极简白色不需要）
                            if (style != UiStyle.plain && !isLight)
                              ColoredBox(
                                color: Color(0x80000000),
                                child: SizedBox.expand(),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  Scaffold(
                    backgroundColor: Colors.transparent,
                    // 沉浸式时隐藏整个 AppBar（顶部工具栏由沉浸层提供）
                    appBar: immersiveActive
                        ? null
                        : AppBar(
                            backgroundColor: Colors.transparent,
                            elevation: 0,
                            centerTitle: true,
                            leading: IconButton(
                              icon: Icon(
                                Icons.keyboard_arrow_down,
                                color: fgPrimary,
                                size: 32,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                            title: Text(
                              song?.name ?? '未在播放',
                              style: TextStyle(
                                color: fgPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            actions: [
                              if (song != null) ...[
                                // 沉浸式歌词切换（仅液态玻璃档显示）
                                if (uiStyle.value == UiStyle.glass)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 2),
                                    child: IconButton(
                                      icon: Icon(
                                        _immersive
                                            ? Icons.lyrics
                                            : Icons.lyrics_outlined,
                                        color: _immersive
                                            ? fgPrimary
                                            : fgPrimary.withOpacity(0.5),
                                        size: 24,
                                      ),
                                      tooltip: '沉浸式歌词',
                                      onPressed: _toggleImmersive,
                                    ),
                                  ),
                                // 音质选择按钮
                                Padding(
                                  padding: EdgeInsets.only(right: 4),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.high_quality,
                                      color: fgPrimary.withOpacity(0.85),
                                      size: 24,
                                    ),
                                    tooltip:
                                        '音质：${_qualityLabel(AppConfig.audioQuality)}',
                                    onPressed: () => _showQualitySheet(context),
                                  ),
                                ),
                                // 播放队列按钮
                                Padding(
                                  padding: EdgeInsets.only(right: 4),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.queue_music,
                                      color: fgPrimary.withOpacity(0.85),
                                      size: 24,
                                    ),
                                    onPressed: () =>
                                        _showQueueSheet(context, player),
                                  ),
                                ),
                                // 爱心（点击弹跳 + 收藏切换）
                                Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: _BouncingHeart(
                                    player: player,
                                    song: song,
                                  ),
                                ),
                              ],
                            ],
                          ),
                    body: SafeArea(
                      bottom: false,
                      child: song == null
                          ? Center(
                              child: Text(
                                '没有正在播放的歌曲',
                                style: TextStyle(color: fgSecondary),
                              ),
                            )
                          : AnimatedSwitcher(
                              duration: const Duration(milliseconds: 400),
                              switchInCurve: Curves.easeInOutCubic,
                              switchOutCurve: Curves.easeInOutCubic,
                              // 默认布局退出时淡出 + 上移；沉浸式占位淡入 + 下移
                              transitionBuilder: (child, anim) {
                                final isDefault =
                                    child.key ==
                                    const ValueKey('default-layout');
                                final begin = isDefault
                                    ? const Offset(0, -0.035)
                                    : const Offset(0, 0.035);
                                return FadeTransition(
                                  opacity: anim,
                                  child: SlideTransition(
                                    position: Tween<Offset>(
                                      begin: begin,
                                      end: Offset.zero,
                                    ).animate(anim),
                                    child: child,
                                  ),
                                );
                              },
                              child: immersiveActive
                                  ? const SizedBox.expand(
                                      key: ValueKey('immersive-placeholder'),
                                    )
                                  : KeyedSubtree(
                                      key: const ValueKey('default-layout'),
                                      child: OrientationBuilder(
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
                                                  Expanded(
                                                    child: _buildRightPanel(
                                                      player,
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : _buildPortrait(player, song),
                                      ),
                                    ),
                            ),
                    ),
                  ),
                  // 沉浸式歌词层（位于 Scaffold 之上 → 歌词/按钮可交互）
                  // 动画进行中或已呈现时挂载；退出动画结束（dismissed）后卸载
                  if (song != null &&
                      _immerseCtrl.status != AnimationStatus.dismissed)
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !immersiveActive,
                        // 必须用 Material 包裹：沉浸层在 Scaffold 之外（外层 Stack 兄弟节点），
                        // 若不包裹，Text 拿不到 Material 的 DefaultTextStyle，
                        // Flutter 引擎会给文字画"黄色双下划线"提示（历史双黄线根因）
                        child: Material(
                          type: MaterialType.transparency,
                          child: FadeTransition(
                            opacity: _immerseCurve,
                            child: SlideTransition(
                              // 进入时从下方轻微下移 20px 浮现
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.035),
                                end: Offset.zero,
                              ).animate(_immerseCurve),
                              child: _ImmersiveLayout(
                                player: player,
                                song: song,
                                coverScale: _immerseCurve,
                                controller: _immersiveLyricController,
                                onUserScrollStart: () =>
                                    _userScrolling = true,
                                onUserScrollEnd: () =>
                                    _userScrolling = false,
                                lyricScale: _lyricScale,
                                onFontSizeTap: () =>
                                    _showLyricFontSheet(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 沉浸式顶部工具栏（替代 AppBar，随过渡一起淡入淡出）
                  if (song != null &&
                      _immerseCtrl.status != AnimationStatus.dismissed)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: IgnorePointer(
                        ignoring: !immersiveActive,
                        child: FadeTransition(
                          opacity: _immerseCurve,
                          child: SafeArea(
                            bottom: false,
                            child: Row(
                              children: [
                                IconButton(
                                  icon: Icon(
                                    Icons.keyboard_arrow_down,
                                    color: fgPrimary,
                                    size: 32,
                                  ),
                                  onPressed: () => Navigator.pop(context),
                                ),
                                const Spacer(),
                                // 沉浸式切换按钮
                                Padding(
                                  padding: const EdgeInsets.only(right: 2),
                                  child: IconButton(
                                    icon: Icon(
                                      _immersive
                                          ? Icons.lyrics
                                          : Icons.lyrics_outlined,
                                      color: fgPrimary,
                                      size: 24,
                                    ),
                                    tooltip: '沉浸式歌词',
                                    onPressed: _toggleImmersive,
                                  ),
                                ),
                                // 音质选择按钮
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.high_quality,
                                      color: fgPrimary.withOpacity(0.85),
                                      size: 24,
                                    ),
                                    tooltip:
                                        '音质：${_qualityLabel(AppConfig.audioQuality)}',
                                    onPressed: () => _showQualitySheet(context),
                                  ),
                                ),
                                // 播放队列按钮
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: IconButton(
                                    icon: Icon(
                                      Icons.queue_music,
                                      color: fgPrimary.withOpacity(0.85),
                                      size: 24,
                                    ),
                                    onPressed: () =>
                                        _showQueueSheet(context, player),
                                  ),
                                ),
                                // 爱心（点击弹跳 + 收藏切换）
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: _BouncingHeart(
                                    player: player,
                                    song: song,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            builder: (context, child) {
              // 关闭动画时弹回动画不存在 → 用 _dy；弹回动画播放中 → 用插值
              final dy = _returnCtrl.isAnimating
                  ? (_returnTween?.value ?? 0)
                  : _dy.value;
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
      },
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
          SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildRightPanel(PlayerState player) {
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _SongInfo(
            song: player.currentDetail ?? player.current!,
            quality: player.currentQuality,
          ),
          SizedBox(height: 16),
          _ProgressSection(player: player),
          SizedBox(height: 8),
          _PlayModeBar(player: player),
          SizedBox(height: 8),
          _Controls(player: player),
          SizedBox(height: 16),
          _LyricsPanel(
            player: player,
            controller: _lyricController,
            onUserScrollStart: () => _userScrolling = true,
            onUserScrollEnd: () => _userScrolling = false,
          ),
          SizedBox(height: 24),
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
          margin: EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                fgPrimary.withOpacity(0.18),
                fgPrimary.withOpacity(0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: fgPrimary.withOpacity(0.25), width: 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Text(
                      '播放音质',
                      style: TextStyle(
                        color: fgPrimary,
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

  /// 沉浸式歌词字号弹层（小/中/大 三档）
  void _showLyricFontSheet(BuildContext context) {
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
                fgPrimary.withOpacity(0.18),
                fgPrimary.withOpacity(0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: fgPrimary.withOpacity(0.25), width: 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Text(
                      '歌词字号',
                      style: TextStyle(
                        color: fgPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _lyricFontOption(ctx, 0.85, '小', '更紧凑，一屏更多歌词'),
                  _lyricFontOption(ctx, 1.0, '中', '默认大小'),
                  _lyricFontOption(ctx, 1.15, '大', '更大更清晰'),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 单个字号选项行
  Widget _lyricFontOption(
    BuildContext sheetCtx,
    double scale,
    String label,
    String desc,
  ) {
    final selected = _lyricScale == scale;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      title: Text(
        label,
        style: TextStyle(
          color: selected ? const Color(0xFFE05A8A) : fgPrimary,
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      subtitle: Text(
        desc,
        style: TextStyle(color: fgPrimary.withOpacity(0.45), fontSize: 11),
      ),
      trailing: selected
          ? const Icon(Icons.check_circle, color: Color(0xFFE05A8A), size: 20)
          : null,
      onTap: () async {
        _lyricScale = scale;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(_lyricScalePrefsKey, scale);
        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
        setState(() {});
        // 行高随字号变化，重新定位当前行
        _lastLyricIndex = -1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final p = context.read<PlayerState>();
          _autoScrollLyrics(p.currentLyricIndex, p.lyrics.length);
        });
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
          color: selected ? Color(0xFFE05A8A) : fgPrimary,
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      subtitle: Text(
        desc,
        style: TextStyle(color: fgPrimary.withOpacity(0.45), fontSize: 11),
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
                    fgPrimary.withOpacity(0.18),
                    fgPrimary.withOpacity(0.06),
                  ],
                ),
                border: Border.all(
                  color: fgPrimary.withOpacity(0.25),
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
                      color: fgPrimary.withOpacity(0.3),
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
                          color: fgPrimary.withOpacity(0.8),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '播放队列',
                          style: TextStyle(
                            color: fgPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '共 ${queue.length} 首',
                          style: TextStyle(
                            color: fgPrimary.withOpacity(0.55),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(color: fgPrimary.withOpacity(0.12), height: 1),
                  // 列表
                  Expanded(
                    child: queue.isEmpty
                        ? Center(
                            child: Text(
                              '队列为空',
                              style: TextStyle(
                                color: fgPrimary.withOpacity(0.4),
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
                                      ? fgPrimary.withOpacity(0.10)
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
                                            color: fgPrimary.withOpacity(0.25),
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: s.cover.isEmpty
                                              ? Container(
                                                  color: fgPrimary.withOpacity(
                                                    0.08,
                                                  ),
                                                  child: Icon(
                                                    Icons.music_note,
                                                    color: fgPrimary
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
                                                        color: fgPrimary
                                                            .withOpacity(0.08),
                                                      ),
                                                  errorWidget: (_, __, ___) =>
                                                      Container(
                                                        color: fgPrimary
                                                            .withOpacity(0.08),
                                                        child: Icon(
                                                          Icons.music_note,
                                                          color: fgPrimary
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
                                                    ? fgPrimary
                                                    : fgPrimary.withOpacity(
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
                                                color: fgPrimary.withOpacity(
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
                                          color: fgPrimary.withOpacity(0.8),
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
                      fgPrimary.withOpacity(0.20),
                      fgPrimary.withOpacity(0.05),
                    ],
                  ),
                  border: Border.all(
                    color: fgPrimary.withOpacity(0.32),
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
              border: Border.all(color: fgPrimary.withOpacity(0.25), width: 1),
            ),
            child: ClipOval(
              child: song.cover.isEmpty
                  ? Container(
                      color: isLight ? Color(0xFFEDECE7) : Color(0xFF2A2050),
                      child: Icon(
                        Icons.music_note,
                        color: fgPrimary.withOpacity(0.5),
                        size: size / 3,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: song.cover,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: isLight ? Color(0xFFEDECE7) : Color(0xFF2A2050),
                        child: Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(
                                fgPrimary.withOpacity(0.6),
                              ),
                            ),
                          ),
                        ),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: isLight ? Color(0xFFEDECE7) : Color(0xFF2A2050),
                        child: Icon(
                          Icons.music_note,
                          color: fgPrimary.withOpacity(0.5),
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
              color: isLight ? Color(0xFFEDECE7) : Color(0xFF1A1233),
              border: Border.all(color: fgPrimary.withOpacity(0.5)),
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
  _SongInfo({required this.song, this.quality = ''});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Text(
            song.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fgPrimary,
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
            style: TextStyle(color: fgPrimary.withOpacity(0.60), fontSize: 14),
          ),
          if (quality.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              quality,
              style: TextStyle(
                color: fgPrimary.withOpacity(0.42),
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
      padding: EdgeInsets.symmetric(horizontal: 28),
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
                            Container(color: fgPrimary.withOpacity(0.14)),
                            // 缓冲
                            FractionallySizedBox(
                              widthFactor: bufferedRatio,
                              child: Container(
                                color: fgPrimary.withOpacity(0.28),
                              ),
                            ),
                            // 已播放
                            FractionallySizedBox(
                              widthFactor: ratio,
                              child: Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [fgSecondary, fgPrimary],
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
                  color: fgPrimary.withOpacity(0.55),
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              ),
              if (player.loading)
                Text(
                  '缓冲中…',
                  style: TextStyle(
                    color: fgPrimary.withOpacity(0.45),
                    fontSize: 11,
                  ),
                ),
              if (player.error != null)
                Flexible(
                  child: Text(
                    player.error!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Color(0xFFE05A8A), fontSize: 11),
                  ),
                ),
              Text(
                _fmt(totalMs),
                style: TextStyle(
                  color: fgPrimary.withOpacity(0.55),
                  fontSize: 11,
                  decoration: TextDecoration.none,
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
  _Controls({required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlassIconButton(
            icon: Icons.skip_previous,
            size: 58,
            iconSize: 30,
            onTap: player.previous,
          ),
          SizedBox(width: 28),
          GlassButton(
            size: 78,
            onTap: player.togglePlay,
            child: player.loading
                ? SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(fgPrimary),
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
                      color: fgPrimary,
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
          style: TextStyle(color: fgPrimary.withOpacity(0.30), fontSize: 13),
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
                        color: active ? fgPrimary : fgPrimary.withOpacity(0.35),
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
                              ? fgPrimary.withOpacity(0.75)
                              : fgPrimary.withOpacity(0.28),
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
              colors: isLight
                  ? [const Color(0xFFFFFFFF), const Color(0xFFFDFDFA)]
                  : [fgPrimary.withOpacity(0.10), fgPrimary.withOpacity(0.04)],
            ),
            border: Border.all(
              color: isLight
                  ? const Color(0xFFE4E3DD)
                  : fgPrimary.withOpacity(0.20),
              width: 1,
            ),
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
                color: fgPrimary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: fgPrimary.withOpacity(0.22)),
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
                    color: fgPrimary.withOpacity(0.8),
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
                      color: fgPrimary.withOpacity(0.75),
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

// ==================== 沉浸式歌词布局（仅 glass 档） ====================

/// 沉浸式布局：封面铺满 + 歌词叠加 + 底部信息 + 缩小控制条
class _ImmersiveLayout extends StatelessWidget {
  final PlayerState player;
  final Song song;
  final Animation<double> coverScale;
  final ScrollController controller;
  final VoidCallback onUserScrollStart;
  final VoidCallback onUserScrollEnd;
  final double lyricScale;
  final VoidCallback onFontSizeTap;

  const _ImmersiveLayout({
    required this.player,
    required this.song,
    required this.coverScale,
    required this.controller,
    required this.onUserScrollStart,
    required this.onUserScrollEnd,
    required this.lyricScale,
    required this.onFontSizeTap,
  });

  /// 封面加载失败/为空时的深色渐变兜底（保证白色歌词可读）
  Widget _coverFallback() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF16161A), Color(0xFF070708)],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final quality = player.currentQuality;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. 封面铺满（进入时 0.94 → 1.0 放大浮现）
        Positioned.fill(
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(coverScale),
            child: song.cover.isEmpty
                ? _coverFallback()
                : CachedNetworkImage(
                    imageUrl: song.cover,
                    fit: BoxFit.cover,
                    httpHeaders: kImageHttpHeaders,
                    placeholder: (_, __) => _coverFallback(),
                    errorWidget: (_, __, ___) => _coverFallback(),
                  ),
          ),
        ),
        // 顶部轻暗渐变：黑 35% → 透明
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topInset + 200,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x59000000), Color(0x00000000)],
              ),
            ),
          ),
        ),
        // 底部轻暗渐变：透明 → 黑 55%
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 320,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0x8C000000)],
              ),
            ),
          ),
        ),
        // 全局暗色遮罩：保证白字歌词在任何明暗封面上都可读（黑 22%）
        const Positioned.fill(child: ColoredBox(color: Color(0x38000000))),
        // 2~4. 前景：歌词（中部）+ 底部信息 + 进度 + 缩小控制条
        Padding(
          padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
          child: Column(
            children: [
              // 让出透明 AppBar 的位置
              SizedBox(height: kToolbarHeight),
              Expanded(
                child: Stack(
                  children: [
                    // 歌词区压暗背板：中央最深、向上下渐隐。
                    // 作用：保证歌词在任何明暗封面上都可读，同时上下边缘透出封面保持沉浸感
                    const Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [0.0, 0.18, 0.5, 0.82, 1.0],
                              colors: [
                                Color(0x00000000),
                                Color(0x66000000),
                                Color(0x8C000000),
                                Color(0x66000000),
                                Color(0x00000000),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    _ImmersiveLyrics(
                      player: player,
                      controller: controller,
                      onUserScrollStart: onUserScrollStart,
                      onUserScrollEnd: onUserScrollEnd,
                      lyricScale: lyricScale,
                    ),
                  ],
                ),
              ),
              // 底部信息区：歌名
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              // 作者 + 音质
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      song.artistText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.65),
                        fontSize: 13,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  if (quality.isNotEmpty)
                    Text(
                      '  ·  $quality',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 11,
                        decoration: TextDecoration.none,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _ProgressSection(player: player),
              const SizedBox(height: 8),
              _ImmersiveControls(player: player, onFontSizeTap: onFontSizeTap),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }
}

/// 沉浸式歌词：无背景面板，直接悬浮在封面上；当前行白色高亮 + 胶囊衬底
class _ImmersiveLyrics extends StatefulWidget {
  final PlayerState player;
  final ScrollController controller;
  final VoidCallback onUserScrollStart;
  final VoidCallback onUserScrollEnd;
  final double lyricScale;

  const _ImmersiveLyrics({
    required this.player,
    required this.controller,
    required this.onUserScrollStart,
    required this.onUserScrollEnd,
    required this.lyricScale,
  });

  @override
  State<_ImmersiveLyrics> createState() => _ImmersiveLyricsState();
}

class _ImmersiveLyricsState extends State<_ImmersiveLyrics> {
  bool _hasNotified = false;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final lyrics = player.lyrics;

    if (lyrics.isEmpty) {
      return Center(
        child: Text(
          player.translation.isEmpty ? '暂无歌词' : '',
          style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 14),
        ),
      );
    }

    final current = player.currentLyricIndex;
    return NotificationListener<UserScrollNotification>(
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
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 8),
        // 固定行高：与 _autoScrollLyrics 的 rowH（64×scale）完全一致，
        // 保证跟随滚动精确居中；自适应行高会让滚动位置错位
        itemExtent: 64 * widget.lyricScale,
        itemCount: lyrics.length,
        itemBuilder: (context, i) {
          final active = i == current;
          final trans = player.translationAt(i);
          final scale = widget.lyricScale;
          return GestureDetector(
            onTap: () => player.seek(lyrics[i].time),
            child: Center(
              // 当前行衬底：用“上透→中黑→下透”的垂直羽化渐变，
              // 而不是整块纯色——避免衬底上下硬边在亮封面上夹出两条亮线（双黄线）
              child: Container(
                height: 64 * scale,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: active
                      ? const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x00000000),
                            Color(0x73000000),
                            Color(0x00000000),
                          ],
                        )
                      : null,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      lyrics[i].text.isEmpty ? '♪' : lyrics[i].text,
                      textAlign: TextAlign.center,
                      // 最多两行，长歌词自动换行不再截断
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: active
                            ? Colors.white
                            : Colors.white.withOpacity(0.55),
                        fontSize: (active ? 19 : 14) * scale,
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        height: 1.25,
                        // 显式禁用下划线：防任何 DefaultTextStyle 继承（双黄线历史问题）
                        decoration: TextDecoration.none,
                        // 不渲染阴影：避免 Android 阴影伪影（黄线/脏字）
                      ),
                    ),
                    if (trans != null && trans.isNotEmpty)
                      Text(
                        trans,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(active ? 0.85 : 0.4),
                          fontSize: (active ? 11 : 10) * scale,
                          height: 1.15,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 沉浸式底部控制条：按钮缩小（侧键 40/图标30，播放键 48/图标26）
class _ImmersiveControls extends StatelessWidget {
  final PlayerState player;
  final VoidCallback onFontSizeTap;
  const _ImmersiveControls({required this.player, required this.onFontSizeTap});

  Widget _circle(
    double size,
    Widget child,
    VoidCallback onTap, {
    double background = 0.12,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(background),
          border: Border.all(color: Colors.white.withOpacity(0.35)),
        ),
        child: Center(child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 紧凑播放模式（保留顺序/随机/单曲循环功能）
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
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: Icon(
                  switch (player.playMode) {
                    PlayMode.order => Icons.repeat,
                    PlayMode.shuffle => Icons.shuffle,
                    PlayMode.repeatOne => Icons.repeat_one,
                  },
                  color: Colors.white.withOpacity(0.85),
                  size: 20,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          _circle(
            40,
            const Icon(Icons.skip_previous, size: 30, color: Colors.white),
            player.previous,
          ),
          const SizedBox(width: 18),
          _circle(
            48,
            player.loading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : Icon(
                    player.playing ? Icons.pause : Icons.play_arrow,
                    size: 26,
                    color: Colors.white,
                  ),
            player.togglePlay,
            background: 0.18,
          ),
          const SizedBox(width: 18),
          _circle(
            40,
            const Icon(Icons.skip_next, size: 30, color: Colors.white),
            player.next,
          ),
          const SizedBox(width: 14),
          // 歌词字号调节（与左侧播放模式等宽，保持播放键视觉居中）
          GestureDetector(
            onTap: onFontSizeTap,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: Text(
                  'Aa',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
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
      content: Text(msg, style: TextStyle(color: fgPrimary)),
      backgroundColor: isLight
          ? const Color(0xFFEDECE7)
          : Colors.black.withOpacity(0.6),
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
            color: fav ? Color(0xFFE05A8A) : fgSecondary,
            size: 24,
          ),
        ),
      ),
    );
  }
}

/// 播放页极简暗色档背景（纯黑微渐变）
class _PlainBg extends StatelessWidget {
  const _PlainBg();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF000000), Color(0xFF0A0A0C)],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

/// 播放页极简白色档背景（暖白微渐变）
class _LightBg extends StatelessWidget {
  const _LightBg();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFDFDFA), Color(0xFFF9FAF4)],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

/// 播放页无封面时的兜底背景（黑底 + 左侧青绿弥散光，与全局风格一致）
class _FallbackBg extends StatelessWidget {
  const _FallbackBg();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF000000), Color(0xFF0A0A0C), Color(0xFF0D0D10)],
        ),
      ),
      child: Stack(
        children: [
          // 左侧青绿弥散光（约 60% 屏宽，与根背景一致）
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
        ],
      ),
    );
  }
}
