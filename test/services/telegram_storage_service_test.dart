import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';

void main() {
  group('TelegramStorageService', () {
    late Dio mockDio;
    late TelegramStorageService service;

    setUp(() {
      mockDio = Dio(BaseOptions(baseUrl: 'https://api.telegram.org/botTEST_TOKEN/'));
      service = TelegramStorageService(
        botToken: 'TEST_TOKEN',
        chatId: '-100123456789',
        dio: mockDio,
      );
    });

    test('getDownloadUrl parses file_path correctly', () async {
      mockDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('getFile')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'result': {'file_path': 'documents/test_chunk.bin'}
              },
            ));
          } else {
            handler.next(options);
          }
        },
      ));

      final url = await service.getDownloadUrl('file_id_xyz');
      expect(url, equals('https://api.telegram.org/file/botTEST_TOKEN/documents/test_chunk.bin'));
    });

    test('deleteMessage returns true on 200 ok: true', () async {
      mockDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('deleteMessage')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'ok': true, 'result': true},
            ));
          } else {
            handler.next(options);
          }
        },
      ));

      final deleted = await service.deleteMessage(456);
      expect(deleted, isTrue);
    });

    test('sendDocument uploads chunk and returns fileId & messageId', () async {
      mockDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('sendDocument')) {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'result': {
                  'message_id': 888,
                  'document': {'file_id': 'tg_chunk_file_id_999'}
                }
              },
            ));
          } else {
            handler.next(options);
          }
        },
      ));

      final result = await service.sendDocument([1, 2, 3, 4], 'chunk0.bin');
      expect(result.fileId, equals('tg_chunk_file_id_999'));
      expect(result.messageId, equals(888));
    });
  });
}
