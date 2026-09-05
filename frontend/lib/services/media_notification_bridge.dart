/// 自定义媒体通知桥接（Part 2）
///
/// 通过 MethodChannel "liquid_music/media_notification" 与原生 Kotlin 通信：
/// - Dart → 原生：update（歌曲信息/播放状态/收藏状态/当前歌词行/进度）
/// - 原生 → Dart：onAction（通知栏按钮点击：prev/toggle/next/favorite）
///
/// 原生侧用相同通知 ID（1124）覆盖 audio_service 的默认通知，
/// 实现带歌词行 + 收藏按钮的自定义 RemoteViews 媒体通知。
library;

import 'package:flutter/services.dart';

import '../state/player_state.dart';

class MediaNotificationBridge {
  static const MethodChannel _channel =
      MethodChannel('liquid_music/media_notification');

  /// 登录态获取器（决定收藏是否同步网易云），由 main() 注入
  static bool Function()? loggedInGetter;

  static PlayerState? _player;
  static int _lastPushMs = 0;
  static int _lastLyricIndex = -2;

  static void init(PlayerState player, {bool Function()? loggedIn}) {
    _player = player;
    loggedInGetter = loggedIn;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onAction') return;
      final ps = _player;
      if (ps == null) return;
      final action = call.arguments as String?;
      switch (action) {
        case 'prev':
          await ps.previous();
          break;
        case 'toggle':
          await ps.togglePlay();
          break;
        case 'next':
          await ps.next();
          break;
        case 'favorite':
          final song = ps.current;
          if (song != null) {
            await ps.toggleFavorite(song,
                loggedIn: loggedInGetter?.call() ?? false);
          }
          break;
      }
    });
  }

  /// 推送当前播放状态到原生通知
  ///
  /// [force]=true 跳过节流（切歌/播放暂停/收藏变化立即生效）；
  /// 否则约 1 秒最多一次（歌词行变化也会立即推送）。
  /// 原生侧用标准 MediaStyle 媒体通知（非 RemoteViews），
  /// 附加"收藏"按钮；系统控制按钮由 MediaSession 提供，上岛正常。
  static void push({bool force = false}) {
    final ps = _player;
    final song = ps?.current;
    if (ps == null || song == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final lyricIndex = ps.currentLyricIndex;
    final lyricChanged = lyricIndex != _lastLyricIndex;
    if (!force && !lyricChanged && now - _lastPushMs < 900) return;
    _lastPushMs = now;
    _lastLyricIndex = lyricIndex;

    final detail = ps.currentDetail;
    final cover =
        (detail != null && detail.cover.isNotEmpty) ? detail.cover : song.cover;
    final lyricText = (lyricIndex >= 0 && lyricIndex < ps.lyrics.length)
        ? ps.lyrics[lyricIndex].text
        : '';

    _channel.invokeMethod('update', {
      'title': song.name,
      'artist': song.artists.join(' / '),
      'album': song.album,
      'cover': cover,
      'isPlaying': ps.playing,
      'isFavorite': ps.isFavorite(song),
      'lyric': lyricText,
      'positionMs': ps.position.inMilliseconds,
      'durationMs': ps.duration.inMilliseconds,
    }).catchError((_) {});
  }
}
