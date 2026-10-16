import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/screens/home_screen.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:tgcloud/services/telegram_config_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/services/upload_service.dart';
import 'package:tgcloud/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  final databaseService = DatabaseService();
  await databaseService.init();

  // Konfigurasi Telegram: dari input manual (secure storage),
  // fallback ke --dart-define bila belum pernah diisi.
  final tgConfig = await TelegramConfigService().load();

  final telegramService = TelegramStorageService(
    botToken: tgConfig.botToken,
    chatId: tgConfig.chatId,
  );

  final uploadService = UploadService(
    databaseService: databaseService,
    telegramService: telegramService,
  );

  final downloadService = DownloadService(
    databaseService: databaseService,
    telegramService: telegramService,
  );

  runApp(TGCloudApp(
    databaseService: databaseService,
    telegramService: telegramService,
    uploadService: uploadService,
    downloadService: downloadService,
  ));
}

class TGCloudApp extends StatelessWidget {
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;
  final UploadService uploadService;
  final DownloadService downloadService;

  const TGCloudApp({
    super.key,
    required this.databaseService,
    required this.telegramService,
    required this.uploadService,
    required this.downloadService,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TGCloud',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: HomeScreen(
        databaseService: databaseService,
        telegramService: telegramService,
        uploadService: uploadService,
        downloadService: downloadService,
      ),
    );
  }
}
