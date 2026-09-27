import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zip_app/ble/trip_sync.dart';
import 'package:zip_app/ble/zip_client.dart';
import 'package:zip_app/data/demo_source.dart';
import 'package:zip_app/data/trip_file_parser.dart';

import 'helpers/fakes.dart';

/// Die Synchronisation läuft gegen die emulierte Firmware des Demo-Modus –
/// damit werden Befehle, Fenster, Lücken, CRC und Löschen Ende-zu-Ende geprüft.
void main() {
  late DemoSource source;
  late DemoScooter scooter;
  late ZipClient client;
  late MemoryTripStore store;

  Future<void> connect({double dropRate = 0, int chunkSize = 235}) async {
    scooter = DemoScooter(
      seed: 3,
      dropRate: dropRate,
      chunkSize: chunkSize,
      chunkDelay: Duration.zero,
      now: DateTime(2026, 9, 27, 12),
    );
    source = DemoSource(scooter: scooter, connectDelay: Duration.zero);
    client = ZipClient(source);
    store = MemoryTripStore();
    await source.connect();
    expect(source.state.isConnected, isTrue);
  }

  TripSync makeSync({bool deleteAfter = false, bool tripRunning = false}) => TripSync(
    client: client,
    store: store,
    deleteAfterTransfer: () => deleteAfter,
    isTripRunning: () => tripRunning,
  );

  tearDown(() async {
    await client.dispose();
    await source.dispose();
  });

  test('alle Fahrten werden vollständig und korrekt übertragen', () async {
    await connect();
    final progress = <SyncProgress>[];
    final result = await makeSync().run(onProgress: progress.add);

    expect(result.listed, hasLength(4));
    expect(result.downloaded, 4);
    expect(result.failed, 0);
    expect(result.errors, isEmpty);
    for (final trip in scooter.trips) {
      final saved = store.files[trip.entry.key];
      expect(saved, isNotNull);
      expect(saved, trip.file, reason: 'Fahrt ${trip.entry.tripId} bitgenau');
      expect(TripFileParser.parse(saved!).points, hasLength(trip.entry.pointCount));
    }
    expect(store.segments, isEmpty, reason: 'Zwischenstände aufgeräumt');
    expect(progress.last.current, 4);
    expect(progress.last.fraction, closeTo(1, 1e-9));
    // Keine Fahrt auf dem Roller gelöscht (Einstellung aus).
    expect(scooter.trips, hasLength(4));
    expect(result.remainingOnScooter, hasLength(4));
  });

  test('vorhandene und lokal gelöschte Fahrten werden nicht erneut geladen', () async {
    await connect();
    await makeSync().run();
    final first = scooter.trips.first.entry.key;
    store.files.remove(first);
    store.deleted.add(first);

    final again = await makeSync().run();
    expect(again.downloaded, 0);
    expect(store.files.containsKey(first), isFalse);
  });

  test('verlorene Datenstücke werden erkannt und nachgeladen', () async {
    await connect(dropRate: 0.08);
    final result = await makeSync().run();
    expect(result.failed, 0, reason: result.errors.join('\n'));
    expect(result.downloaded, 4);
    expect(scooter.droppedChunks, greaterThan(0), reason: 'Test muss Lücken enthalten');
    for (final trip in scooter.trips) {
      expect(store.files[trip.entry.key], trip.file);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('abgebrochener Download wird ab dem letzten Stand fortgesetzt', () async {
    await connect();
    final trip = scooter.trips.last;
    final key = trip.entry.key;
    // Simulierter Abbruch: die erste Hälfte (lückenlos) ist schon gespeichert.
    final half = trip.file.length ~/ 2;
    await store.appendPartial(
      key,
      0,
      Uint8List.sublistView(trip.file, 0, half),
      trip.entry.fileSize,
    );
    store.appendedBytes = 0;

    final bytes = await makeSync().downloadTrip(trip.entry);
    expect(bytes, trip.file);
    expect(store.appendedBytes, trip.file.length - half, reason: 'nur der Rest wurde geladen');
  });

  test('Zwischenstand zu einer geänderten Datei wird verworfen', () async {
    await connect();
    final trip = scooter.trips.first;
    await store.appendPartial(trip.entry.key, 0, Uint8List(64), trip.entry.fileSize + 100);
    final bytes = await makeSync().downloadTrip(trip.entry);
    expect(bytes, trip.file);
  });

  test('falsche Prüfsumme: einmal neu laden, dann Fehler melden', () async {
    await connect();
    // Datei auf dem Roller mit falscher CRC.
    final original = scooter.trips.first;
    scooter.trips[0] = _BrokenCrcTrip(original.entry, original.file);
    final result = await makeSync().run();
    expect(result.failed, 1);
    expect(result.downloaded, 3);
    expect(result.errors.single, contains('Prüfsumme'));
    expect(store.files.containsKey(original.entry.key), isFalse);
    expect(store.segments.containsKey(original.entry.key), isFalse);
  });

  test('beschädigter Zwischenstand wird durch die CRC-Prüfung erkannt', () async {
    await connect();
    final trip = scooter.trips.last;
    // Falsche Bytes im gespeicherten Anfang (z. B. defekter Speicher).
    final corrupt = Uint8List.fromList(trip.file.sublist(0, 200))..[100] ^= 0xFF;
    await store.appendPartial(trip.entry.key, 0, corrupt, trip.entry.fileSize);
    final bytes = await makeSync().downloadTrip(trip.entry);
    expect(bytes, trip.file, reason: 'nach CRC-Fehler vollständig neu geladen');
  });

  test('Löschen nach Übertragung erst nach Speichern – laufende Fahrt bleibt', () async {
    await connect();
    final newest = scooter.trips.map((t) => t.entry.tripId).reduce((a, b) => a > b ? a : b);
    final result = await makeSync(deleteAfter: true, tripRunning: true).run();
    expect(result.downloaded, 4);
    expect(result.deletedOnScooter, 3);
    expect(scooter.trips.map((t) => t.entry.tripId), [newest]);
    expect(result.remainingOnScooter.map((k) => k.tripId), [newest]);
    for (final key in store.entries.keys) {
      expect(store.files[key], isNotNull);
    }
  });

  test('Löschen nach Übertragung ohne laufende Fahrt leert den Roller', () async {
    await connect();
    final result = await makeSync(deleteAfter: true).run();
    expect(result.deletedOnScooter, 4);
    expect(scooter.trips, isEmpty);
    expect(result.remainingOnScooter, isEmpty);
  });

  test('gewachsene Datei (Fahrt lief noch) wird erneut geladen', () async {
    await connect();
    await makeSync().run();
    final trip = scooter.trips.last;
    // Lokal liegt nur ein älterer, kürzerer Stand.
    store.files[trip.entry.key] = Uint8List.sublistView(trip.file, 0, trip.file.length - 160);
    final result = await makeSync().run();
    expect(result.downloaded, 1);
    expect(store.files[trip.entry.key], trip.file);
  });

  test('kleine Datenstücke (Standard-MTU) funktionieren ebenso', () async {
    await connect(chunkSize: 11);
    final trip = scooter.trips.last;
    final bytes = await makeSync().downloadTrip(trip.entry);
    expect(bytes, trip.file);
  });

  test('Fensterauswertung: nur der lückenlose Anfang zählt', () {
    final window = TripWindow(0, {
      0: Uint8List.fromList([1, 2, 3]),
      3: Uint8List.fromList([4, 5]),
      // Lücke bei 5
      7: Uint8List.fromList([8]),
    }, null);
    expect(window.contiguousFrom(0), [1, 2, 3, 4, 5]);
    expect(window.contiguousFrom(2), [3, 4, 5], reason: 'überlappendes Stück wird zugeschnitten');
    expect(window.contiguousFrom(5), isEmpty);
    expect(ZipClient.windowChunks, 32);
  });
}

class _BrokenCrcTrip extends DemoTrip {
  _BrokenCrcTrip(super.entry, super.file);

  @override
  int get crc32 => super.crc32 ^ 0x1;
}
