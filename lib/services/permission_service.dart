import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tgcloud/services/database_service.dart';

class PermissionService {
  /// Minta izin notifikasi (Android 13+) — sekali saja, tidak mengulang.
  static Future<void> requestNotificationOnce(DatabaseService db) async {
    if (!Platform.isAndroid) return;
    try {
      if (await db.getSetting('notif_perm_asked') == '1') return;
      final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      if (sdk < 33) return; // di bawah Android 13 izin otomatis dari manifest
      if (await Permission.notification.status.isDenied) {
        await Permission.notification.request();
      }
      await db.setSetting('notif_perm_asked', '1');
    } catch (_) {}
  }
}
