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

        // Verifikasi integritas chunk dan dekripsi di isolate latar agar UI tidak freeze
        final decryptedBytes = await CryptoService.verifyAndDecryptChunkIsolate(
          encryptedBytes,
          key,
          chunk.nonceHex,
          chunk.sha256Chunk,
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
    final finalHash = await CryptoService.calculateFileSha256(outputFile.path);

    if (finalHash != cloudFile.sha256Original) {
      await outputFile.delete();
      throw Exception('Integritas file total rusak! Hash asli tidak cocok dengan hasil rekonstruksi.');
    }

    onProgress?.call(1.0, 'Download selesai!');
    return outputFile;
  }
}
