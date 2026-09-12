/// 全局 UI 设置（设置页可调，shared_preferences 持久化）
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 界面风格预设
enum UiStyle {
  /// 液态玻璃：封面模糊 + 实时毛玻璃 + 玻璃卡片 + 青绿光效
  glass,

  /// 极简暗色：纯黑背景 + 扁平卡片，无模糊无光效
  plain,

  /// 暗色透明：封面模糊 + 详情页全透明透出下层 + 玻璃卡片
  transparent,

  /// 极简白色（暖白）：白底黑字，全局无玻璃无模糊
  white,
}

/// 当前界面风格（默认液态玻璃）
final ValueNotifier<UiStyle> uiStyle = ValueNotifier<UiStyle>(UiStyle.glass);

/// 歌曲卡片是否渲染毛玻璃背景模糊（默认 false：不渲染，提升列表滚动性能）
final ValueNotifier<bool> songCardBlur = ValueNotifier<bool>(false);

// ---------- 歌单详情页过渡动画三开关（默认全开，可自由组合） ----------

/// 封面飞入（Hero）：封面从列表飞入详情页头部
final ValueNotifier<bool> transitionHero = ValueNotifier<bool>(true);

/// 推入转场：详情页整页上滑淡入 + 缩放，背景模糊渐显
final ValueNotifier<bool> transitionPage = ValueNotifier<bool>(true);

/// 列表递进：歌曲项逐项上浮淡入
final ValueNotifier<bool> transitionStagger = ValueNotifier<bool>(true);

// ---------- 主题色代理：随界面风格切换 ----------

/// 是否为极简白色（浅色主题）
bool get isLight => uiStyle.value == UiStyle.white;

/// 主文字 / 主要图标颜色
Color get fgPrimary => isLight ? const Color(0xFF1A1B1C) : Colors.white;

/// 次文字颜色
Color get fgSecondary => isLight ? const Color(0xFF6B7280) : Colors.white70;

/// 弱文字颜色（占位、说明）
Color get fgTertiary => isLight ? const Color(0xFF9CA3AF) : Colors.white38;

/// 更弱的文字（标签、注释）
Color get fgHint => isLight ? const Color(0xFFB6BAC2) : Colors.white24;

/// 页面根背景
Color get bgBase => isLight ? const Color(0xFFF9FAF4) : Colors.black;

/// 卡片底色（白档=纯白卡片；暗色档=深灰实色）
Color get bgCard => isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1A1C20);

/// 弹窗 / 浮层底色
Color get bgElevated =>
    isLight ? const Color(0xFFF2F1EC) : const Color(0xFF121216);

/// 分隔线 / 描边色
Color get borderColor =>
    isLight ? const Color(0xFFE4E3DD) : Colors.white.withOpacity(0.25);

/// 是否禁用一切玻璃 / 模糊效果（浅色极简档）
bool get noGlass => isLight || uiStyle.value == UiStyle.plain;

/// 启动时加载 UI 设置
Future<void> loadUiSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final styleName = prefs.getString('ui_style');
  uiStyle.value = UiStyle.values.firstWhere(
    (e) => e.name == styleName,
    orElse: () => UiStyle.glass,
  );
  songCardBlur.value = prefs.getBool('song_card_blur') ?? false;
  transitionHero.value = prefs.getBool('transition_hero') ?? true;
  transitionPage.value = prefs.getBool('transition_page') ?? true;
  transitionStagger.value = prefs.getBool('transition_stagger') ?? true;
}

/// 切换「封面飞入」并持久化
Future<void> setTransitionHero(bool value) async {
  transitionHero.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('transition_hero', value);
}

/// 切换「推入转场」并持久化
Future<void> setTransitionPage(bool value) async {
  transitionPage.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('transition_page', value);
}

/// 切换「列表递进」并持久化
Future<void> setTransitionStagger(bool value) async {
  transitionStagger.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('transition_stagger', value);
}

/// 切换界面风格并持久化
Future<void> setUiStyle(UiStyle style) async {
  uiStyle.value = style;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ui_style', style.name);
}

/// 切换歌曲卡片毛玻璃并持久化
Future<void> setSongCardBlur(bool value) async {
  songCardBlur.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('song_card_blur', value);
}
