import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tgcloud/services/crypto_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/telegram_config_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';

class ManifestService {
  final DatabaseService _db;

  ManifestService(this._db);

  /// Bangun map envelope terenkripsi dari seluruh isi DB.
  /// Format:
  /// {
  ///   "format": "tgcloud-backup", "version": 1,
  ///   "exported_at": "`<ISO8601>`",
  ///   "salt": "`<hex>`", "nonce": "`<hex>`", "payload": "`<hex>`"
  /// }
  /// payload = AES-GCM( utf8( json({files:[...], chunks:[...]}) ) )
  ///   - files: list row cloud_files APA ADANYA (semua kolom)
  ///   - chunks: list row cloud_chunks APA ADANYA (semua kolom)
  ///   - salt = generateSalt() baru setiap ekspor
  ///   - key  = deriveKey(pin, salt)
  Future<Map<String, dynamic>> buildBackup(String pin) async {
    final files = await _db.db.query('cloud_files');
    final chunks = await _db.db.query('cloud_chunks');

    final payloadMap = {
      'files': files,
      'chunks': chunks,
    };
    final jsonString = jsonEncode(payloadMap);
    final jsonBytes = utf8.encode(jsonString);

    final saltHex = CryptoService.generateSalt();
    final nonceHex = CryptoService.generateNonce();
    final keyBytes = CryptoService.deriveKey(pin, saltHex);
    final encryptedBytes = CryptoService.encryptChunk(jsonBytes, keyBytes, nonceHex);
    final payloadHex = _bytesToHex(encryptedBytes);

    return {
      'format': 'tgcloud-backup',
      'version': 1,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'salt': saltHex,
      'nonce': nonceHex,
      'payload': payloadHex,
    };
  }

  /// Kebalikan buildBackup: verifikasi format+version, decrypt dengan pin,
  /// kembalikan {files, chunks}. Throw Exception bila:
  /// format/version tidak dikenal, atau decrypt gagal (PIN salah / korup).
  Future<Map<String, List<Map<String, dynamic>>>> parseBackup(
    Map<String, dynamic> envelope,
    String pin,
  ) async {
    if (envelope['format'] != 'tgcloud-backup') {
      throw Exception('Format cadangan tidak dikenal: ${envelope['format']}');
    }

    final version = envelope['version'];
    if (version is num && version.toInt() > 1) {
      throw Exception('Format cadangan lebih baru, update aplikasi dulu');
    }
    if (version != 1) {
      throw Exception('Versi format cadangan tidak valid');
    }

    final salt = envelope['salt'] as String?;
    final nonce = envelope['nonce'] as String?;
    final payload = envelope['payload'] as String?;

    if (salt == null || nonce == null || payload == null || salt.isEmpty || nonce.isEmpty || payload.isEmpty) {
      throw Exception('Data cadangan tidak lengkap');
    }

    final keyBytes = CryptoService.deriveKey(pin, salt);
    try {
      final payloadBytes = _hexToBytes(payload);
      final decryptedBytes = CryptoService.decryptChunk(payloadBytes, keyBytes, nonce);
      final jsonString = utf8.decode(decryptedBytes);
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;

      final files = (decoded['files'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final chunks = (decoded['chunks'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      return {
        'files': files,
        'chunks': chunks,
      };
    } catch (e) {
      throw Exception('PIN salah atau file cadangan rusak: $e');
    }
  }

  /// Ganti SELURUH isi DB dengan data hasil parseBackup, dalam 1 transaksi:
  /// DELETE FROM cloud_chunks; DELETE FROM cloud_files;
  /// lalu INSERT tiap row DENGAN id aslinya (agar relasi file_id tetap utuh).
  Future<void> replaceDatabase(Map<String, List<Map<String, dynamic>>> data) async {
    final files = data['files'] ?? [];
    final chunks = data['chunks'] ?? [];

    await _db.db.transaction((txn) async {
      await txn.delete('cloud_chunks');
      await txn.delete('cloud_files');

      for (final file in files) {
        await txn.insert('cloud_files', file);
      }
      for (final chunk in chunks) {
        await txn.insert('cloud_chunks', chunk);
      }
    });
  }

  /// Ekspor envelope DB ke file .tgcbak di local storage dan buka dialog share.
  Future<File> exportToFile(
    String pin, {
    Directory? destinationDir,
    Future<void> Function(List<XFile> files)? shareFn,
  }) async {
    final envelope = await buildBackup(pin);
    final dir = destinationDir ?? await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final formatter = DateFormat('yyyyMMdd-HHmm');
    final filename = 'tgcloud-backup-${formatter.format(now)}.tgcbak';
    final file = File(p.join(dir.path, filename));
    await file.writeAsString(jsonEncode(envelope));

    final xfile = XFile(file.path);
    if (shareFn != null) {
      await shareFn([xfile]);
    } else {
      await SharePlus.instance.share(ShareParams(
        files: [xfile],
        text: 'Cadangan Metadata TGCloud',
      ));
    }
    return file;
  }

  /// Pilih file via file picker atau path custom, baca envelope, lalu decrypt via parseBackup.
  /// Mengembalikan data {files, chunks} atau null bila user membatalkan pilihan.
  Future<Map<String, List<Map<String, dynamic>>>?> importFromFile(
    String pin, {
    Future<String?> Function()? pickFileFn,
  }) async {
    String? path;
    if (pickFileFn != null) {
      path = await pickFileFn();
    } else {
      final result = await FilePicker.pickFile();
      if (result != null) {
        path = result.path;
      }
    }

    if (path == null) return null;

    final file = File(path);
    if (!await file.exists()) {
      throw Exception('File cadangan tidak ditemukan: $path');
    }

    final content = await file.readAsString();
    final envelope = jsonDecode(content) as Map<String, dynamic>;
    return await parseBackup(envelope, pin);
  }

  /// Upload envelope sebagai dokumen + pin + hapus manifest lama.
  /// Caption dokumen: "TGCloud-index-v1" (penanda).
  /// Simpan message_id manifest aktif di app_settings key "manifest_message_id"
  /// dan waktu sinkron di "manifest_synced_at".
  Future<void> syncToTelegram({
    required String pin,
    required TelegramStorageService tg,
    required TelegramConfigService cfg,
  }) async {
    final envelope = await buildBackup(pin);
    final bytes = utf8.encode(jsonEncode(envelope));

    final result = await tg.sendDocument(
      bytes,
      'tgcloud-index.json',
      caption: 'TGCloud-index-v1',
    );

    await tg.pinChatMessage(result.messageId);

    final oldMsgIdStr = await _db.getSetting('manifest_message_id');
    if (oldMsgIdStr != null) {
      final oldMsgId = int.tryParse(oldMsgIdStr);
      if (oldMsgId != null && oldMsgId != result.messageId) {
        await tg.deleteMessage(oldMsgId);
      }
    }

    await _db.setSetting('manifest_message_id', result.messageId.toString());
    await _db.setSetting('manifest_synced_at', DateTime.now().toUtc().toIso8601String());
  }

  /// Ambil manifest dari pinned message channel, decrypt, replace DB.
  /// Throw bila tidak ada pinned manifest / PIN salah.
  Future<void> restoreFromTelegram({
    required String pin,
    required TelegramStorageService tg,
    required TelegramConfigService cfg,
  }) async {
    final chat = await tg.getChat();
    final pinned = chat['pinned_message'];
    if (pinned == null || pinned['document'] == null || pinned['document']['file_id'] == null) {
      throw Exception('Tidak ada manifest di channel');
    }

    final fileId = pinned['document']['file_id'] as String;
    final downloadUrl = await tg.getDownloadUrl(fileId);
    final bytes = await tg.downloadChunk(downloadUrl);

    final jsonString = utf8.decode(bytes);
    final envelope = jsonDecode(jsonString) as Map<String, dynamic>;
    final data = await parseBackup(envelope, pin);

    await replaceDatabase(data);

    final msgId = pinned['message_id'];
    if (msgId != null) {
      await _db.setSetting('manifest_message_id', msgId.toString());
    }
    await _db.setSetting('manifest_synced_at', DateTime.now().toUtc().toIso8601String());
  }

  static String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < hex.length; i += 2) {
      result[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
    }
    return result;
  }
}
