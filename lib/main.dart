import 'package:flutter/material.dart';
import 'package:tgcloud/config/app_config.dart';
import 'package:tgcloud/screens/home_screen.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/services/upload_service.dart';
import 'package:tgcloud/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final databaseService = DatabaseService();
  await databaseService.init();

  final telegramService = TelegramStorageService(
    botToken: AppConfig.botToken,
    chatId: AppConfig.chatId,
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
    uploadService: uploadService,
    downloadService: downloadService,
  ));
}

class TGCloudApp extends StatelessWidget {
  final DatabaseService databaseService;
  final UploadService uploadService;
  final DownloadService downloadService;

  const TGCloudApp({
    super.key,
    required this.databaseService,
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
        uploadService: uploadService,
        downloadService: downloadService,
      ),
    );
  }
}
