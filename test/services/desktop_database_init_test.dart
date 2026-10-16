import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/services/database_service.dart';

void main() {
  test('DatabaseService.init initializes FFI and opens database on desktop', () async {
    final dbService = DatabaseService(inMemory: true);
    await dbService.init();
    final files = await dbService.getAllFiles();
    expect(files, isEmpty);
    await dbService.close();
  });

  test('DatabaseService persists data across reopen on desktop', () async {
    final dbService1 = DatabaseService(inMemory: false);
    await dbService1.init();
    await dbService1.setSetting('test_persist_key', 'persisted_value');
    expect(await dbService1.getSetting('test_persist_key'), equals('persisted_value'));
    await dbService1.close();

    final dbService2 = DatabaseService(inMemory: false);
    await dbService2.init();
    expect(await dbService2.getSetting('test_persist_key'), equals('persisted_value'));
    await dbService2.close();
  });
}
