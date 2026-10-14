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
