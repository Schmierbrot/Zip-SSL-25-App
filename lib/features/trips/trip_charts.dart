import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models.dart';

/// Für die Diagramme ausgedünnte Messreihe über die Zeit (x in Minuten).
class TripSeries {
  TripSeries._(this.pointIndex, this.speed, this.temp, this.maxX);

  /// Diagramm-Index → Index in der vollständigen Punktliste.
  final List<int> pointIndex;
  final List<FlSpot> speed;

  /// Temperatur; ungültige Werte als [FlSpot.nullSpot] (Lücke in der Linie).
  final List<FlSpot> temp;
  final double maxX;

  bool get hasTemperature => temp.any((s) => !s.isNull());

  static TripSeries from(List<TripPoint> points, {int maxSamples = 360}) {
    if (points.isEmpty) return TripSeries._(const [], const [], const [], 1);
    final step = math.max(1, (points.length / maxSamples).ceil());
    final indices = <int>[for (var i = 0; i < points.length; i += step) i];
    if (indices.last != points.length - 1) indices.add(points.length - 1);
    final t0 = points.first.timeMs;
    double x(TripPoint p) => (p.timeMs - t0) / 60000.0;

    final speed = <FlSpot>[];
    final temp = <FlSpot>[];
    for (final i in indices) {
      final p = points[i];
      speed.add(FlSpot(x(p), p.speedKmh));
      final t = p.tempC;
      temp.add(t == null ? FlSpot.nullSpot : FlSpot(x(p), t));
    }
    return TripSeries._(indices, speed, temp, math.max(x(points.last), 0.1));
  }
}

/// Liniendiagramm mit roter Linie und dezenten Achsen. Meldet den
/// berührten Punkt (Index in [spots]) oder `null`, wenn losgelassen.
class TripLineChart extends StatelessWidget {
  const TripLineChart({
    super.key,
    required this.title,
    required this.unit,
    required this.spots,
    required this.maxX,
    required this.onTouch,
    this.minY,
    this.decimals = 0,
  });

  final String title;
  final String unit;
  final List<FlSpot> spots;
  final double maxX;
  final ValueChanged<int?> onTouch;
  final double? minY;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final values = spots.where((s) => !s.isNull()).map((s) => s.y);
    final dataMax = values.isEmpty ? 1.0 : values.reduce(math.max);
    final dataMin = values.isEmpty ? 0.0 : values.reduce(math.min);
    // Erst den Schritt bestimmen, dann die Untergrenze auf dieses Raster legen –
    // sonst überlappen die unteren Achsenbeschriftungen.
    final yInterval = _niceInterval(math.max(dataMax - (minY ?? dataMin), 1), 4);
    final lower = minY ?? (dataMin / yInterval).floor() * yInterval;
    final upper = (dataMax / yInterval).ceil() * yInterval;
    final xInterval = _niceInterval(maxX, 3);
    final labelStyle = ZipText.inter(size: 11, color: ZipColors.textSecondary, tabular: true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: ZipSpacing.xxs, bottom: ZipSpacing.s),
          child: Text(title.toUpperCase(), style: ZipText.label),
        ),
        Container(
          height: 190,
          padding: const EdgeInsets.fromLTRB(
            ZipSpacing.xs,
            ZipSpacing.m,
            ZipSpacing.m,
            ZipSpacing.xs,
          ),
          decoration: const BoxDecoration(color: ZipColors.card, borderRadius: ZipRadii.cardRadius),
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: maxX,
              minY: lower,
              maxY: math.max(upper, lower + yInterval),
              clipData: const FlClipData.all(),
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: yInterval,
                getDrawingHorizontalLine: (_) =>
                    const FlLine(color: ZipColors.separator, strokeWidth: 0.5),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    interval: yInterval,
                    getTitlesWidget: (value, meta) => SideTitleWidget(
                      meta: meta,
                      child: Text(value.round().toString(), style: labelStyle),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 24,
                    interval: xInterval,
                    getTitlesWidget: (value, meta) {
                      // Letzte Beschriftung weglassen, wenn sie zu nah am Rand klebt.
                      if (value > 0 && value >= maxX - xInterval * 0.3 && value != meta.max) {
                        return const SizedBox.shrink();
                      }
                      return SideTitleWidget(
                        meta: meta,
                        fitInside: SideTitleFitInsideData.fromTitleMeta(meta, distanceFromEdge: 0),
                        child: Text('${value.round()} min', style: labelStyle),
                      );
                    },
                  ),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  color: ZipColors.accent,
                  barWidth: 2,
                  isCurved: false,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        ZipColors.accent.withValues(alpha: 0.22),
                        ZipColors.accent.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ],
              lineTouchData: LineTouchData(
                handleBuiltInTouches: true,
                touchCallback: (event, response) {
                  final touched = response?.lineBarSpots;
                  if (!event.isInterestedForInteractions || touched == null || touched.isEmpty) {
                    onTouch(null);
                  } else {
                    onTouch(touched.first.spotIndex);
                  }
                },
                getTouchedSpotIndicator: (bar, indexes) => [
                  for (final _ in indexes)
                    TouchedSpotIndicatorData(
                      const FlLine(color: ZipColors.textTertiary, strokeWidth: 1),
                      FlDotData(
                        getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                          radius: 4.5,
                          color: ZipColors.accent,
                          strokeWidth: 2,
                          strokeColor: ZipColors.textPrimary,
                        ),
                      ),
                    ),
                ],
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => ZipColors.elevated,
                  tooltipBorderRadius: const BorderRadius.all(Radius.circular(10)),
                  fitInsideHorizontally: true,
                  fitInsideVertically: true,
                  getTooltipItems: (touched) => [
                    for (final s in touched)
                      LineTooltipItem(
                        '${s.y.toStringAsFixed(decimals).replaceAll('.', ',')} $unit\n',
                        ZipText.inter(size: 14, weight: FontWeight.w600, tabular: true),
                        children: [
                          TextSpan(
                            text: _formatMinutes(s.x),
                            style: ZipText.inter(
                              size: 12,
                              color: ZipColors.textSecondary,
                              tabular: true,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            duration: Duration.zero,
          ),
        ),
      ],
    );
  }

  static String _formatMinutes(double minutes) {
    final totalS = (minutes * 60).round();
    final m = totalS ~/ 60;
    final s = (totalS % 60).toString().padLeft(2, '0');
    return '$m:$s min';
  }

  /// „Runde“ Achsenschritte (1, 2, 5, 10, 20, 50 …).
  static double _niceInterval(double range, int ticks) {
    if (range <= 0) return 1;
    final raw = range / ticks;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final norm = raw / mag;
    final nice = norm < 1.5
        ? 1
        : norm < 3
        ? 2
        : norm < 7
        ? 5
        : 10;
    return nice * mag;
  }
}
