/// 本地收藏数据库（sqflite）
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../config.dart';
import '../models/song.dart';

class DbService {
  DbService._();
  static Database? _db;

  /// 统一异常暴露：DB 操作失败时 debugPrint 打印。
  /// （原先异常被静默吞掉，会出现"no such column"导致收藏/历史
  ///  列表恒空却无迹可循）
  static Future<T> _guard<T>(String op, Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      debugPrint('[DbService] $op 失败: $e');
      rethrow;
    }
  }

  /// Song → 数据库行：artists 是 List<String>，sqflite 不能直接写
  /// List 进 TEXT 列（会报 String cannot be cast to Integer / 存成 BLOB），
  /// 统一序列化为 "|" 分隔字符串（与 Song.fromDb 的 split('|') 对应）。
  static Map<String, dynamic> _songToRow(Song song) {
    final row = song.toJson();
    row['artists'] = song.artists.join('|');
    return row;
  }

  static Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'liquid_music.db'),
      version: 6,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE favorites (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            artists TEXT NOT NULL,
            album TEXT NOT NULL,
            cover TEXT NOT NULL,
            duration INTEGER NOT NULL,
            source TEXT NOT NULL DEFAULT 'netease',
            bvid TEXT,
            hash TEXT,
            mid TEXT,
            songId INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE play_history (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            artists TEXT NOT NULL,
            album TEXT NOT NULL,
            cover TEXT NOT NULL,
            duration INTEGER NOT NULL,
            source TEXT NOT NULL DEFAULT 'netease',
            bvid TEXT,
            hash TEXT,
            mid TEXT,
            songId INTEGER NOT NULL DEFAULT 0,
            played_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE search_history (
            keyword TEXT PRIMARY KEY,
            time INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS search_history (
              keyword TEXT PRIMARY KEY,
              time INTEGER NOT NULL
            )
          ''');
        }
        if (oldV < 3) {
          await db.execute(
            "ALTER TABLE favorites ADD COLUMN source TEXT NOT NULL DEFAULT 'netease'",
          );
          await db.execute('ALTER TABLE favorites ADD COLUMN bvid TEXT');
          await db.execute(
            "ALTER TABLE play_history ADD COLUMN source TEXT NOT NULL DEFAULT 'netease'",
          );
          await db.execute('ALTER TABLE play_history ADD COLUMN bvid TEXT');
        }
        if (oldV < 4) {
          // 酷狗接入：hash 为酷狗歌曲取流主键（/kugou/song/url?hash=）
          await db.execute('ALTER TABLE favorites ADD COLUMN hash TEXT');
          await db.execute('ALTER TABLE play_history ADD COLUMN hash TEXT');
        }
        if (oldV < 5) {
          // QQ 音源接入：mid 为 QQ 歌曲 songmid（/qq/song/url?mid= 取流主键）
          await db.execute('ALTER TABLE favorites ADD COLUMN mid TEXT');
          await db.execute('ALTER TABLE play_history ADD COLUMN mid TEXT');
        }
        if (oldV < 6) {
          // QQ 收藏同步：songId 为 QQ 数字歌曲 id（/qq/like?songid= 用）
          // 注意：默认值为 0，旧数据迁移后 QQ 歌本地收藏无法回同步（在线歌曲不受影响）
          await db.execute(
            'ALTER TABLE favorites ADD COLUMN songId INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE play_history ADD COLUMN songId INTEGER NOT NULL DEFAULT 0',
          );
        }
      },
    );
  }

  // ---------- 收藏 ----------

  static Future<bool> isFavorite(int id) => _guard('isFavorite', () async {
    final db = await database;
    final rows = await db.query(
      'favorites',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  });

  static Future<void> toggleFavorite(Song song) =>
      _guard('toggleFavorite(${song.id})', () async {
        final db = await database;
        final fav = await isFavorite(song.id);
        if (fav) {
          await db.delete('favorites', where: 'id = ?', whereArgs: [song.id]);
        } else {
          await db.insert('favorites', {
            ..._songToRow(song),
            'created_at': DateTime.now().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });

  static Future<List<Song>> favorites() => _guard('favorites', () async {
    final db = await database;
    final rows = await db.query('favorites', orderBy: 'created_at DESC');
    return rows.map(Song.fromDb).toList();
  });

  /// 收藏 ID 集合（用于列表页快速判断红心状态）
  static Future<Set<int>> favoriteIds() => _guard('favoriteIds', () async {
    final db = await database;
    final rows = await db.query('favorites', columns: ['id']);
    return rows.map((r) => r['id'] as int).toSet();
  });

  // ---------- 播放历史 ----------

  static Future<void> addHistory(Song song) =>
      _guard('addHistory(${song.id})', () async {
        final db = await database;
        await db.insert('play_history', {
          ..._songToRow(song),
          'played_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  static Future<List<Song>> history({int limit = 100}) =>
      _guard('history', () async {
        final db = await database;
        final rows = await db.query(
          'play_history',
          orderBy: 'played_at DESC',
          limit: limit,
        );
        return rows.map(Song.fromDb).toList();
      });

  // ---------- 搜索历史 ----------

  /// 读取搜索历史（按时间倒序，最多 [limit] 条）
  static Future<List<String>> searchHistory({
    int limit = AppConfig.kMaxSearchHistory,
  }) async {
    final db = await database;
    final rows = await db.query(
      'search_history',
      orderBy: 'time DESC',
      limit: limit,
    );
    return rows.map((r) => r['keyword'] as String).toList();
  }

  /// 写入一条搜索记录（去重 + 更新时间；超过上限删最旧）
  static Future<void> addSearchHistory(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('search_history', {
      'keyword': kw,
      'time': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // 超出上限：删掉最旧的若干条
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM search_history'),
        ) ??
        0;
    final max = AppConfig.kMaxSearchHistory;
    if (count > max) {
      await db.rawDelete(
        'DELETE FROM search_history WHERE keyword IN '
        '(SELECT keyword FROM search_history ORDER BY time ASC LIMIT ?)',
        [count - max],
      );
    }
  }

  static Future<void> deleteSearchHistory(String keyword) async {
    final db = await database;
    await db.delete(
      'search_history',
      where: 'keyword = ?',
      whereArgs: [keyword],
    );
  }

  static Future<void> clearSearchHistory() async {
    final db = await database;
    await db.delete('search_history');
  }
}
