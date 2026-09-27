import 'dart:async';
import 'dart:typed_data';

import 'package:zip_app/ble/trip_sync.dart';
import 'package:zip_app/data/models.dart';
import 'package:zip_app/data/zip_data_source.dart';

/// Datenquelle für Tests: Befehle landen in [written], Antworten werden
/// über [respond] bzw. [onWrite] eingespeist.
class FakeSource implements ZipDataSource {
  FakeSource({this.onWrite});

  /// Wird bei jedem geschriebenen Befehl aufgerufen.
  void Function(Uint8List command, FakeSource source)? onWrite;

  final List<Uint8List> written = [];
  ZipLinkState _state = const ZipLinkState(status: LinkStatus.connected);

  final StreamController<ZipLinkState> _states = StreamController.broadcast();
  final StreamController<Uint8List> _telemetry = StreamController.broadcast();
  final StreamController<Uint8List> _light = StreamController.broadcast();
  final StreamController<Uint8List> _response = StreamController.broadcast();
  final StreamController<ZipNotice> _notices = StreamController.broadcast();

  void respond(List<int> packet) => _response.add(Uint8List.fromList(packet));
  void telemetry(List<int> packet) => _telemetry.add(Uint8List.fromList(packet));
  void setState(ZipLinkState s) {
    _state = s;
    _states.add(s);
  }

  @override
  bool get isDemo => false;
  @override
  ZipLinkState get state => _state;
  @override
  Stream<ZipLinkState> get states => _states.stream;
  @override
  Stream<Uint8List> get telemetryPackets => _telemetry.stream;
  @override
  Stream<Uint8List> get lightPackets => _light.stream;
  @override
  Stream<Uint8List> get responsePackets => _response.stream;
  @override
  Stream<ZipNotice> get notices => _notices.stream;
  @override
  bool get canTurnOnBluetooth => false;

  @override
  Future<void> writeControl(Uint8List command) async {
    written.add(command);
    onWrite?.call(command, this);
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> connect() async {}
  @override
  Future<void> scanAndConnect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> forgetDevice() async {}
  @override
  Future<void> writeLights(int bits) async {}
  @override
  Future<void> readLights() async {}
  @override
  Future<void> turnOnBluetooth() async {}
  @override
  void setForeground(bool foreground) {}

  @override
  Future<void> dispose() async {
    await _states.close();
    await _telemetry.close();
    await _light.close();
    await _response.close();
    await _notices.close();
  }
}

/// Speicher im Arbeitsspeicher statt sqflite.
class MemoryTripStore implements TripStore {
  final Map<TripKey, Uint8List> files = {};
  final Map<TripKey, TripEntry> entries = {};
  final Set<TripKey> deleted = {};
  final Map<TripKey, Map<int, Uint8List>> segments = {};
  final Map<TripKey, int> expected = {};

  /// Zählt, wie viele Bytes insgesamt als Zwischenstand gespeichert wurden.
  int appendedBytes = 0;

  @override
  Future<Map<TripKey, int>> localFileSizes() async => {
    for (final e in files.entries) e.key: e.value.length,
  };

  @override
  Future<Set<TripKey>> deletedKeys() async => Set.of(deleted);

  @override
  Future<PartialDownload?> loadPartial(TripKey key) async {
    final segs = segments[key];
    if (segs == null || segs.isEmpty) return null;
    final builder = BytesBuilder();
    final offsets = segs.keys.toList()..sort();
    for (final o in offsets) {
      if (o != builder.length) break;
      builder.add(segs[o]!);
    }
    return PartialDownload(expected[key]!, builder.toBytes());
  }

  @override
  Future<void> appendPartial(TripKey key, int offset, Uint8List data, int expectedSize) async {
    segments.putIfAbsent(key, () => {})[offset] = Uint8List.fromList(data);
    expected[key] = expectedSize;
    appendedBytes += data.length;
  }

  @override
  Future<void> clearPartial(TripKey key) async {
    segments.remove(key);
    expected.remove(key);
  }

  @override
  Future<void> saveTrip(TripEntry entry, Uint8List file, TripFile parsed) async {
    files[entry.key] = file;
    entries[entry.key] = entry;
  }
}
