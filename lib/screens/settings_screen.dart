import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tgcloud/services/app_lock_service.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/manifest_service.dart';
import 'package:tgcloud/services/telegram_config_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/theme/app_theme.dart';
import 'package:tgcloud/widgets/adaptive.dart';

class SettingsScreen extends StatefulWidget {
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;
  final Function(String newPin)? onPinChanged;
  final VoidCallback? onDatabaseRestored;

  const SettingsScreen({
    super.key,
    required this.databaseService,
    required this.telegramService,
    this.onPinChanged,
    this.onDatabaseRestored,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _wifiOnly = false;
  bool _autoBackup = false;
  String _lastBackupTime = '-';
  String? _manifestSyncedAt;
  late final ManifestService _manifestService = ManifestService(widget.databaseService);

  final _tokenController = TextEditingController();
  final _chatIdController = TextEditingController();
  String _tgStatus = 'Belum dikonfigurasi';
  bool _tgSaving = false;
  bool _appLockEnabled = false;
  bool _biometricEnabled = false;
  bool _canBiometric = false;
  String _biometricDesc = 'Biometrik';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _chatIdController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final wifi = await widget.databaseService.getSetting('wifi_only');
    final auto = await widget.databaseService.getSetting('auto_backup_enabled');
    final lastTime = await widget.databaseService.getSetting('last_backup_time');
    final manifestSynced = await widget.databaseService.getSetting('manifest_synced_at');
    final tgConfig = await TelegramConfigService().load();
    final lock = await AppLockService.isEnabled(widget.databaseService);
    final bio = await AppLockService.isBiometricEnabled(widget.databaseService);
    final canBio = await AppLockService.canUseBiometric();
    final bioDesc = await AppLockService.getBiometricTypeDescription();

    if (!mounted) return;
    setState(() {
      _wifiOnly = wifi == 'true';
      _autoBackup = auto == 'true';
      _lastBackupTime = lastTime ?? 'Belum pernah dicadangkan';
      _manifestSyncedAt = manifestSynced;
      _tokenController.text = tgConfig.botToken;
      _chatIdController.text = tgConfig.chatId;
      _tgStatus = tgConfig.isConfigured
          ? 'Terkonfigurasi'
          : 'Belum dikonfigurasi';
      _appLockEnabled = lock;
      _biometricEnabled = bio;
      _canBiometric = canBio;
      _biometricDesc = bioDesc;
    });
  }

  Future<void> _saveTelegramConfig() async {
    final token = _tokenController.text.trim();
    final chatId = _chatIdController.text.trim();

    if (token.isEmpty || chatId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Isi Bot Token dan Channel Chat ID dulu.')),
      );
      return;
    }

    setState(() {
      _tgSaving = true;
      _tgStatus = 'Memvalidasi token...';
    });

    final configService = TelegramConfigService();
    final username = await configService.validateToken(token);

    if (!mounted) return;

    if (username == null) {
      setState(() {
        _tgSaving = false;
        _tgStatus = 'Token tidak valid / tidak ada koneksi internet.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gagal: token bot tidak valid.'),
          backgroundColor: AppTheme.danger,
        ),
      );
      return;
    }

    await configService.save(token, chatId);
    widget.telegramService.updateConfig(botToken: token, chatId: chatId);

    setState(() {
      _tgSaving = false;
      _tgStatus = 'Terhubung sebagai @$username';
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Telegram terhubung (@$username).'),
        backgroundColor: AppTheme.success,
      ),
    );
  }

  Future<void> _exportTelegramConfig() async {
    final token = _tokenController.text.trim();
    final chatId = _chatIdController.text.trim();

    if (token.isEmpty || chatId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Isi Bot Token dan Channel Chat ID sebelum mengekspor.'),
          backgroundColor: AppTheme.danger,
        ),
      );
      return;
    }

    final pinController = TextEditingController();
    final exportChoice = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Ekspor Konfigurasi Bot & Channel',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Simpan Bot Token dan Channel Chat ID ke file (*.tgcfg) agar tidak perlu mengisi manual saat aplikasi diinstall ulang.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: const InputDecoration(
                labelText: 'PIN Enkripsi (opsional)',
                hintText: 'Kosongkan jika tanpa sandi',
                labelStyle: TextStyle(color: AppTheme.primary),
                hintStyle: TextStyle(color: AppTheme.textMuted),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Batal', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(ctx, pinController.text.trim()),
            child: const Text('Ekspor', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );

    if (exportChoice == null) return;

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Menyiapkan file konfigurasi Telegram...')),
        );
      }
      final configService = TelegramConfigService();
      final file = await configService.exportToFile(
        botToken: token,
        chatId: chatId,
        pin: exportChoice.isEmpty ? null : exportChoice,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Konfigurasi diekspor: ${file.path}'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengekspor: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _importTelegramConfig() async {
    try {
      final configService = TelegramConfigService();
      final rawData = await configService.pickAndReadConfigFile();
      if (rawData == null) return;

      TelegramConfig importedConfig;
      if (rawData['format'] == 'tgcloud-config' && rawData['is_encrypted'] == true) {
        if (!mounted) return;
        final pin = await _askPinDialog(
          title: 'Buka Konfigurasi Terenkripsi',
          actionLabel: 'Buka',
        );
        if (pin == null || pin.isEmpty) return;
        importedConfig = TelegramConfigService.parseConfigEnvelope(rawData, pin: pin);
      } else {
        importedConfig = TelegramConfigService.parseConfigEnvelope(rawData);
      }

      if (!mounted) return;
      setState(() {
        _tokenController.text = importedConfig.botToken;
        _chatIdController.text = importedConfig.chatId;
      });

      final shouldSave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Konfigurasi Ditemukan', style: TextStyle(color: AppTheme.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Channel ID: ${importedConfig.chatId}',
                  style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                'Token: ${importedConfig.botToken.length > 10 ? "${importedConfig.botToken.substring(0, 8)}..." : "***"}',
                style: const TextStyle(color: AppTheme.textMuted),
              ),
              const SizedBox(height: 12),
              const Text(
                'Simpan dan validasi koneksi Telegram sekarang?',
                style: TextStyle(color: AppTheme.textMuted),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Isi Form Saja', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Simpan & Validasi', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      );

      if (shouldSave == true) {
        await _saveTelegramConfig();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Konfigurasi dimuat ke formulir. Tekan "Simpan & Validasi" untuk mengaktifkan.'),
              backgroundColor: AppTheme.primary,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengimpor: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _changePinDialog() async {
    final controller = TextEditingController();
    final newPin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Ubah PIN Enkripsi', style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(
            labelText: 'PIN Baru (6 angka)',
            labelStyle: TextStyle(color: AppTheme.primary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Simpan', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );

    if (newPin != null && newPin.length >= 4) {
      await widget.databaseService.setSetting('user_pin', newPin);
      widget.onPinChanged?.call(newPin);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PIN enkripsi berhasil diperbarui!'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    }
  }

  Future<String?> _askPinDialog({required String title, required String actionLabel}) async {
    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(
            labelText: 'PIN Enkripsi',
            labelStyle: TextStyle(color: AppTheme.primary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Batal', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(actionLabel, style: const TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
    return pin;
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return 'Belum pernah';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    } catch (_) {
      return iso;
    }
  }

  Future<void> _exportToFile() async {
    final pin = await _askPinDialog(title: 'Ekspor Cadangan', actionLabel: 'Ekspor');
    if (pin == null || pin.isEmpty) return;

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Menyiapkan file cadangan...')),
        );
      }
      final file = await _manifestService.exportToFile(pin);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cadangan diekspor: ${file.path}'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengekspor: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _importFromFile() async {
    final pin = await _askPinDialog(title: 'Impor Cadangan', actionLabel: 'Pilih File');
    if (pin == null || pin.isEmpty) return;

    try {
      final data = await _manifestService.importFromFile(pin);
      if (data == null) return;

      if (!mounted) return;
      final fileCount = data['files']?.length ?? 0;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Konfirmasi Impor Cadangan', style: TextStyle(color: AppTheme.textPrimary)),
          content: Text(
            'Ganti seluruh daftar file lokal dengan cadangan ini? ($fileCount file ditemukan). Tindakan ini akan menimpa database lokal saat ini.',
            style: const TextStyle(color: AppTheme.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ganti Database', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      if (confirm == true) {
        await _manifestService.replaceDatabase(data);
        widget.onDatabaseRestored?.call();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Daftar file berhasil dipulihkan dari file cadangan!'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengimpor: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _syncToTelegram() async {
    if (!widget.telegramService.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Isi Bot Token dan Channel Chat ID dulu.'),
          backgroundColor: AppTheme.danger,
        ),
      );
      return;
    }

    final pin = await _askPinDialog(title: 'Sinkronkan Index ke Telegram', actionLabel: 'Sinkronkan');
    if (pin == null || pin.isEmpty) return;

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mengunggah index manifest ke Telegram...')),
        );
      }
      await _manifestService.syncToTelegram(
        pin: pin,
        tg: widget.telegramService,
        cfg: TelegramConfigService(),
      );
      final syncedAt = await widget.databaseService.getSetting('manifest_synced_at');
      if (mounted) {
        setState(() {
          _manifestSyncedAt = syncedAt;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Index manifest berhasil disinkronkan dan di-pin di channel!'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal sinkron: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _restoreFromTelegram() async {
    if (!widget.telegramService.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Isi Bot Token dan Channel Chat ID dulu.'),
          backgroundColor: AppTheme.danger,
        ),
      );
      return;
    }

    final pin = await _askPinDialog(title: 'Pulihkan Index dari Telegram', actionLabel: 'Lanjut');
    if (pin == null || pin.isEmpty) return;

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Pulihkan Index Telegram', style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Ganti seluruh daftar file lokal dengan manifest yang ada di channel Telegram?',
          style: TextStyle(color: AppTheme.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Pulihkan', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mengunduh dan memulihkan index dari Telegram...')),
        );
      }
      await _manifestService.restoreFromTelegram(
        pin: pin,
        tg: widget.telegramService,
        cfg: TelegramConfigService(),
      );
      widget.onDatabaseRestored?.call();
      final syncedAt = await widget.databaseService.getSetting('manifest_synced_at');
      if (mounted) {
        setState(() {
          _manifestSyncedAt = syncedAt;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Index berhasil dipulihkan dari Telegram!'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal memulihkan index: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pengaturan & Cadangan'),
      ),
      // Desktop: form dibatasi lebarnya dan ditengahkan agar tidak melebar penuh.
      body: CenteredConstrained(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.all(16),
        children: [
          // Seksi Koneksi Telegram
          const Text('Koneksi Telegram', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _tokenController,
                  obscureText: true,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Bot Token',
                    hintText: '123456:ABC-DEF...',
                    labelStyle: TextStyle(color: AppTheme.textMuted),
                    hintStyle: TextStyle(color: AppTheme.textMuted),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _chatIdController,
                  keyboardType: TextInputType.text,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Channel Chat ID',
                    hintText: '-1001234567890',
                    labelStyle: TextStyle(color: AppTheme.textMuted),
                    hintStyle: TextStyle(color: AppTheme.textMuted),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Status: $_tgStatus',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _tgSaving ? null : _saveTelegramConfig,
                  child: Text(
                    _tgSaving ? 'Memvalidasi...' : 'Simpan & Validasi',
                    style: const TextStyle(color: Colors.black),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primary,
                          side: const BorderSide(color: AppTheme.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: const Text('Ekspor Bot ID', style: TextStyle(fontSize: 13)),
                        onPressed: _exportTelegramConfig,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primary,
                          side: const BorderSide(color: AppTheme.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        icon: const Icon(Icons.file_download_outlined, size: 18),
                        label: const Text('Impor Bot ID', style: TextStyle(fontSize: 13)),
                        onPressed: _importTelegramConfig,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Seksi Keamanan
          const Text('Keamanan', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          ListTile(
            tileColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            leading: const Icon(Icons.lock_outline_rounded, color: AppTheme.primary),
            title: const Text('Ubah PIN Enkripsi', style: TextStyle(color: AppTheme.textPrimary)),
            subtitle: const Text('Kunci derivasi AES-256-GCM', style: TextStyle(color: AppTheme.textMuted)),
            trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
            onTap: _changePinDialog,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            tileColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            activeThumbColor: AppTheme.primary,
            title: const Text('Kunci Aplikasi', style: TextStyle(color: AppTheme.textPrimary)),
            subtitle: const Text('Minta PIN/biometrik saat aplikasi dibuka', style: TextStyle(color: AppTheme.textMuted)),
            value: _appLockEnabled,
            onChanged: (val) async {
              setState(() => _appLockEnabled = val);
              await AppLockService.setEnabled(widget.databaseService, val);
            },
          ),
          if (_canBiometric) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              tileColor: AppTheme.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              activeThumbColor: AppTheme.primary,
              title: const Text('Buka dengan Biometrik', style: TextStyle(color: AppTheme.textPrimary)),
              subtitle: Text(_biometricDesc, style: const TextStyle(color: AppTheme.textMuted)),
              value: _biometricEnabled,
              onChanged: _appLockEnabled
                  ? (val) async {
                      setState(() => _biometricEnabled = val);
                      await AppLockService.setBiometricEnabled(widget.databaseService, val);
                    }
                  : null,
            ),
          ],
          const SizedBox(height: 24),

          // Seksi Jaringan & Transfer
          const Text('Jaringan & Transfer', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          SwitchListTile(
            tileColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            activeThumbColor: AppTheme.primary,
            title: const Text('Hanya Saat Terhubung WiFi', style: TextStyle(color: AppTheme.textPrimary)),
            subtitle: const Text('Mencegah penggunaan kuota data seluler', style: TextStyle(color: AppTheme.textMuted)),
            value: _wifiOnly,
            onChanged: (val) async {
              setState(() => _wifiOnly = val);
              await widget.databaseService.setSetting('wifi_only', val.toString());
            },
          ),
          const SizedBox(height: 24),

          // Seksi Cadangan Media Otomatis
          const Text('Cadangan Media Otomatis', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          SwitchListTile(
            tileColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            activeThumbColor: AppTheme.primary,
            title: const Text('Aktifkan Cadangan Otomatis', style: TextStyle(color: AppTheme.textPrimary)),
            subtitle: Text('Terakhir: $_lastBackupTime', style: const TextStyle(color: AppTheme.textMuted)),
            value: _autoBackup,
            onChanged: (val) async {
              setState(() => _autoBackup = val);
              await widget.databaseService.setSetting('auto_backup_enabled', val.toString());
            },
          ),
          const SizedBox(height: 24),

          // Seksi Cadangan & Pulihkan Metadata
          const Text('Cadangan & Pulihkan Metadata', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.file_upload_outlined, color: AppTheme.primary),
                  title: const Text('Ekspor ke File (*.tgcbak)', style: TextStyle(color: AppTheme.textPrimary)),
                  subtitle: const Text('Simpan cadangan terenkripsi ke file lokal', style: TextStyle(color: AppTheme.textMuted)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                  onTap: _exportToFile,
                ),
                const Divider(height: 1, color: AppTheme.border),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined, color: AppTheme.primary),
                  title: const Text('Impor dari File (*.tgcbak)', style: TextStyle(color: AppTheme.textPrimary)),
                  subtitle: const Text('Pulihkan daftar file dari cadangan lokal', style: TextStyle(color: AppTheme.textMuted)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                  onTap: _importFromFile,
                ),
                const Divider(height: 1, color: AppTheme.border),
                ListTile(
                  leading: const Icon(Icons.key_outlined, color: AppTheme.primary),
                  title: const Text('Ekspor Konfigurasi Bot (*.tgcfg)', style: TextStyle(color: AppTheme.textPrimary)),
                  subtitle: const Text('Simpan Bot Token & Chat ID ke file terpisah', style: TextStyle(color: AppTheme.textMuted)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                  onTap: _exportTelegramConfig,
                ),
                const Divider(height: 1, color: AppTheme.border),
                ListTile(
                  leading: const Icon(Icons.vpn_key_outlined, color: AppTheme.primary),
                  title: const Text('Impor Konfigurasi Bot (*.tgcfg)', style: TextStyle(color: AppTheme.textPrimary)),
                  subtitle: const Text('Muat Bot Token & Chat ID dari file cadangan', style: TextStyle(color: AppTheme.textMuted)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                  onTap: _importTelegramConfig,
                ),
                const Divider(height: 1, color: AppTheme.border),
                ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined, color: AppTheme.primary),
                  title: const Text('Sinkronkan Index ke Telegram', style: TextStyle(color: AppTheme.textPrimary)),
                  subtitle: Text('Upload manifest terenkripsi ke channel\nTerakhir: ${_formatDate(_manifestSyncedAt)}', style: const TextStyle(color: AppTheme.textMuted)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                  onTap: _syncToTelegram,
                ),
                const Divider(height: 1, color: AppTheme.border),
                ListTile(
                  leading: const Icon(Icons.cloud_download_outlined, color: AppTheme.primary),
                  title: const Text('Pulihkan Index dari Telegram', style: TextStyle(color: AppTheme.textPrimary)),
                  subtitle: const Text('Ambil index dari pesan ter-pin di channel', style: TextStyle(color: AppTheme.textMuted)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                  onTap: _restoreFromTelegram,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Tombol Bersihkan Cache
          ListTile(
            tileColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            leading: const Icon(Icons.cleaning_services_rounded, color: AppTheme.danger),
            title: const Text('Bersihkan Cache Sementara', style: TextStyle(color: AppTheme.danger)),
            subtitle: const Text('Menghapus file parsial, pratinjau & unduhan sementara', style: TextStyle(color: AppTheme.textMuted)),
            onTap: () async {
              try {
                final temp = await getTemporaryDirectory();
                final previewDir = Directory(p.join(temp.path, 'tgcloud_preview'));
                if (await previewDir.exists()) {
                  await previewDir.delete(recursive: true);
                }
              } catch (_) {}
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Cache sementara berhasil dibersihkan.'),
                    backgroundColor: AppTheme.surfaceLight,
                  ),
                );
              }
            },
          ),
        ],
        ),
      ),
    );
  }
}
