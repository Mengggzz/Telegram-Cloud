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

    test('insertFile stores and retrieves sumber_path', () async {
      final file = CloudFile(
        nama: 'photo.jpg',
        ukuranBytes: 1234,
        mime: 'image/jpeg',
        sha256Original: 'hashphoto',
        salt: 'saltphoto',
        jumlahChunk: 1,
        dibuatPada: DateTime.now().toIso8601String(),
        status: 'uploading',
        sumberPath: '/path/to/photo.jpg',
      );

      final fileId = await dbService.insertFile(file);
      final retrieved = await dbService.getFileById(fileId);
      expect(retrieved?.sumberPath, equals('/path/to/photo.jpg'));
    });
  });
}
