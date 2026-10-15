import 'dart:async';
import 'package:dio/dio.dart';

class TgUploadResult {
  final String fileId;
  final int messageId;

  TgUploadResult({required this.fileId, required this.messageId});
}

class TelegramStorageService {
  String botToken;
  String chatId;
  Dio dio;

  TelegramStorageService({
    required this.botToken,
    required this.chatId,
    Dio? dio,
  }) : dio = dio ?? _buildDio(botToken);

  static Dio _buildDio(String botToken) {
    return Dio(BaseOptions(
      baseUrl: 'https://api.telegram.org/bot$botToken/',
      connectTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 90),
      receiveTimeout: const Duration(seconds: 90),
    ));
  }

  bool get isConfigured => botToken.isNotEmpty && chatId.isNotEmpty;

  /// Dipanggil setelah user menyimpan konfigurasi di layar Pengaturan.
  void updateConfig({required String botToken, required String chatId}) {
    this.botToken = botToken;
    this.chatId = chatId;
    dio = _buildDio(botToken);
  }

  Future<TgUploadResult> sendDocument(
    List<int> chunkBytes,
    String filename, {
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    int maxRetries = 3,
  }) async {
    int attempts = 0;
    while (true) {
      try {
        attempts++;
        final formData = FormData.fromMap({
          'chat_id': chatId,
          'document': MultipartFile.fromBytes(chunkBytes, filename: filename),
        });

        final response = await dio.post(
          'sendDocument',
          data: formData,
          cancelToken: cancelToken,
          onSendProgress: onSendProgress,
        );

        if (response.data['ok'] == true) {
          final doc = response.data['result']['document'];
          return TgUploadResult(
            fileId: doc['file_id'] as String,
            messageId: response.data['result']['message_id'] as int,
          );
        } else {
          throw Exception('Telegram API error: ${response.data['description']}');
        }
      } on DioException catch (e) {
        if (cancelToken?.isCancelled == true) rethrow;

        if (e.response?.statusCode == 429) {
          final retryAfter = e.response?.data?['parameters']?['retry_after'] ?? 5;
          await Future.delayed(Duration(seconds: (retryAfter as num).toInt()));
          continue;
        }

        if (attempts >= maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 2 * attempts));
      }
    }
  }

  Future<String> getDownloadUrl(String fileId) async {
    final response = await dio.get('getFile', queryParameters: {'file_id': fileId});
    if (response.data['ok'] == true) {
      final filePath = response.data['result']['file_path'] as String;
      return 'https://api.telegram.org/file/bot$botToken/$filePath';
    }
    throw Exception('Gagal mendapatkan URL Telegram: ${response.data['description']}');
  }

  Future<List<int>> downloadChunk(
    String downloadUrl, {
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    int maxRetries = 3,
  }) async {
    int attempts = 0;
    while (true) {
      try {
        attempts++;
        final response = await dio.get<List<int>>(
          downloadUrl,
          cancelToken: cancelToken,
          onReceiveProgress: onReceiveProgress,
          options: Options(responseType: ResponseType.bytes),
        );
        return response.data!;
      } on DioException {
        if (cancelToken?.isCancelled == true) rethrow;
        if (attempts >= maxRetries) rethrow;
        await Future.delayed(Duration(seconds: 2 * attempts));
      }
    }
  }

  Future<bool> deleteMessage(int messageId) async {
    try {
      final response = await dio.post('deleteMessage', data: {
        'chat_id': chatId,
        'message_id': messageId,
      });
      return response.data['ok'] == true;
    } catch (_) {
      return false;
    }
  }
}
