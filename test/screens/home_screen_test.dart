import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/screens/home_screen.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/services/upload_service.dart';
import 'package:dio/dio.dart';

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

  testWidgets('HomeScreen renders title, search, and empty state', (tester) async {
    final tg = TelegramStorageService(botToken: 'dummy', chatId: '-100', dio: Dio());
    final upload = UploadService(databaseService: db, telegramService: tg);
    final download = DownloadService(databaseService: db, telegramService: tg);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          databaseService: db,
          telegramService: tg,
          uploadService: upload,
          downloadService: download,
        ),
      ));
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    expect(find.text('TGCloud'), findsOneWidget);
    expect(find.text('Total File'), findsOneWidget);
    expect(find.text('Kapasitas Terpakai'), findsOneWidget);
    expect(find.text('Belum ada file di cloud'), findsOneWidget);
    expect(find.text('Unggah File'), findsOneWidget);
    expect(find.text('Baru install ulang? Pulihkan index dari Telegram'), findsOneWidget);
  });

  testWidgets('HomeScreen does not render restore banner when files exist', (tester) async {
    final tg = TelegramStorageService(botToken: 'dummy', chatId: '-100', dio: Dio());
    final upload = UploadService(databaseService: db, telegramService: tg);
    final download = DownloadService(databaseService: db, telegramService: tg);

    await tester.runAsync(() async {
      await db.insertFile(CloudFile(
        nama: 'file1.txt',
        ukuranBytes: 100,
        mime: 'text/plain',
        sha256Original: 'hash1',
        salt: 'salt1',
        jumlahChunk: 1,
        dibuatPada: '2026-10-18T00:00:00Z',
        status: 'complete',
      ));

      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          databaseService: db,
          telegramService: tg,
          uploadService: upload,
          downloadService: download,
        ),
      ));
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    expect(find.text('Baru install ulang? Pulihkan index dari Telegram'), findsNothing);
    expect(find.text('file1.txt'), findsOneWidget);
  });
}
