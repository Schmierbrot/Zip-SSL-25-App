import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../core/theme.dart';

/// Mini-Vorschau der Streckenform (ohne Kartenhintergrund).
class RoutePreview extends StatelessWidget {
  const RoutePreview({super.key, required this.points, this.size = const Size(84, 64)});

  /// Normierte Punkte (x/y abwechselnd, 0..1).
  final Float32List points;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.fromSize(
      size: size,
      child: CustomPaint(painter: RoutePreviewPainter(points)),
    );
  }
}

class RoutePreviewPainter extends CustomPainter {
  RoutePreviewPainter(this.points);

  final Float32List points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 4) {
      // Keine GPS-Daten: dezente gestrichelte Linie.
      final paint = Paint()
        ..color = ZipColors.textTertiary
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      final y = size.height / 2;
      for (var x = size.width * 0.2; x < size.width * 0.8; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(x + 3, y), paint);
      }
      return;
    }
    const pad = 6.0;
    final side = (size.shortestSide - pad * 2).clamp(1.0, double.infinity);
    final dx = (size.width - side) / 2;
    final dy = (size.height - side) / 2;
    Offset at(int i) => Offset(dx + points[i * 2] * side, dy + points[i * 2 + 1] * side);

    final n = points.length ~/ 2;
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < n; i++) {
      final p = at(i);
      path.lineTo(p.dx, p.dy);
    }
    final bounds = Rect.fromLTWH(dx, dy, side, side);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = const LinearGradient(colors: [ZipColors.accentDark, ZipColors.accent])
          .createShader(bounds);
    canvas.drawPath(path, line);

    canvas.drawCircle(at(0), 2.6, Paint()..color = ZipColors.textSecondary);
    canvas.drawCircle(at(n - 1), 3, Paint()..color = ZipColors.accent);
  }

  @override
  bool shouldRepaint(RoutePreviewPainter old) => !identical(old.points, points);
}
