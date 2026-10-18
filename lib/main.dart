import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tgcloud/screens/home_screen.dart';
import 'package:tgcloud/screens/lock_screen.dart';
import 'package:tgcloud/services/app_lock_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:tgcloud/services/foreground_service.dart';
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

  final lockEnabled = await AppLockService.isEnabled(databaseService);

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

  ForegroundServiceManager.init();

  runApp(TGCloudApp(
    databaseService: databaseService,
    telegramService: telegramService,
    uploadService: uploadService,
    downloadService: downloadService,
    lockEnabled: lockEnabled,
  ));
}

class TGCloudApp extends StatelessWidget {
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;
  final UploadService uploadService;
  final DownloadService downloadService;
  final bool lockEnabled;

  const TGCloudApp({
    super.key,
    required this.databaseService,
    required this.telegramService,
    required this.uploadService,
    required this.downloadService,
    this.lockEnabled = false,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TGCloud',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: _AppGate(
        lockEnabled: lockEnabled,
        databaseService: databaseService,
        telegramService: telegramService,
        uploadService: uploadService,
        downloadService: downloadService,
      ),
    );
  }
}

class _AppGate extends StatefulWidget {
  final bool lockEnabled;
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;
  final UploadService uploadService;
  final DownloadService downloadService;

  const _AppGate({
    required this.lockEnabled,
    required this.databaseService,
    required this.telegramService,
    required this.uploadService,
    required this.downloadService,
  });

  @override
  State<_AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<_AppGate> with WidgetsBindingObserver {
  late bool _unlocked = !widget.lockEnabled;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (widget.lockEnabled &&
          _pausedAt != null &&
          DateTime.now().difference(_pausedAt!).inSeconds > 60) {
        setState(() {
          _unlocked = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) {
      return LockScreen(
        databaseService: widget.databaseService,
        onUnlocked: () {
          setState(() {
            _unlocked = true;
          });
        },
      );
    }

    return HomeScreen(
      databaseService: widget.databaseService,
      telegramService: widget.telegramService,
      uploadService: widget.uploadService,
      downloadService: widget.downloadService,
    );
  }
}
