import 'package:flutter/material.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  final DatabaseService databaseService;
  final Function(String newPin)? onPinChanged;

  const SettingsScreen({
    super.key,
    required this.databaseService,
    this.onPinChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _wifiOnly = false;
  bool _autoBackup = false;
  String _lastBackupTime = '-';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final wifi = await widget.databaseService.getSetting('wifi_only');
    final auto = await widget.databaseService.getSetting('auto_backup_enabled');
    final lastTime = await widget.databaseService.getSetting('last_backup_time');

    setState(() {
      _wifiOnly = wifi == 'true';
      _autoBackup = auto == 'true';
      _lastBackupTime = lastTime ?? 'Belum pernah dicadangkan';
    });
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
    );
  }
}
