import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
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
        } else {
          handler.next(options);
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

    test('cancelUpload deletes messages from telegram and deletes file from DB', () async {
      final cloudFile = await uploadService.uploadFile(
        sampleFile.path,
        '123456',
        chunkSizeBytes: 16384,
      );

      await uploadService.cancelUpload(cloudFile.id!);
      final fileAfter = await db.getFileById(cloudFile.id!);
      expect(fileAfter, isNull);
      final chunksAfter = await db.getChunksForFile(cloudFile.id!);
      expect(chunksAfter.isEmpty, isTrue);
    });
  });
}
