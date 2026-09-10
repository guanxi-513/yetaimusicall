/// 播放器全局状态（Provider ChangeNotifier）
///
/// 管理：当前队列、当前曲目、播放状态、进度/缓冲、歌词、收藏集合
library;

import 'dart:async' show unawaited;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../config.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_handler.dart';
import '../services/db_service.dart';
import '../services/lrc_parser.dart';
import '../services/media_notification_bridge.dart';
import '../services/music_cache.dart';

/// 播放模式：顺序 / 随机 / 单曲循环
enum PlayMode { order, shuffle, repeatOne }

class PlayerState extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  final Random _random = Random();

  /// audio_service 桥（后台播放 + 系统媒体通知）
  LiquidAudioHandler? _handler;
  AudioPlayer get player => _player;

  /// 绑定 AudioHandler（main 里 AudioService.init 后调用，只调一次）
  void attachAudioHandler(LiquidAudioHandler handler) {
    if (_handler != null) return;
    _handler = handler;
    handler.bind(this);
    if (_current != null) handler.updateSong(_current!);
  }

  // ---------- 队列与当前曲目 ----------
  List<Song> _queue = [];
  int _index = -1;
  Song? _current;
  List<Song> get queue => _queue;
  int get index => _index;
  Song? get current => _current;

  /// 当前歌曲实际播放音质描述（如"FLAC 无损 · 解锁源pyncmd"），
  /// 用于播放页显示真实音质，避免与用户所选音质混淆
  String currentQuality = '';

  // ---------- 播放模式 ----------
  PlayMode _playMode = PlayMode.order;
  PlayMode get playMode => _playMode;
  void togglePlayMode() {
    switch (_playMode) {
      case PlayMode.order:
        _playMode = PlayMode.shuffle;
        break;
      case PlayMode.shuffle:
        _playMode = PlayMode.repeatOne;
        break;
      case PlayMode.repeatOne:
        _playMode = PlayMode.order;
        break;
    }
    notifyListeners();
  }

  // ---------- 播放状态 ----------
  bool _playing = false;
  bool _loading = false;
  String? _error;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;

  // ---------- 进度 ----------
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get buffered => _buffered;

  // ---------- 歌词 ----------
  List<LyricLine> _lyrics = const [];
  List<LyricLine> _translation = const [];

  /// 与 [_lyrics] 对齐的翻译文本（无对应翻译为 null）
  List<String?> _translationsAligned = const [];
  List<LyricLine> get lyrics => _lyrics;
  List<LyricLine> get translation => _translation;
  int get currentLyricIndex => LrcParser.currentIndex(_lyrics, _position);

  /// 第 i 行歌词对应的翻译（时间相同即视为对应）
  String? translationAt(int i) {
    if (i < 0 || i >= _translationsAligned.length) return null;
    return _translationsAligned[i];
  }

  // ---------- 封面详情（cover 可能要 /song/detail 补全）----------
  Song? _currentDetail;
  Song? get currentDetail => _currentDetail ?? _current;

  // ---------- 播放完成/失败自动切歌 ----------
  bool _autoAdvancing = false;

  PlayerState() {
    _player.playerStateStream.listen((state) {
      _playing = state.playing;
      notifyListeners();
      // 播放/暂停状态变化 → 立即刷新通知栏（图标切换）
      MediaNotificationBridge.push(force: true);
    });
    _player.positionStream.listen((p) {
      _position = p;
      notifyListeners();
      // 歌词行变化时立即推送，否则按 1s 节流推送进度
      MediaNotificationBridge.push();
    });
    _player.durationStream.listen((d) {
      _duration = d ?? Duration.zero;
      notifyListeners();
    });
    _player.bufferedPositionStream.listen((b) {
      _buffered = b;
      notifyListeners();
    });
    // 播放完成 → 自动下一首
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && !_autoAdvancing) {
        _autoAdvancing = true;
        next(auto: true);
        Future.delayed(
          const Duration(seconds: 1),
          () => _autoAdvancing = false,
        );
      }
    });
    loadFavorites();
  }

  // ---------- 播放控制 ----------

  /// 播放某首歌，并把它所在的列表设为队列
  Future<void> play(Song song, {List<Song>? queue}) async {
    if (queue != null) {
      _queue = List.of(queue);
      _index = queue.indexWhere((s) => s.id == song.id);
    } else {
      final existing = _queue.indexWhere((s) => s.id == song.id);
      if (existing >= 0) {
        _index = existing;
      } else {
        _queue.insert(0, song);
        _index = 0;
      }
    }
    if (_index < 0) {
      _queue.add(song);
      _index = _queue.length - 1;
    }
    await _startCurrent();
  }

  /// 一键播放：清空当前队列，把 [songs] 按顺序加入并从第一首开始播放
  Future<void> playAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    _queue = List.of(songs);
    _index = 0;
    await _startCurrent();
  }

  Future<void> next({bool auto = false}) async {
    if (_queue.isEmpty || _index < 0) return;

    switch (_playMode) {
      case PlayMode.repeatOne:
        if (auto) {
          // 单曲循环：自然播完 → 重播当前
          await _startCurrent();
        } else {
          // 手动下一首：按顺序前进
          _index = (_index + 1) % _queue.length;
          await _startCurrent();
        }
        break;
      case PlayMode.shuffle:
        if (_queue.length <= 1) {
          await _startCurrent();
          return;
        }
        int r;
        do {
          r = _random.nextInt(_queue.length);
        } while (r == _index);
        _index = r;
        await _startCurrent();
        break;
      case PlayMode.order:
        if (_index >= _queue.length - 1) {
          // 到末尾
          if (auto) {
            // 自然播完：回到第一首并暂停
            _index = 0;
            await _startCurrent(autoplay: false);
            await pause();
          } else {
            // 手动：回到第一首继续
            _index = 0;
            await _startCurrent();
          }
        } else {
          _index += 1;
          await _startCurrent();
        }
        break;
    }
  }

  Future<void> previous() async {
    if (_queue.isEmpty || _index < 0) return;

    switch (_playMode) {
      case PlayMode.shuffle:
        if (_queue.length <= 1) return;
        int r;
        do {
          r = _random.nextInt(_queue.length);
        } while (r == _index);
        _index = r;
        await _startCurrent();
        break;
      case PlayMode.repeatOne:
      case PlayMode.order:
        if (_index <= 0) {
          _index = _queue.length - 1;
        } else {
          _index -= 1;
        }
        await _startCurrent();
        break;
    }
  }

  /// 跳转到队列中指定索引播放
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _index = index;
    await _startCurrent();
  }

  Future<void> togglePlay() async {
    if (_current == null) return;
    if (_playing) {
      await pause();
    } else {
      final h = _handler;
      if (h != null) {
        await h.play();
      } else {
        await _player.play();
      }
    }
  }

  Future<void> pause() async {
    final h = _handler;
    if (h != null) {
      await h.pause();
    } else {
      await _player.pause();
    }
  }

  Future<void> seek(Duration position) async {
    final h = _handler;
    if (h != null) {
      await h.seek(position);
    } else {
      await _player.seek(position);
    }
    _position = position;
    notifyListeners();
    MediaNotificationBridge.push(force: true);
  }

  /// 播放失败自动跳下一首（最多连跳 3 次防死循环）
  int _consecutiveFailures = 0;

  /// 根据 /song/url 返回的实际码率/来源生成音质描述（用于播放页显示）
  String _qualityDesc(int? br, String source, bool unblocked) {
    final q = _brLabel(br);
    if (unblocked) {
      final src = source.isEmpty ? '' : ' · $source';
      return '$q · 解锁源$src';
    }
    return q;
  }

  String _brLabel(int? br) {
    if (br == null) return '未知音质';
    if (br >= 900000) return 'FLAC 无损';
    if (br >= 300000) return '高品 320k';
    return '标准 128k';
  }

  Future<void> _startCurrent({bool autoplay = true}) async {
    if (_index < 0 || _index >= _queue.length) return;
    final song = _queue[_index];
    _current = song;
    _currentDetail = null;
    currentQuality = '';
    _lyrics = const [];
    _translation = const [];
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _loading = true;
    _error = null;
    notifyListeners();

    // 更新系统媒体通知（audio_service 元数据 + 自定义通知）
    _handler?.updateSong(song);
    MediaNotificationBridge.push(force: true);

    // 并行补全详情（封面）与歌词，不阻塞播放
    unawaited(_loadDetail(song));
    unawaited(_loadLyric(song));

    try {
      // 缓存优先：本地有缓存直接播本地（离线/秒开）
      final cached = await MusicCache.cachedPath(song);
      if (cached != null) {
        await _player.setUrl(cached);
      } else {
        String playUrl;
        if (song.isBilibili) {
          // B站 CDN 需带 bilibili Referer 防盗链，走服务器代理
          playUrl = await ApiService.biliStreamUrl(song.bvid!);
          await _player.setUrl(playUrl);
        } else if (song.isKugou) {
          // 酷狗：/kugou/song/url?hash=（免费128k，地址 2-4 小时时效实时请求）
          final info = await ApiService.kugouSongUrl(song.hash ?? '');
          currentQuality = _qualityDesc(info.br, 'kugou', false);
          try {
            await _player.setUrl(info.url);
            playUrl = info.url;
          } catch (e) {
            debugPrint('酷狗直连失败，回退服务器代理：$e');
            playUrl = ApiService.proxyUrlOf(info.url);
            await _player.setUrl(playUrl);
          }
          unawaited(_cacheSong(song, playUrl));
        } else if (song.isQQ) {
          // QQ：/qq/song/url?mid=&name=&artist=&duration=
          // 必须带歌名/歌手/时长（后端靠它做 VIP 歌兜底匹配，返回实际音源）
          final info = await ApiService.qqSongUrl(
            mid: song.mid ?? '',
            name: song.name,
            artist: song.artists.isNotEmpty ? song.artists.join(' / ') : '',
            duration: song.duration,
          );
          currentQuality = _qualityDesc(info.br, info.source, info.unblocked);
          final qqUrl = info.url.startsWith('/')
              // B站兜底可能返回相对路径（/stream/bili?bvid=xxx），补全服务器地址
              ? '${AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '')}${info.url}'
              : info.url;
          try {
            await _player.setUrl(qqUrl);
            playUrl = qqUrl;
          } catch (e) {
            debugPrint('QQ 直连失败，回退服务器代理：$e');
            playUrl = ApiService.proxyUrlOf(qqUrl);
            await _player.setUrl(playUrl);
          }
          unawaited(_cacheSong(song, playUrl));
        } else if (song.isSoda) {
          // 汽水：/soda/song/url?id=&name=&artist=&duration=
          // 必须带歌名/歌手/时长（毫秒）——后端靠它做 VIP 歌换源匹配，返回实际音源
          final info = await ApiService.sodaSongUrl(
            id: song.id.toString(),
            name: song.name,
            artist: song.artists.isNotEmpty ? song.artists.join(' / ') : '',
            duration: song.duration,
          );
          currentQuality = _qualityDesc(info.br, info.source, info.unblocked);
          final sodaUrl = info.url.startsWith('/')
              // 兜底可能返回相对路径（/stream/bili?bvid=xxx），补全服务器地址
              ? '${AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '')}${info.url}'
              : info.url;
          try {
            await _player.setUrl(sodaUrl);
            playUrl = sodaUrl;
          } catch (e) {
            debugPrint('汽水直连失败，回退服务器代理：$e');
            playUrl = ApiService.proxyUrlOf(sodaUrl);
            await _player.setUrl(playUrl);
          }
          unawaited(_cacheSong(song, playUrl));
        } else {
          // 网易云：优先直连真实 CDN（不占服务器带宽），失败回退服务器代理
          final info = await ApiService.songStreamInfo(
            song.id,
            br: AppConfig.audioBitrate,
          );
          currentQuality = _qualityDesc(info.br, info.source, info.unblocked);
          final real = info.url;
          try {
            await _player.setUrl(real);
            playUrl = real;
          } catch (e) {
            debugPrint('直连 CDN 失败，回退服务器代理：$e');
            playUrl = ApiService.proxyUrlOf(real);
            await _player.setUrl(playUrl);
          }
          unawaited(_cacheSong(song, playUrl));
        }
      }
      // 登记最近播放并修剪：缓存只保留最近播放的 30 首
      unawaited(MusicCache.registerPlayedAndPrune(song, keep: 30));
      _consecutiveFailures = 0;
      // 播放源就绪即记历史：await 确保可靠执行，单独 try 防止落库失败误触发"跳下一首"
      try {
        await DbService.addHistory(song);
      } catch (_) {
        debugPrint('addHistory 失败（不影响播放）');
      }
      if (autoplay) {
        await _player.play();
      }
    } catch (e) {
      _error = '播放失败：$e';
      _loading = false;
      notifyListeners();
      // 自动跳过下一首
      if (_consecutiveFailures < 3 && _queue.length > 1) {
        _consecutiveFailures++;
        debugPrint('播放失败，自动跳过：$e');
        await Future.delayed(const Duration(milliseconds: 600));
        await next();
      }
      return;
    }
    _loading = false;
    notifyListeners();
  }

  /// 后台缓存音频到本地（失败不影响播放，由 MusicCache 内部兜底）
  Future<void> _cacheSong(Song song, String url) async {
    try {
      await MusicCache.cacheFromUrl(song, url);
    } catch (_) {
      // 缓存失败不影响播放
    }
  }

  Future<void> _loadDetail(Song song) async {
    // B站/酷狗/QQ/汽水歌无网易云详情接口，跳过
    if (song.isBilibili || song.isKugou || song.isQQ || song.isSoda) return;
    try {
      final details = await ApiService.songDetail([song.id]);
      if (details.isNotEmpty && details.first.cover.isNotEmpty) {
        _currentDetail = details.first;
        notifyListeners();
        // 封面补全后刷新系统通知（MediaItem.artUri）与自定义通知
        _handler?.updateDetail(details.first);
        MediaNotificationBridge.push(force: true);
      }
    } catch (_) {
      // 封面补全失败不影响播放
    }
  }

  Future<void> _loadLyric(Song song) async {
    try {
      // 汽水：优先官方歌词（/soda/lyric），失败回退歌名+歌手多源兜底；
      // 网易云歌有数字 id 走原接口（保留翻译）；酷狗/QQ/B站歌按歌名+歌手走多源兜底。
      final artist = song.artists.isNotEmpty ? song.artists.join(' / ') : '';
      final result = song.isSoda
          ? await _sodaLyricWithFallback(song, artist)
          : (!song.isKugou && !song.isQQ && !song.isBilibili && song.id > 0)
          ? await ApiService.lyric(song.id)
          : await ApiService.lyricAny(
              song.name,
              artist,
              duration: song.duration,
            );
      _lyrics = result.main;
      _translation = result.translation;
      // 按时间对齐翻译（毫秒级容差）
      final tMap = <int, String>{
        for (final t in _translation)
          if (t.text.isNotEmpty) t.time.inMilliseconds: t.text,
      };
      _translationsAligned = [
        for (final l in _lyrics)
          tMap[l.time.inMilliseconds] ??
              _findNearTranslation(l.time.inMilliseconds),
      ];
      notifyListeners();
      // 歌词加载完成后刷新自定义通知（从"暂无歌词"切到当前行）
      MediaNotificationBridge.push(force: true);
    } catch (_) {
      // 歌词加载失败静默处理
    }
  }

  /// 汽水歌词：优先官方 /soda/lyric，失败回退歌名+歌手多源兜底
  Future<({List<LyricLine> main, List<LyricLine> translation})>
  _sodaLyricWithFallback(Song song, String artist) async {
    try {
      return await ApiService.sodaLyric(song.id.toString());
    } catch (_) {
      return await ApiService.lyricAny(
        song.name,
        artist,
        duration: song.duration,
      );
    }
  }

  String? _findNearTranslation(int ms) {
    for (final t in _translation) {
      if ((t.time.inMilliseconds - ms).abs() <= 300) return t.text;
    }
    return null;
  }

  // ---------- 收藏（本地收藏与网易云喜欢完全分离） ----------
  Set<int> _localFavoriteIds = {}; // 本地收藏（DbService.favorites 表）
  Set<int> _cloudFavoriteIds = {}; // 网易云"我喜欢的音乐"
  Set<int> _qqLikedSongIds = {}; // QQ 音乐「我喜欢」（songId 集合）

  /// 全局爱心集合（本地或云端任一）：仅供红心展示
  Set<int> get favoriteIds => _localFavoriteIds.union(_cloudFavoriteIds);

  /// QQ 已收藏 songId 集合（QQ 歌曲红心依据）
  Set<int> get qqLikedSongIds => _qqLikedSongIds;

  /// 全局爱心：本地或云端任一存在即红心（播放页/搜索页/普通歌单）
  bool isFavorite(Song song) {
    // QQ 歌：本地收藏 ∪ QQ「我喜欢」；不参与网易云集合
    if (song.isQQ) {
      return _localFavoriteIds.contains(song.id) ||
          _qqLikedSongIds.contains(song.songId);
    }
    return _localFavoriteIds.contains(song.id) ||
        _cloudFavoriteIds.contains(song.id);
  }

  /// 仅 QQ 云端喜欢（QQ「我喜欢」歌单专用）
  bool isQqFavorite(Song song) =>
      song.isQQ && _qqLikedSongIds.contains(song.songId);

  /// 仅本地收藏（「我的收藏」tab 专用）
  bool isLocalFavorite(Song song) => _localFavoriteIds.contains(song.id);

  /// 仅云端喜欢（网易云喜欢列表专用）
  bool isCloudFavorite(Song song) => _cloudFavoriteIds.contains(song.id);

  /// 收藏版本号：每次本地收藏/取消后自增。
  /// 「我的」页等长列表监听它，变化时自动重载本地收藏。
  int _favoritesVersion = 0;
  int get favoritesVersion => _favoritesVersion;

  Future<void> loadFavorites() async {
    try {
      _localFavoriteIds = await DbService.favoriteIds();
      notifyListeners();
    } catch (e) {
      // 暴露静默的 DB 异常（如 no such column），避免收藏列表恒空却无迹可循
      debugPrint('[PlayerState] loadFavorites 失败: $e');
    }
  }

  /// 只翻转本地收藏（「我的收藏」tab 专用），完全不碰云端
  Future<String> toggleFavoriteLocal(Song song) async {
    await DbService.toggleFavorite(song);
    await loadFavorites();
    _favoritesVersion++;
    notifyListeners();
    MediaNotificationBridge.push(force: true);
    return 'local';
  }

  /// 只翻转云端喜欢（网易云喜欢列表专用），完全不碰本地
  /// 返回 'ok'（成功）| 'error'（网络失败/未登录，状态未变）
  Future<String> toggleFavoriteCloud(Song song) async {
    final target = !isCloudFavorite(song);
    try {
      final r = await ApiService.like(song.id, target);
      if (r.ok) {
        // 以服务端真实结果为准更新集合
        if (r.liked) {
          _cloudFavoriteIds.add(song.id);
        } else {
          _cloudFavoriteIds.remove(song.id);
        }
        notifyListeners();
        MediaNotificationBridge.push(force: true);
        return 'ok';
      }
      return 'error';
    } catch (_) {
      return 'error';
    }
  }

  /// 从网易云拉取喜欢列表并合并（登录后调用）
  Future<void> loadCloudFavorites() async {
    try {
      final cloudIds = await ApiService.likelist();
      _cloudFavoriteIds = cloudIds.toSet();
      notifyListeners();
      MediaNotificationBridge.push(force: true);
    } catch (_) {
      // 静默失败
    }
  }

  /// 从 QQ 拉取「我喜欢」songId 集合（QQ 登录后调用）
  Future<void> loadQqFavorites() async {
    try {
      final ids = await ApiService.qqLikedIds();
      _qqLikedSongIds = ids;
      notifyListeners();
      MediaNotificationBridge.push(force: true);
    } catch (_) {
      // 未登录 / 网络失败：静默
    }
  }

  /// 清空 QQ 收藏集合（QQ 退出登录时调用）
  void clearQqFavorites() {
    _qqLikedSongIds = {};
    notifyListeners();
    MediaNotificationBridge.push(force: true);
  }

  /// 清空云端收藏集合（退出登录时调用）
  void clearCloudFavorites() {
    _cloudFavoriteIds = {};
    notifyListeners();
    MediaNotificationBridge.push(force: true);
  }

  /// 全局爱心（播放页/搜索页/普通歌单详情）：双写
  ///
  /// 收藏 = 本地 + 云端都加；取消 = 本地 + 云端都删。
  /// 【本地先行、云端后补】——无论云端成败，本地状态都立即正确
  /// （爱心立即变色、可立即再次点击取消）。
  ///
  /// 本地写库用"目标状态"而非盲目翻转：云端收藏（仅在 _cloudFavoriteIds、
  /// 不在本地库）的歌曲被取消时，不能因为翻转而误加进本地收藏。
  ///
  /// - B站歌 / 未登录：只做本地收藏，返回 'local'
  /// - 已登录：尽力同步网易云
  ///   - 'ok'：云端同步成功
  ///   - 'local'：服务端未登录 / 返回异常，仅本地收藏
  ///   - 'error'：网络异常，仅本地收藏
  Future<String> toggleFavorite(Song song, {bool loggedIn = false}) async {
    final newLike = !isFavorite(song);
    final localFav = _localFavoriteIds.contains(song.id);

    // 第一步：本地写目标态（先落库再通知，让爱心立即变色、可立即取消）
    if (localFav != newLike) {
      await DbService.toggleFavorite(song);
    }
    await loadFavorites();
    _favoritesVersion++;
    notifyListeners();
    MediaNotificationBridge.push(force: true);

    // QQ 歌：本地 + QQ「我喜欢」双写（不碰网易云）
    if (song.isQQ) {
      // 没有数字 songId 的 QQ 歌（异常数据）只做本地
      if (song.songId <= 0) return 'local';
      try {
        await ApiService.qqLikeSong(song.songId, newLike);
        // 以服务端真实结果为准
        if (newLike) {
          _qqLikedSongIds.add(song.songId);
        } else {
          _qqLikedSongIds.remove(song.songId);
        }
        notifyListeners();
        MediaNotificationBridge.push(force: true);
        return 'ok';
      } catch (_) {
        // QQ 未登录 / 网络失败：仅本地已生效
        return 'local';
      }
    }

    // B站/酷狗歌只做本地收藏；未登录也仅本地（不同步网易云）
    if (song.isBilibili || song.isKugou || !loggedIn) {
      return 'local';
    }

    // 第二步：云端同步到目标态 —— 失败不影响第一步已生效的本地状态
    try {
      final r = await ApiService.like(song.id, newLike);
      if (r.ok) {
        // 云端成功 → 收藏集合与服务端真实结果对齐（而不是本地预判）
        if (r.liked) {
          _cloudFavoriteIds.add(song.id);
        } else {
          _cloudFavoriteIds.remove(song.id);
        }
        notifyListeners();
        MediaNotificationBridge.push(force: true);
        return 'ok';
      }
      // 服务端明确未登录 / 返回异常：本地已生效，仅本地
      return 'local';
    } catch (_) {
      // 网络异常：本地已生效，仅本地
      return 'error';
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
