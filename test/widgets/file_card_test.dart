import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tgcloud/models/cloud_file.dart';
import 'package:tgcloud/widgets/file_card.dart';

void main() {
  testWidgets('FileCard renders file name, formatted size, and buttons', (tester) async {
    final file = CloudFile(
      id: 1,
      nama: 'video_liburan.mp4',
      ukuranBytes: 52428800, // 50MB
      mime: 'video/mp4',
      sha256Original: 'hash',
      isEncrypted: 1,
      salt: 'salt',
      jumlahChunk: 4,
      dibuatPada: '2026-10-14T10:00:00Z',
      status: 'complete',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileCard(
          file: file,
          onDownload: () {},
          onDelete: () {},
        ),
      ),
    ));

    expect(find.text('video_liburan.mp4'), findsOneWidget);
    expect(find.textContaining('50.0 MB'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
  });
}
