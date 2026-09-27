import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../data/gpx_export.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/stat_tile.dart';
import 'trip_charts.dart';
import 'trips_controller.dart';
import 'trips_screen.dart' show confirmTripDelete;

class TripDetailScreen extends ConsumerWidget {
  const TripDetailScreen({super.key, required this.tripId});

  final int tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(tripDetailProvider(tripId));
    return Scaffold(
      backgroundColor: ZipColors.background,
      body: switch (detail) {
        AsyncData(value: final d?) => _TripDetailBody(detail: d),
        AsyncData() => const _Centered(text: 'Diese Fahrt gibt es nicht mehr.'),
        AsyncError(:final error) => _Centered(text: 'Fahrt konnte nicht geladen werden:\n$error'),
        _ => const Center(child: CupertinoActivityIndicator()),
      },
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          const Positioned(left: ZipSpacing.s, top: ZipSpacing.xs, child: _BackButton()),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(ZipSpacing.l),
              child: Text(text, style: ZipText.bodySecondary, textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aufbereitete Daten für Karte und Diagramme (einmal pro Fahrt berechnet).
class _TripView {
  _TripView(this.detail)
    : series = TripSeries.from(detail.points),
      positioned = [
        for (var i = 0; i < detail.points.length; i++)
          if (detail.points[i].hasPosition) i,
      ] {
    route = _buildRoute();
  }

  final TripDetail detail;
  final TripSeries series;

  /// Indizes aller Punkte mit gültiger Position.
  final List<int> positioned;
  late final List<Polyline> route;

  List<TripPoint> get points => detail.points;
  bool get hasRoute => positioned.length >= 2;

  LatLng latLngOf(int pointIndex) {
    final p = points[pointIndex];
    return LatLng(p.lat, p.lon);
  }

  LatLngBounds get bounds => LatLngBounds.fromPoints([for (final i in positioned) latLngOf(i)]);

  /// Nächstgelegener Punkt mit Position (für Diagramm → Kartenmarker).
  LatLng? positionNear(int pointIndex) {
    if (positioned.isEmpty) return null;
    var lo = 0;
    var hi = positioned.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (positioned[mid] < pointIndex) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var best = positioned[lo];
    if (lo > 0 && (pointIndex - positioned[lo - 1]).abs() < (best - pointIndex).abs()) {
      best = positioned[lo - 1];
    }
    return latLngOf(best);
  }

  /// Route in Abschnitte gleicher Farbe zerlegen: langsam #8B1A15 → schnell #FF3B30.
  List<Polyline> _buildRoute() {
    if (!hasRoute) return const [];
    const buckets = 8;
    const maxRoutePoints = 1500;
    final step = math.max(1, (positioned.length / maxRoutePoints).ceil());
    final idx = <int>[for (var i = 0; i < positioned.length; i += step) positioned[i]];
    if (idx.last != positioned.last) idx.add(positioned.last);

    final maxSpeed = math.max(1.0, points.fold<double>(0, (m, p) => math.max(m, p.speedKmh)));
    // Leicht geglättete Geschwindigkeit, damit die Farbe nicht flackert.
    int bucketAt(int k) {
      var sum = 0.0;
      var n = 0;
      for (var j = math.max(0, k - 2); j <= math.min(idx.length - 1, k + 2); j++) {
        sum += points[idx[j]].speedKmh;
        n++;
      }
      final f = (sum / n / maxSpeed).clamp(0.0, 1.0);
      return (f * (buckets - 1)).round();
    }

    Color colorOf(int bucket) =>
        Color.lerp(ZipColors.accentDark, ZipColors.accent, bucket / (buckets - 1))!;

    final lines = <Polyline>[];
    var current = <LatLng>[latLngOf(idx.first)];
    var currentBucket = bucketAt(0);
    for (var k = 1; k < idx.length; k++) {
      final b = bucketAt(k);
      final pt = latLngOf(idx[k]);
      current.add(pt);
      if (b != currentBucket) {
        lines.add(Polyline(points: current, color: colorOf(currentBucket), strokeWidth: 4));
        current = [pt];
        currentBucket = b;
      }
    }
    if (current.length >= 2) {
      lines.add(Polyline(points: current, color: colorOf(currentBucket), strokeWidth: 4));
    }
    return lines;
  }
}

class _TripDetailBody extends ConsumerStatefulWidget {
  const _TripDetailBody({required this.detail});

  final TripDetail detail;

  @override
  ConsumerState<_TripDetailBody> createState() => _TripDetailBodyState();
}

class _TripDetailBodyState extends ConsumerState<_TripDetailBody> {
  late _TripView _view = _TripView(widget.detail);

  /// Im Diagramm berührter Punkt (Index in der vollständigen Punktliste).
  int? _selected;

  @override
  void didUpdateWidget(_TripDetailBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.detail, widget.detail)) _view = _TripView(widget.detail);
  }

  void _onChartTouch(int? chartIndex) {
    final next = chartIndex == null ? null : _view.series.pointIndex[chartIndex];
    if (next != _selected) setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.detail.summary;
    final local = summary.startLocal;
    final end = local.add(Duration(seconds: summary.durationS));
    final screen = MediaQuery.sizeOf(context);
    final topInset = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final limit = ref.watch(settingsProvider.select((s) => s.tempLimitC));

    return Column(
      children: [
        SizedBox(
          height: screen.height * 0.45,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _view.hasRoute
                  ? _TripMap(view: _view, selected: _selected, topInset: topInset)
                  : const ColoredBox(
                      color: ZipColors.card,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.location_slash,
                              color: ZipColors.textTertiary,
                              size: 36,
                            ),
                            SizedBox(height: ZipSpacing.xs),
                            Text('Keine GPS-Daten für diese Fahrt'),
                          ],
                        ),
                      ),
                    ),
              Positioned(
                left: ZipSpacing.s,
                top: topInset + ZipSpacing.xs,
                child: const _BackButton(),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              ZipSpacing.page,
              ZipSpacing.l,
              ZipSpacing.page,
              bottomInset + ZipSpacing.xl,
            ),
            physics: const BouncingScrollPhysics(),
            children: [
              Text(formatDateLong(local), style: ZipText.title),
              const SizedBox(height: ZipSpacing.xxs),
              Text('${formatClock(local)} – ${formatClock(end)} Uhr', style: ZipText.bodySecondary),
              const SizedBox(height: ZipSpacing.l),
              _StatsGrid(summary: summary, tempLimit: limit),
              const SizedBox(height: ZipSpacing.l),
              TripLineChart(
                title: 'Geschwindigkeit',
                unit: 'km/h',
                spots: _view.series.speed,
                maxX: _view.series.maxX,
                minY: 0,
                onTouch: _onChartTouch,
              ),
              if (_view.series.hasTemperature) ...[
                const SizedBox(height: ZipSpacing.l),
                TripLineChart(
                  title: 'Zylinderkopftemperatur',
                  unit: '°C',
                  spots: _view.series.temp,
                  maxX: _view.series.maxX,
                  onTouch: _onChartTouch,
                ),
              ],
              const SizedBox(height: ZipSpacing.xl),
              Builder(
                builder: (buttonContext) => ZipSecondaryButton(
                  label: 'Als GPX teilen',
                  icon: CupertinoIcons.share,
                  onPressed: _view.hasRoute ? () => unawaited(_shareGpx(buttonContext)) : null,
                ),
              ),
              const SizedBox(height: ZipSpacing.s),
              ZipSecondaryButton(
                label: 'Löschen',
                icon: CupertinoIcons.delete,
                destructive: true,
                onPressed: () => unawaited(_delete()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _shareGpx(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    final summary = widget.detail.summary;
    final name = gpxFileName(summary);
    final bytes = utf8.encode(buildGpx(summary, widget.detail.points));
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'application/gpx+xml', name: name)],
          fileNameOverrides: [name],
          subject: 'Zip-Fahrt vom ${formatDateLong(summary.startLocal)}',
          sharePositionOrigin: origin,
        ),
      );
    } catch (e) {
      showToast('Teilen fehlgeschlagen: $e', isError: true);
    }
  }

  Future<void> _delete() async {
    final summary = widget.detail.summary;
    final mode = await confirmTripDelete(context, ref, summary);
    if (mode == null || !mounted) return;
    unawaited(ref.read(tripSyncProvider.notifier).deleteTrip(summary, mode));
    Navigator.of(context).pop();
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.summary, required this.tempLimit});

  final TripSummary summary;
  final int tempLimit;

  @override
  Widget build(BuildContext context) {
    const size = 30.0;
    final avg = summary.avgMovingSpeedKmh;
    final maxTemp = summary.maxTempC;
    final tooHot = maxTemp != null && maxTemp > tempLimit;

    Widget row(Widget a, Widget b) => Padding(
      padding: const EdgeInsets.only(bottom: ZipSpacing.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: a),
          const SizedBox(width: ZipSpacing.s),
          Expanded(child: b),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          StatTile(
            label: 'Distanz',
            text: formatNumber(summary.distanceM / 1000, decimals: 1),
            unit: 'km',
            valueSize: size,
          ),
          StatTile(label: 'Dauer', text: formatDuration(summary.durationS), valueSize: size),
        ),
        row(
          StatTile(
            label: 'Ø Geschwindigkeit',
            text: avg == null ? '–' : avg.round().toString(),
            unit: 'km/h',
            valueSize: size,
          ),
          StatTile(
            label: 'Höchstgeschw.',
            text: summary.maxSpeedKmh.round().toString(),
            unit: 'km/h',
            valueSize: size,
          ),
        ),
        StatTile(
          label: 'Max. Zylinderkopf',
          text: maxTemp == null ? '–' : maxTemp.round().toString(),
          unit: '°C',
          valueSize: size,
          valueColor: tooHot ? ZipColors.accent : ZipColors.textPrimary,
          footnote: tooHot ? 'Über der Warngrenze von $tempLimit °C' : null,
          footnoteColor: ZipColors.accent,
        ),
      ],
    );
  }
}

class _TripMap extends StatelessWidget {
  const _TripMap({required this.view, required this.selected, required this.topInset});

  final _TripView view;
  final int? selected;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final first = view.latLngOf(view.positioned.first);
    final last = view.latLngOf(view.positioned.last);
    final marker = selected == null ? null : view.positionNear(selected!);

    return FlutterMap(
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: view.bounds,
          padding: EdgeInsets.fromLTRB(36, topInset + 56, 36, 44),
          maxZoom: 17,
        ),
        backgroundColor: const Color(0xFF0E0E0E),
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          // CARTO Dark Matter auf Basis von OpenStreetMap, ohne API-Key.
          urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
          subdomains: const ['a', 'b', 'c', 'd'],
          retinaMode: RetinaMode.isHighDensity(context),
          maxNativeZoom: 20,
          userAgentPackageName: 'de.schmierbrot.zip_app',
        ),
        PolylineLayer(polylines: view.route),
        CircleLayer(
          circles: [
            CircleMarker(
              point: first,
              radius: 5,
              color: ZipColors.textPrimary,
              borderColor: ZipColors.background,
              borderStrokeWidth: 2,
            ),
            CircleMarker(
              point: last,
              radius: 5,
              color: ZipColors.accent,
              borderColor: ZipColors.textPrimary,
              borderStrokeWidth: 2,
            ),
            if (marker != null)
              CircleMarker(
                point: marker,
                radius: 8,
                color: ZipColors.textPrimary,
                borderColor: ZipColors.accent,
                borderStrokeWidth: 3,
              ),
          ],
        ),
        // Pflichtangabe für OpenStreetMap-Daten und CARTO-Kacheln.
        Align(
          alignment: Alignment.bottomRight,
          child: Container(
            margin: const EdgeInsets.all(ZipSpacing.xs),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: const BoxDecoration(
              color: Color(0xB3000000),
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
            child: Text(
              '© OpenStreetMap-Mitwirkende © CARTO',
              style: ZipText.inter(size: 10, color: ZipColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Material(
          color: const Color(0x99000000),
          child: InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(CupertinoIcons.chevron_back, color: ZipColors.textPrimary, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}
