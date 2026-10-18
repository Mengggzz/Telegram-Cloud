import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tgcloud/services/telegram_config_service.dart';

void main() {
  group('TelegramConfigService', () {
    const testBotToken = '123456789:ABCdefGHIjklMNOpqrsTUVwxyz';
    const testChatId = '-1009876543210';
    const testPin = '654321';

    test('buildConfigEnvelope unencrypted creates format tgcloud-config', () {
      final envelope = TelegramConfigService.buildConfigEnvelope(
        botToken: testBotToken,
        chatId: testChatId,
      );

      expect(envelope['format'], equals('tgcloud-config'));
      expect(envelope['version'], equals(1));
      expect(envelope['is_encrypted'], isFalse);
      expect(envelope['bot_token'], equals(testBotToken));
      expect(envelope['chat_id'], equals(testChatId));

      final parsed = TelegramConfigService.parseConfigEnvelope(envelope);
      expect(parsed.botToken, equals(testBotToken));
      expect(parsed.chatId, equals(testChatId));
      expect(parsed.isConfigured, isTrue);
    });

    test('buildConfigEnvelope encrypted with PIN encrypts payload and decrypts with correct PIN', () {
      final envelope = TelegramConfigService.buildConfigEnvelope(
        botToken: testBotToken,
        chatId: testChatId,
        pin: testPin,
      );

      expect(envelope['format'], equals('tgcloud-config'));
      expect(envelope['version'], equals(1));
      expect(envelope['is_encrypted'], isTrue);
      expect(envelope['salt'], isNotNull);
      expect(envelope['nonce'], isNotNull);
      expect(envelope['payload'], isNotNull);
      expect(envelope['bot_token'], isNull);

      final parsed = TelegramConfigService.parseConfigEnvelope(envelope, pin: testPin);
      expect(parsed.botToken, equals(testBotToken));
      expect(parsed.chatId, equals(testChatId));
    });

    test('parseConfigEnvelope throws on wrong PIN for encrypted config', () {
      final envelope = TelegramConfigService.buildConfigEnvelope(
        botToken: testBotToken,
        chatId: testChatId,
        pin: testPin,
      );

      expect(
        () => TelegramConfigService.parseConfigEnvelope(envelope, pin: '000000'),
        throwsA(predicate((e) => e.toString().contains('PIN salah'))),
      );
    });

    test('parseConfigEnvelope throws when encrypted config opened without PIN', () {
      final envelope = TelegramConfigService.buildConfigEnvelope(
        botToken: testBotToken,
        chatId: testChatId,
        pin: testPin,
      );

      expect(
        () => TelegramConfigService.parseConfigEnvelope(envelope),
        throwsA(predicate((e) => e.toString().contains('PIN diperlukan'))),
      );
    });

    test('parseConfigEnvelope parses raw plain JSON with snake_case and camelCase', () {
      final snakeJson = {
        'bot_token': testBotToken,
        'chat_id': testChatId,
      };
      final config1 = TelegramConfigService.parseConfigEnvelope(snakeJson);
      expect(config1.botToken, equals(testBotToken));
      expect(config1.chatId, equals(testChatId));

      final camelJson = {
        'botToken': testBotToken,
        'chatId': testChatId,
      };
      final config2 = TelegramConfigService.parseConfigEnvelope(camelJson);
      expect(config2.botToken, equals(testBotToken));
      expect(config2.chatId, equals(testChatId));
    });

    test('exportToFile creates .tgcfg file and triggers shareFn', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgcfg_test');
      List<XFile>? sharedFiles;

      final configService = TelegramConfigService();
      final file = await configService.exportToFile(
        botToken: testBotToken,
        chatId: testChatId,
        pin: testPin,
        destinationDir: tempDir,
        shareFn: (files) async {
          sharedFiles = files;
        },
      );

      expect(file.existsSync(), isTrue);
      expect(file.path.endsWith('.tgcfg'), isTrue);
      expect(sharedFiles, isNotNull);
      expect(sharedFiles!.first.path, equals(file.path));

      final content = await file.readAsString();
      final envelope = jsonDecode(content) as Map<String, dynamic>;
      final parsed = TelegramConfigService.parseConfigEnvelope(envelope, pin: testPin);
      expect(parsed.botToken, equals(testBotToken));
      expect(parsed.chatId, equals(testChatId));

      await tempDir.delete(recursive: true);
    });

    test('importFromFile reads file and returns parsed config', () async {
      final tempDir = await Directory.systemTemp.createTemp('tgcfg_import_test');
      final file = File('${tempDir.path}/config.tgcfg');
      final envelope = TelegramConfigService.buildConfigEnvelope(
        botToken: testBotToken,
        chatId: testChatId,
        pin: testPin,
      );
      await file.writeAsString(jsonEncode(envelope));

      final configService = TelegramConfigService();
      final imported = await configService.importFromFile(
        pin: testPin,
        pickFileFn: () async => file.path,
      );

      expect(imported, isNotNull);
      expect(imported!.botToken, equals(testBotToken));
      expect(imported.chatId, equals(testChatId));

      await tempDir.delete(recursive: true);
    });
  });
}
