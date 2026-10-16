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
      final hash = await CryptoService.calculateFileSha256(file.path);
      final existing = await databaseService.getFileByHash(hash);
      if (existing == null) {
        newFiles.add(file);
      }
    }
    return newFiles;
  }
}
