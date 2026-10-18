import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/models/cloud_chunk.dart';

class DatabaseService {
  final bool inMemory;
  Database? _db;

  Database get db {
    if (_db == null) {
      throw StateError('Database belum diinisialisasi. Panggil init() terlebih dahulu.');
    }
    return _db!;
  }

  DatabaseService({this.inMemory = false});

  Future<void> init() async {
    if (_db != null) return;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    if (inMemory) {
      _db = await openDatabase(
        inMemoryDatabasePath,
        version: 1,
        onCreate: _onCreate,
        onConfigure: _onConfigure,
      );
    } else {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, 'tgcloud.db');
      _db = await openDatabase(
        path,
        version: 1,
        onCreate: _onCreate,
        onConfigure: _onConfigure,
      );
    }
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE cloud_files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nama TEXT NOT NULL,
        ukuran_bytes INTEGER NOT NULL,
        mime TEXT NOT NULL,
        sha256_original TEXT NOT NULL,
        is_encrypted INTEGER NOT NULL DEFAULT 1,
        salt TEXT NOT NULL,
        jumlah_chunk INTEGER NOT NULL,
        dibuat_pada TEXT NOT NULL,
        status TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE cloud_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER NOT NULL,
        chunk_index INTEGER NOT NULL,
        ukuran_chunk INTEGER NOT NULL,
        tg_file_id TEXT,
        tg_message_id INTEGER,
        nonce_hex TEXT NOT NULL,
        sha256_chunk TEXT NOT NULL,
        status TEXT NOT NULL,
        FOREIGN KEY (file_id) REFERENCES cloud_files(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  Future<int> insertFile(CloudFile file) async {
    return await _db!.insert('cloud_files', file.toMap());
  }

  Future<int> insertChunk(CloudChunk chunk) async {
    return await _db!.insert('cloud_chunks', chunk.toMap());
  }

  Future<List<CloudFile>> getAllFiles({String? search}) async {
    List<Map<String, dynamic>> res;
    if (search != null && search.trim().isNotEmpty) {
      res = await _db!.query(
        'cloud_files',
        where: 'nama LIKE ?',
        whereArgs: ['%${search.trim()}%'],
        orderBy: 'id DESC',
      );
    } else {
      res = await _db!.query('cloud_files', orderBy: 'id DESC');
    }
    return res.map(CloudFile.fromMap).toList();
  }

  Future<CloudFile?> getFileById(int id) async {
    final res = await _db!.query('cloud_files', where: 'id = ?', whereArgs: [id]);
    if (res.isEmpty) return null;
    return CloudFile.fromMap(res.first);
  }

  Future<CloudFile?> getFileByHash(String sha256) async {
    final res = await _db!.query(
      'cloud_files',
      where: 'sha256_original = ? AND status = ?',
      whereArgs: [sha256, 'complete'],
    );
    if (res.isEmpty) return null;
    return CloudFile.fromMap(res.first);
  }

  Future<List<CloudChunk>> getChunksForFile(int fileId) async {
    final res = await _db!.query(
      'cloud_chunks',
      where: 'file_id = ?',
      whereArgs: [fileId],
      orderBy: 'chunk_index ASC',
    );
    return res.map(CloudChunk.fromMap).toList();
  }

  Future<void> updateFileStatus(int fileId, String status) async {
    await _db!.update('cloud_files', {'status': status}, where: 'id = ?', whereArgs: [fileId]);
  }

  Future<void> updateChunkStatus(int chunkId, String status, {String? tgFileId, int? tgMessageId}) async {
    final values = <String, dynamic>{'status': status};
    if (tgFileId != null) values['tg_file_id'] = tgFileId;
    if (tgMessageId != null) values['tg_message_id'] = tgMessageId;
    await _db!.update('cloud_chunks', values, where: 'id = ?', whereArgs: [chunkId]);
  }

  Future<void> deleteFile(int fileId) async {
    await _db!.delete('cloud_files', where: 'id = ?', whereArgs: [fileId]);
  }

  Future<String?> getSetting(String key) async {
    final res = await _db!.query('app_settings', where: 'key = ?', whereArgs: [key]);
    if (res.isEmpty) return null;
    return res.first['value'] as String?;
  }

  Future<void> setSetting(String key, String value) async {
    await _db!.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
