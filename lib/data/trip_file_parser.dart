import 'dart:math' as math;
import 'dart:typed_data';

import '../ble/zip_protocol.dart';
import 'models.dart';

/// Fehler beim Lesen einer Fahrtdatei.
class TripFileFormatException implements Exception {
  const TripFileFormatException(this.message);

  final String message;

  @override
  String toString() => 'TripFileFormatException: $message';
}

/// Parser für das Fahrtdatei-Format:
///
/// Header (32 Bytes): 0-3 "ZIPT", 4 Formatversion, 8-11 tripId, 12-15 Startzeit.
/// Datensätze (16 Bytes): lat×1e7 i32, lon×1e7 i32, ms u32, Geschw. u16, Temp i16.
abstract final class TripFileParser {
  static TripFile parse(Uint8List bytes) {
    if (bytes.length < kTripFileHeaderLength) {
      throw TripFileFormatException(
        'Datei zu kurz (${bytes.length} Bytes, Header braucht $kTripFileHeaderLength)',
      );
    }
    for (var i = 0; i < kTripFileMagic.length; i++) {
      if (bytes[i] != kTripFileMagic[i]) {
        throw const TripFileFormatException('Kennung „ZIPT“ fehlt');
      }
    }
    final d = ByteData.sublistView(bytes);
    final version = d.getUint8(4);
    if (version != kTripFileFormatVersion) {
      throw TripFileFormatException('Formatversion $version wird nicht unterstützt');
    }
    final tripId = d.getUint32(8, Endian.little);
    final startUnix = d.getUint32(12, Endian.little);

    final payload = bytes.length - kTripFileHeaderLength;
    final count = payload ~/ kTripRecordLength;
    final points = List<TripPoint>.generate(count, (i) {
      final o = kTripFileHeaderLength + i * kTripRecordLength;
      return TripPoint(
        latE7: d.getInt32(o, Endian.little),
        lonE7: d.getInt32(o + 4, Endian.little),
        timeMs: d.getUint32(o + 8, Endian.little),
        speedDeciKmh: d.getUint16(o + 12, Endian.little),
        tempDeciC: d.getInt16(o + 14, Endian.little),
      );
    }, growable: false);

    return TripFile(
      formatVersion: version,
      tripId: tripId,
      startUnix: startUnix,
      points: points,
      trailingBytes: payload % kTripRecordLength,
    );
  }
}

/// Aus den Punkten berechnete Kennzahlen einer Fahrt.
class TripStats {
  const TripStats({
    required this.durationS,
    required this.distanceM,
    required this.maxSpeedKmh,
    required this.maxTempC,
    required this.avgMovingSpeedKmh,
  });

  final int durationS;
  final int distanceM;
  final double maxSpeedKmh;
  final double? maxTempC;

  /// Zeitgewichteter Durchschnitt nur über Abschnitte mit mehr als 2 km/h.
  final double? avgMovingSpeedKmh;

  /// Schwelle, ab der „gefahren“ wird.
  static const double movingThresholdKmh = 2.0;

  static TripStats fromPoints(List<TripPoint> points) {
    if (points.isEmpty) {
      return const TripStats(
        durationS: 0,
        distanceM: 0,
        maxSpeedKmh: 0,
        maxTempC: null,
        avgMovingSpeedKmh: null,
      );
    }
    var maxSpeed = 0.0;
    double? maxTemp;
    var distance = 0.0;
    var movingMs = 0;
    var movingWeighted = 0.0;
    TripPoint? lastPositioned;

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      maxSpeed = math.max(maxSpeed, p.speedKmh);
      final t = p.tempC;
      if (t != null) maxTemp = maxTemp == null ? t : math.max(maxTemp, t);

      if (i > 0) {
        final prev = points[i - 1];
        final dt = p.timeMs - prev.timeMs;
        if (dt > 0 && dt < 60000) {
          final v = (p.speedKmh + prev.speedKmh) / 2;
          if (v > movingThresholdKmh) {
            movingMs += dt;
            movingWeighted += v * dt;
          }
        }
      }
      if (p.hasPosition) {
        if (lastPositioned != null) {
          distance += haversineMeters(lastPositioned.lat, lastPositioned.lon, p.lat, p.lon);
        }
        lastPositioned = p;
      }
    }

    return TripStats(
      durationS: (points.last.timeMs - points.first.timeMs) ~/ 1000,
      distanceM: distance.round(),
      maxSpeedKmh: maxSpeed,
      maxTempC: maxTemp,
      avgMovingSpeedKmh: movingMs > 0 ? movingWeighted / movingMs : null,
    );
  }
}

/// Erzeugt eine normierte Streckenform (x/y abwechselnd, 0..1) für die
/// Mini-Vorschau. Das Seitenverhältnis bleibt erhalten, die Form wird zentriert.
Float32List buildRoutePreview(List<TripPoint> points, {int maxPoints = 64}) {
  final positioned = points.where((p) => p.hasPosition).toList(growable: false);
  if (positioned.length < 2) return Float32List(0);

  final step = math.max(1, (positioned.length / maxPoints).ceil());
  final sampled = <TripPoint>[for (var i = 0; i < positioned.length; i += step) positioned[i]];
  if (!identical(sampled.last, positioned.last)) sampled.add(positioned.last);

  // Einfache äquirektanguläre Projektion reicht für eine Vorschau.
  final lat0 = sampled.first.lat * math.pi / 180;
  final k = math.cos(lat0);
  final xs = sampled.map((p) => p.lon * k).toList();
  final ys = sampled.map((p) => -p.lat).toList();
  final minX = xs.reduce(math.min);
  final maxX = xs.reduce(math.max);
  final minY = ys.reduce(math.min);
  final maxY = ys.reduce(math.max);
  final span = math.max(maxX - minX, maxY - minY);
  if (span == 0) return Float32List(0);
  final offX = (span - (maxX - minX)) / 2;
  final offY = (span - (maxY - minY)) / 2;

  final out = Float32List(sampled.length * 2);
  for (var i = 0; i < sampled.length; i++) {
    out[i * 2] = ((xs[i] - minX + offX) / span);
    out[i * 2 + 1] = ((ys[i] - minY + offY) / span);
  }
  return out;
}
