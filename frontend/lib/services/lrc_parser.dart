/// LRC 歌词解析器
///
/// 支持多时间标签行：`[00:12.34][00:50.12]歌词内容`
library;

import '../models/song.dart';

class LrcParser {
  LrcParser._();

  static final RegExp _tagRegex = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 组合标记/不可见字符清洗：
  /// 覆盖组合变音符（含 U+0332 单下划线、U+0333 双下划线）、
  /// 组合用符号、零宽字符（ZWNJ/ZWJ/BOM）等——这类字符会被字体引擎
  /// 直接渲染成"字下方的黄/彩色线"，表现为歌词逐字符被标记。
  static final RegExp _markRegex = RegExp(
    r'[\u0300-\u036f\u0483-\u0489\u0591-\u05bd\u05bf\u05c1\u05c2\u05c4\u05c5\u05c7'
    r'\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06dc\u06df-\u06e4\u06e7\u06e8\u06ea-\u06ed'
    r'\u0711\u0730-\u074a\u07a6-\u07b0\u07eb-\u07f3\u0816-\u0819\u081b-\u0823\u0825-\u0827\u0829-\u082d'
    r'\u0859-\u085b\u08e3-\u0902\u093a\u093c\u0941-\u0948\u094d\u0951-\u0957\u0962\u0963'
    r'\u0981\u09bc\u09be\u09c1-\u09c4\u09cd\u09d7\u09e2\u09e3'
    r'\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f'
    r'\u200b-\u200d\ufeff]',
  );

  /// 解析 LRC 文本为按时间升序的 [{time, text}] 列表
  static List<LyricLine> parse(String? lrc) {
    if (lrc == null || lrc.trim().isEmpty) return const [];
    final lines = <LyricLine>[];
    for (final rawLine in lrc.split(RegExp(r'\r?\n'))) {
      final tags = _tagRegex.allMatches(rawLine).toList();
      if (tags.isEmpty) continue;
      // 去掉所有时间标签与不可见组合字符，剩下的就是歌词文本
      final text = rawLine
          .replaceAll(_tagRegex, '')
          .replaceAll(_markRegex, '')
          .trim();
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
