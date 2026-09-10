/// audio_service 桥接层
///
/// [LiquidAudioHandler] 继承 BaseAudioHandler，内部共享 PlayerState 持有的
/// just_audio 播放器实例（不新建），把播放状态/进度/当前歌曲广播给系统
/// （通知栏 / 锁屏 / 耳机线控 / 车机）。
///
/// 职责边界：
/// - 队列管理、播放模式、流地址解析仍在 PlayerState（"大脑"）
/// - 本类只做"广播员 + 遥控入口"：
///   - 广播：playbackState / mediaItem
///   - 遥控：skipToNext / skipToPrevious 转发给 PlayerState
library;

import 'package:audio_service/audio_service.dart';
// just_audio 也导出 PlayerState（播放器状态事件类），hide 掉避免与本项目
// 的 state/player_state.dart PlayerState 混淆
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../models/song.dart';
import '../state/player_state.dart';

class LiquidAudioHandler extends BaseAudioHandler {
  AudioPlayer? _player;
  PlayerState? _state;

  /// 绑定 PlayerState（共享其 AudioPlayer 实例）
  void bind(PlayerState state) {
    if (_state != null) return; // 只绑定一次
    _state = state;
    _player = state.player;

    // 播放/暂停状态变化 → 广播（通知栏图标、锁屏状态）
    _player!.playerStateStream.listen((_) => _syncPlaybackState());
    _player!.processingStateStream.listen((_) => _syncPlaybackState());
    // 进度/缓冲 → 广播（通知栏进度条）
    _player!.positionStream.listen((pos) {
      final value = playbackState.value;
      playbackState.add(value.copyWith(
        updatePosition: pos,
        bufferedPosition: _player!.bufferedPosition,
      ));
    });
    _syncPlaybackState();
  }

  AudioPlayer get player => _player!;

  // ---------- 系统遥控入口（通知栏/锁屏/耳机按钮触发） ----------

  @override
  Future<void> play() => _player?.play() ?? Future.value();

  @override
  Future<void> pause() => _player?.pause() ?? Future.value();

  @override
  Future<void> stop() async {
    await _player?.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => _state?.next() ?? Future.value();

  @override
  Future<void> skipToPrevious() => _state?.previous() ?? Future.value();

  @override
  Future<void> seek(Duration position) =>
      _player?.seek(position) ?? Future.value();

  /// App 任务被划掉时的收尾（保留当前默认：交由 native 停止前台服务）
  @override
  Future<void> onTaskRemoved() async {
    if (_player?.playing != true) {
      await stop();
    }
  }

  // ---------- 广播 ----------

  /// 当前歌曲变化时由 PlayerState 调用 → 更新通知/锁屏元数据
  void updateSong(Song song) {
    mediaItem.add(MediaItem(
      id: song.isBilibili
          ? (song.bvid ?? 'bili_${song.id}')
          : song.isKugou
              ? (song.hash ?? 'kg_${song.id}')
              : song.isQQ
                  ? (song.mid ?? 'qq_${song.id}')
                  : '${song.id}',
      title: song.name,
      artist: song.artists.join(' / '),
      album: song.album,
      artUri:
          song.cover.isEmpty ? null : Uri.tryParse(song.cover),
      duration: song.duration > 0
          ? Duration(milliseconds: song.duration)
          : null,
    ));
  }

  /// 详情补全（封面）后刷新元数据
  void updateDetail(Song song) => updateSong(song);

  void _syncPlaybackState() {
    final p = _player;
    if (p == null) return;
    final playing = p.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _mapProcessingState(p.processingState),
      playing: playing,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
    ));
  }

  AudioProcessingState _mapProcessingState(ProcessingState s) => switch (s) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };
}
