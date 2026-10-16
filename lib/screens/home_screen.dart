import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/services/upload_service.dart';
import 'package:tgcloud/theme/app_theme.dart';
import 'package:tgcloud/widgets/file_card.dart';
import 'package:tgcloud/widgets/adaptive.dart';
import 'package:tgcloud/screens/upload_progress_sheet.dart';
import 'package:tgcloud/screens/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final DatabaseService databaseService;
  final TelegramStorageService telegramService;
  final UploadService uploadService;
  final DownloadService downloadService;

  const HomeScreen({
    super.key,
    required this.databaseService,
    required this.telegramService,
    required this.uploadService,
    required this.downloadService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<CloudFile> _files = [];
  bool _isLoading = false;
  String _searchQuery = '';
  String _userPin = '123456'; // Default PIN sesi

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    await _checkInitialPin();
    await _loadFiles();
  }

  Future<void> _checkInitialPin() async {
    final savedPin = await widget.databaseService.getSetting('user_pin');
    if (savedPin != null && savedPin.isNotEmpty) {
      _userPin = savedPin;
    } else {
      await widget.databaseService.setSetting('user_pin', _userPin);
    }
  }

  Future<void> _loadFiles() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    final files = await widget.databaseService.getAllFiles(search: _searchQuery);
    if (!mounted) return;
    setState(() {
      _files = files;
      _isLoading = false;
    });
  }

  int get _totalBytes => _files.fold(0, (sum, f) => sum + f.ukuranBytes);

  String _formatTotalSize(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  Future<void> _pickAndUpload() async {
    final pickedFile = await FilePicker.pickFile();
    if (pickedFile == null || pickedFile.path == null) return;

    final path = pickedFile.path!;
    final filename = pickedFile.name;

    double progress = 0.0;
    String status = 'Menyiapkan...';
    StateSetter? sheetSetState;

    if (!mounted) return;
    // Desktop: dialog terpusat. Mobile: bottom sheet (lihat UploadProgressSheet.show).
    UploadProgressSheet.show(
      context: context,
      builder: (ctx, setModalState) {
        sheetSetState = setModalState;
        return UploadProgressSheet(
          filename: filename,
          progress: progress,
          statusText: status,
          onCancel: () {
            Navigator.pop(ctx);
          },
        );
      },
    );

    try {
      await widget.uploadService.uploadFile(
        path,
        _userPin,
        onProgress: (p, s) {
          progress = p;
          status = s;
          sheetSetState?.call(() {});
        },
      );

      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$filename berhasil diunggah ke TGCloud!'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengunggah: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _downloadFile(CloudFile file) async {
    final dir = await getApplicationDocumentsDirectory();

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text('Mengunduh ${file.nama}', style: const TextStyle(color: AppTheme.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              LinearProgressIndicator(color: AppTheme.primary),
              SizedBox(height: 12),
              Text('Mengunduh dan mendekripsi chunk...', style: TextStyle(color: AppTheme.textMuted)),
            ],
          ),
        );
      },
    );

    try {
      final downloaded = await widget.downloadService.downloadAndReassemble(
        file.id!,
        _userPin,
        dir.path,
      );

      if (mounted) Navigator.pop(context);

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppTheme.surface,
            title: const Text('Download Selesai', style: TextStyle(color: AppTheme.textPrimary)),
            content: Text('File disimpan di ${downloaded.path}', style: const TextStyle(color: AppTheme.textMuted)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Tutup', style: TextStyle(color: AppTheme.textMuted)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
                onPressed: () {
                  Navigator.pop(ctx);
                  OpenFilex.open(downloaded.path);
                },
                child: const Text('Buka File', style: TextStyle(color: Colors.black)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengunduh: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _deleteFile(CloudFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Hapus File', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('Hapus "${file.nama}" dari cloud?', style: const TextStyle(color: AppTheme.textMuted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: AppTheme.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.uploadService.cancelUpload(file.id!);
      _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${file.nama} dihapus dari TGCloud.'),
            backgroundColor: AppTheme.surfaceLight,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Layar lebar (desktop): tombol unggah pindah ke AppBar, FAB disembunyikan,
    // konten dibatasi lebarnya agar tidak melebar penuh.
    final wide = isWideScreen(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('TGCloud'),
        actions: [
          if (wide)
            TextButton.icon(
              onPressed: _pickAndUpload,
              icon: const Icon(Icons.cloud_upload_rounded, color: AppTheme.primary),
              label: const Text(
                'Unggah File',
                style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: AppTheme.textPrimary),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(
                    databaseService: widget.databaseService,
                    telegramService: widget.telegramService,
                    onPinChanged: (newPin) {
                      _userPin = newPin;
                    },
                  ),
                ),
              );
              _loadFiles();
            },
          ),
        ],
      ),
      body: CenteredConstrained(
        child: Column(
          children: [
            // Peringatan bila Telegram belum dikonfigurasi
            if (!widget.telegramService.isConfigured)
              GestureDetector(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                        databaseService: widget.databaseService,
                        telegramService: widget.telegramService,
                        onPinChanged: (newPin) {
                          _userPin = newPin;
                        },
                      ),
                    ),
                  );
                  setState(() {});
                  _loadFiles();
                },
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.danger),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: AppTheme.danger),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Telegram belum dikonfigurasi. Ketuk untuk isi Bot Token & Chat ID.',
                          style: TextStyle(color: AppTheme.danger, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Header Ringkasan
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      const Text('Total File', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(
                        '${_files.length}',
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Container(width: 1, height: 35, color: AppTheme.border),
                  Column(
                    children: [
                      const Text('Kapasitas Terpakai', style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(
                        _formatTotalSize(_totalBytes),
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: TextField(
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Cari nama file...',
                  hintStyle: const TextStyle(color: AppTheme.textMuted),
                  prefixIcon: const Icon(Icons.search, color: AppTheme.primary),
                  filled: true,
                  fillColor: AppTheme.surface,
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.primary),
                  ),
                ),
                onChanged: (val) {
                  _searchQuery = val;
                  _loadFiles();
                },
              ),
            ),

            // File List
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
                  : _files.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(Icons.cloud_queue_rounded, size: 64, color: AppTheme.textMuted),
                              SizedBox(height: 12),
                              Text('Belum ada file di cloud', style: TextStyle(color: AppTheme.textMuted, fontSize: 16)),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          color: AppTheme.primary,
                          onRefresh: _loadFiles,
                          child: ListView.builder(
                            itemCount: _files.length,
                            itemBuilder: (ctx, i) {
                              final file = _files[i];
                              return FileCard(
                                file: file,
                                onDownload: () => _downloadFile(file),
                                onDelete: () => _deleteFile(file),
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
      floatingActionButton: wide
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.cloud_upload_rounded),
              label: const Text('Unggah File', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _pickAndUpload,
            ),
    );
  }
}
