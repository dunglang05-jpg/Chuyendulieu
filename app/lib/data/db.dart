/// SQLite persistence: transfer history/reports and receiver checkpoints (resume state).
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/transfer/receiver_store.dart';

class AppDatabase {
  AppDatabase._(this.db);
  final Database db;

  static Future<AppDatabase> open() async {
    final path = p.join(await getDatabasesPath(), 'phone_transfer_pro.db');
    final db = await openDatabase(path, version: 1, onCreate: (db, v) async {
      await db.execute('''
        CREATE TABLE sessions(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          started_at INTEGER NOT NULL,
          finished_at INTEGER,
          role TEXT NOT NULL,
          peer_platform TEXT,
          state TEXT NOT NULL,
          error_code TEXT,
          files_ok INTEGER DEFAULT 0,
          files_failed INTEGER DEFAULT 0,
          files_skipped INTEGER DEFAULT 0,
          bytes INTEGER DEFAULT 0,
          duration_ms INTEGER DEFAULT 0,
          categories TEXT
        )''');
      // Resume state per transferId. Contains file paths inside the app inbox only, never content.
      await db.execute('CREATE TABLE checkpoints(transfer_id TEXT PRIMARY KEY, state TEXT NOT NULL, updated_at INTEGER NOT NULL)');
    });
    return AppDatabase._(db);
  }

  Future<int> startSession(String role) =>
      db.insert('sessions', {'started_at': DateTime.now().millisecondsSinceEpoch, 'role': role, 'state': 'started'});

  Future<void> finishSession(int id,
      {required String state,
      String? peerPlatform,
      String? errorCode,
      int ok = 0,
      int failed = 0,
      int skipped = 0,
      int bytes = 0,
      int durationMs = 0,
      Map<String, int>? categories}) async {
    await db.update(
        'sessions',
        {
          'finished_at': DateTime.now().millisecondsSinceEpoch,
          'state': state,
          'peer_platform': peerPlatform,
          'error_code': errorCode,
          'files_ok': ok,
          'files_failed': failed,
          'files_skipped': skipped,
          'bytes': bytes,
          'duration_ms': durationMs,
          'categories': categories == null ? null : jsonEncode(categories),
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<List<Map<String, Object?>>> history({int limit = 50}) =>
      db.query('sessions', orderBy: 'started_at DESC', limit: limit);
}

class SqliteCheckpointStore implements CheckpointStore {
  SqliteCheckpointStore(this.app);
  final AppDatabase app;

  @override
  Future<Map<String, dynamic>> load(String transferId) async {
    final rows = await app.db.query('checkpoints', where: 'transfer_id = ?', whereArgs: [transferId]);
    if (rows.isEmpty) return {};
    final j = jsonDecode(rows.first['state'] as String);
    return j is Map<String, dynamic> ? j : {};
  }

  /// SQLite commits are durable (journal + fsync), so a crash leaves either the old or the new state.
  @override
  Future<void> save(String transferId, Map<String, dynamic> state) => app.db.insert(
      'checkpoints', {'transfer_id': transferId, 'state': jsonEncode(state), 'updated_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> delete(String transferId) =>
      app.db.delete('checkpoints', where: 'transfer_id = ?', whereArgs: [transferId]);
}
