import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tgcloud/config/app_config.dart';

/// Konfigurasi koneksi Telegram (bot token + channel chat ID).
class TelegramConfig {
  final String botToken;
  final String chatId;

  const TelegramConfig({required this.botToken, required this.chatId});

  bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;
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
}
