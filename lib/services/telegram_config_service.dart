import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tgcloud/config/app_config.dart';
import 'package:tgcloud/services/crypto_service.dart';

/// Konfigurasi koneksi Telegram (bot token + channel chat ID).
class TelegramConfig {
  final String botToken;
  final String chatId;

  const TelegramConfig({required this.botToken, required this.chatId});

  bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'bot_token': botToken,
        'chat_id': chatId,
      };

  factory TelegramConfig.fromMap(Map<String, dynamic> map) {
    final token = (map['bot_token'] ?? map['botToken'] ?? '').toString().trim();
    final chat = (map['chat_id'] ?? map['chatId'] ?? '').toString().trim();
    return TelegramConfig(botToken: token, chatId: chat);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TelegramConfig &&
          runtimeType == other.runtimeType &&
          botToken == other.botToken &&
          chatId == other.chatId;

  @override
  int get hashCode => botToken.hashCode ^ chatId.hashCode;
}

/// Simpan/baca konfigurasi Telegram di secure storage.
/// Fallback ke --dart-define (AppConfig) bila belum pernah diisi manual.
class TelegramConfigService {
  static const _tokenKey = 'tg_bot_token';
  static const _chatIdKey = 'tg_chat_id';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<TelegramConfig> load() async {
    final token = await _storage.read(key: _tokenKey) ?? AppConfig.botToken;
    final chatId = await _storage.read(key: _chatIdKey) ?? AppConfig.chatId;
    return TelegramConfig(botToken: token, chatId: chatId);
  }

  Future<void> save(String botToken, String chatId) async {
    await _storage.write(key: _tokenKey, value: botToken.trim());
    await _storage.write(key: _chatIdKey, value: chatId.trim());
  }

  /// Validasi token via getMe. Return username bot bila valid, null bila tidak.
  Future<String?> validateToken(String botToken) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: 'https://api.telegram.org/bot${botToken.trim()}/',
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ));
      final res = await dio.get('getMe');
      if (res.data is Map && res.data['ok'] == true) {
        final result = res.data['result'];
        if (result is Map) {
          return result['username'] as String? ?? 'valid';
        }
        return 'valid';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Buat map envelope konfigurasi Telegram (opsional terenkripsi dengan PIN).
  static Map<String, dynamic> buildConfigEnvelope({
    required String botToken,
    required String chatId,
    String? pin,
  }) {
    if (pin != null && pin.trim().isNotEmpty) {
      final payloadJson = jsonEncode({
        'bot_token': botToken.trim(),
        'chat_id': chatId.trim(),
      });
      final payloadBytes = utf8.encode(payloadJson);
      final saltHex = CryptoService.generateSalt();
      final nonceHex = CryptoService.generateNonce();
      final keyBytes = CryptoService.deriveKey(pin.trim(), saltHex);
      final encryptedBytes = CryptoService.encryptChunk(payloadBytes, keyBytes, nonceHex);
      return {
        'format': 'tgcloud-config',
        'version': 1,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'is_encrypted': true,
        'salt': saltHex,
        'nonce': nonceHex,
        'payload': CryptoService.bytesToHex(encryptedBytes),
      };
    } else {
      return {
        'format': 'tgcloud-config',
        'version': 1,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'is_encrypted': false,
        'bot_token': botToken.trim(),
        'chat_id': chatId.trim(),
      };
    }
  }

  /// Parse dan decrypt map envelope konfigurasi.
  /// Mendukung format tgcloud-config (terenkripsi maupun plain) dan file JSON plain.
  static TelegramConfig parseConfigEnvelope(
    Map<String, dynamic> data, {
    String? pin,
  }) {
    // Format JSON langsung {"bot_token": "...", "chat_id": "..."}
    if (data.containsKey('bot_token') && data.containsKey('chat_id') && data['is_encrypted'] != true) {
      return TelegramConfig(
        botToken: data['bot_token'].toString().trim(),
        chatId: data['chat_id'].toString().trim(),
      );
    }
    if (data.containsKey('botToken') && data.containsKey('chatId')) {
      return TelegramConfig(
        botToken: data['botToken'].toString().trim(),
        chatId: data['chatId'].toString().trim(),
      );
    }

    if (data['format'] == 'tgcloud-config') {
      final isEncrypted = data['is_encrypted'] == true;
      if (!isEncrypted) {
        return TelegramConfig(
          botToken: (data['bot_token'] ?? '').toString().trim(),
          chatId: (data['chat_id'] ?? '').toString().trim(),
        );
      }

      final salt = data['salt'] as String?;
      final nonce = data['nonce'] as String?;
      final payload = data['payload'] as String?;

      if (salt == null || nonce == null || payload == null || salt.isEmpty || nonce.isEmpty || payload.isEmpty) {
        throw Exception('Data konfigurasi terenkripsi tidak lengkap');
      }

      if (pin == null || pin.trim().isEmpty) {
        throw Exception('PIN diperlukan untuk membuka file konfigurasi terenkripsi');
      }

      final keyBytes = CryptoService.deriveKey(pin.trim(), salt);
      final payloadBytes = CryptoService.hexToBytes(payload);

      try {
        final decryptedBytes = CryptoService.decryptChunk(payloadBytes, keyBytes, nonce);
        final decoded = jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;
        return TelegramConfig(
          botToken: (decoded['bot_token'] ?? decoded['botToken'] ?? '').toString().trim(),
          chatId: (decoded['chat_id'] ?? decoded['chatId'] ?? '').toString().trim(),
        );
      } catch (e) {
        throw Exception('PIN salah atau file konfigurasi rusak');
      }
    }

    throw Exception('Format file konfigurasi tidak dikenal');
  }

  /// Ekspor konfigurasi ke file `.tgcfg` dan bagikan via SharePlus.
  Future<File> exportToFile({
    required String botToken,
    required String chatId,
    String? pin,
    Directory? destinationDir,
    Future<void> Function(List<XFile> files)? shareFn,
  }) async {
    final envelope = buildConfigEnvelope(botToken: botToken, chatId: chatId, pin: pin);
    final dir = destinationDir ?? await getApplicationDocumentsDirectory();
    final now = DateTime.now();
    final formatter = DateFormat('yyyyMMdd-HHmm');
    final filename = 'tgcloud-config-${formatter.format(now)}.tgcfg';
    final file = File(p.join(dir.path, filename));
    await file.writeAsString(jsonEncode(envelope));

    final xfile = XFile(file.path);
    if (shareFn != null) {
      await shareFn([xfile]);
    } else {
      await SharePlus.instance.share(ShareParams(
        files: [xfile],
        text: 'Konfigurasi Telegram TGCloud',
      ));
    }
    return file;
  }

  /// Buka dialog file picker dan baca isi file JSON/tgcfg tanpa parsing dulu.
  /// Memungkinkan UI memeriksa apakah file terenkripsi sebelum meminta PIN.
  Future<Map<String, dynamic>?> pickAndReadConfigFile({
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
      throw Exception('File konfigurasi tidak ditemukan: $path');
    }

    final content = await file.readAsString();
    final dynamic decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Format file konfigurasi tidak valid (bukan JSON object)');
    }
    return decoded;
  }

  /// Impor konfigurasi langsung dari file `.tgcfg` atau `.json`.
  Future<TelegramConfig?> importFromFile({
    String? pin,
    Future<String?> Function()? pickFileFn,
  }) async {
    final data = await pickAndReadConfigFile(pickFileFn: pickFileFn);
    if (data == null) return null;
    return parseConfigEnvelope(data, pin: pin);
  }
}
