import '../core/format.dart';
import 'models.dart';

/// Erzeugt eine GPX-1.1-Datei aus einer Fahrt. Geschwindigkeit und
/// Zylinderkopftemperatur stehen als Erweiterung im eigenen Namensraum
/// (GPX 1.1 kennt dafür keine Standardfelder).
String buildGpx(TripSummary summary, List<TripPoint> points) {
  final start = DateTime.fromMillisecondsSinceEpoch(summary.key.startUnix * 1000, isUtc: true);
  final local = start.toLocal();
  final name = 'Zip-Fahrt ${formatDateLong(local)}, ${formatClock(local)}';
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="Zip App"'
      ' xmlns="http://www.topografix.com/GPX/1/1"'
      ' xmlns:zip="urn:zip-ssl-25:trip:1"'
      ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
      ' xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">',
    )
    ..writeln('  <metadata>')
    ..writeln('    <name>${_escape(name)}</name>')
    ..writeln('    <time>${_iso(start)}</time>')
    ..writeln('  </metadata>')
    ..writeln('  <trk>')
    ..writeln('    <name>${_escape(name)}</name>')
    ..writeln('    <type>scooter</type>')
    ..writeln('    <trkseg>');
  for (final p in points) {
    if (!p.hasPosition) continue;
    final time = start.add(Duration(milliseconds: p.timeMs));
    b
      ..writeln('      <trkpt lat="${p.lat.toStringAsFixed(7)}" lon="${p.lon.toStringAsFixed(7)}">')
      ..writeln('        <time>${_iso(time)}</time>')
      ..writeln('        <extensions>')
      ..writeln('          <zip:speed_kmh>${p.speedKmh.toStringAsFixed(1)}</zip:speed_kmh>');
    final t = p.tempC;
    if (t != null) b.writeln('          <zip:cht_c>${t.toStringAsFixed(1)}</zip:cht_c>');
    b
      ..writeln('        </extensions>')
      ..writeln('      </trkpt>');
  }
  b
    ..writeln('    </trkseg>')
    ..writeln('  </trk>')
    ..writeln('</gpx>');
  return b.toString();
}

/// Dateiname wie `zip-fahrt-2026-09-27-1432.gpx`.
String gpxFileName(TripSummary summary) {
  final l = summary.startLocal;
  String two(int v) => v.toString().padLeft(2, '0');
  return 'zip-fahrt-${l.year}-${two(l.month)}-${two(l.day)}-${two(l.hour)}${two(l.minute)}.gpx';
}

String _iso(DateTime utc) {
  final s = utc.toUtc().toIso8601String();
  // Millisekunden weglassen: 2026-09-27T12:32:05Z
  final dot = s.indexOf('.');
  return dot > 0 ? '${s.substring(0, dot)}Z' : s;
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
