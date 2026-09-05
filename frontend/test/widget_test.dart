import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_music/models/song.dart';
import 'package:liquid_music/services/lrc_parser.dart';

void main() {
  test('Song.fromJson 解析基本字段', () {
    final song = Song.fromJson({
      'id': 1,
      'name': '测试歌曲',
      'artists': [
        {'name': '歌手A'},
        {'name': '歌手B'},
      ],
      'album': {'name': '专辑X'},
      'cover': 'http://example.com/c.jpg',
      'duration': 210000,
    });
    expect(song.id, 1);
    expect(song.artistText, '歌手A / 歌手B');
    expect(song.album, '专辑X');
    expect(song.durationText, '03:30');
  });

  test('LRC 解析多时间标签', () {
    final lines = LrcParser.parse('[00:12.30][01:05.10] hello\n[00:50]world');
    expect(lines.length, 3);
    expect(lines[0].text, 'hello');
    expect(
      lines[0].time,
      const Duration(minutes: 0, seconds: 12, milliseconds: 300),
    );
    // 排序后：12.3s(hello) → 50s(world) → 65.1s(hello)
    expect(lines[1].text, 'world');
    expect(lines[2].text, 'hello');
    final idx = LrcParser.currentIndex(lines, const Duration(seconds: 30));
    expect(idx, 0);
  });

  test('LRC 解析空文本返回空列表', () {
    expect(LrcParser.parse(null), isEmpty);
    expect(LrcParser.parse(''), isEmpty);
  });
}
