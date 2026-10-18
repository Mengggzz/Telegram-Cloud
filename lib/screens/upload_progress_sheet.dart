import 'package:flutter/material.dart';
import 'package:tgcloud/theme/app_theme.dart';
import 'package:tgcloud/widgets/adaptive.dart';

class UploadProgressSheet extends StatefulWidget {
  final String filename;
  final double progress;
  final String statusText;
  final List<String>? logs;
  final VoidCallback onCancel;

  const UploadProgressSheet({
    super.key,
    required this.filename,
    required this.progress,
    required this.statusText,
    this.logs,
    required this.onCancel,
  });

  /// Tampilkan progres upload: bottom sheet di layar sempit (mobile),
  /// dialog terpusat di layar lebar (desktop).
  static Future<T?> show<T>({
    required BuildContext context,
    required Widget Function(BuildContext context, StateSetter setModalState) builder,
  }) {
    if (isWideScreen(context)) {
      return showDialog<T>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: StatefulBuilder(builder: builder),
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet<T>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: builder),
    );
  }

  @override
  State<UploadProgressSheet> createState() => _UploadProgressSheetState();
}

class _UploadProgressSheetState extends State<UploadProgressSheet> {
  final ScrollController _scrollController = ScrollController();
  bool _showLogs = true;

  @override
  void didUpdateWidget(UploadProgressSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.logs != null &&
        widget.logs!.length != (oldWidget.logs?.length ?? 0)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasLogs = widget.logs != null && widget.logs!.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_upload_rounded, color: AppTheme.primary, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.filename,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: widget.progress.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppTheme.surfaceLight,
              valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  widget.statusText,
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(widget.progress * 100).toInt()}%',
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          if (hasLogs) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Log Aktivitas',
                  style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _showLogs = !_showLogs),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _showLogs ? 'Sembunyikan' : 'Tampilkan',
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 11,
                          ),
                        ),
                        Icon(
                          _showLogs ? Icons.expand_less : Icons.expand_more,
                          color: AppTheme.primary,
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_showLogs) ...[
              const SizedBox(height: 6),
              Container(
                height: 115,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF141414),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: widget.logs!.length,
                  itemBuilder: (context, index) {
                    final log = widget.logs![index];
                    final isHighlight = log.contains('SHA-256') ||
                        log.contains('selesai') ||
                        log.contains('100%');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: SelectableText(
                        log,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: isHighlight
                              ? AppTheme.primaryLight
                              : const Color(0xFFB0BEC5),
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.danger,
                side: const BorderSide(color: AppTheme.danger),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: widget.onCancel,
              child: const Text('Batalkan Unggahan'),
            ),
          ),
        ],
      ),
    );
  }
}
