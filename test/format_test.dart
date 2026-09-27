import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zip_app/core/format.dart';
import 'package:zip_app/data/gpx_export.dart';
import 'package:zip_app/data/models.dart';

void main() {
  group('Zahlen', () {
    test('Tausenderpunkt und Dezimalkomma', () {
      expect(formatNumber(1284.6, decimals: 1), '1.284,6');
      expect(formatNumber(0), '0');
      expect(formatNumber(999), '999');
      expect(formatNumber(1000), '1.000');
      expect(formatNumber(1234567.89, decimals: 2), '1.234.567,89');
      expect(formatNumber(-12.345, decimals: 1), '-12,3');
      expect(formatNumber(-0.01, decimals: 1), '0,0', reason: 'kein „-0,0“');
    });

    test('Kilometer, Dauer, Speicher', () {
      expect(formatKm(1284600), '1.284,6 km');
      expect(formatKm(3400), '3,4 km');
      expect(formatDuration(45), '45 s');
      expect(formatDuration(32 * 60 + 10), '32 min');
      expect(formatDuration(3600 + 4 * 60), '1 h 04 min');
      expect(formatStorageMb(850), '850 MB');
      expect(formatStorageMb(29812), '29,1 GB');
    });

    test('Datum und Uhrzeit auf Deutsch', () {
      final d = DateTime(2026, 9, 26, 7, 5);
      expect(formatClock(d), '07:05');
      expect(formatDateShort(d), 'Sa. 26. Sept.');
      expect(formatDateLong(d), 'Samstag, 26. September 2026');
      expect(formatMonthYear(d), 'September 2026');
    });

    test('Eingabe in deutscher und englischer Schreibweise', () {
      expect(parseLocalizedNumber('1.284,6'), 1284.6);
      expect(parseLocalizedNumber('1284,6'), 1284.6);
      expect(parseLocalizedNumber('1284.6'), 1284.6);
      expect(parseLocalizedNumber('1.284'), 1284);
      expect(parseLocalizedNumber('12.5'), 12.5);
      expect(parseLocalizedNumber(' 42 '), 42);
      expect(parseLocalizedNumber('1.234.567'), 1234567);
      expect(parseLocalizedNumber(''), isNull);
      expect(parseLocalizedNumber('abc'), isNull);
      expect(parseLocalizedNumber('-5'), isNull);
      expect(parseLocalizedNumber('1,2,3'), isNull);
    });
  });

  group('GPX', () {
    test('enthält Trackpunkte, Zeiten und Erweiterungen; ohne Punkte ohne Fix', () {
      final summary = TripSummary(
        localId: 1,
        key: const TripKey(5, 1790000000),
        durationS: 2,
        distanceM: 10,
        maxSpeedKmh: 30,
        maxTempC: 200,
        avgMovingSpeedKmh: 20,
        pointCount: 3,
        fileSize: 80,
        preview: Float32List(0),
      );
      const points = [
        TripPoint(latE7: 0, lonE7: 0, timeMs: 0, speedDeciKmh: 0, tempDeciC: 0),
        TripPoint(
          latE7: 513155000,
          lonE7: 94876000,
          timeMs: 1000,
          speedDeciKmh: 253,
          tempDeciC: 1874,
        ),
        TripPoint(
          latE7: 513156000,
          lonE7: 94877000,
          timeMs: 2500,
          speedDeciKmh: 300,
          tempDeciC: kInvalidTemperature,
        ),
      ];
      final gpx = buildGpx(summary, points);
      expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(gpx, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
      expect('<trkpt'.allMatches(gpx), hasLength(2));
      expect(gpx, contains('<trkpt lat="51.3155000" lon="9.4876000">'));
      expect(gpx, contains('<time>2026-09-21T14:13:21Z</time>'));
      expect(gpx, contains('<time>2026-09-21T14:13:22Z</time>'));
      expect(gpx, contains('<zip:speed_kmh>25.3</zip:speed_kmh>'));
      expect(gpx, contains('<zip:cht_c>187.4</zip:cht_c>'));
      expect('<zip:cht_c>'.allMatches(gpx), hasLength(1));
      expect(gpx.trim(), endsWith('</gpx>'));
      expect(gpxFileName(summary), matches(RegExp(r'^zip-fahrt-2026-09-2\d-\d{4}\.gpx$')));
    });
  });
}
