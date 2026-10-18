import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/services/app_lock_service.dart';
import 'package:tgcloud/services/database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late DatabaseService db;

  setUp(() async {
    db = DatabaseService(inMemory: true);
    await db.init();
  });

  tearDown(() async {
    await db.close();
  });

  group('AppLockService', () {
    test('isEnabled defaults to false, setEnabled persists 1/0', () async {
      expect(await AppLockService.isEnabled(db), isFalse);

      await AppLockService.setEnabled(db, true);
      expect(await AppLockService.isEnabled(db), isTrue);

      await AppLockService.setEnabled(db, false);
      expect(await AppLockService.isEnabled(db), isFalse);
    });

    test('isBiometricEnabled defaults to false, setBiometricEnabled persists 1/0', () async {
      expect(await AppLockService.isBiometricEnabled(db), isFalse);

      await AppLockService.setBiometricEnabled(db, true);
      expect(await AppLockService.isBiometricEnabled(db), isTrue);

      await AppLockService.setBiometricEnabled(db, false);
      expect(await AppLockService.isBiometricEnabled(db), isFalse);
    });
  });
}
