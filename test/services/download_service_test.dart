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
            data: {
              'ok': true,
              'result': {'file_path': 'docs/note.bin'}
            },
          ));
        } else if (options.path.contains('docs/note.bin')) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: encrypted,
          ));
        } else {
          handler.next(options);
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
