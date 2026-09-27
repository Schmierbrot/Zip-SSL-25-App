import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zip_app/ble/zip_protocol.dart';
import 'package:zip_app/data/models.dart';

/// Baut ein Telemetrie-Paket byteweise (unabhängig vom Encoder der App).
Uint8List telemetryBytes({
  int version = 1,
  int flags = 0,
  int speed = 0,
  int temp = 0,
  int odometer = 0,
  int trip = 0,
  int sats = 0,
  int lights = 0,
}) {
  final d = ByteData(16)
    ..setUint8(0, version)
    ..setUint8(1, flags)
    ..setUint16(2, speed, Endian.little)
    ..setInt16(4, temp, Endian.little)
    ..setUint32(6, odometer, Endian.little)
    ..setUint32(10, trip, Endian.little)
    ..setUint8(14, sats)
    ..setUint8(15, lights);
  return d.buffer.asUint8List();
}

Matcher throwsFormat() => throwsA(isA<ZipFormatException>());

void main() {
  group('Telemetrie', () {
    test('korrektes Paket wird vollständig gelesen', () {
      final t = parseTelemetry(
        telemetryBytes(
          flags: 0x0D, // Fix, SD ok, Fahrt läuft
          speed: 523,
          temp: 1874,
          odometer: 1284600,
          trip: 3400,
          sats: 9,
          lights: 0x03,
        ),
      );
      expect(t.protocolVersion, 1);
      expect(t.speedKmh, closeTo(52.3, 1e-9));
      expect(t.tempC, closeTo(187.4, 1e-9));
      expect(t.odometerM, 1284600);
      expect(t.tripDistanceM, 3400);
      expect(t.satellites, 9);
      expect(t.gpsFix, isTrue);
      expect(t.tempWarning, isFalse);
      expect(t.sdOk, isTrue);
      expect(t.tripRunning, isTrue);
      expect(t.tempSensorFault, isFalse);
      expect(t.simulation, isFalse);
      expect(t.lights.parking, isTrue);
      expect(t.lights.headlight, isTrue);
      expect(t.lights.hazard, isFalse);
    });

    test('Little Endian: Bytes werden in der richtigen Reihenfolge gelesen', () {
      final bytes = Uint8List.fromList([
        1, 0, //
        0x34, 0x12, // 0x1234 = 4660 → 466,0 km/h
        0x01, 0x80, // 0x8001 = -32767
        0x78, 0x56, 0x34, 0x12, // 0x12345678
        0x01, 0x00, 0x00, 0x00, // 1
        7, 0,
      ]);
      final t = parseTelemetry(bytes);
      expect(t.speedDeciKmh, 0x1234);
      expect(t.tempDeciC, -32767);
      expect(t.odometerM, 0x12345678);
      expect(t.tripDistanceM, 1);
    });

    test('Randwerte: Maximum uint16/uint32 und negative Temperatur', () {
      final t = parseTelemetry(
        telemetryBytes(
          speed: 0xFFFF,
          temp: -400,
          odometer: 0xFFFFFFFF,
          trip: 0xFFFFFFFF,
          sats: 255,
          flags: 0xFF,
          lights: 0xFF,
        ),
      );
      expect(t.speedDeciKmh, 65535);
      expect(t.odometerM, 4294967295);
      expect(t.tripDistanceM, 4294967295);
      expect(t.satellites, 255);
      expect(t.simulation, isTrue);
      // Sensorfehler-Bit gesetzt → keine Temperatur.
      expect(t.tempC, isNull);
      // Unbekannte Licht-Bits werden ausgeblendet.
      expect(t.lights.bits, 0x07);

      final cold = parseTelemetry(telemetryBytes(temp: -400));
      expect(cold.tempC, closeTo(-40.0, 1e-9));
    });

    test('-32768 bedeutet ungültige Temperatur', () {
      final t = parseTelemetry(telemetryBytes(temp: kInvalidTemperature));
      expect(t.tempDeciC, kInvalidTemperature);
      expect(t.tempC, isNull);
    });

    test('Sensorfehler (Bit4) ergibt keine Temperatur, auch bei plausiblem Wert', () {
      final t = parseTelemetry(telemetryBytes(temp: 2000, flags: TelemetryFlags.tempSensorFault));
      expect(t.tempSensorFault, isTrue);
      expect(t.tempC, isNull);
    });

    test('zu kurze und zu lange Pakete werden verworfen', () {
      for (final length in [0, 1, 15, 17, 20]) {
        final bytes = Uint8List(length);
        if (length > 0) bytes[0] = 1; // richtige Version, nur die Länge stimmt nicht
        expect(
          () => parseTelemetry(bytes),
          throwsA(
            isA<TelemetryFormatException>().having(
              (e) => e.reason,
              'reason',
              TelemetryRejection.wrongLength,
            ),
          ),
          reason: 'Länge $length',
        );
      }
    });

    test('unbekannte Protokollversion wird verworfen', () {
      for (final v in [0, 2, 255]) {
        expect(
          () => parseTelemetry(telemetryBytes(version: v)),
          throwsA(
            isA<TelemetryFormatException>().having(
              (e) => e.reason,
              'reason',
              TelemetryRejection.unsupportedVersion,
            ),
          ),
        );
      }
    });

    test('Encoder und Parser sind zueinander passend', () {
      const t = Telemetry(
        protocolVersion: 1,
        flags: 0x27,
        speedDeciKmh: 612,
        tempDeciC: -32768,
        odometerM: 99999,
        tripDistanceM: 12,
        satellites: 11,
        lights: LightState(0x05),
      );
      expect(parseTelemetry(encodeTelemetry(t)), t);
    });
  });

  group('Licht', () {
    test('Bits werden korrekt zugeordnet', () {
      expect(parseLightState([0x01]).parking, isTrue);
      expect(parseLightState([0x02]).headlight, isTrue);
      expect(parseLightState([0x04]).hazard, isTrue);
      expect(parseLightState([0x00]), LightState.off);
      expect(parseLightState([0xF8]), LightState.off, reason: 'obere Bits ignorieren');
    });

    test('leeres Paket ist ungültig', () {
      expect(() => parseLightState(const []), throwsFormat());
    });

    test('withChannel setzt und löscht einzelne Bits', () {
      final s = LightState.off
          .withChannel(LightChannel.parking, true)
          .withChannel(LightChannel.hazard, true);
      expect(s.bits, 0x05);
      expect(s.withChannel(LightChannel.parking, false).bits, 0x04);
      expect(encodeLightState(s), [0x05]);
    });
  });

  group('Befehle', () {
    test('Fahrten auflisten und Info lesen sind 1 Byte', () {
      expect(ZipCommands.listTrips(), [0x01]);
      expect(ZipCommands.readInfo(), [0x06]);
    });

    test('Fahrt-Daten lesen: tripId, offset u32 LE und maxChunks', () {
      expect(ZipCommands.readTrip(0x04030201, 0x0D0C0B0A, 32), [
        0x02,
        0x01, 0x02, 0x03, 0x04, //
        0x0A, 0x0B, 0x0C, 0x0D, //
        32,
      ]);
    });

    test('Löschen, Gesamtkilometer und Warngrenze', () {
      expect(ZipCommands.deleteTrip(7), [0x03, 7, 0, 0, 0]);
      expect(ZipCommands.setOdometer(1284600), [0x04, 0xF8, 0x99, 0x13, 0x00]);
      expect(ZipCommands.setTempLimit(250), [0x05, 250, 0]);
      expect(ZipCommands.setTempLimit(300), [0x05, 0x2C, 0x01]);
    });

    test('Randwerte werden akzeptiert, Überläufe abgelehnt', () {
      expect(ZipCommands.setOdometer(0xFFFFFFFF), [0x04, 0xFF, 0xFF, 0xFF, 0xFF]);
      expect(ZipCommands.readTrip(0, 0, 1).last, 1);
      expect(ZipCommands.readTrip(0, 0, 255).last, 255);
      expect(() => ZipCommands.setOdometer(0x100000000), throwsArgumentError);
      expect(() => ZipCommands.setOdometer(-1), throwsArgumentError);
      expect(() => ZipCommands.setTempLimit(0x10000), throwsArgumentError);
      expect(() => ZipCommands.readTrip(1, 0, 0), throwsArgumentError);
      expect(() => ZipCommands.readTrip(1, 0, 256), throwsArgumentError);
    });

    test('parseCommand (Demo-Firmware) versteht alle Befehle', () {
      expect(parseCommand(ZipCommands.listTrips()), isA<ListTripsCommand>());
      final read = parseCommand(ZipCommands.readTrip(9, 470, 32)) as ReadTripCommand;
      expect([read.tripId, read.offset, read.maxChunks], [9, 470, 32]);
      expect((parseCommand(ZipCommands.deleteTrip(3)) as DeleteTripCommand).tripId, 3);
      expect((parseCommand(ZipCommands.setOdometer(5)) as SetOdometerCommand).meters, 5);
      expect((parseCommand(ZipCommands.setTempLimit(245)) as SetTempLimitCommand).celsius, 245);
      expect(parseCommand(ZipCommands.readInfo()), isA<ReadInfoCommand>());
    });

    test('parseCommand meldet unbekannte Befehle (1) und falsche Länge (2)', () {
      expect(
        () => parseCommand([0x42]),
        throwsA(isA<ZipCommandException>().having((e) => e.code, 'code', 1)),
      );
      expect(
        () => parseCommand([0x02, 1, 2]),
        throwsA(isA<ZipCommandException>().having((e) => e.code, 'code', 2)),
      );
      expect(
        () => parseCommand(const []),
        throwsA(isA<ZipCommandException>().having((e) => e.code, 'code', 2)),
      );
    });
  });

  group('Antworten', () {
    test('0x81 Fahrteintrag', () {
      final d = ByteData(29)
        ..setUint8(0, 0x81)
        ..setUint32(1, 42, Endian.little)
        ..setUint32(5, 1790000000, Endian.little)
        ..setUint32(9, 1932, Endian.little)
        ..setUint32(13, 12400, Endian.little)
        ..setUint16(17, 587, Endian.little)
        ..setInt16(19, 2365, Endian.little)
        ..setUint32(21, 1932, Endian.little)
        ..setUint32(25, 30944, Endian.little);
      final r = parseResponse(d.buffer.asUint8List()) as TripEntryResponse;
      final e = r.entry;
      expect(e.tripId, 42);
      expect(e.startUnix, 1790000000);
      expect(e.durationS, 1932);
      expect(e.distanceM, 12400);
      expect(e.maxSpeedDeciKmh, 587);
      expect(e.maxTempDeciC, 2365);
      expect(e.pointCount, 1932);
      expect(e.fileSize, 30944);
      expect(parseResponse(encodeTripEntry(e)), isA<TripEntryResponse>());
      expect((parseResponse(encodeTripEntry(e)) as TripEntryResponse).entry, e);
    });

    test('0x81 mit ungültiger Maximaltemperatur', () {
      const e = TripEntry(
        tripId: 1,
        startUnix: 0,
        durationS: 0,
        distanceM: 0,
        maxSpeedDeciKmh: 0,
        maxTempDeciC: kInvalidTemperature,
        pointCount: 0,
        fileSize: 32,
      );
      final parsed = parseResponse(encodeTripEntry(e)) as TripEntryResponse;
      expect(parsed.entry.maxTempDeciC, kInvalidTemperature);
    });

    test('0x82 Listenende', () {
      final r = parseResponse([0x82, 0x2C, 0x01]) as TripListEndResponse;
      expect(r.count, 300);
    });

    test('0x83 Datenstück mit Nutzdaten', () {
      final bytes = encodeChunk(5, 0x01020304, [9, 8, 7]);
      expect(bytes.sublist(0, 9), [0x83, 5, 0, 0, 0, 4, 3, 2, 1]);
      final r = parseResponse(bytes) as TripChunkResponse;
      expect(r.tripId, 5);
      expect(r.offset, 0x01020304);
      expect(r.data, [9, 8, 7]);
    });

    test('0x83 ohne Nutzdaten ist gültig, aber leer', () {
      final r = parseResponse(encodeChunk(1, 0, const [])) as TripChunkResponse;
      expect(r.data, isEmpty);
    });

    test('0x84 Dateiende', () {
      final r = parseResponse(encodeEndOfFile(3, 4096, 0xCBF43926)) as TripEndOfFileResponse;
      expect(r.tripId, 3);
      expect(r.totalSize, 4096);
      expect(r.crc32, 0xCBF43926);
    });

    test('0x85 Bestätigung ok und Fehlerstatus', () {
      final ok = parseResponse([0x85, 0x04, 0]) as AckResponse;
      expect(ok.commandOpcode, 0x04);
      expect(ok.ok, isTrue);
      final bad = parseResponse([0x85, 0x05, 2]) as AckResponse;
      expect(bad.ok, isFalse);
      expect(bad.status, 2);
    });

    test('0x86 Info', () {
      const info = DeviceInfo(
        protocolVersion: 1,
        firmwareVersion: [1, 2, 3],
        tempLimitC: 245,
        odometerM: 1284600,
        sdFreeMb: 29812,
      );
      final r = parseResponse(encodeInfo(info)) as InfoResponse;
      expect(r.info.protocolVersion, 1);
      expect(r.info.firmwareString, '1.2.3');
      expect(r.info.tempLimitC, 245);
      expect(r.info.odometerM, 1284600);
      expect(r.info.sdFreeMb, 29812);
    });

    test('0xFF Fehler mit deutscher Meldung', () {
      final r = parseResponse([0xFF, 0x02, 3]) as ErrorResponse;
      expect(r.commandOpcode, 0x02);
      expect(r.code, 3);
      expect(r.message, contains('nicht gefunden'));
      expect(zipErrorMessage(1), contains('kennt diesen Befehl nicht'));
      expect(zipErrorMessage(2), contains('Länge'));
      expect(zipErrorMessage(4), contains('SD-Karte'));
      expect(zipErrorMessage(5), contains('beschäftigt'));
      expect(zipErrorMessage(99), contains('99'));
    });

    test('zu kurze Antworten werfen einen Formatfehler', () {
      final cases = <List<int>>[
        [],
        [0x81, 1, 2, 3],
        encodeTripEntry(
          const TripEntry(
            tripId: 1,
            startUnix: 1,
            durationS: 1,
            distanceM: 1,
            maxSpeedDeciKmh: 1,
            maxTempDeciC: 1,
            pointCount: 1,
            fileSize: 1,
          ),
        ).sublist(0, 28),
        [0x82, 1],
        [0x83, 1, 0, 0, 0, 0, 0, 0],
        [0x84, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        [0x85, 1],
        [0x86, 1, 1, 0, 0, 0xF0, 0, 0, 0, 0, 0, 0, 0, 0],
        [0xFF, 1],
      ];
      for (final c in cases) {
        expect(() => parseResponse(c), throwsFormat(), reason: 'Paket $c');
      }
    });

    test('unbekannter Opcode wirft einen Formatfehler', () {
      expect(() => parseResponse([0x87, 0, 0]), throwsFormat());
      expect(() => parseResponse([0x01]), throwsFormat());
    });

    test('längere Pakete werden toleriert (Vorwärtskompatibilität)', () {
      final r = parseResponse([0x85, 0x03, 0, 0xAA, 0xBB]) as AckResponse;
      expect(r.ok, isTrue);
    });
  });

  group('CRC32', () {
    test('Standard-Prüfwert „123456789“', () {
      expect(Crc32.compute(ascii.encode('123456789')), 0xCBF43926);
    });

    test('leere Daten und bekannte Werte', () {
      expect(Crc32.compute(const []), 0);
      expect(
        Crc32.compute(ascii.encode('The quick brown fox jumps over the lazy dog')),
        0x414FA339,
      );
      expect(Crc32.compute([0]), 0xD202EF8D);
    });

    test('inkrementell = am Stück', () {
      final data = List<int>.generate(1000, (i) => (i * 31) & 0xFF);
      final crc = Crc32()
        ..add(data.sublist(0, 123))
        ..add(data.sublist(123, 777))
        ..add(data.sublist(777));
      expect(crc.value, Crc32.compute(data));
    });
  });
}
