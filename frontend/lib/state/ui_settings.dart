/// 全局 UI 设置（设置页可调，shared_preferences 持久化）
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 歌曲卡片是否渲染毛玻璃背景模糊（默认 false：不渲染，提升列表滚动性能）
final ValueNotifier<bool> songCardBlur = ValueNotifier<bool>(false);

/// 启动时加载 UI 设置
Future<void> loadUiSettings() async {
  final prefs = await SharedPreferences.getInstance();
  songCardBlur.value = prefs.getBool('song_card_blur') ?? false;
}

/// 切换歌曲卡片毛玻璃并持久化
Future<void> setSongCardBlur(bool value) async {
  songCardBlur.value = value;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('song_card_blur', value);
}
