/// 搜索页：毛玻璃搜索框 + 搜索源切换（网易云 / B站）+ 历史记录 chips + 滚动加载更多
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../config.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/db_service.dart';
import '../widgets/glass_card.dart';
import '../widgets/song_tile.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  Timer? _debounce;

  List<Song> _results = const [];
  bool _searching = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _searched = false;
  String? _error;
  String _currentKeywords = '';

  /// 搜索源：'netease' | 'bilibili'
  String _source = 'netease';

  List<String> _history = const [];
  bool _historyLoaded = false;

  static const int _pageLimit = AppConfig.kSearchPageLimit;
  /// B站搜索固定 limit=20，不支持分页
  static const int _biliLimit = 20;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadHistory();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final h = await DbService.searchHistory();
    if (!mounted) return;
    setState(() {
      _history = h;
      _historyLoaded = true;
    });
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searched = false;
        _error = null;
        _currentKeywords = '';
      });
      _loadHistory();
      return;
    }
    // 防抖 500ms 实时搜索
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _search(text.trim(), saveHistory: false);
    });
  }

  /// 切换搜索源
  void _switchSource(String newSource) {
    if (newSource == _source) return;
    setState(() {
      _source = newSource;
      _results = const [];
      _searched = false;
      _hasMore = true;
      _error = null;
    });
    // 关键词非空时立即用新源重新搜
    final kw = _controller.text.trim();
    if (kw.isNotEmpty) {
      _search(kw, saveHistory: false);
    }
  }

  Future<void> _search(String keywords, {bool saveHistory = true}) async {
    _currentKeywords = keywords;
    setState(() {
      _searching = true;
      _error = null;
      _hasMore = true;
    });
    try {
      List<Song> songs;
      if (_source == 'bilibili') {
        songs = await ApiService.searchBili(keywords, limit: _biliLimit);
        // B站搜索不支持分页
        _hasMore = false;
      } else {
        songs = await ApiService.search(keywords, limit: _pageLimit, offset: 0);
        _hasMore = songs.length >= _pageLimit;
      }
      if (!mounted) return;
      setState(() {
        _results = songs;
        _searching = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _searching = false;
        _searched = true;
        _error = '搜索失败：$e';
      });
    }
    if (saveHistory) {
      await DbService.addSearchHistory(keywords);
      _loadHistory();
    }
  }

  Future<void> _loadMore() async {
    // B站搜索不支持分页
    if (_source == 'bilibili') return;
    if (_loadingMore || !_hasMore || _currentKeywords.isEmpty) return;
    setState(() => _loadingMore = true);
    final offset = _results.length;
    try {
      final more = await ApiService.search(_currentKeywords,
          limit: _pageLimit, offset: offset);
      if (!mounted) return;
      setState(() {
        _results = [..._results, ...more];
        _loadingMore = false;
        _hasMore = more.length >= _pageLimit;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _pickHistory(String kw) {
    _controller.text = kw;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: kw.length),
    );
    _search(kw, saveHistory: true);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        // 搜索源切换器
        _SourceSwitcher(
          source: _source,
          onChanged: _switchSource,
        ),
        // 毛玻璃搜索框
        _GlassSearchField(
          controller: _controller,
          source: _source,
          onChanged: _onChanged,
          onSubmitted: (text) {
            if (text.trim().isNotEmpty) {
              _search(text.trim(), saveHistory: true);
            }
          },
        ),
        // 结果区
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_searching) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13),
          ),
        ),
      );
    }
    // 无搜索内容 → 显示历史记录
    if (!_searched && _controller.text.trim().isEmpty) {
      return _buildHistoryArea();
    }
    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, color: Colors.white.withOpacity(0.30), size: 48),
            const SizedBox(height: 12),
            Text(
              '没有找到相关歌曲',
              style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      itemCount: _results.length + 1,
      itemBuilder: (context, i) {
        if (i == _results.length) {
          return _buildListFooter();
        }
        return SongTile(song: _results[i], queue: _results, index: i + 1);
      },
    );
  }

  Widget _buildListFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                color: Colors.white70, strokeWidth: 2),
          ),
        ),
      );
    }
    if (_hasMore) {
      return const SizedBox(height: 8);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          '没有更多了',
          style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12),
        ),
      ),
    );
  }

  // ---------- 历史搜索记录区 ----------

  Widget _buildHistoryArea() {
    if (!_historyLoaded) {
      return const SizedBox.shrink();
    }
    if (_history.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, color: Colors.white.withOpacity(0.30), size: 52),
            const SizedBox(height: 12),
            Text(
              '搜索歌曲、歌手、专辑',
              style: TextStyle(
                color: Colors.white.withOpacity(0.35),
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      children: [
        // 标题 + 清空
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '搜索历史',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _history
              .map((kw) => _HistoryChip(
                    keyword: kw,
                    onTap: () => _pickHistory(kw),
                    onDelete: () async {
                      await DbService.deleteSearchHistory(kw);
                      _loadHistory();
                    },
                  ))
              .toList(),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () async {
              await DbService.clearSearchHistory();
              _loadHistory();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.18)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_sweep,
                      color: Colors.white.withOpacity(0.6), size: 14),
                  const SizedBox(width: 4),
                  Text(
                    '清空历史',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 搜索源分段选择器（毛玻璃样式）
class _SourceSwitcher extends StatelessWidget {
  final String source;
  final ValueChanged<String> onChanged;
  const _SourceSwitcher({required this.source, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.20),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.14),
                  Colors.white.withOpacity(0.05),
                ],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.22), width: 1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                _segment('网易云', 'netease'),
                _segment('B站', 'bilibili'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _segment(String label, String value) {
    final active = source == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(value),
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: active ? Colors.white.withOpacity(0.25) : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: active
                ? Border.all(color: Colors.white.withOpacity(0.35), width: 1)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white.withOpacity(0.50),
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// 历史记录 chip：毛玻璃 + 关键词 + 删除按钮
class _HistoryChip extends StatelessWidget {
  final String keyword;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _HistoryChip({
    required this.keyword,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      borderRadius: 16,
      blurSigma: 10,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history,
                  color: Colors.white.withOpacity(0.45), size: 14),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  keyword,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close,
                      color: Colors.white.withOpacity(0.5), size: 14),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃搜索框
class _GlassSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String source;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _GlassSearchField({
    required this.controller,
    required this.source,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final hint = source == 'bilibili' ? '搜索B站视频音频…' : '搜索歌曲、歌手…';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.16),
                  Colors.white.withOpacity(0.06),
                ],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                Icon(Icons.search, color: Colors.white.withOpacity(0.6), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    cursorColor: Colors.white70,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: hint,
                      hintStyle:
                          TextStyle(color: Colors.white.withOpacity(0.35)),
                    ),
                  ),
                ),
                if (controller.text.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      controller.clear();
                      onChanged('');
                    },
                    child: Icon(Icons.close,
                        color: Colors.white.withOpacity(0.5), size: 18),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
