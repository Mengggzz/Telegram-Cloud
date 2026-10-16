import 'dart:async';
import 'dart:io';
import 'dart:math';
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
    var filename = p.basename(filePath);
    final mime = _detectMime(filename);
    final chunkSize = chunkSizeBytes ?? AppConfig.chunkSizeBytes;
    final totalChunks = max(1, (fileSize / chunkSize).ceil());

    onProgress?.call(0.01, 'Menghitung hash file...');

    // SHA-256 dihitung di isolate latar (streaming dari disk) agar UI
    // tidak freeze untuk file besar. Lihat CryptoService.calculateFileSha256.
    final sha256Original = await CryptoService.calculateFileSha256(filePath);

    // Cek deduplikasi
    final existing = await databaseService.getFileByHash(sha256Original);
    if (existing != null) {
      throw Exception('File identik sudah ada di cloud: ${existing.nama}');
    }

    // Hindari nama duplikat persis
    final allFiles = await databaseService.getAllFiles();
    int duplicateCount = 1;
    String baseName = p.basenameWithoutExtension(filename);
    String ext = p.extension(filename);
    while (allFiles.any((f) => f.nama.toLowerCase() == filename.toLowerCase())) {
      filename = '$baseName ($duplicateCount)$ext';
      duplicateCount++;
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

    // Siapkan semua baris chunk di database dengan nonce dan sha256_chunk
    final createdChunks = <CloudChunk>[];
    final raf = await file.open(mode: FileMode.read);
    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final currentLength = min(chunkSize, fileSize - start);
        await raf.setPosition(start);
        final rawSlice = await raf.read(currentLength);

        final nonce = CryptoService.generateNonce();
        final encryptedSlice = CryptoService.encryptChunk(rawSlice, key, nonce);
        final sha256Chunk = CryptoService.calculateSha256(encryptedSlice);

        final chunk = CloudChunk(
          fileId: fileId,
          chunkIndex: i,
          ukuranChunk: encryptedSlice.length,
          nonceHex: nonce,
          sha256Chunk: sha256Chunk,
          status: 'pending',
        );

        final chunkId = await databaseService.insertChunk(chunk);
        createdChunks.add(CloudChunk(
          id: chunkId,
          fileId: fileId,
          chunkIndex: i,
          ukuranChunk: encryptedSlice.length,
          nonceHex: nonce,
          sha256Chunk: sha256Chunk,
          status: 'pending',
        ));
      }
    } finally {
      await raf.close();
    }

    // Worker pool upload maks 2 paralel
    int completedCount = 0;
    int uploadedBytes = 0;
    final poolSize = min(2, totalChunks);
    int nextChunkIndex = 0;
    // Sampel (waktu, totalBytes) untuk menghitung kecepatan rolling 5 detik.
    final speedSamples = <MapEntry<DateTime, int>>[];
    final uploadStart = DateTime.now();

    /// Kecepatan upload dalam Mbps, dihitung dari sampel 5 detik terakhir
    /// agar angka stabil (tidak lompat-lompat per chunk).
    String currentSpeedMbps() {
      final now = DateTime.now();
      speedSamples.add(MapEntry(now, uploadedBytes));
      while (speedSamples.length > 2 &&
          now.difference(speedSamples.first.key).inSeconds > 5) {
        speedSamples.removeAt(0);
      }
      double mbps;
      if (speedSamples.length >= 2) {
        final dt = now.difference(speedSamples.first.key).inMilliseconds / 1000.0;
        final db = uploadedBytes - speedSamples.first.value;
        mbps = dt > 0 ? (db * 8 / 1000000) / dt : -1;
      } else {
        final dt = now.difference(uploadStart).inMilliseconds / 1000.0;
        mbps = dt > 0.5 ? (uploadedBytes * 8 / 1000000) / dt : -1;
      }
      if (mbps < 0) return '...';
      return '${mbps.toStringAsFixed(1).replaceAll('.', ',')} Mbps';
    }

    Future<void> worker() async {
      while (true) {
        if (cancelToken?.isCancelled == true) {
          throw Exception('Upload dibatalkan');
        }

        int currentIndex;
        if (nextChunkIndex >= totalChunks) return;
        currentIndex = nextChunkIndex++;

        final chunk = createdChunks[currentIndex];
        await databaseService.updateChunkStatus(chunk.id!, 'uploading');

        // Baca chunk dari file disk secara streaming
        final rafWorker = await file.open(mode: FileMode.read);
        List<int> rawSlice;
        try {
          await rafWorker.setPosition(currentIndex * chunkSize);
          rawSlice = await rafWorker.read(min(chunkSize, fileSize - (currentIndex * chunkSize)));
        } finally {
          await rafWorker.close();
        }

        final encryptedSlice = CryptoService.encryptChunk(rawSlice, key, chunk.nonceHex);

        final uploadResult = await telegramService.sendDocument(
          encryptedSlice,
          '${chunk.sha256Chunk}.bin',
          cancelToken: cancelToken,
        );

        await databaseService.updateChunkStatus(
          chunk.id!,
          'done',
          tgFileId: uploadResult.fileId,
          tgMessageId: uploadResult.messageId,
        );

        completedCount++;
        uploadedBytes += encryptedSlice.length;
        final progress = completedCount / totalChunks;
        onProgress?.call(
          progress,
          'Mengunggah chunk $completedCount dari $totalChunks \u2022 ${currentSpeedMbps()}',
        );
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
      case '.mov': return 'video/quicktime';
      case '.jpg':
      case '.jpeg': return 'image/jpeg';
      case '.png': return 'image/png';
      case '.gif': return 'image/gif';
      case '.mp3': return 'audio/mpeg';
      case '.m4a': return 'audio/mp4';
      case '.pdf': return 'application/pdf';
      case '.zip': return 'application/zip';
      case '.rar': return 'application/x-rar-compressed';
      default: return 'application/octet-stream';
    }
  }
}
