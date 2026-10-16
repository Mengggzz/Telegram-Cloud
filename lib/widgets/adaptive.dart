import 'package:flutter/material.dart';

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
