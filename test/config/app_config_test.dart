import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/config/app_config.dart';

void main() {
  group('AppConfig', () {
    test('default chunk size should be 15MB', () {
      expect(AppConfig.chunkSizeBytes, equals(15 * 1024 * 1024));
    });

    test('isConfigured returns false when tokens are empty', () {
      expect(AppConfig.isConfigured, isFalse);
    });
  });
}
