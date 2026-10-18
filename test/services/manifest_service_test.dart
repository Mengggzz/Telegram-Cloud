import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/models/cloud_chunk.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/manifest_service.dart';
import 'package:tgcloud/services/telegram_config_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService dbService;
  late ManifestService manifestService;

  setUp(() async {
    dbService = DatabaseService(inMemory: true);
    await dbService.init();
    manifestService = ManifestService(dbService);
  });

  tearDown(() async {
    await dbService.close();
  });

  group('ManifestService', () {
    test('buildBackup creates valid envelope and parseBackup recovers data with correct PIN', () async {
      final fileId = await dbService.insertFile(CloudFile(
        nama: 'secret.pdf',
        ukuranBytes: 1024,
        mime: 'application/pdf',
        sha256Original: 'hash123',
        salt: 'salt123',
        jumlahChunk: 1,
        dibuatPada: '2026-10-18T00:00:00Z',
        status: 'complete',
      ));

      await dbService.insertChunk(CloudChunk(
        fileId: fileId,
        chunkIndex: 0,
        ukuranChunk: 1024,
        tgFileId: 'tg123',
        tgMessageId: 999,
        nonceHex: 'nonce123',
        sha256Chunk: 'chunkhash123',
        status: 'uploaded',
      ));

      final envelope = await manifestService.buildBackup('123456');

      expect(envelope['format'], equals('tgcloud-backup'));
      expect(envelope['version'], equals(1));
      expect(envelope['exported_at'], isNotNull);
      expect(envelope['salt'], isNotEmpty);
      expect(envelope['nonce'], isNotEmpty);
      expect(envelope['payload'], isNotEmpty);

      final parsed = await manifestService.parseBackup(envelope, '123456');
      expect(parsed['files']!.length, equals(1));
      expect(parsed['files']!.first['nama'], equals('secret.pdf'));
      expect(parsed['chunks']!.length, equals(1));
      expect(parsed['chunks']!.first['tg_file_id'], equals('tg123'));
    });

    test('parseBackup throws on wrong PIN', () async {
      await dbService.insertFile(CloudFile(
        nama: 'data.txt',
        ukuranBytes: 50,
        mime: 'text/plain',
        sha256Original: 'abc',
        salt: 'salt',
        jumlahChunk: 1,
        dibuatPada: '2026-10-18T00:00:00Z',
        status: 'complete',
      ));

      final envelope = await manifestService.buildBackup('123456');
      expect(
        () => manifestService.parseBackup(envelope, '654321'),
        throwsA(isA<Exception>()),
      );
    });

    test('parseBackup throws when version > 1', () async {
      final envelope = {
        'format': 'tgcloud-backup',
        'version': 2,
        'exported_at': DateTime.now().toIso8601String(),
        'salt': 'abcdef',
        'nonce': '123456',
        'payload': 'cafebabe',
      };

      expect(
        () => manifestService.parseBackup(envelope, '123456'),
        throwsA(predicate((e) => e.toString().contains('Format cadangan lebih baru, update aplikasi dulu'))),
      );
    });

    test('parseBackup throws when format is unknown', () async {
      final envelope = {
        'format': 'unknown-backup',
        'version': 1,
        'exported_at': DateTime.now().toIso8601String(),
        'salt': 'abcdef',
        'nonce': '123456',
        'payload': 'cafebabe',
      };

      expect(
        () => manifestService.parseBackup(envelope, '123456'),
        throwsA(isA<Exception>()),
      );
    });

    test('replaceDatabase deletes existing data and restores backup data with preserved IDs', () async {
      // Data lama di DB
      final oldId = await dbService.insertFile(CloudFile(
        nama: 'old.txt',
        ukuranBytes: 10,
        mime: 'text/plain',
        sha256Original: 'oldhash',
        salt: 'oldsalt',
        jumlahChunk: 1,
        dibuatPada: '2026-10-18T00:00:00Z',
        status: 'complete',
      ));
      await dbService.insertChunk(CloudChunk(
        fileId: oldId,
        chunkIndex: 0,
        ukuranChunk: 10,
        nonceHex: 'oldnonce',
        sha256Chunk: 'oldchunkhash',
        status: 'uploaded',
      ));

      final backupData = {
        'files': [
          {
            'id': 42,
            'nama': 'restored.txt',
            'ukuran_bytes': 200,
            'mime': 'text/plain',
            'sha256_original': 'restoredhash',
            'is_encrypted': 1,
            'salt': 'restoredsalt',
            'jumlah_chunk': 1,
            'dibuat_pada': '2026-10-18T01:00:00Z',
            'status': 'complete',
          }
        ],
        'chunks': [
          {
            'id': 100,
            'file_id': 42,
            'chunk_index': 0,
            'ukuran_chunk': 200,
            'tg_file_id': 'restored_tg_file',
            'tg_message_id': 777,
            'nonce_hex': 'restored_nonce',
            'sha256_chunk': 'restored_chunk_hash',
            'status': 'uploaded',
          }
        ]
      };

      await manifestService.replaceDatabase(backupData);

      final files = await dbService.getAllFiles();
      expect(files.length, equals(1));
      expect(files.first.id, equals(42));
      expect(files.first.nama, equals('restored.txt'));

      final chunks = await dbService.getChunksForFile(42);
      expect(chunks.length, equals(1));
      expect(chunks.first.id, equals(100));
      expect(chunks.first.tgFileId, equals('restored_tg_file'));
    });

    test('exportToFile writes .tgcbak and calls share', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgcbak_test');
      List<XFile>? sharedFiles;

      final fileId = await dbService.insertFile(CloudFile(
        nama: 'export_test.pdf',
        ukuranBytes: 512,
        mime: 'application/pdf',
        sha256Original: 'hash512',
        salt: 'salt512',
        jumlahChunk: 1,
        dibuatPada: '2026-10-18T00:00:00Z',
        status: 'complete',
      ));

      final exportedFile = await manifestService.exportToFile(
        '123456',
        destinationDir: tempDir,
        shareFn: (files) async {
          sharedFiles = files;
        },
      );

      expect(exportedFile.existsSync(), isTrue);
      expect(exportedFile.path.endsWith('.tgcbak'), isTrue);
      expect(sharedFiles, isNotNull);
      expect(sharedFiles!.first.path, equals(exportedFile.path));

      final content = await exportedFile.readAsString();
      final envelope = jsonDecode(content) as Map<String, dynamic>;
      final parsed = await manifestService.parseBackup(envelope, '123456');
      expect(parsed['files']!.first['id'], equals(fileId));

      await tempDir.delete(recursive: true);
    });

    test('importFromFile reads file and returns parsed data', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgcbak_test_import');
      final file = File('${tempDir.path}/test.tgcbak');
      final envelope = await manifestService.buildBackup('123456');
      await file.writeAsString(jsonEncode(envelope));

      final imported = await manifestService.importFromFile(
        '123456',
        pickFileFn: () async => file.path,
      );

      expect(imported, isNotNull);
      expect(imported!['files'], isEmpty);
      expect(imported['chunks'], isEmpty);

      await tempDir.delete(recursive: true);
    });

    test('syncToTelegram uploads document, pins message, deletes old manifest, and saves settings', () async {
      await dbService.setSetting('manifest_message_id', '111');

      final dio = Dio(BaseOptions(baseUrl: 'https://api.telegram.org/botTEST/'));
      bool sendDocCalled = false;
      bool pinCalled = false;
      bool deleteCalled = false;

      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('sendDocument')) {
            sendDocCalled = true;
            final formData = options.data as FormData;
            expect(formData.fields.firstWhere((e) => e.key == 'caption').value, equals('TGCloud-index-v1'));
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'result': {
                  'message_id': 222,
                  'document': {'file_id': 'manifest_tg_file_id'}
                }
              },
            ));
          } else if (options.path.contains('pinChatMessage')) {
            pinCalled = true;
            expect((options.data as Map)['message_id'], equals(222));
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'ok': true, 'result': true},
            ));
          } else if (options.path.contains('deleteMessage')) {
            deleteCalled = true;
            expect((options.data as Map)['message_id'], equals(111));
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'ok': true, 'result': true},
            ));
          } else {
            handler.next(options);
          }
        },
      ));

      final tg = TelegramStorageService(botToken: 'TEST', chatId: '-1001', dio: dio);
      final cfg = TelegramConfigService();

      await manifestService.syncToTelegram(pin: '123456', tg: tg, cfg: cfg);

      expect(sendDocCalled, isTrue);
      expect(pinCalled, isTrue);
      expect(deleteCalled, isTrue);

      final newMsgId = await dbService.getSetting('manifest_message_id');
      final syncedAt = await dbService.getSetting('manifest_synced_at');
      expect(newMsgId, equals('222'));
      expect(syncedAt, isNotNull);
    });

    test('restoreFromTelegram fetches pinned document, decrypts, and replaces DB', () async {
      // Setup data awal di DB untuk diexport
      await dbService.insertFile(CloudFile(
        nama: 'cloud_backup.txt',
        ukuranBytes: 123,
        mime: 'text/plain',
        sha256Original: 'hash',
        salt: 'salt',
        jumlahChunk: 1,
        dibuatPada: '2026-10-18T00:00:00Z',
        status: 'complete',
      ));
      final envelope = await manifestService.buildBackup('123456');
      final envelopeBytes = utf8.encode(jsonEncode(envelope));

      // Hapus DB agar kosong
      await dbService.db.delete('cloud_files');

      final dio = Dio(BaseOptions(baseUrl: 'https://api.telegram.org/botTEST/'));
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('getChat')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'result': {
                  'pinned_message': {
                    'message_id': 333,
                    'document': {'file_id': 'manifest_file_xyz'}
                  }
                }
              },
            ));
          } else if (options.path.contains('getFile')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'result': {'file_path': 'documents/manifest.json'}
              },
            ));
          } else if (options.path.contains('documents/manifest.json')) {
            handler.resolve(Response<List<int>>(
              requestOptions: options,
              statusCode: 200,
              data: envelopeBytes,
            ));
          } else {
            handler.next(options);
          }
        },
      ));

      final tg = TelegramStorageService(botToken: 'TEST', chatId: '-1001', dio: dio);
      final cfg = TelegramConfigService();

      await manifestService.restoreFromTelegram(pin: '123456', tg: tg, cfg: cfg);

      final files = await dbService.getAllFiles();
      expect(files.length, equals(1));
      expect(files.first.nama, equals('cloud_backup.txt'));
    });
  });
}
