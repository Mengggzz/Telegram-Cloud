import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// true di Windows/macOS/Linux asli (bukan web, bukan mobile).
/// Dipakai untuk fitur khusus desktop seperti drag & drop file.
bool get isDesktop {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

/// Lebar minimum yang dianggap "layar lebar" (desktop / tablet landscape).
const double kWideBreakpoint = 720.0;

bool isWideScreen(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kWideBreakpoint;

/// Membatasi lebar konten di layar lebar agar tidak melebar penuh,
/// sekaligus menengahkan. Di layar sempit (mobile), child tampil apa adanya.
class CenteredConstrained extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const CenteredConstrained({
    super.key,
    required this.child,
    this.maxWidth = 720.0,
  });

  @override
  Widget build(BuildContext context) {
    if (!isWideScreen(context)) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
