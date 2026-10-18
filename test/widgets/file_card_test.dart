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

  testWidgets('FileCard renders resume button when status is uploading', (tester) async {
    bool resumePressed = false;
    final file = CloudFile(
      id: 2,
      nama: 'incomplete.mp4',
      ukuranBytes: 10485760,
      mime: 'video/mp4',
      sha256Original: 'hash2',
      isEncrypted: 1,
      salt: 'salt2',
      jumlahChunk: 2,
      dibuatPada: '2026-10-18T10:00:00Z',
      status: 'uploading',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileCard(
          file: file,
          onDownload: () {},
          onDelete: () {},
          onResume: () => resumePressed = true,
        ),
      ),
    ));

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    expect(resumePressed, isTrue);
  });

  testWidgets('FileCard renders preview button when onPreview provided for media', (tester) async {
    bool previewPressed = false;
    final file = CloudFile(
      id: 3,
      nama: 'photo.jpg',
      ukuranBytes: 1024,
      mime: 'image/jpeg',
      sha256Original: 'hash3',
      salt: 'salt3',
      jumlahChunk: 1,
      dibuatPada: '2026-10-18T10:00:00Z',
      status: 'complete',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileCard(
          file: file,
          onDownload: () {},
          onDelete: () {},
          onPreview: () => previewPressed = true,
        ),
      ),
    ));

    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    expect(previewPressed, isTrue);
  });
}
