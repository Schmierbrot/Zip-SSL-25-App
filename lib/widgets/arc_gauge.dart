import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Bogen-Tacho: 240°-Bogen mit dünner grauer Spur und rotem Fortschritt
/// (runde Enden, leichter Verlauf von dunklem zu hellem Rot). In der Mitte
/// die Geschwindigkeit, weich animiert, damit 5-Hz-Updates nicht springen.
class ArcGauge extends StatelessWidget {
  const ArcGauge({super.key, required this.speedKmh, required this.maxKmh, this.unit = 'KM/H'});

  /// Geschwindigkeit oder `null` ohne GPS-Fix (Anzeige „–“, Bogen grau).
  final double? speedKmh;
  final int maxKmh;
  final String unit;

  static const double strokeWidth = 14;

  /// Höhe relativ zur Breite: Radius + unterer Teil des Bogens (sin 30° = 0,5).
  static double heightForWidth(double width) {
    final r = (width - strokeWidth) / 2;
    return r * 1.5 + strokeWidth;
  }

  @override
  Widget build(BuildContext context) {
    final active = speedKmh != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth;
        if (constraints.hasBoundedHeight) {
          // Breite so wählen, dass der Bogen in die verfügbare Höhe passt.
          final r = (constraints.maxHeight - strokeWidth) / 1.5;
          width = math.min(width, r * 2 + strokeWidth);
        }
        final height = heightForWidth(width);
        final radius = (width - strokeWidth) / 2;
        final numberSize = radius * 0.62;

        return SizedBox(
          width: width,
          height: height,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: active ? speedKmh!.clamp(0, 999).toDouble() : 0),
            duration: ZipMotion.slow,
            curve: ZipMotion.curve,
            builder: (context, value, _) {
              return CustomPaint(
                painter: ArcGaugePainter(
                  fraction: maxKmh <= 0 ? 0 : (value / maxKmh).clamp(0.0, 1.0),
                  active: active,
                  strokeWidth: strokeWidth,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: EdgeInsets.only(top: strokeWidth / 2 + radius - numberSize * 0.62),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          active ? value.round().toString() : '–',
                          style: ZipText.number(
                            numberSize,
                            weight: FontWeight.w200,
                            color: active ? ZipColors.textPrimary : ZipColors.textSecondary,
                          ),
                        ),
                        SizedBox(height: numberSize * 0.08),
                        Text(unit, style: ZipText.label.copyWith(letterSpacing: 2)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class ArcGaugePainter extends CustomPainter {
  ArcGaugePainter({
    required this.fraction,
    required this.active,
    this.strokeWidth = ArcGauge.strokeWidth,
  });

  final double fraction;
  final bool active;
  final double strokeWidth;

  /// Start bei 150° (unten links), 240° im Uhrzeigersinn bis 30° (unten rechts).
  static const double startAngle = 150 * math.pi / 180;
  static const double sweepAngle = 240 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = (size.width - strokeWidth) / 2;
    final center = Offset(size.width / 2, strokeWidth / 2 + radius);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = ZipColors.elevated;
    canvas.drawArc(rect, startAngle, sweepAngle, false, track);

    if (fraction <= 0.002) return;
    final sweep = sweepAngle * fraction;
    // Die runden Enden ragen um halbe Strichstärke über den Winkel hinaus –
    // den Verlauf entsprechend früher beginnen und später enden lassen.
    final cap = (strokeWidth / 2) / radius;
    final colors = active
        ? const [ZipColors.accentDark, ZipColors.accent]
        : const [ZipColors.textTertiary, ZipColors.textTertiary];
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: sweep + 2 * cap,
      colors: colors,
      transform: GradientRotation(startAngle - cap),
    ).createShader(rect);

    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..shader = shader;
    canvas.drawArc(rect, startAngle, sweep, false, progress);
  }

  @override
  bool shouldRepaint(ArcGaugePainter old) =>
      old.fraction != fraction || old.active != active || old.strokeWidth != strokeWidth;
}
