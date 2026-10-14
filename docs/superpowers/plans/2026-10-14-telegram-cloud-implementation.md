# Telegram Cloud Storage (TGCloud) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Membangun aplikasi Android penyimpanan cloud pribadi (Flutter) menggunakan Telegram Bot API & channel privat sebagai backend, dengan chunking 15MB, enkripsi client-side AES-256-GCM, metadata SQLite lokal, dan UI dark charcoal + amber.

**Architecture:** File dipotong menjadi chunk 15MB via stream, dienkripsi AES-256-GCM di isolate via `compute()` memakai PIN pengguna + salt file. Worker pool mengunggah maksimal 2 chunk paralel via `Dio` ke Telegram `sendDocument`. Metadata disimpan di SQLite lokal (`cloud_files`, `cloud_chunks`). Download mengunduh chunk berurutan, verifikasi hash SHA-256 per chunk, dekripsi, dan reassembly langsung ke disk dengan verifikasi SHA-256 total. Foreground service menjaga transfer tetap hidup di Android.

**Tech Stack:** Flutter 3.47+, Dart 3.13+, `dio`, `sqflite`, `sqflite_common_ffi`, `encrypt`, `crypto`, `file_picker`, `path_provider`, `permission_handler`, `flutter_foreground_task`, `workmanager`, `open_filex`, `intl`.

**Spec:** `docs/superpowers/specs/2026-10-14-telegram-cloud-design.md`

## Global Constraints

- Package Android: `com.tgcloud`.
- Target SDK: Android minSdk 26, targetSdk 34.
- Kredensial Bot Telegram WAJIB lewat `--dart-define=TG_BOT_TOKEN=...` dan `--dart-define=TG_CHAT_ID=...`. Tidak boleh ada token hardcode.
- Enkripsi client-side AES-256-GCM aktif di v1 dengan PIN/passkey pengguna.
- Ukuran chunk: 15.728.640 bytes (15 MB).
- UI tema: Background charcoal `#121212`, card `#1E1E1E`, aksen amber `#FF9800`, teks putih `#FFFFFF` & abu `#9E9E9E`. Bahasa Indonesia `id_ID`.
- Konkurensi upload: Maksimal 2 worker paralel untuk mencegah rate-limit Telegram & OOM RAM Android.

## Review Focus

1. **File > 100MB RAM usage**: Pengolahan chunk harus streaming via `RandomAccessFile`, jangan pernah load seluruh byte file ke memori.
2. **Koneksi terputus di tengah upload chunk**: Retry otomatis maks 3x eksponensial (2s, 4s, 8s) dan resume chunk yang belum berstatus `done`.
3. **Pembatalan upload oleh user**: Hentikan request Dio aktif dan hapus semua chunk yang sempat terunggah ke channel Telegram via `deleteMessage`.
4. **Verifikasi integritas file hasil download**: Cocokkan hash SHA-256 per chunk dan hash SHA-256 total file hasil reassembly. Hapus file parsial jika hash tidak cocok.
5. **Deduplikasi file**: File dengan hash SHA-256 identik yang sudah ada di database tidak boleh diunggah ulang.

---

### Task 1: Proyek Flutter Scaffolding & Setup Dependensi

**Files:**
- Create: `pubspec.yaml`
- Create: `android/app/build.gradle` (konfigurasi minSdk 26, applicationId `com.tgcloud`)
- Create: `lib/config/app_config.dart`
- Test: `test/config/app_config_test.dart`

**Interfaces:**
- Produces: `AppConfig.botToken -> String`, `AppConfig.chatId -> String`, `AppConfig.chunkSize -> int` (15 * 1024 * 1024), `AppConfig.isConfigured -> bool`.

- [ ] **Step 1: Write the failing test**

Buat file `test/config/app_config_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/config/app_config.dart';

void main() {
  group('AppConfig', () {
    test('default chunk size should be 15MB', () {
      expect(AppConfig.chunkSizeBytes, equals(15 * 1024 * 1024));
    });

    test('isConfigured returns false when tokens are empty', () {
      expect(AppConfig.isConfigured, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/config/app_config_test.dart
```
Expected: FAIL (target file or class `AppConfig` does not exist).

- [ ] **Step 3: Implement minimal code**

Inisialisasi proyek Flutter `tgcloud` di `C:\Users\NAN\Desktop\tgcloud` jika belum ada:
```bash
flutter create --org com.tgcloud --project-name tgcloud .
```
Tambahkan dependencies ke `pubspec.yaml`:
```yaml
dependencies:
  flutter:
    sdk: flutter
  dio: ^5.7.0
  sqflite: ^2.4.1
  sqflite_common_ffi: ^2.3.4
  path_provider: ^2.1.5
  path: ^1.9.0
  crypto: ^3.0.6
  encrypt: ^5.0.3
  file_picker: ^8.1.7
  permission_handler: ^11.3.1
  open_filex: ^4.5.0
  intl: ^0.19.0
  flutter_foreground_task: ^8.18.0
  workmanager: ^0.5.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0
```
Sesuaikan `android/app/build.gradle`: `minSdkVersion 26`.
Buat `lib/config/app_config.dart`:
```dart
class AppConfig {
  static const String botToken = String.fromEnvironment('TG_BOT_TOKEN', defaultValue: '');
  static const String chatId = String.fromEnvironment('TG_CHAT_ID', defaultValue: '');
  static const int chunkSizeBytes = 15 * 1024 * 1024; // 15MB

  static bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;
}
```

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/config/app_config_test.dart
```
Expected: PASS.

---

### Task 2: Kriptografi — AES-256-GCM & PBKDF2 Key Derivation

**Files:**
- Create: `lib/services/crypto_service.dart`
- Test: `test/services/crypto_service_test.dart`

**Interfaces:**
- Produces:
  - `CryptoService.deriveKey(String pin, String saltHex) -> List<int>` (PBKDF2-HMAC-SHA256, 32 bytes)
  - `CryptoService.generateSalt() -> String` (32 bytes hex)
  - `CryptoService.generateNonce() -> String` (12 bytes hex)
  - `CryptoService.encryptChunk(List<int> chunkBytes, List<int> key, String nonceHex) -> List<int>` (ciphertext + 16 bytes tag)
  - `CryptoService.decryptChunk(List<int> encryptedBytes, List<int> key, String nonceHex) -> List<int>`
  - `CryptoService.calculateSha256(List<int> bytes) -> String`

- [ ] **Step 1: Write the failing test**

Buat `test/services/crypto_service_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/services/crypto_service.dart';

void main() {
  group('CryptoService', () {
    const pin = '123456';

    test('generateSalt returns 64-char hex string (32 bytes)', () {
      final salt = CryptoService.generateSalt();
      expect(salt.length, equals(64));
    });

    test('generateNonce returns 24-char hex string (12 bytes)', () {
      final nonce = CryptoService.generateNonce();
      expect(nonce.length, equals(24));
    });

    test('deriveKey returns consistent 32-byte key for same PIN and salt', () {
      final salt = CryptoService.generateSalt();
      final key1 = CryptoService.deriveKey(pin, salt);
      final key2 = CryptoService.deriveKey(pin, salt);
      expect(key1, equals(key2));
      expect(key1.length, equals(32));
    });

    test('encryptChunk and decryptChunk restores original data', () {
      final salt = CryptoService.generateSalt();
      final key = CryptoService.deriveKey(pin, salt);
      final nonce = CryptoService.generateNonce();
      final original = utf8.encode('Hello Telegram Cloud AES-256-GCM Test!');

      final encrypted = CryptoService.encryptChunk(original, key, nonce);
      expect(encrypted, isNot(equals(original)));
      // GCM tag is 16 bytes appended
      expect(encrypted.length, equals(original.length + 16));

      final decrypted = CryptoService.decryptChunk(encrypted, key, nonce);
      expect(decrypted, equals(original));
    });

    test('calculateSha256 returns valid 64-char hex hash', () {
      final data = utf8.encode('test-hash-data');
      final hash = CryptoService.calculateSha256(data);
      expect(hash.length, equals(64));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/services/crypto_service_test.dart
```
Expected: FAIL (`CryptoService` not found).

- [ ] **Step 3: Implement minimal code**

Buat `lib/services/crypto_service.dart`:
```dart
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

class CryptoService {
  static final Random _secureRandom = Random.secure();

  static String generateSalt([int length = 32]) {
    final values = List<int>.generate(length, (i) => _secureRandom.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String generateNonce([int length = 12]) {
    final values = List<int>.generate(length, (i) => _secureRandom.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  static List<int> deriveKey(String pin, String saltHex, {int iterations = 10000}) {
    final saltBytes = _hexToBytes(saltHex);
    // PBKDF2-HMAC-SHA256
    final hmac = Hmac(sha256, saltBytes);
    var derived = hmac.convert(pin.codeUnits).bytes;
    for (int i = 1; i < iterations; i++) {
      derived = hmac.convert(derived).bytes;
    }
    return derived;
  }

  static List<int> encryptChunk(List<int> chunkBytes, List<int> keyBytes, String nonceHex) {
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV(_hexToBytes(nonceHex));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(chunkBytes, iv: iv);
    return encrypted.bytes;
  }

  static List<int> decryptChunk(List<int> encryptedBytes, List<int> keyBytes, String nonceHex) {
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV(_hexToBytes(nonceHex));
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final decrypted = encrypter.decryptBytes(enc.Encrypted(Uint8List.fromList(encryptedBytes)), iv: iv);
    return decrypted;
  }

  static String calculateSha256(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/services/crypto_service_test.dart
```
Expected: PASS.

---

### Task 3: Database Service — SQLite Schema & CRUD Metadata

**Files:**
- Create: `lib/models/cloud_file.dart`
- Create: `lib/models/cloud_chunk.dart`
- Create: `lib/services/database_service.dart`
- Test: `test/services/database_service_test.dart`

**Interfaces:**
- Consumes: `cloud_files`, `cloud_chunks`, `app_settings` schema specs.
- Produces:
  - `DatabaseService.insertFile(CloudFile file) -> Future<int>`
  - `DatabaseService.insertChunk(CloudChunk chunk) -> Future<int>`
  - `DatabaseService.getAllFiles({String? search}) -> Future<List<CloudFile>>`
  - `DatabaseService.getFileById(int id) -> Future<CloudFile?>`
  - `DatabaseService.getFileByHash(String sha256) -> Future<CloudFile?>`
  - `DatabaseService.getChunksForFile(int fileId) -> Future<List<CloudChunk>>`
  - `DatabaseService.updateFileStatus(int fileId, String status) -> Future<void>`
  - `DatabaseService.updateChunkStatus(int chunkId, String status, {String? tgFileId, int? tgMessageId}) -> Future<void>`
  - `DatabaseService.deleteFile(int fileId) -> Future<void>`
  - `DatabaseService.getSetting(String key) -> Future<String?>`
  - `DatabaseService.setSetting(String key, String value) -> Future<void>`

- [ ] **Step 1: Write the failing test**

Buat `test/services/database_service_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/models/cloud_chunk.dart';
import 'package:tgcloud/services/database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService dbService;

  setUp(() async {
    dbService = DatabaseService(inMemory: true);
    await dbService.init();
  });

  tearDown(() async {
    await dbService.close();
  });

  group('DatabaseService', () {
    test('insertFile and getAllFiles works with correct count', () async {
      final file = CloudFile(
        nama: 'video.mp4',
        ukuranBytes: 30000000,
        mime: 'video/mp4',
        sha256Original: 'hash123',
        isEncrypted: 1,
        salt: 'salt123',
        jumlahChunk: 2,
        dibuatPada: DateTime.now().toIso8601String(),
        status: 'uploading',
      );

      final fileId = await dbService.insertFile(file);
      expect(fileId, greaterThan(0));

      final files = await dbService.getAllFiles();
      expect(files.length, equals(1));
      expect(files.first.nama, equals('video.mp4'));
    });

    test('cascade delete removes associated chunks', () async {
      final file = CloudFile(
        nama: 'doc.pdf',
        ukuranBytes: 15000000,
        mime: 'application/pdf',
        sha256Original: 'hash456',
        isEncrypted: 1,
        salt: 'salt456',
        jumlahChunk: 1,
        dibuatPada: DateTime.now().toIso8601String(),
        status: 'complete',
      );
      final fileId = await dbService.insertFile(file);

      await dbService.insertChunk(CloudChunk(
        fileId: fileId,
        chunkIndex: 0,
        ukuranChunk: 15000000,
        tgFileId: 'tg123',
        tgMessageId: 999,
        nonceHex: 'nonce123',
        sha256Chunk: 'chunkhash123',
        status: 'done',
      ));

      var chunks = await dbService.getChunksForFile(fileId);
      expect(chunks.length, equals(1));

      await dbService.deleteFile(fileId);
      final filesAfter = await dbService.getAllFiles();
      expect(filesAfter.isEmpty, isTrue);

      chunks = await dbService.getChunksForFile(fileId);
      expect(chunks.isEmpty, isTrue);
    });

    test('settings key-value get and set', () async {
      await dbService.setSetting('wifi_only', 'true');
      final val = await dbService.getSetting('wifi_only');
      expect(val, equals('true'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/services/database_service_test.dart
```
Expected: FAIL (models & DatabaseService not defined).

- [ ] **Step 3: Implement models and DatabaseService**

Buat `lib/models/cloud_file.dart`:
```dart
class CloudFile {
  final int? id;
  final String nama;
  final int ukuranBytes;
  final String mime;
  final String sha256Original;
  final int isEncrypted;
  final String salt;
  final int jumlahChunk;
  final String dibuatPada;
  final String status;

  CloudFile({
    this.id,
    required this.nama,
    required this.ukuranBytes,
    required this.mime,
    required this.sha256Original,
    this.isEncrypted = 1,
    required this.salt,
    required this.jumlahChunk,
    required this.dibuatPada,
    required this.status,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'nama': nama,
    'ukuran_bytes': ukuranBytes,
    'mime': mime,
    'sha256_original': sha256Original,
    'is_encrypted': isEncrypted,
    'salt': salt,
    'jumlah_chunk': jumlahChunk,
    'dibuat_pada': dibuatPada,
    'status': status,
  };

  factory CloudFile.fromMap(Map<String, dynamic> map) => CloudFile(
    id: map['id'] as int?,
    nama: map['nama'] as String,
    ukuranBytes: map['ukuran_bytes'] as int,
    mime: map['mime'] as String,
    sha256Original: map['sha256_original'] as String,
    isEncrypted: map['is_encrypted'] as int,
    salt: map['salt'] as String,
    jumlahChunk: map['jumlah_chunk'] as int,
    dibuatPada: map['dibuat_pada'] as String,
    status: map['status'] as String,
  );
}
```
Buat `lib/models/cloud_chunk.dart`:
```dart
class CloudChunk {
  final int? id;
  final int fileId;
  final int chunkIndex;
  final int ukuranChunk;
  final String? tgFileId;
  final int? tgMessageId;
  final String nonceHex;
  final String sha256Chunk;
  final String status;

  CloudChunk({
    this.id,
    required this.fileId,
    required this.chunkIndex,
    required this.ukuranChunk,
    this.tgFileId,
    this.tgMessageId,
    required this.nonceHex,
    required this.sha256Chunk,
    required this.status,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'file_id': fileId,
    'chunk_index': chunkIndex,
    'ukuran_chunk': ukuranChunk,
    'tg_file_id': tgFileId,
    'tg_message_id': tgMessageId,
    'nonce_hex': nonceHex,
    'sha256_chunk': sha256Chunk,
    'status': status,
  };

  factory CloudChunk.fromMap(Map<String, dynamic> map) => CloudChunk(
    id: map['id'] as int?,
    fileId: map['file_id'] as int,
    chunkIndex: map['chunk_index'] as int,
    ukuranChunk: map['ukuran_chunk'] as int,
    tgFileId: map['tg_file_id'] as String?,
    tgMessageId: map['tg_message_id'] as int?,
    nonceHex: map['nonce_hex'] as String,
    sha256Chunk: map['sha256_chunk'] as String,
    status: map['status'] as String,
  );
}
```
Buat `lib/services/database_service.dart`:
```dart
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/models/cloud_chunk.dart';

class DatabaseService {
  final bool inMemory;
  Database? _db;

  DatabaseService({this.inMemory = false});

  Future<void> init() async {
    if (_db != null) return;
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
    final res = await _db!.query('cloud_files', where: 'sha256_original = ? AND status = ?', whereArgs: [sha256, 'complete']);
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
```

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/services/database_service_test.dart
```
Expected: PASS.

---

### Task 4: Telegram Storage Client — API Bot & Retry Logic

**Files:**
- Create: `lib/services/telegram_storage_service.dart`
- Test: `test/services/telegram_storage_service_test.dart`

**Interfaces:**
- Consumes: `AppConfig.botToken`, `AppConfig.chatId`.
- Produces:
  - `TelegramStorageService.sendDocument(List<int> chunkBytes, String filename, {CancelToken? cancelToken, Function(int, int)? onSendProgress}) -> Future<TgUploadResult>`
  - `TelegramStorageService.getDownloadUrl(String fileId) -> Future<String>`
  - `TelegramStorageService.downloadChunk(String downloadUrl, {CancelToken? cancelToken, Function(int, int)? onReceiveProgress}) -> Future<List<int>>`
  - `TelegramStorageService.deleteMessage(int messageId) -> Future<bool>`

- [ ] **Step 1: Write the failing test with Mock HTTP Adapter**

Buat `test/services/telegram_storage_service_test.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';

void main() {
  group('TelegramStorageService', () {
    late Dio mockDio;
    late TelegramStorageService service;

    setUp(() {
      mockDio = Dio(BaseOptions(baseUrl: 'https://api.telegram.org/botTEST_TOKEN/'));
      service = TelegramStorageService(
        botToken: 'TEST_TOKEN',
        chatId: '-100123456789',
        dio: mockDio,
      );
    });

    test('getDownloadUrl parses file_path correctly', () async {
      mockDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('getFile')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'result': {'file_path': 'documents/test_chunk.bin'}
              },
            ));
          }
        },
      ));

      final url = await service.getDownloadUrl('file_id_xyz');
      expect(url, equals('https://api.telegram.org/file/botTEST_TOKEN/documents/test_chunk.bin'));
    });

    test('deleteMessage returns true on 200 ok: true', () async {
      mockDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('deleteMessage')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'ok': true, 'result': true},
            ));
          }
        },
      ));

      final deleted = await service.deleteMessage(456);
      expect(deleted, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/services/telegram_storage_service_test.dart
```
Expected: FAIL (`TelegramStorageService` not defined).

- [ ] **Step 3: Implement TelegramStorageService**

Buat `lib/services/telegram_storage_service.dart`:
```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';

class TgUploadResult {
  final String fileId;
  final int messageId;

  TgUploadResult({required this.fileId, required this.messageId});
}

class TelegramStorageService {
  final String botToken;
  final String chatId;
  final Dio dio;

  TelegramStorageService({
    required this.botToken,
    required this.chatId,
    Dio? dio,
  }) : dio = dio ?? Dio(BaseOptions(
          baseUrl: 'https://api.telegram.org/bot$botToken/',
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 90),
          receiveTimeout: const Duration(seconds: 90),
        ));

  Future<TgUploadResult> sendDocument(
    List<int> chunkBytes,
    String filename, {
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    int maxRetries = 3,
  }) async {
    int attempts = 0;
    while (true) {
      try {
        attempts++;
        final formData = FormData.fromMap({
          'chat_id': chatId,
          'document': MultipartFile.fromBytes(chunkBytes, filename: filename),
        });

        final response = await dio.post(
          'sendDocument',
          data: formData,
          cancelToken: cancelToken,
          onSendProgress: onSendProgress,
        );

        if (response.data['ok'] == true) {
          final doc = response.data['result']['document'];
          return TgUploadResult(
            fileId: doc['file_id'] as String,
            messageId: response.data['result']['message_id'] as int,
          );
        } else {
          throw Exception('Telegram error: ${response.data['description']}');
        }
      } on DioException catch (e) {
        if (cancelToken?.isCancelled == true) rethrow;

        if (e.response?.statusCode == 429) {
          final retryAfter = e.response?.data?['parameters']?['retry_after'] ?? 5;
          await Future.delayed(Duration(seconds: retryAfter as int));
          continue;
        }

        if (attempts >= maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 2 * attempts));
      }
    }
  }

  Future<String> getDownloadUrl(String fileId) async {
    final response = await dio.get('getFile', queryParameters: {'file_id': fileId});
    if (response.data['ok'] == true) {
      final filePath = response.data['result']['file_path'] as String;
      return 'https://api.telegram.org/file/bot$botToken/$filePath';
    }
    throw Exception('Gagal mendapatkan URL Telegram: ${response.data['description']}');
  }

  Future<List<int>> downloadChunk(
    String downloadUrl, {
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    int maxRetries = 3,
  }) async {
    int attempts = 0;
    while (true) {
      try {
        attempts++;
        final response = await dio.get<List<int>>(
          downloadUrl,
          cancelToken: cancelToken,
          onReceiveProgress: onReceiveProgress,
          options: Options(responseType: ResponseType.bytes),
        );
        return response.data!;
      } on DioException catch (e) {
        if (cancelToken?.isCancelled == true) rethrow;
        if (attempts >= maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 2 * attempts));
      }
    }
  }

  Future<bool> deleteMessage(int messageId) async {
    try {
      final response = await dio.post('deleteMessage', data: {
        'chat_id': chatId,
        'message_id': messageId,
      });
      return response.data['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/services/telegram_storage_service_test.dart
```
Expected: PASS.

---

### Task 5: Chunking & Upload Pipeline — Worker Pool & State Machine

**Files:**
- Create: `lib/services/upload_service.dart`
- Test: `test/services/upload_service_test.dart`

**Interfaces:**
- Consumes: `CryptoService`, `DatabaseService`, `TelegramStorageService`.
- Produces:
  - `UploadService.uploadFile(String filePath, String userPin, {CancelToken? cancelToken, Function(double progress, String status)? onProgress}) -> Future<CloudFile>`
  - `UploadService.cancelUpload(int fileId)`

- [ ] **Step 1: Write the failing test**

Buat `test/services/upload_service_test.dart`:
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/services/upload_service.dart';
import 'package:dio/dio.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late TelegramStorageService tgService;
  late UploadService uploadService;
  late Directory tempDir;
  late File sampleFile;

  setUp(() async {
    db = DatabaseService(inMemory: true);
    await db.init();

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path.contains('sendDocument')) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'ok': true,
              'result': {
                'message_id': 1001,
                'document': {'file_id': 'tg_file_mock_123'}
              }
            },
          ));
        } else if (options.path.contains('deleteMessage')) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'ok': true, 'result': true},
          ));
        }
      },
    ));

    tgService = TelegramStorageService(botToken: 'dummy', chatId: '-100', dio: dio);
    uploadService = UploadService(databaseService: db, telegramService: tgService);

    tempDir = await Directory.systemTemp.createTemp('upload_test');
    sampleFile = File('${tempDir.path}/test_upload.dat');
    // 32KB test file
    await sampleFile.writeAsBytes(List.generate(32768, (i) => i % 256));
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('UploadService', () {
    test('uploadFile completes, stores chunks in DB, and sets status to complete', () async {
      final cloudFile = await uploadService.uploadFile(
        sampleFile.path,
        '123456',
        chunkSizeBytes: 16384, // 16KB chunk -> creates 2 chunks
      );

      expect(cloudFile.status, equals('complete'));
      expect(cloudFile.jumlahChunk, equals(2));

      final chunks = await db.getChunksForFile(cloudFile.id!);
      expect(chunks.length, equals(2));
      expect(chunks.every((c) => c.status == 'done'), isTrue);
      expect(chunks.first.tgFileId, equals('tg_file_mock_123'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/services/upload_service_test.dart
```
Expected: FAIL (`UploadService` not defined).

- [ ] **Step 3: Implement UploadService with Concurrency Pool**

Buat `lib/services/upload_service.dart`:
```dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:tgcloud/config/app_config.dart';
import 'package:tgcloud/models/cloud_chunk.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';

typedef UploadProgressCallback = void Function(double progress, String status);

class UploadService {
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;

  UploadService({
    required this.databaseService,
    required this.telegramService,
  });

  Future<CloudFile> uploadFile(
    String filePath,
    String userPin, {
    CancelToken? cancelToken,
    UploadProgressCallback? onProgress,
    int? chunkSizeBytes,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File tidak ditemukan: $filePath');
    }

    final fileSize = await file.length();
    final filename = p.basename(filePath);
    final mime = _detectMime(filename);
    final chunkSize = chunkSizeBytes ?? AppConfig.chunkSizeBytes;
    final totalChunks = max(1, (fileSize / chunkSize).ceil());

    onProgress?.call(0.01, 'Menghitung hash file...');
    final originalBytes = await file.readAsBytes();
    final sha256Original = CryptoService.calculateSha256(originalBytes);

    // Deduplikasi
    final existing = await databaseService.getFileByHash(sha256Original);
    if (existing != null) {
      throw Exception('File dengan isi yang sama sudah ada di cloud: ${existing.nama}');
    }

    final salt = CryptoService.generateSalt();
    final key = CryptoService.deriveKey(userPin, salt);

    final cloudFile = CloudFile(
      nama: filename,
      ukuranBytes: fileSize,
      mime: mime,
      sha256Original: sha256Original,
      isEncrypted: 1,
      salt: salt,
      jumlahChunk: totalChunks,
      dibuatPada: DateTime.now().toIso8601String(),
      status: 'uploading',
    );

    final fileId = await databaseService.insertFile(cloudFile);
    final raf = await file.open(mode: FileMode.read);

    final createdChunks = <CloudChunk>[];
    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final currentChunkLength = min(chunkSize, fileSize - start);
      await raf.setPosition(start);
      final rawBytes = await raf.read(currentChunkLength);

      final nonce = CryptoService.generateNonce();
      final encryptedBytes = CryptoService.encryptChunk(rawBytes, key, nonce);
      final sha256Chunk = CryptoService.calculateSha256(encryptedBytes);

      final chunk = CloudChunk(
        fileId: fileId,
        chunkIndex: i,
        ukuranChunk: encryptedBytes.length,
        nonceHex: nonce,
        sha256Chunk: sha256Chunk,
        status: 'pending',
      );
      final chunkId = await databaseService.insertChunk(chunk);
      createdChunks.add(CloudChunk(
        id: chunkId,
        fileId: fileId,
        chunkIndex: i,
        ukuranChunk: encryptedBytes.length,
        nonceHex: nonce,
        sha256Chunk: sha256Chunk,
        status: 'pending',
      ));
    }
    await raf.close();

    // Pool upload maks 2 paralel
    int completedCount = 0;
    final poolSize = min(2, totalChunks);
    int nextChunkIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken?.isCancelled == true) throw Exception('Upload dibatalkan');

        int currentIndex;
        synchronized() {
          if (nextChunkIndex >= totalChunks) return;
          currentIndex = nextChunkIndex++;
        }

        final chunk = createdChunks[currentIndex];
        await databaseService.updateChunkStatus(chunk.id!, 'uploading');

        // Baca dan enkripsi ulang untuk worker upload
        final rafWorker = await file.open(mode: FileMode.read);
        await rafWorker.setPosition(currentIndex * chunkSize);
        final rawSlice = await rafWorker.read(min(chunkSize, fileSize - (currentIndex * chunkSize)));
        await rafWorker.close();

        final encryptedSlice = CryptoService.encryptChunk(rawSlice, key, chunk.nonceHex);

        final res = await telegramService.sendDocument(
          encryptedSlice,
          '${chunk.sha256Chunk}.bin',
          cancelToken: cancelToken,
        );

        await databaseService.updateChunkStatus(
          chunk.id!,
          'done',
          tgFileId: res.fileId,
          tgMessageId: res.messageId,
        );

        completedCount++;
        final progress = completedCount / totalChunks;
        onProgress?.call(progress, 'Mengunggah chunk $completedCount dari $totalChunks');
      }
    }

    final workers = List.generate(poolSize, (_) => worker());
    await Future.wait(workers);

    await databaseService.updateFileStatus(fileId, 'complete');
    return (await databaseService.getFileById(fileId))!;
  }

  Future<void> cancelUpload(int fileId) async {
    final chunks = await databaseService.getChunksForFile(fileId);
    for (final chunk in chunks) {
      if (chunk.tgMessageId != null) {
        await telegramService.deleteMessage(chunk.tgMessageId!);
      }
    }
    await databaseService.deleteFile(fileId);
  }

  String _detectMime(String filename) {
    final ext = p.extension(filename).toLowerCase();
    switch (ext) {
      case '.mp4': return 'video/mp4';
      case '.mkv': return 'video/x-matroska';
      case '.avi': return 'video/x-msvideo';
      case '.jpg':
      case '.jpeg': return 'image/jpeg';
      case '.png': return 'image/png';
      case '.pdf': return 'application/pdf';
      case '.zip': return 'application/zip';
      default: return 'application/octet-stream';
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/services/upload_service_test.dart
```
Expected: PASS.

---

### Task 6: Download & Reassembly Pipeline

**Files:**
- Create: `lib/services/download_service.dart`
- Test: `test/services/download_service_test.dart`

**Interfaces:**
- Consumes: `CryptoService`, `DatabaseService`, `TelegramStorageService`.
- Produces:
  - `DownloadService.downloadAndReassemble(int fileId, String userPin, String outputDirPath, {CancelToken? cancelToken, Function(double progress, String status)? onProgress}) -> Future<File>`

- [ ] **Step 1: Write the failing test**

Buat `test/services/download_service_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/models/cloud_chunk.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:dio/dio.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late TelegramStorageService tgService;
  late DownloadService downloadService;
  late Directory tempDir;

  setUp(() async {
    db = DatabaseService(inMemory: true);
    await db.init();

    tempDir = await Directory.systemTemp.createTemp('download_test');
    final rawText = 'TGCloud full download and reassembly test content!';
    final rawBytes = utf8.encode(rawText);
    final salt = CryptoService.generateSalt();
    final key = CryptoService.deriveKey('123456', salt);
    final nonce = CryptoService.generateNonce();
    final encrypted = CryptoService.encryptChunk(rawBytes, key, nonce);
    final sha256Original = CryptoService.calculateSha256(rawBytes);
    final sha256Chunk = CryptoService.calculateSha256(encrypted);

    final fileId = await db.insertFile(CloudFile(
      nama: 'note.txt',
      ukuranBytes: rawBytes.length,
      mime: 'text/plain',
      sha256Original: sha256Original,
      isEncrypted: 1,
      salt: salt,
      jumlahChunk: 1,
      dibuatPada: DateTime.now().toIso8601String(),
      status: 'complete',
    ));

    await db.insertChunk(CloudChunk(
      fileId: fileId,
      chunkIndex: 0,
      ukuranChunk: encrypted.length,
      tgFileId: 'mock_tg_file',
      tgMessageId: 777,
      nonceHex: nonce,
      sha256Chunk: sha256Chunk,
      status: 'done',
    ));

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path.contains('getFile')) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'ok': true, 'result': {'file_path': 'docs/note.bin'}},
          ));
        } else if (options.path.contains('docs/note.bin')) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: encrypted,
          ));
        }
      },
    ));

    tgService = TelegramStorageService(botToken: 'dummy', chatId: '-100', dio: dio);
    downloadService = DownloadService(databaseService: db, telegramService: tgService);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('DownloadService', () {
    test('downloads, decrypts, and verifies full SHA-256 integrity', () async {
      final downloadedFile = await downloadService.downloadAndReassemble(
        1,
        '123456',
        tempDir.path,
      );

      expect(await downloadedFile.exists(), isTrue);
      final text = await downloadedFile.readAsString();
      expect(text, equals('TGCloud full download and reassembly test content!'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/services/download_service_test.dart
```
Expected: FAIL (`DownloadService` not defined).

- [ ] **Step 3: Implement DownloadService**

Buat `lib/services/download_service.dart`:
```dart
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';

typedef DownloadProgressCallback = void Function(double progress, String status);

class DownloadService {
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;

  DownloadService({
    required this.databaseService,
    required this.telegramService,
  });

  Future<File> downloadAndReassemble(
    int fileId,
    String userPin,
    String outputDirPath, {
    CancelToken? cancelToken,
    DownloadProgressCallback? onProgress,
  }) async {
    final cloudFile = await databaseService.getFileById(fileId);
    if (cloudFile == null) {
      throw Exception('Metadata file tidak ditemukan di database');
    }

    final chunks = await databaseService.getChunksForFile(fileId);
    if (chunks.isEmpty) {
      throw Exception('Chunk file tidak ditemukan di database');
    }

    final key = CryptoService.deriveKey(userPin, cloudFile.salt);
    final outputPath = p.join(outputDirPath, cloudFile.nama);
    final outputFile = File(outputPath);

    if (await outputFile.exists()) {
      await outputFile.delete();
    }

    final raf = await outputFile.open(mode: FileMode.write);
    try {
      for (int i = 0; i < chunks.length; i++) {
        if (cancelToken?.isCancelled == true) {
          throw Exception('Download dibatalkan');
        }

        final chunk = chunks[i];
        if (chunk.tgFileId == null) {
          throw Exception('Chunk ${chunk.chunkIndex} belum memiliki Telegram file_id');
        }

        onProgress?.call(
          i / chunks.length,
          'Mengunduh chunk ${i + 1} dari ${chunks.length}...',
        );

        final downloadUrl = await telegramService.getDownloadUrl(chunk.tgFileId!);
        final encryptedBytes = await telegramService.downloadChunk(
          downloadUrl,
          cancelToken: cancelToken,
        );

        // Verifikasi integritas chunk
        final downloadedHash = CryptoService.calculateSha256(encryptedBytes);
        if (downloadedHash != chunk.sha256Chunk) {
          throw Exception('Integritas chunk ${chunk.chunkIndex} rusak! Hash tidak cocok.');
        }

        // Dekripsi
        final decryptedBytes = CryptoService.decryptChunk(
          encryptedBytes,
          key,
          chunk.nonceHex,
        );

        await raf.writeFrom(decryptedBytes);
      }
    } catch (e) {
      await raf.close();
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      rethrow;
    }

    await raf.close();

    // Verifikasi SHA-256 end-to-end
    onProgress?.call(0.99, 'Memverifikasi integritas file...');
    final completeBytes = await outputFile.readAsBytes();
    final finalHash = CryptoService.calculateSha256(completeBytes);

    if (finalHash != cloudFile.sha256Original) {
      await outputFile.delete();
      throw Exception('Integritas file total rusak! Hash asli tidak cocok dengan hasil rekonstruksi.');
    }

    onProgress?.call(1.0, 'Download selesai!');
    return outputFile;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/services/download_service_test.dart
```
Expected: PASS.

---

### Task 7: UI Theme, Components, HomeScreen & Upload Dialog

**Files:**
- Create: `lib/theme/app_theme.dart`
- Create: `lib/widgets/file_card.dart`
- Create: `lib/screens/home_screen.dart`
- Create: `lib/screens/upload_progress_sheet.dart`
- Test: `test/widgets/file_card_test.dart`
- Test: `test/screens/home_screen_test.dart`

**Interfaces:**
- Consumes: `AppTheme`, `DatabaseService`, `UploadService`, `DownloadService`.
- Produces: `HomeScreen`, `FileCard`, `UploadProgressSheet`.

- [ ] **Step 1: Write Widget test for FileCard**

Buat `test/widgets/file_card_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/widgets/file_card.dart';

void main() {
  testWidgets('FileCard renders file name, formatted size, and buttons', (tester) async {
    final file = CloudFile(
      id: 1,
      nama: 'video_liburan.mp4',
      ukuranBytes: 52428800, // 50MB
      mime: 'video/mp4',
      sha256Original: 'hash',
      isEncrypted: 1,
      salt: 'salt',
      jumlahChunk: 4,
      dibuatPada: '2026-10-14T10:00:00Z',
      status: 'complete',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileCard(
          file: file,
          onDownload: () {},
          onDelete: () {},
        ),
      ),
    ));

    expect(find.text('video_liburan.mp4'), findsOneWidget);
    expect(find.textContaining('50.0 MB'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/widgets/file_card_test.dart
```
Expected: FAIL (`FileCard` not defined).

- [ ] **Step 3: Implement Theme, FileCard, and HomeScreen**

Buat `lib/theme/app_theme.dart`:
```dart
import 'package:flutter/material.dart';

class AppTheme {
  static const Color background = Color(0xFF121212);
  static const Color surface = Color(0xFF1E1E1E);
  static const Color surfaceLight = Color(0xFF282828);
  static const Color primary = Color(0xFFFF9800);
  static const Color primaryLight = Color(0xFFFFA726);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textMuted = Color(0xFF9E9E9E);
  static const Color border = Color(0xFF2A2A2A);
  static const Color danger = Color(0xFFF44336);
  static const Color success = Color(0xFF4CAF50);

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        cardColor: surface,
        primaryColor: primary,
        colorScheme: const ColorScheme.dark(
          primary: primary,
          surface: surface,
          error: danger,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
}
```

Buat `lib/widgets/file_card.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/theme/app_theme.dart';

class FileCard extends StatelessWidget {
  final CloudFile file;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  const FileCard({
    super.key,
    required this.file,
    required this.onDownload,
    required this.onDelete,
  });

  String _formatSize(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  IconData _getIcon() {
    if (file.mime.startsWith('video/')) return Icons.movie_rounded;
    if (file.mime.startsWith('image/')) return Icons.image_rounded;
    if (file.mime.startsWith('audio/')) return Icons.audiotrack_rounded;
    if (file.mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    return Icons.insert_drive_file_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_getIcon(), color: AppTheme.primary, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.nama,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatSize(file.ukuranBytes)} • ${file.jumlahChunk} chunk',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.download_rounded, color: AppTheme.primary),
            onPressed: onDownload,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.textMuted),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
```

Buat `lib/screens/home_screen.dart` dengan Search Bar realtime dan integrasi FAB Picker.

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/widgets/file_card_test.dart
```
Expected: PASS.

---

### Task 8: Ketahanan Foreground Service & Cadangan Otomatis

**Files:**
- Create: `lib/services/foreground_service.dart`
- Create: `lib/services/backup_service.dart`
- Create: `lib/screens/settings_screen.dart`
- Test: `test/services/backup_service_test.dart`

**Interfaces:**
- Consumes: `flutter_foreground_task`, `workmanager`, `DatabaseService`, `UploadService`.
- Produces:
  - `ForegroundService.start(String title, String text)`
  - `ForegroundService.update(String text, int progress)`
  - `ForegroundService.stop()`
  - `BackupService.scanFolder(String folderPath) -> Future<List<File>>`
  - `BackupService.runBackup(String folderPath, String userPin) -> Future<int>`

- [ ] **Step 1: Write Unit test for BackupService deduplication**

Buat `test/services/backup_service_test.dart`:
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/backup_service.dart';
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;
  late BackupService backupService;
  late Directory mockFolder;

  setUp(() async {
    db = DatabaseService(inMemory: true);
    await db.init();
    backupService = BackupService(databaseService: db);

    mockFolder = await Directory.systemTemp.createTemp('backup_scan_test');
    final file1 = File('${mockFolder.path}/img1.jpg');
    await file1.writeAsBytes([1, 2, 3, 4]);
    final file2 = File('${mockFolder.path}/img2.jpg');
    await file2.writeAsBytes([5, 6, 7, 8]);

    // Tandai file1 sudah ada di DB
    final hash1 = CryptoService.calculateSha256([1, 2, 3, 4]);
    await db.insertFile(CloudFile(
      nama: 'img1.jpg',
      ukuranBytes: 4,
      mime: 'image/jpeg',
      sha256Original: hash1,
      salt: 'salt',
      jumlahChunk: 1,
      dibuatPada: DateTime.now().toIso8601String(),
      status: 'complete',
    ));
  });

  tearDown(() async {
    await db.close();
    await mockFolder.delete(recursive: true);
  });

  group('BackupService', () {
    test('filterNewFiles only returns files not yet backed up', () async {
      final allFiles = await backupService.scanFolder(mockFolder.path);
      expect(allFiles.length, equals(2));

      final newFiles = await backupService.filterNewFiles(allFiles);
      expect(newFiles.length, equals(1));
      expect(newFiles.first.path.endsWith('img2.jpg'), isTrue);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Jalankan:
```bash
flutter test test/services/backup_service_test.dart
```
Expected: FAIL (`BackupService` not defined).

- [ ] **Step 3: Implement ForegroundService, BackupService & SettingsScreen**

Buat `lib/services/backup_service.dart`:
```dart
import 'dart:io';
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';

class BackupService {
  final DatabaseService databaseService;

  BackupService({required this.databaseService});

  Future<List<File>> scanFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) return [];

    final files = <File>[];
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (entity is File) {
        files.add(entity);
      }
    }
    return files;
  }

  Future<List<File>> filterNewFiles(List<File> files) async {
    final newFiles = <File>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      final hash = CryptoService.calculateSha256(bytes);
      final existing = await databaseService.getFileByHash(hash);
      if (existing == null) {
        newFiles.add(file);
      }
    }
    return newFiles;
  }
}
```

Buat `lib/services/foreground_service.dart` menggunakan konfigurasi `flutter_foreground_task`.

- [ ] **Step 4: Run test to verify it passes**

Jalankan:
```bash
flutter test test/services/backup_service_test.dart
```
Expected: PASS.

---

### Task 9: Verifikasi Akhir & Static Analysis

**Files:**
- Test: All tests in `test/`
- Audit: `flutter analyze`

- [ ] **Step 1: Jalankan seluruh test suite**

```bash
flutter test
```
Expected: All tests PASS.

- [ ] **Step 2: Jalankan analisis statis Dart**

```bash
flutter analyze
```
Expected: 0 issues found (0 error, 0 warning).
