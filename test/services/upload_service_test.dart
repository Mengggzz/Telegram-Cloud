import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/models/cloud_chunk.dart';
import 'package:tgcloud/models/cloud_file.dart';
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

    test('resumeUpload completes pending chunks and updates file status to complete', () async {
      int uploadedChunksCount = 0;
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('sendDocument')) {
            uploadedChunksCount++;
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'result': {
                  'message_id': 2000 + uploadedChunksCount,
                  'document': {'file_id': 'tg_resume_file_$uploadedChunksCount'}
                }
              },
            ));
          } else {
            handler.next(options);
          }
        },
      ));

      final resumeTg = TelegramStorageService(botToken: 'dummy', chatId: '-100', dio: dio);
      final customUploadService = UploadService(databaseService: db, telegramService: resumeTg);

      final salt = CryptoService.generateSalt();
      final nonce0 = CryptoService.generateNonce();
      final nonce1 = CryptoService.generateNonce();

      final fileId = await db.insertFile(CloudFile(
        nama: 'test_upload.dat',
        ukuranBytes: 32768,
        mime: 'application/octet-stream',
        sha256Original: 'original_hash',
        salt: salt,
        jumlahChunk: 2,
        dibuatPada: DateTime.now().toIso8601String(),
        status: 'uploading',
        sumberPath: sampleFile.path,
      ));

      // Chunk 0 is already done
      await db.insertChunk(CloudChunk(
        fileId: fileId,
        chunkIndex: 0,
        ukuranChunk: 16384,
        tgFileId: 'already_uploaded_id',
        tgMessageId: 100,
        nonceHex: nonce0,
        sha256Chunk: 'hash0',
        status: 'done',
      ));

      // Chunk 1 is pending
      await db.insertChunk(CloudChunk(
        fileId: fileId,
        chunkIndex: 1,
        ukuranChunk: 16384,
        nonceHex: nonce1,
        sha256Chunk: 'hash1',
        status: 'pending',
      ));

      final resumedFile = await customUploadService.resumeUpload(
        fileId,
        '123456',
        chunkSizeBytes: 16384,
      );

      expect(resumedFile.status, equals('complete'));
      expect(uploadedChunksCount, equals(1)); // only the pending chunk was uploaded

      final chunksFinal = await db.getChunksForFile(fileId);
      expect(chunksFinal.length, equals(2));
      expect(chunksFinal.every((c) => c.status == 'done'), isTrue);
      expect(chunksFinal[0].tgFileId, equals('already_uploaded_id'));
      expect(chunksFinal[1].tgFileId, equals('tg_resume_file_1'));
    });

    test('resumeUpload throws if source file deleted', () async {
      final cloudFile = await uploadService.uploadFile(
        sampleFile.path,
        '123456',
        chunkSizeBytes: 16384,
      );

      // Force status back to uploading
      await db.updateFileStatus(cloudFile.id!, 'uploading');
      await sampleFile.delete();

      expect(
        () => uploadService.resumeUpload(cloudFile.id!, '123456'),
        throwsA(predicate((e) => e.toString().contains('File sumber tidak ditemukan'))),
      );
    });

    test('resumeUpload throws if source file size changed', () async {
      final cloudFile = await uploadService.uploadFile(
        sampleFile.path,
        '123456',
        chunkSizeBytes: 16384,
      );

      await db.updateFileStatus(cloudFile.id!, 'uploading');
      await sampleFile.writeAsBytes([1, 2, 3]); // size changed

      expect(
        () => uploadService.resumeUpload(cloudFile.id!, '123456'),
        throwsA(predicate((e) => e.toString().contains('Ukuran file sumber berubah'))),
      );
    });
  });
}
