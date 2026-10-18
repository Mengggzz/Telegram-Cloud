import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:tgcloud/config/app_config.dart';
import 'package:tgcloud/models/cloud_chunk.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';

typedef UploadProgressCallback = void Function(double progress, String status);
typedef UploadLogCallback = void Function(String message);

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
    UploadLogCallback? onLog,
    void Function(int fileId)? onFileIdCreated,
  }) async {
    void log(String msg) {
      final t = DateTime.now().toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      onLog?.call('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $msg');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File tidak ditemukan: $filePath');
    }

    final fileSize = await file.length();
    var filename = p.basename(filePath);
    final mime = _detectMime(filename);
    final chunkSize = chunkSizeBytes ?? AppConfig.chunkSizeBytes;
    final totalChunks = max(1, (fileSize / chunkSize).ceil());

    log('File dipilih: $filename (${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB)');
    log('Mulai menghitung hash SHA-256...');

    String sha256Original = '';
    final hashStartTime = DateTime.now();
    await for (final p in CryptoService.calculateFileSha256Progress(filePath)) {
      if (cancelToken?.isCancelled == true) {
        log('Upload dibatalkan saat menghitung hash');
        throw Exception('Upload dibatalkan');
      }

      final mbRead = (p.bytesRead / (1024 * 1024)).toStringAsFixed(1);
      final mbTotal = (p.totalBytes / (1024 * 1024)).toStringAsFixed(1);
      final pct = p.percentage;

      final currentProgress = p.fraction * 0.05;
      final statusMsg = 'Menghitung hash... ($mbRead / $mbTotal MB • $pct%)';
      onProgress?.call(currentProgress, statusMsg);

      if (p.hash != null) {
        sha256Original = p.hash!;
        final dur = DateTime.now().difference(hashStartTime).inMilliseconds / 1000.0;
        log('SHA-256 (${dur.toStringAsFixed(1)}s): $sha256Original');
      }
    }

    // Cek deduplikasi
    log('Memeriksa duplikasi hash di database...');
    final existing = await databaseService.getFileByHash(sha256Original);
    if (existing != null) {
      log('File identik sudah ada di cloud: ${existing.nama}');
      throw Exception('File identik sudah ada di cloud: ${existing.nama}');
    }
    log('File unik. Menyiapkan $totalChunks chunk enkripsi (AES-GCM)...');

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

    // Thumbnail terenkripsi (opsional; gagal -> null, upload tetap lanjut)
    String? thumbDataHex;
    String? thumbNonceHex;
    try {
      Uint8List? thumbRaw;
      if (mime.startsWith('image/')) {
        final rawBytes = await file.readAsBytes();
        final decoded = img.decodeImage(rawBytes);
        if (decoded != null) {
          final resized = img.copyResize(decoded,
              width: decoded.width > 320 ? 320 : decoded.width);
          thumbRaw = Uint8List.fromList(img.encodeJpg(resized, quality: 70));
        }
      } else if (mime.startsWith('video/')) {
        final plugin = FcNativeVideoThumbnail();
        thumbRaw = await plugin.saveThumbnailToBytes(
          srcFile: filePath,
          width: 320,
          height: 320,
          quality: 70,
        );
      }
      if (thumbRaw != null && thumbRaw.lengthInBytes < 200 * 1024) {
        final tNonce = CryptoService.generateNonce();
        final tEnc = CryptoService.encryptChunk(thumbRaw, key, tNonce);
        thumbDataHex = tEnc.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        thumbNonceHex = tNonce;
        log('Thumbnail dibuat (${(thumbRaw.lengthInBytes / 1024).toStringAsFixed(0)} KB)');
      }
    } catch (e) {
      log('Thumbnail dilewati: $e'); // mis. platform tak didukung
    }

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
      sumberPath: filePath,
      thumbData: thumbDataHex,
      thumbNonce: thumbNonceHex,
    );

    final fileId = await databaseService.insertFile(cloudFile);
    onFileIdCreated?.call(fileId);

    // ===== PIPELINE: tiap worker = baca -> enkripsi (isolate) -> upload.
    // Menggantikan fase "persiapan semua chunk di awal" yang serial.
    int completedCount = 0;
    int uploadedBytes = 0;
    int nextChunkIndex = 0;
    final poolSize = min(AppConfig.maxUploadWorkers, totalChunks);
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

    log('Mulai upload pipeline: $totalChunks chunk, $poolSize worker paralel');

    Future<void> worker() async {
      // Satu handle file per worker (RandomAccessFile tidak aman dipakai
      // paralel dari satu handle yang sama).
      final raf = await file.open(mode: FileMode.read);
      int failStreak = 0;
      try {
        while (true) {
          if (cancelToken?.isCancelled == true) {
            throw Exception('Upload dibatalkan');
          }
          int currentIndex;
          if (nextChunkIndex >= totalChunks) return;
          currentIndex = nextChunkIndex++; // aman: single-threaded

          try {
            final start = currentIndex * chunkSize;
            final len = min(chunkSize, fileSize - start);
            await raf.setPosition(start);
            final rawSlice = await raf.read(len);

            final nonce = CryptoService.generateNonce();
            // Enkripsi + hash di isolate latar (satu-satunya enkripsi:
            // tidak ada lagi kerja ganda).
            final enc = await CryptoService.encryptChunkIsolate(
                rawSlice, key, nonce);

            final chunkId = await databaseService.insertChunk(CloudChunk(
              fileId: fileId,
              chunkIndex: currentIndex,
              ukuranChunk: enc.bytes.length,
              nonceHex: nonce,
              sha256Chunk: enc.sha256Hex,
              status: 'uploading',
            ));

            final uploadResult = await telegramService.sendDocument(
              enc.bytes,
              '${enc.sha256Hex}.bin',
              cancelToken: cancelToken,
            );

            await databaseService.updateChunkStatus(
              chunkId,
              'done',
              tgFileId: uploadResult.fileId,
              tgMessageId: uploadResult.messageId,
            );

            completedCount++;
            failStreak = 0;
            uploadedBytes += enc.bytes.length;
            // Hash 1%-5%, upload 5%-100% (fase persiapan sudah tidak ada).
            final progress = 0.05 + (completedCount / totalChunks) * 0.95;
            final speed = currentSpeedMbps();
            onProgress?.call(
              progress,
              'Mengunggah chunk $completedCount dari $totalChunks \u2022 $speed',
            );
            log('Chunk $completedCount/$totalChunks terunggah \u2022 $speed');
          } catch (e) {
            failStreak++;
            if (failStreak >= 3) rethrow;
            log('Worker retry ($failStreak/3): $e');
          }
        }
      } finally {
        await raf.close();
      }
    }

    await Future.wait(List.generate(poolSize, (_) => worker()));

    await databaseService.updateFileStatus(fileId, 'complete');
    log('Upload $filename berhasil diselesaikan 100%!');
    return (await databaseService.getFileById(fileId))!;
  }

  /// Melanjutkan upload yang terputus: hanya chunk yang belum 'done'
  /// yang diunggah ulang. Chunk yang sudah 'done' (punya tg_file_id)
  /// dipakai apa adanya.
  Future<CloudFile> resumeUpload(
    int fileId,
    String userPin, {
    CancelToken? cancelToken,
    UploadProgressCallback? onProgress,
    UploadLogCallback? onLog,
    void Function(int fileId)? onFileIdCreated,
    int? chunkSizeBytes,
  }) async {
    void log(String msg) {
      final t = DateTime.now().toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      onLog?.call('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $msg');
    }

    final cloudFile = await databaseService.getFileById(fileId);
    if (cloudFile == null) throw Exception('Data file tidak ditemukan di database');
    if (cloudFile.status == 'complete') throw Exception('File ini sudah selesai diupload');

    final src = cloudFile.sumberPath;
    final srcFile = src != null ? File(src) : null;
    if (srcFile == null || !await srcFile.exists()) {
      throw Exception('File sumber tidak ditemukan${src != null ? ': $src' : ''}. '
          'Hapus entri ini lalu upload ulang, atau pindahkan file kembali ke path semula.');
    }
    final fileSize = await srcFile.length();
    if (fileSize != cloudFile.ukuranBytes) {
      throw Exception('Ukuran file sumber berubah (${cloudFile.ukuranBytes} -> $fileSize). '
          'Tidak aman dilanjutkan; hapus lalu upload ulang.');
    }

    onFileIdCreated?.call(fileId);
    final key = CryptoService.deriveKey(userPin, cloudFile.salt);
    final chunkSize = chunkSizeBytes ?? AppConfig.chunkSizeBytes;

    final allChunks = await databaseService.getChunksForFile(fileId);
    // chunkIndex -> row (bila ada)
    final byIndex = {for (final c in allChunks) c.chunkIndex: c};
    final pendingIdx = <int>[];
    for (int i = 0; i < cloudFile.jumlahChunk; i++) {
      final row = byIndex[i];
      if (row == null || row.status != 'done' || row.tgFileId == null) {
        pendingIdx.add(i);
      }
    }
    final alreadyDone = cloudFile.jumlahChunk - pendingIdx.length;
    final total = cloudFile.jumlahChunk;

    log('Melanjutkan upload: $alreadyDone/$total chunk sudah terunggah');

    int completedCount = 0;
    int nextPtr = 0;
    final poolSize = min(AppConfig.maxUploadWorkers, pendingIdx.length);

    Future<void> worker() async {
      final raf = await srcFile.open(mode: FileMode.read);
      int failStreak = 0;
      try {
        while (true) {
          if (cancelToken?.isCancelled == true) {
            throw Exception('Upload dibatalkan');
          }
          if (nextPtr >= pendingIdx.length) return;
          final currentIndex = pendingIdx[nextPtr++];

          try {
            final existing = byIndex[currentIndex];

            // Bila baris lama punya pesan yatim (pernah 'done' tapi file_id
            // hilang), hapus dulu agar tidak menumpuk di channel.
            if (existing?.tgMessageId != null) {
              try {
                await telegramService.deleteMessage(existing!.tgMessageId!);
              } catch (_) {}
            }

            final start = currentIndex * chunkSize;
            final len = min(chunkSize, fileSize - start);
            await raf.setPosition(start);
            final rawSlice = await raf.read(len);

            // Pakai nonce lama bila ada (hasil enkripsi deterministik,
            // cocok dengan sha256_chunk yang tersimpan).
            final nonce = existing?.nonceHex ?? CryptoService.generateNonce();
            final enc = await CryptoService.encryptChunkIsolate(
                rawSlice, key, nonce);

            final int chunkId;
            if (existing?.id != null) {
              chunkId = existing!.id!;
              await databaseService.updateChunkStatus(chunkId, 'uploading');
            } else {
              chunkId = await databaseService.insertChunk(CloudChunk(
                fileId: fileId,
                chunkIndex: currentIndex,
                ukuranChunk: enc.bytes.length,
                nonceHex: nonce,
                sha256Chunk: enc.sha256Hex,
                status: 'uploading',
              ));
            }

            final uploadResult = await telegramService.sendDocument(
              enc.bytes,
              '${enc.sha256Hex}.bin',
              cancelToken: cancelToken,
            );

            await databaseService.updateChunkStatus(
              chunkId, 'done',
              tgFileId: uploadResult.fileId,
              tgMessageId: uploadResult.messageId,
            );

            completedCount++;
            failStreak = 0;
            final done = alreadyDone + completedCount;
            onProgress?.call(
              0.05 + (done / total) * 0.95,
              'Mengunggah chunk $done dari $total...',
            );
            log('Chunk $done/$total terunggah');
          } catch (e) {
            failStreak++;
            if (failStreak >= 3) rethrow;
            log('Worker retry ($failStreak/3): $e');
          }
        }
      } finally {
        await raf.close();
      }
    }

    await Future.wait(List.generate(poolSize, (_) => worker()));
    await databaseService.updateFileStatus(fileId, 'complete');
    log('Upload selesai: ${cloudFile.nama}');
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
