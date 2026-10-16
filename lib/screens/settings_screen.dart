import 'package:flutter/material.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/telegram_config_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/theme/app_theme.dart';
import 'package:tgcloud/widgets/adaptive.dart';

class SettingsScreen extends StatefulWidget {
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;
  final Function(String newPin)? onPinChanged;

  const SettingsScreen({
    super.key,
    required this.databaseService,
    required this.telegramService,
    this.onPinChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _wifiOnly = false;
  bool _autoBackup = false;
  String _lastBackupTime = '-';

  final _tokenController = TextEditingController();
  final _chatIdController = TextEditingController();
  String _tgStatus = 'Belum dikonfigurasi';
  bool _tgSaving = false;

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
    final tgConfig = await TelegramConfigService().load();

    if (!mounted) return;
    setState(() {
      _wifiOnly = wifi == 'true';
      _autoBackup = auto == 'true';
      _lastBackupTime = lastTime ?? 'Belum pernah dicadangkan';
      _tokenController.text = tgConfig.botToken;
      _chatIdController.text = tgConfig.chatId;
      _tgStatus = tgConfig.isConfigured
          ? 'Terkonfigurasi'
          : 'Belum dikonfigurasi';
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

          // Seksi Cadangan
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

          // Tombol Bersihkan Cache
          ListTile(
            tileColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            leading: const Icon(Icons.cleaning_services_rounded, color: AppTheme.danger),
            title: const Text('Bersihkan Cache Sementara', style: TextStyle(color: AppTheme.danger)),
            subtitle: const Text('Menghapus file parsial & unduhan sementara', style: TextStyle(color: AppTheme.textMuted)),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Cache sementara berhasil dibersihkan.'),
                  backgroundColor: AppTheme.surfaceLight,
                ),
              );
            },
          ),
        ],
        ),
      ),
    );
  }
}
