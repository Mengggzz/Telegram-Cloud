import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/services/foreground_service.dart';

void main() {
  group('ForegroundServiceManager on non-Android', () {
    test('init does not throw on desktop', () {
      expect(() => ForegroundServiceManager.init(), returnsNormally);
    });

    test('start returns false and does not throw on desktop', () async {
      final res = await ForegroundServiceManager.start(
        title: 'Upload Test',
        text: 'Uploading test.bin...',
      );
      expect(res, isFalse);
    });

    test('update does not throw on desktop', () async {
      await expectLater(
        ForegroundServiceManager.update(title: 'Update', text: '50%'),
        completes,
      );
    });

    test('stop does not throw on desktop', () async {
      await expectLater(
        ForegroundServiceManager.stop(),
        completes,
      );
    });
  });
}
