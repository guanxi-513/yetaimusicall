/// LRC 歌词解析器
///
/// 支持多时间标签行：`[00:12.34][00:50.12]歌词内容`
library;

import '../models/song.dart';

class LrcParser {
  LrcParser._();

  static final RegExp _tagRegex = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 解析 LRC 文本为按时间升序的 [{time, text}] 列表
  static List<LyricLine> parse(String? lrc) {
    if (lrc == null || lrc.trim().isEmpty) return const [];
    final lines = <LyricLine>[];
    for (final rawLine in lrc.split(RegExp(r'\r?\n'))) {
      final tags = _tagRegex.allMatches(rawLine).toList();
      if (tags.isEmpty) continue;
      // 去掉所有时间标签，剩下的就是歌词文本
      final text = rawLine.replaceAll(_tagRegex, '').trim();
      for (final tag in tags) {
        final min = int.tryParse(tag.group(1)!) ?? 0;
        final sec = int.tryParse(tag.group(2)!) ?? 0;
        var ms = 0;
        final fracStr = tag.group(3);
        if (fracStr != null) {
          // .5 → 500ms，.50 → 500ms，.500 → 500ms
          ms = int.parse(fracStr.padRight(3, '0').substring(0, 3));
        }
        final time = Duration(minutes: min, seconds: sec, milliseconds: ms);
        lines.add(LyricLine(time, text));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  /// 根据当前播放位置找到当前歌词行下标（-1 表示尚未开始）
  static int currentIndex(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    int lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (lines[mid].time <= position) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}
