import 'package:local_auth/local_auth.dart';
import 'package:tgcloud/services/database_service.dart';

class AppLockService {
  static const _kEnabled = 'app_lock_enabled';
  static const _kBio = 'biometric_enabled';

  static Future<bool> isEnabled(DatabaseService db) async =>
      await db.getSetting(_kEnabled) == '1';

  static Future<void> setEnabled(DatabaseService db, bool v) async =>
      await db.setSetting(_kEnabled, v ? '1' : '0');

  static Future<bool> isBiometricEnabled(DatabaseService db) async =>
      await db.getSetting(_kBio) == '1';

  static Future<void> setBiometricEnabled(DatabaseService db, bool v) async =>
      await db.setSetting(_kBio, v ? '1' : '0');

  /// true bila perangkat punya biometrik yang siap dipakai.
  static Future<bool> canUseBiometric() async {
    try {
      final auth = LocalAuthentication();
      if (!await auth.canCheckBiometrics) return false;
      final list = await auth.getAvailableBiometrics();
      return list.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Minta autentikasi biometrik saja. Return true bila sukses.
  /// Return false bila gagal/dibatalkan -> panggil UI PIN.
  static Future<bool> authenticateBiometric() async {
    try {
      final auth = LocalAuthentication();
      return await auth.authenticate(
        localizedReason: 'Buka kunci TGCloud',
        options: const AuthenticationOptions(biometricOnly: true),
      );
    } catch (_) {
      return false;
    }
  }

  /// Deskripsi singkat biometrik yang tersedia (misal: "Sidik jari / Wajah").
  static Future<String> getBiometricTypeDescription() async {
    try {
      final auth = LocalAuthentication();
      final list = await auth.getAvailableBiometrics();
      if (list.contains(BiometricType.face)) return 'Wajah / Biometrik';
      if (list.contains(BiometricType.fingerprint)) return 'Sidik jari';
      if (list.contains(BiometricType.strong)) return 'Biometrik perangkat';
      return 'Biometrik';
    } catch (_) {
      return 'Biometrik';
    }
  }
}
