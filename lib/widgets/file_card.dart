import 'package:flutter/material.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/theme/app_theme.dart';

class FileCard extends StatelessWidget {
  final CloudFile file;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback? onResume;

  const FileCard({
    super.key,
    required this.file,
    required this.onDownload,
    required this.onDelete,
    this.onResume,
  });

  String _formatSize(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  IconData _getIcon() {
    if (file.mime.startsWith('video/')) return Icons.movie_rounded;
    if (file.mime.startsWith('image/')) return Icons.image_rounded;
    if (file.mime.startsWith('audio/')) return Icons.audiotrack_rounded;
    if (file.mime.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (file.mime.contains('zip') || file.mime.contains('rar')) return Icons.folder_zip_rounded;
    return Icons.insert_drive_file_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_getIcon(), color: AppTheme.primary, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.nama,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${_formatSize(file.ukuranBytes)} • ${file.jumlahChunk} chunk',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                ),
              ],
            ),
          ),
          if (file.status != 'complete')
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded, color: AppTheme.primary),
              tooltip: 'Lanjutkan Upload',
              onPressed: onResume,
            )
          else
            IconButton(
              icon: const Icon(Icons.download_rounded, color: AppTheme.primary),
              onPressed: onDownload,
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: AppTheme.textMuted),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
