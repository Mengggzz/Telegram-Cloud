import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:tgcloud/services/database_service.dart';

class PermissionService {
  /// Minta izin notifikasi (Android 13+) — sekali saja, tidak mengulang.
  static Future<void> requestNotificationOnce(DatabaseService db) async {
    if (!Platform.isAndroid) return;
    try {
      if (await db.getSetting('notif_perm_asked') == '1') return;
      final status = await FlutterForegroundTask.checkNotificationPermission();
      if (status != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      await db.setSetting('notif_perm_asked', '1');
    } catch (_) {}
  }
}
