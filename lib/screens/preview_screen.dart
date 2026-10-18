import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/services/database_service.dart';
import 'package:tgcloud/services/download_service.dart';
import 'package:tgcloud/theme/app_theme.dart';
import 'package:video_player/video_player.dart';

class PreviewScreen extends StatefulWidget {
  final CloudFile file;
  final String userPin;
  final DatabaseService databaseService;
  final DownloadService downloadService;

  const PreviewScreen({
    super.key,
    required this.file,
    required this.userPin,
    required this.databaseService,
    required this.downloadService,
  });

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  bool _isLoading = true;
  double _progress = 0.0;
  String _statusText = 'Mengunduh untuk pratinjau...';
  String? _errorMessage;
  File? _downloadedFile;
  final CancelToken _cancelToken = CancelToken();

  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _startDownloadAndPreview();
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    _chewieController?.dispose();
    _videoPlayerController?.dispose();
    super.dispose();
  }

  Future<void> _startDownloadAndPreview() async {
    try {
      final tempBase = await getTemporaryDirectory();
      final previewDir = Directory(p.join(tempBase.path, 'tgcloud_preview'));
      if (!await previewDir.exists()) {
        await previewDir.create(recursive: true);
      }

      final targetPath = p.join(previewDir.path, widget.file.nama);
      final existingFile = File(targetPath);
      File resultFile;

      // Jika file sudah ada di cache pratinjau dan ukurannya sesuai, gunakan langsung
      if (await existingFile.exists() && await existingFile.length() == widget.file.ukuranBytes) {
        resultFile = existingFile;
      } else {
        resultFile = await widget.downloadService.downloadAndReassemble(
          widget.file.id!,
          widget.userPin,
          previewDir.path,
          cancelToken: _cancelToken,
          onProgress: (prog, status) {
            if (mounted) {
              setState(() {
                _progress = prog;
                _statusText = status;
              });
            }
          },
        );
      }

      if (!mounted) return;

      if (widget.file.mime.startsWith('video/')) {
        _videoPlayerController = VideoPlayerController.file(resultFile);
        await _videoPlayerController!.initialize();
        _chewieController = ChewieController(
          videoPlayerController: _videoPlayerController!,
          autoPlay: true,
          looping: false,
          allowFullScreen: true,
          aspectRatio: _videoPlayerController!.value.aspectRatio > 0
              ? _videoPlayerController!.value.aspectRatio
              : 16 / 9,
          errorBuilder: (context, errorMessage) {
            return Center(
              child: Text(
                'Gagal memutar video: $errorMessage',
                style: const TextStyle(color: AppTheme.danger),
              ),
            );
          },
        );
      }

      setState(() {
        _downloadedFile = resultFile;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.8),
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.file.nama,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Center(
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.primary),
            const SizedBox(height: 20),
            Text(
              _statusText,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress.clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: AppTheme.surfaceLight,
                valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${(_progress * 100).toInt()}%',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: AppTheme.danger, size: 48),
            const SizedBox(height: 16),
            Text(
              'Gagal memuat pratinjau:\n$_errorMessage',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: () => Navigator.pop(context),
              child: const Text('Tutup', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      );
    }

    if (_downloadedFile == null) {
      return const SizedBox();
    }

    if (widget.file.mime.startsWith('image/')) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 4.0,
        child: Image.file(
          _downloadedFile!,
          fit: BoxFit.contain,
        ),
      );
    }

    if (widget.file.mime.startsWith('video/') && _chewieController != null) {
      return Chewie(controller: _chewieController!);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file_rounded, color: AppTheme.primary, size: 64),
        const SizedBox(height: 16),
        Text(
          widget.file.nama,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Pratinjau langsung tidak tersedia untuk format ${widget.file.mime}.',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 14),
        ),
      ],
    );
  }
}
