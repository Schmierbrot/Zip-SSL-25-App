import 'package:flutter_test/flutter_test.dart';
import 'package:zip_app/ble/command_queue.dart';
import 'package:zip_app/ble/zip_client.dart';
import 'package:zip_app/ble/zip_protocol.dart';
import 'package:zip_app/data/models.dart';
import 'package:zip_app/data/zip_data_source.dart';

import 'helpers/fakes.dart';

const _info = DeviceInfo(
  protocolVersion: 1,
  firmwareVersion: [1, 0, 3],
  tempLimitC: 250,
  odometerM: 1000,
  sdFreeMb: 512,
);

TripEntry _entry(int id) => TripEntry(
  tripId: id,
  startUnix: 1000 + id,
  durationS: 60,
  distanceM: 500,
  maxSpeedDeciKmh: 300,
  maxTempDeciC: 1800,
  pointCount: 60,
  fileSize: 32 + 60 * 16,
);

void main() {
  late FakeSource source;
  late ZipClient client;

  setUp(() {
    source = FakeSource();
    client = ZipClient(source, commandTimeout: const Duration(milliseconds: 200));
  });

  tearDown(() async {
    await client.dispose();
    await source.dispose();
  });

  test('Befehle werden nacheinander gesendet – immer nur einer offen', () async {
    source.onWrite = (cmd, s) {
      // Antwort erst später, damit die Warteschlange warten muss.
      Future<void>.delayed(const Duration(milliseconds: 30), () {
        if (cmd[0] == ZipOpcode.readInfo) s.respond(encodeInfo(_info));
        if (cmd[0] == ZipOpcode.setTempLimit) s.respond(encodeAck(ZipOpcode.setTempLimit, 0));
      });
    };
    final a = client.readInfo();
    final b = client.setTempLimit(250);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(source.written, hasLength(1), reason: 'zweiter Befehl wartet');
    expect((await a).tempLimitC, 250);
    await b;
    expect(source.written.map((c) => c[0]), [ZipOpcode.readInfo, ZipOpcode.setTempLimit]);
  });

  test('Timeout mit genau einer Wiederholung', () async {
    source.onWrite = (_, _) {}; // Roller schweigt
    await expectLater(client.readInfo(), throwsA(isA<ZipTimeoutException>()));
    expect(source.written, hasLength(2));
  });

  test('Wiederholung ist erfolgreich, wenn die zweite Antwort kommt', () async {
    var calls = 0;
    source.onWrite = (_, s) {
      if (++calls == 2) s.respond(encodeInfo(_info));
    };
    expect((await client.readInfo()).firmwareString, '1.0.3');
    expect(calls, 2);
  });

  test('Fehlerantwort 0xFF wird als verständliche Meldung geworfen', () async {
    source.onWrite = (cmd, s) => s.respond(encodeError(cmd[0], ZipErrorCode.sdError));
    await expectLater(
      client.setOdometer(5),
      throwsA(
        isA<ZipCommandException>()
            .having((e) => e.code, 'code', 4)
            .having((e) => e.message, 'message', contains('SD-Karte')),
      ),
    );
    expect(source.written, hasLength(1), reason: 'echte Fehler nicht wiederholen');
  });

  test('„beschäftigt“ wird einmal wiederholt', () async {
    var calls = 0;
    source.onWrite = (cmd, s) {
      calls++;
      s.respond(
        calls == 1 ? encodeError(cmd[0], ZipErrorCode.busy) : encodeAck(ZipOpcode.setOdometer, 0),
      );
    };
    await client.setOdometer(1234);
    expect(calls, 2);
  });

  test('Bestätigung mit Status ≠ 0 ist ein Fehler', () async {
    source.onWrite = (_, s) => s.respond(encodeAck(ZipOpcode.setTempLimit, 2));
    await expectLater(client.setTempLimit(999), throwsA(isA<ZipCommandException>()));
  });

  test('Löschen: „nicht gefunden“ gilt als Erfolg', () async {
    source.onWrite = (_, s) =>
        s.respond(encodeError(ZipOpcode.deleteTrip, ZipErrorCode.tripNotFound));
    await client.deleteTrip(3);
  });

  test('Fahrtenliste wird gesammelt; fehlender Eintrag löst Wiederholung aus', () async {
    var calls = 0;
    source.onWrite = (_, s) {
      calls++;
      s.respond(encodeTripEntry(_entry(1)));
      if (calls > 1) s.respond(encodeTripEntry(_entry(2)));
      s.respond(encodeListEnd(2));
    };
    final list = await client.listTrips();
    expect(calls, 2);
    expect(list.map((e) => e.tripId), unorderedEquals([1, 2]));
  });

  test('Antworten anderer Befehle werden ignoriert', () async {
    source.onWrite = (_, s) {
      s.respond(encodeAck(ZipOpcode.deleteTrip, 0)); // gehört nicht dazu
      s.respond(encodeInfo(_info));
    };
    expect((await client.readInfo()).sdFreeMb, 512);
  });

  test('Verbindungsabbruch bricht offene und wartende Befehle ab', () async {
    source.onWrite = (_, _) {};
    final a = client.readInfo();
    final b = client.listTrips();
    source.setState(const ZipLinkState(status: LinkStatus.disconnected));
    await expectLater(a, throwsA(isA<ZipDisconnectedException>()));
    await expectLater(b, throwsA(isA<ZipDisconnectedException>()));
  });

  test('ungültige Pakete lassen den Client nicht abstürzen', () async {
    source.onWrite = (_, s) {
      s.respond(const []);
      s.respond(const [0x86, 1]);
      s.respond(const [0x42, 0, 0]);
      s.respond(encodeInfo(_info));
    };
    expect((await client.readInfo()).protocolVersion, 1);
  });

  group('Telemetrie im Client', () {
    test('falsche Version oder Länge: verwerfen und einmal Hinweis', () async {
      final notices = <ZipNotice>[];
      final telemetry = <Telemetry>[];
      final s1 = client.notices.listen(notices.add);
      final s2 = client.telemetry.listen(telemetry.add);

      final good = encodeTelemetry(
        const Telemetry(
          protocolVersion: 1,
          flags: 0,
          speedDeciKmh: 100,
          tempDeciC: 900,
          odometerM: 1,
          tripDistanceM: 0,
          satellites: 5,
          lights: LightState.off,
        ),
      );
      final wrongVersion = [...good]..[0] = 2;
      source
        ..telemetry(wrongVersion)
        ..telemetry(good.sublist(0, 12))
        ..telemetry(good);
      await Future<void>.delayed(Duration.zero);

      expect(telemetry, hasLength(1));
      expect(notices, hasLength(1));
      expect(notices.single.kind, ZipNoticeKind.firmwareMismatch);
      expect(notices.single.message, 'Firmware-Version passt nicht zur App');
      await s1.cancel();
      await s2.cancel();
    });
  });
}
