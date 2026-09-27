import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zip_app/ble/zip_protocol.dart';
import 'package:zip_app/data/models.dart';
import 'package:zip_app/data/trip_file_parser.dart';

/// Baut eine Fahrtdatei byteweise (unabhängig vom Encoder der App).
Uint8List buildFile({
  List<int> magic = const [0x5A, 0x49, 0x50, 0x54],
  int version = 1,
  int tripId = 17,
  int start = 1790000000,
  List<List<int>> records = const [],
  List<int> trailing = const [],
}) {
  final d = ByteData(32 + records.length * 16 + trailing.length);
  for (var i = 0; i < 4; i++) {
    d.setUint8(i, magic[i]);
  }
  d
    ..setUint8(4, version)
    ..setUint32(8, tripId, Endian.little)
    ..setUint32(12, start, Endian.little);
  var o = 32;
  for (final r in records) {
    d
      ..setInt32(o, r[0], Endian.little)
      ..setInt32(o + 4, r[1], Endian.little)
      ..setUint32(o + 8, r[2], Endian.little)
      ..setUint16(o + 12, r[3], Endian.little)
      ..setInt16(o + 14, r[4], Endian.little);
    o += 16;
  }
  for (final b in trailing) {
    d.setUint8(o++, b);
  }
  return d.buffer.asUint8List();
}

Matcher throwsTripFormat(String part) =>
    throwsA(isA<TripFileFormatException>().having((e) => e.message, 'message', contains(part)));

void main() {
  group('Header', () {
    test('gültiger Header ohne Datensätze', () {
      final f = TripFileParser.parse(buildFile());
      expect(f.formatVersion, 1);
      expect(f.tripId, 17);
      expect(f.startUnix, 1790000000);
      expect(f.startUtc, DateTime.utc(2026, 9, 21, 14, 13, 20));
      expect(f.points, isEmpty);
      expect(f.trailingBytes, 0);
    });

    test('zu kurze Datei', () {
      expect(() => TripFileParser.parse(Uint8List(0)), throwsTripFormat('zu kurz'));
      expect(() => TripFileParser.parse(Uint8List(31)), throwsTripFormat('zu kurz'));
    });

    test('falsche Kennung', () {
      expect(
        () => TripFileParser.parse(buildFile(magic: [0x5A, 0x49, 0x50, 0x00])),
        throwsTripFormat('ZIPT'),
      );
    });

    test('unbekannte Formatversion', () {
      expect(() => TripFileParser.parse(buildFile(version: 2)), throwsTripFormat('Formatversion'));
    });

    test('Randwerte im Header (uint32 maximal)', () {
      final f = TripFileParser.parse(buildFile(tripId: 0xFFFFFFFF, start: 0xFFFFFFFF));
      expect(f.tripId, 4294967295);
      expect(f.startUnix, 4294967295);
    });
  });

  group('Datensätze', () {
    test('Werte werden korrekt und Little Endian gelesen', () {
      final f = TripFileParser.parse(
        buildFile(
          records: [
            [513155000, 94876000, 0, 0, 312],
            [-338688000, -583816000, 1000, 523, -400],
            [900000000, 1800000000, 0xFFFFFFFF, 0xFFFF, kInvalidTemperature],
          ],
        ),
      );
      expect(f.points, hasLength(3));

      final a = f.points[0];
      expect(a.lat, closeTo(51.3155, 1e-9));
      expect(a.lon, closeTo(9.4876, 1e-9));
      expect(a.timeMs, 0);
      expect(a.speedKmh, 0);
      expect(a.tempC, closeTo(31.2, 1e-9));
      expect(a.hasPosition, isTrue);

      final b = f.points[1];
      expect(b.lat, closeTo(-33.8688, 1e-9));
      expect(b.lon, closeTo(-58.3816, 1e-9));
      expect(b.timeMs, 1000);
      expect(b.speedKmh, closeTo(52.3, 1e-9));
      expect(b.tempC, closeTo(-40.0, 1e-9));

      final c = f.points[2];
      expect(c.lat, 90);
      expect(c.lon, 180);
      expect(c.timeMs, 4294967295);
      expect(c.speedDeciKmh, 65535);
      expect(c.tempC, isNull, reason: '-32768 = ungültig');
      expect(c.hasPosition, isTrue);
    });

    test('0/0 und Werte außerhalb des Bereichs gelten als „keine Position“', () {
      final f = TripFileParser.parse(
        buildFile(
          records: [
            [0, 0, 0, 0, 0],
            [900000001, 0, 0, 0, 0],
            [0, -1800000001, 0, 0, 0],
            [0, 1, 0, 0, 0],
          ],
        ),
      );
      expect(f.points.map((p) => p.hasPosition), [false, false, false, true]);
    });

    test('unvollständiger letzter Datensatz wird ignoriert', () {
      final f = TripFileParser.parse(
        buildFile(
          records: [
            [1, 1, 0, 10, 10],
          ],
          trailing: [1, 2, 3, 4, 5],
        ),
      );
      expect(f.points, hasLength(1));
      expect(f.trailingBytes, 5);
    });

    test('Encoder der App erzeugt vom Parser lesbare Dateien', () {
      const points = [
        TripPoint(latE7: 1, lonE7: -2, timeMs: 3, speedDeciKmh: 4, tempDeciC: -5),
        TripPoint(latE7: 6, lonE7: 7, timeMs: 8, speedDeciKmh: 9, tempDeciC: kInvalidTemperature),
      ];
      final bytes = encodeTripFile(tripId: 99, startUnix: 1234, points: points);
      expect(bytes.length, 32 + 2 * 16);
      final f = TripFileParser.parse(bytes);
      expect(f.tripId, 99);
      expect(f.startUnix, 1234);
      expect(f.points.map((p) => [p.latE7, p.lonE7, p.timeMs, p.speedDeciKmh, p.tempDeciC]), [
        [1, -2, 3, 4, -5],
        [6, 7, 8, 9, kInvalidTemperature],
      ]);
    });
  });

  group('Kennzahlen', () {
    TripPoint p(int t, double kmh, {double lat = 51.0, double lon = 9.0, int? temp}) => TripPoint(
      latE7: (lat * 1e7).round(),
      lonE7: (lon * 1e7).round(),
      timeMs: t * 1000,
      speedDeciKmh: (kmh * 10).round(),
      tempDeciC: temp ?? 2000,
    );

    test('Ø-Geschwindigkeit nur über Fahrzeit über 2 km/h', () {
      final points = [
        p(0, 0),
        p(10, 0), // 10 s Stillstand
        p(20, 40),
        p(30, 40), // 10 s mit 40 km/h
        p(40, 0),
        p(100, 0), // 60 s Stillstand
      ];
      final stats = TripStats.fromPoints(points);
      expect(stats.durationS, 100);
      expect(stats.maxSpeedKmh, 40);
      // Abschnitte: 10→20 (Ø 20), 20→30 (40), 30→40 (20) → zeitgewichtet 26,67
      expect(stats.avgMovingSpeedKmh, closeTo(80 / 3, 1e-6));
    });

    test('ohne Bewegung gibt es keinen Durchschnitt', () {
      final stats = TripStats.fromPoints([p(0, 0), p(5, 1), p(10, 0)]);
      expect(stats.avgMovingSpeedKmh, isNull);
    });

    test('Distanz aus Positionen, ungültige Temperaturen ignoriert', () {
      final stats = TripStats.fromPoints([
        p(0, 30, lat: 51.0, temp: 1500),
        const TripPoint(
          latE7: 0,
          lonE7: 0,
          timeMs: 500,
          speedDeciKmh: 300,
          tempDeciC: kInvalidTemperature,
        ),
        p(1, 30, lat: 51.001, temp: 2480),
      ]);
      expect(stats.distanceM, closeTo(111, 1));
      expect(stats.maxTempC, closeTo(248, 1e-9));
    });

    test('leere Fahrt', () {
      final stats = TripStats.fromPoints(const []);
      expect(stats.durationS, 0);
      expect(stats.distanceM, 0);
      expect(stats.maxTempC, isNull);
    });
  });

  group('Routen-Vorschau', () {
    test('normiert auf 0..1 und behält das Seitenverhältnis', () {
      final points = [
        for (var i = 0; i <= 10; i++)
          TripPoint(
            latE7: 510000000,
            lonE7: 90000000 + i * 10000,
            timeMs: i * 1000,
            speedDeciKmh: 0,
            tempDeciC: 0,
          ),
      ];
      final preview = buildRoutePreview(points);
      expect(preview.length, 22);
      for (var i = 0; i < preview.length; i += 2) {
        expect(preview[i], inInclusiveRange(0, 1));
        expect(preview[i + 1], closeTo(0.5, 1e-6), reason: 'waagerechte Strecke mittig');
      }
      expect(preview.first, closeTo(0, 1e-6));
      expect(preview[preview.length - 2], closeTo(1, 1e-6));
    });

    test('ohne Positionen leer, lange Fahrten werden ausgedünnt', () {
      expect(
        buildRoutePreview(const [
          TripPoint(latE7: 0, lonE7: 0, timeMs: 0, speedDeciKmh: 0, tempDeciC: 0),
        ]),
        isEmpty,
      );
      final many = [
        for (var i = 0; i < 5000; i++)
          TripPoint(
            latE7: 510000000 + i * 10,
            lonE7: 90000000 + (i % 50) * 100,
            timeMs: i,
            speedDeciKmh: 0,
            tempDeciC: 0,
          ),
      ];
      expect(buildRoutePreview(many).length ~/ 2, lessThanOrEqualTo(65));
    });
  });
}
