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
    );

    final fileId = await databaseService.insertFile(cloudFile);
    onFileIdCreated?.call(fileId);

    // Siapkan baris chunk di database tanpa membaca isi file atau enkripsi di main isolate
    final createdChunks = <CloudChunk>[];
    for (int i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final currentLength = min(chunkSize, fileSize - start);
      final nonce = CryptoService.generateNonce();
      // AES-GCM menambah auth tag 16 byte ke ciphertext
      final estimatedSize = currentLength + 16;

      final chunk = CloudChunk(
        fileId: fileId,
        chunkIndex: i,
        ukuranChunk: estimatedSize,
        nonceHex: nonce,
        sha256Chunk: '',
        status: 'pending',
      );

      final chunkId = await databaseService.insertChunk(chunk);
      createdChunks.add(CloudChunk(
        id: chunkId,
        fileId: fileId,
        chunkIndex: i,
        ukuranChunk: estimatedSize,
        nonceHex: nonce,
        sha256Chunk: '',
        status: 'pending',
      ));
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

        // Enkripsi dan SHA-256 chunk di isolate latar agar UI tidak freeze
        final processed = await CryptoService.encryptAndHashChunkIsolate(
          rawSlice,
          key,
          chunk.nonceHex,
        );

        await databaseService.updateChunkStatus(
          chunk.id!,
          'uploading',
          sha256Chunk: processed.sha256,
          ukuranChunk: processed.bytes.length,
        );

        final uploadResult = await telegramService.sendDocument(
          processed.bytes,
          '${processed.sha256}.bin',
          cancelToken: cancelToken,
        );

        await databaseService.updateChunkStatus(
          chunk.id!,
          'done',
          tgFileId: uploadResult.fileId,
          tgMessageId: uploadResult.messageId,
          sha256Chunk: processed.sha256,
          ukuranChunk: processed.bytes.length,
        );

        completedCount++;
        uploadedBytes += processed.bytes.length;
        final progress = 0.05 + (completedCount / totalChunks) * 0.95;
        final speedStr = currentSpeedMbps();
        onProgress?.call(
          progress,
          'Mengunggah chunk $completedCount dari $totalChunks \u2022 $speedStr',
        );
        log('Chunk $completedCount/$totalChunks selesai diunggah ($speedStr)');
      }
    }

    final workers = List.generate(poolSize, (_) => worker());
    await Future.wait(workers);

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
    allChunks.sort((a, b) => a.chunkIndex.compareTo(b.chunkIndex));
    final pending = allChunks
        .where((c) => c.status != 'done' || c.tgFileId == null)
        .toList();
    final alreadyDone = allChunks.length - pending.length;
    final total = allChunks.length;

    log('Melanjutkan upload: $alreadyDone/$total chunk sudah terunggah');
    onProgress?.call(0.30, 'Melanjutkan: $alreadyDone/$total chunk sudah ada...');

    int completedCount = 0;
    int nextIndex = 0;
    final poolSize = 2; // sama seperti uploadFile

    Future<void> worker() async {
      while (true) {
        if (cancelToken?.isCancelled == true) throw Exception('Upload dibatalkan');
        if (nextIndex >= pending.length) return;
        final chunk = pending[nextIndex++];

        await databaseService.updateChunkStatus(chunk.id!, 'uploading');

        final raf = await srcFile.open(mode: FileMode.read);
        List<int> rawSlice;
        try {
          await raf.setPosition(chunk.chunkIndex * chunkSize);
          rawSlice = await raf.read(
              min(chunkSize, fileSize - (chunk.chunkIndex * chunkSize)));
        } finally {
          await raf.close();
        }

        // Enkripsi dan SHA-256 chunk di isolate latar agar UI tidak freeze
        final processed = await CryptoService.encryptAndHashChunkIsolate(
          rawSlice,
          key,
          chunk.nonceHex,
        );

        await databaseService.updateChunkStatus(
          chunk.id!,
          'uploading',
          sha256Chunk: processed.sha256,
          ukuranChunk: processed.bytes.length,
        );

        final uploadResult = await telegramService.sendDocument(
          processed.bytes,
          '${processed.sha256}.bin',
          cancelToken: cancelToken,
        );

        await databaseService.updateChunkStatus(
          chunk.id!,
          'done',
          tgFileId: uploadResult.fileId,
          tgMessageId: uploadResult.messageId,
          sha256Chunk: processed.sha256,
          ukuranChunk: processed.bytes.length,
        );

        completedCount++;
        final done = alreadyDone + completedCount;
        onProgress?.call(
          0.30 + (done / total) * 0.70,
          'Mengunggah chunk $done dari $total...',
        );
        log('Chunk $done/$total terunggah');
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
