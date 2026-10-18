import 'package:desktop_drop/desktop_drop.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:tgcloud/services/foreground_service.dart';
import 'package:tgcloud/services/manifest_service.dart';
import 'package:tgcloud/services/telegram_config_service.dart';
import 'package:tgcloud/services/telegram_storage_service.dart';
import 'package:tgcloud/services/upload_service.dart';
import 'package:tgcloud/theme/app_theme.dart';
import 'package:tgcloud/widgets/file_card.dart';
import 'package:tgcloud/widgets/adaptive.dart';
import 'package:tgcloud/screens/upload_progress_sheet.dart';
import 'package:tgcloud/screens/settings_screen.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
  bool _dragging = false; // File sedang di-drag ke jendela (desktop)

  @override
  void initState() {
    super.initState();
    _initData();
  }

  Future<void> _initData() async {
    await _checkInitialPin();
    await _loadFiles();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _offerResume();
    });
  }

  Future<void> _offerResume() async {
    if (!mounted) return;
    try {
      final files = await widget.databaseService.getAllFiles();
      final pending = files.where((f) => f.status == 'uploading').toList();
      if (pending.isEmpty || !mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Upload Belum Selesai',
              style: TextStyle(color: AppTheme.textPrimary)),
          content: Text('${pending.length} file belum selesai diupload. Lanjutkan sekarang?',
              style: const TextStyle(color: AppTheme.textMuted)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Nanti', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Lanjutkan', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      );
      if (go == true) {
        for (final f in pending) {
          if (!mounted) return;
          await _resumePath(f);
        }
      }
    } catch (_) {}
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

  Future<void> _autoSyncManifest([String? pinToUse]) async {
    if (!widget.telegramService.isConfigured) return;
    try {
      final manifest = ManifestService(widget.databaseService);
      await manifest.syncToTelegram(
        pin: pinToUse ?? _userPin,
        tg: widget.telegramService,
        cfg: TelegramConfigService(),
      );
    } catch (e) {
      debugPrint('Sync index gagal: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sinkron index gagal, coba manual'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    }
  }

  Future<void> _restoreFromTelegramDialog() async {
    final controller = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Pulihkan Index dari Telegram', style: TextStyle(color: AppTheme.textPrimary)),
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
            child: const Text('Pulihkan', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );

    if (pin == null || pin.isEmpty) return;

    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mengunduh dan memulihkan index dari Telegram...')),
        );
      }
      final manifest = ManifestService(widget.databaseService);
      await manifest.restoreFromTelegram(
        pin: pin,
        tg: widget.telegramService,
        cfg: TelegramConfigService(),
      );
      _userPin = pin;
      await _loadFiles();
      if (mounted) {
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

  Future<void> _pickAndUpload() async {
    final pickedFile = await FilePicker.pickFile();
    if (pickedFile == null || pickedFile.path == null) return;
    await _uploadPath(pickedFile.path!, pickedFile.name);
  }

  /// Upload beberapa file berurutan — dipakai drag & drop di desktop.
  Future<void> _dropAndUpload(List<String> paths) async {
    for (final path in paths) {
      if (!mounted) return;
      await _uploadPath(path, p.basename(path));
    }
  }

  /// Alur upload satu file + dialog progres.
  /// Dipakai bersama oleh file picker dan drag & drop.
  Future<void> _uploadPath(String path, String filename) async {
    double progress = 0.0;
    String status = 'Menyiapkan...';
    StateSetter? sheetSetState;
    final cancelToken = CancelToken();
    int? activeFileId;
    int lastFgPct = -1;

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
          onCancel: () async {
            cancelToken.cancel();
            final choice = await showDialog<String>(
              context: context,
              builder: (dCtx) => AlertDialog(
                backgroundColor: AppTheme.surface,
                title: const Text('Batalkan Unggahan',
                    style: TextStyle(color: AppTheme.textPrimary)),
                content: const Text(
                  'Jeda untuk dilanjutkan nanti, atau hapus progres upload ini?',
                  style: TextStyle(color: AppTheme.textMuted)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dCtx, 'resume'),
                    child: const Text('Jeda',
                        style: TextStyle(color: AppTheme.primary)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dCtx, 'delete'),
                    child: const Text('Hapus',
                        style: TextStyle(color: AppTheme.danger)),
                  ),
                ],
              ),
            );
            if (choice == 'delete' && activeFileId != null) {
              await widget.uploadService.cancelUpload(activeFileId!);
            }
            if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx);
            _loadFiles();
          },
        );
      },
    );

    bool fgStarted = false;
    try {
      fgStarted = await ForegroundServiceManager.start(
        title: 'TGCloud',
        text: 'Mengupload $filename...',
      );
    } catch (_) {
      fgStarted = false;
    }

    bool wakelockOn = false;
    try {
      await WakelockPlus.enable();
      wakelockOn = true;
    } catch (_) {}

    try {
      await widget.uploadService.uploadFile(
        path,
        _userPin,
        cancelToken: cancelToken,
        onFileIdCreated: (id) => activeFileId = id,
        onProgress: (p, s) {
          progress = p;
          status = s;
          sheetSetState?.call(() {});
          final pct = (p * 100).toInt();
          if (fgStarted && pct % 5 == 0 && pct != lastFgPct) {
            lastFgPct = pct;
            try {
              ForegroundServiceManager.update(
                title: 'TGCloud',
                text: '$s • $pct%',
              );
            } catch (_) {}
          }
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
      _autoSyncManifest();
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
    } finally {
      if (wakelockOn) {
        try {
          await WakelockPlus.disable();
        } catch (_) {}
      }
      if (fgStarted) {
        try {
          await ForegroundServiceManager.stop();
        } catch (_) {}
      }
    }
  }

  Future<void> _resumePath(CloudFile file) async {
    final filename = file.nama;
    double progress = 0.0;
    String status = 'Menyiapkan...';
    StateSetter? sheetSetState;
    final cancelToken = CancelToken();
    int? activeFileId = file.id;
    int lastFgPct = -1;

    if (!mounted) return;
    UploadProgressSheet.show(
      context: context,
      builder: (ctx, setModalState) {
        sheetSetState = setModalState;
        return UploadProgressSheet(
          filename: filename,
          progress: progress,
          statusText: status,
          onCancel: () async {
            cancelToken.cancel();
            final choice = await showDialog<String>(
              context: context,
              builder: (dCtx) => AlertDialog(
                backgroundColor: AppTheme.surface,
                title: const Text('Batalkan Unggahan',
                    style: TextStyle(color: AppTheme.textPrimary)),
                content: const Text(
                  'Jeda untuk dilanjutkan nanti, atau hapus progres upload ini?',
                  style: TextStyle(color: AppTheme.textMuted)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dCtx, 'resume'),
                    child: const Text('Jeda',
                        style: TextStyle(color: AppTheme.primary)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dCtx, 'delete'),
                    child: const Text('Hapus',
                        style: TextStyle(color: AppTheme.danger)),
                  ),
                ],
              ),
            );
            if (choice == 'delete' && activeFileId != null) {
              await widget.uploadService.cancelUpload(activeFileId!);
            }
            if (ctx.mounted && Navigator.canPop(ctx)) Navigator.pop(ctx);
            _loadFiles();
          },
        );
      },
    );

    bool fgStarted = false;
    try {
      fgStarted = await ForegroundServiceManager.start(
        title: 'TGCloud',
        text: 'Melanjutkan upload $filename...',
      );
    } catch (_) {
      fgStarted = false;
    }

    bool wakelockOn = false;
    try {
      await WakelockPlus.enable();
      wakelockOn = true;
    } catch (_) {}

    try {
      await widget.uploadService.resumeUpload(
        file.id!,
        _userPin,
        cancelToken: cancelToken,
        onFileIdCreated: (id) => activeFileId = id,
        onProgress: (p, s) {
          progress = p;
          status = s;
          sheetSetState?.call(() {});
          final pct = (p * 100).toInt();
          if (fgStarted && pct % 5 == 0 && pct != lastFgPct) {
            lastFgPct = pct;
            try {
              ForegroundServiceManager.update(
                title: 'TGCloud',
                text: '$s • $pct%',
              );
            } catch (_) {}
          }
        },
      );

      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      _loadFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload $filename dilanjutkan & selesai!'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
      _autoSyncManifest();
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal melanjutkan: ${e.toString()}'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    } finally {
      if (wakelockOn) {
        try {
          await WakelockPlus.disable();
        } catch (_) {}
      }
      if (fgStarted) {
        try {
          await ForegroundServiceManager.stop();
        } catch (_) {}
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
      _autoSyncManifest();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Layar lebar (desktop): tombol unggah pindah ke AppBar, FAB disembunyikan,
    // konten dibatasi lebarnya agar tidak melebar penuh.
    final wide = isWideScreen(context);
    final scaffold = Scaffold(
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
                      _autoSyncManifest(newPin);
                    },
                    onDatabaseRestored: _loadFiles,
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
                          _autoSyncManifest(newPin);
                        },
                        onDatabaseRestored: _loadFiles,
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
            // Banner pulihkan saat daftar kosong (first-run)
            if (_files.isEmpty && !_isLoading && widget.telegramService.isConfigured)
              GestureDetector(
                onTap: _restoreFromTelegramDialog,
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.primary),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.cloud_download_rounded, color: AppTheme.primary),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Baru install ulang? Pulihkan index dari Telegram',
                          style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: AppTheme.primary, size: 20),
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
                                onResume: () => _resumePath(file),
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

    // Drag & drop file hanya di desktop: seluruh jendela jadi zona drop.
    // Di mobile tidak berubah (tetap pakai file picker).
    if (!isDesktop) return scaffold;
    return DropTarget(
      onDragEntered: (_) {
        if (mounted) setState(() => _dragging = true);
      },
      onDragExited: (_) {
        if (mounted) setState(() => _dragging = false);
      },
      onDragDone: (details) {
        if (mounted) setState(() => _dragging = false);
        final paths = details.files
            .map((f) => f.path)
            .where((path) => path.isNotEmpty)
            .toList();
        if (paths.isNotEmpty) _dropAndUpload(paths);
      },
      child: Stack(
        children: [
          scaffold,
          if (_dragging) _buildDropOverlay(),
        ],
      ),
    );
  }

  /// Overlay saat file sedang di-drag ke atas jendela (desktop).
  Widget _buildDropOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        padding: const EdgeInsets.all(28),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.primary, width: 2),
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_upload_rounded,
                    color: AppTheme.primary, size: 64),
                SizedBox(height: 16),
                Text(
                  'Letakkan file di sini',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'File akan langsung diunggah ke TGCloud',
                  style:
                      TextStyle(color: AppTheme.textMuted, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
