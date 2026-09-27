import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/zip_data_source.dart';
import 'command_queue.dart';
import 'zip_protocol.dart';

/// Ergebnis eines Lese-Fensters (Befehl 0x02).
class TripWindow {
  TripWindow(this.requestOffset, Map<int, Uint8List> chunks, this.endOfFile)
    : chunks = Map.unmodifiable(chunks);

  final int requestOffset;

  /// Empfangene Datenstücke nach Offset.
  final Map<int, Uint8List> chunks;

  /// Dateiende (0x84), falls in diesem Fenster empfangen.
  final TripEndOfFileResponse? endOfFile;

  /// Liefert die lückenlosen Bytes ab [offset]. Stücke, die [offset]
  /// überlappen, werden passend zugeschnitten; an der ersten Lücke ist Schluss.
  Uint8List contiguousFrom(int offset) {
    final builder = BytesBuilder(copy: false);
    var pos = offset;
    final sorted = chunks.keys.toList()..sort();
    var progressed = true;
    while (progressed) {
      progressed = false;
      for (final start in sorted) {
        final data = chunks[start]!;
        final end = start + data.length;
        if (start <= pos && end > pos) {
          builder.add(Uint8List.sublistView(data, pos - start));
          pos = end;
          progressed = true;
        }
      }
    }
    return builder.takeBytes();
  }
}

// ---------------------------------------------------------------------------
// Kollektoren
// ---------------------------------------------------------------------------

class _InfoCollector extends ResponseCollector<DeviceInfo> {
  DeviceInfo? _info;

  @override
  int get commandOpcode => ZipOpcode.readInfo;

  @override
  void reset() => _info = null;

  @override
  CollectStatus onResponse(ZipResponse response) {
    if (response is InfoResponse) {
      _info = response.info;
      return CollectStatus.complete;
    }
    return CollectStatus.ignored;
  }

  @override
  DeviceInfo get result => _info!;
}

class _AckCollector extends ResponseCollector<void> {
  _AckCollector(this.commandOpcode);

  @override
  final int commandOpcode;

  @override
  void reset() {}

  @override
  CollectStatus onResponse(ZipResponse response) {
    if (response is AckResponse && response.commandOpcode == commandOpcode) {
      if (!response.ok) throw ZipCommandException(commandOpcode, response.status);
      return CollectStatus.complete;
    }
    return CollectStatus.ignored;
  }

  @override
  void get result {}
}

class _TripListCollector extends ResponseCollector<List<TripEntry>> {
  final Map<int, TripEntry> _entries = {};

  @override
  int get commandOpcode => ZipOpcode.listTrips;

  @override
  void reset() => _entries.clear();

  @override
  CollectStatus onResponse(ZipResponse response) {
    switch (response) {
      case TripEntryResponse(:final entry):
        _entries[entry.tripId] = entry;
        return CollectStatus.accepted;
      case TripListEndResponse(:final count):
        // Fehlt ein Eintrag (verlorene Notification), Liste neu anfordern.
        return count == _entries.length ? CollectStatus.complete : CollectStatus.retry;
      default:
        return CollectStatus.ignored;
    }
  }

  @override
  List<TripEntry> get result => _entries.values.toList(growable: false);
}

class _TripWindowCollector extends ResponseCollector<TripWindow> {
  _TripWindowCollector({
    required this.tripId,
    required this.offset,
    required this.maxChunks,
    required this.expectedSize,
    required this.idleTimeout,
  });

  final int tripId;
  final int offset;
  final int maxChunks;
  final int? expectedSize;

  @override
  final Duration idleTimeout;

  final Map<int, Uint8List> _chunks = {};
  TripEndOfFileResponse? _eof;
  int _chunkLength = 0;

  @override
  int get commandOpcode => ZipOpcode.readTrip;

  @override
  void reset() {
    _chunks.clear();
    _eof = null;
    _chunkLength = 0;
  }

  @override
  bool get hasProgress => _chunks.isNotEmpty || _eof != null;

  @override
  bool get completesOnIdle => true;

  @override
  CollectStatus onResponse(ZipResponse response) {
    switch (response) {
      case TripChunkResponse(:final tripId, :final offset, :final data)
          when tripId == this.tripId && offset >= this.offset && data.isNotEmpty:
        _chunks[offset] = data;
        if (data.length > _chunkLength) _chunkLength = data.length;
        final size = expectedSize;
        // Letztes Stück der Datei: auf 0x84 (mit CRC) warten.
        if (size != null && offset + data.length >= size) return CollectStatus.accepted;
        if (_chunks.length >= maxChunks) return CollectStatus.complete;
        // Fenster endet vor dem Dateiende: letztes Stück des Fensters erreicht?
        // Dann ist klar, ob Lücken existieren – sofort weitermachen.
        final windowEnd = this.offset + maxChunks * _chunkLength;
        if (size != null && windowEnd < size && offset + data.length >= windowEnd) {
          return CollectStatus.complete;
        }
        return CollectStatus.accepted;
      case TripEndOfFileResponse(:final tripId) when tripId == this.tripId:
        _eof = response;
        return CollectStatus.complete;
      default:
        return CollectStatus.ignored;
    }
  }

  @override
  TripWindow get result => TripWindow(offset, _chunks, _eof);
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Protokoll-Schicht über einer [ZipDataSource]: parst Pakete, verwaltet die
/// Befehlswarteschlange und stellt typisierte Streams und Befehle bereit.
class ZipClient {
  ZipClient(this.source, {Duration commandTimeout = const Duration(seconds: 5)}) {
    _queue = ZipCommandQueue(write: source.writeControl, timeout: commandTimeout);
    _subscriptions.addAll([
      source.telemetryPackets.listen(_onTelemetry),
      source.lightPackets.listen(_onLight),
      source.responsePackets.listen(_onResponse),
      source.states.listen(_onLinkState),
      source.notices.listen(_notices.add),
    ]);
  }

  final ZipDataSource source;
  late final ZipCommandQueue _queue;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  final StreamController<Telemetry> _telemetry = StreamController.broadcast();
  final StreamController<LightState> _lights = StreamController.broadcast();
  final StreamController<ZipNotice> _notices = StreamController.broadcast();

  Telemetry? _lastTelemetry;
  LightState? _lastLights;
  bool _mismatchReported = false;

  /// Fenstergröße beim Herunterladen von Fahrten.
  static const int windowChunks = 32;

  /// Funkstille, nach der ein Lese-Fenster als beendet gilt.
  static const Duration windowIdleTimeout = Duration(milliseconds: 1500);

  bool get isDemo => source.isDemo;
  ZipLinkState get linkState => source.state;
  Stream<ZipLinkState> get linkStates => source.states;

  Stream<Telemetry> get telemetry => _telemetry.stream;
  Telemetry? get lastTelemetry => _lastTelemetry;

  Stream<LightState> get lights => _lights.stream;
  LightState? get lastLights => _lastLights;

  Stream<ZipNotice> get notices => _notices.stream;

  void _onTelemetry(Uint8List bytes) {
    try {
      final t = parseTelemetry(bytes);
      _lastTelemetry = t;
      _telemetry.add(t);
    } on TelemetryFormatException catch (e) {
      debugPrint('Telemetrie verworfen: ${e.message}');
      if (!_mismatchReported) {
        _mismatchReported = true;
        _notices.add(ZipNotice.firmwareMismatch);
      }
    }
  }

  void _onLight(Uint8List bytes) {
    try {
      final s = parseLightState(bytes);
      _lastLights = s;
      _lights.add(s);
    } on ZipFormatException catch (e) {
      debugPrint('Lichtzustand verworfen: ${e.message}');
    }
  }

  void _onResponse(Uint8List bytes) {
    try {
      _queue.handleResponse(parseResponse(bytes));
    } on ZipFormatException catch (e) {
      debugPrint('Antwort verworfen: ${e.message}');
    }
  }

  void _onLinkState(ZipLinkState state) {
    if (!state.isConnected) _queue.cancelAll();
  }

  // --- Licht ---------------------------------------------------------------

  Future<void> writeLights(LightState state) => source.writeLights(state.bits);

  Future<void> readLights() => source.readLights();

  // --- Befehle -------------------------------------------------------------

  Future<List<TripEntry>> listTrips() => _queue.send(ZipCommands.listTrips(), _TripListCollector());

  Future<TripWindow> readTripWindow(
    int tripId,
    int offset, {
    int maxChunks = windowChunks,
    int? expectedSize,
  }) {
    return _queue.send(
      ZipCommands.readTrip(tripId, offset, maxChunks),
      _TripWindowCollector(
        tripId: tripId,
        offset: offset,
        maxChunks: maxChunks,
        expectedSize: expectedSize,
        idleTimeout: windowIdleTimeout,
      ),
    );
  }

  /// Löscht eine Fahrt auf dem Roller. „Nicht gefunden“ gilt als Erfolg
  /// (z. B. wenn die Bestätigung beim ersten Versuch verloren ging).
  Future<void> deleteTrip(int tripId) async {
    try {
      await _queue.send(ZipCommands.deleteTrip(tripId), _AckCollector(ZipOpcode.deleteTrip));
    } on ZipCommandException catch (e) {
      if (e.code != ZipErrorCode.tripNotFound) rethrow;
    }
  }

  Future<void> setOdometer(int meters) =>
      _queue.send(ZipCommands.setOdometer(meters), _AckCollector(ZipOpcode.setOdometer));

  Future<void> setTempLimit(int celsius) =>
      _queue.send(ZipCommands.setTempLimit(celsius), _AckCollector(ZipOpcode.setTempLimit));

  Future<DeviceInfo> readInfo() => _queue.send(ZipCommands.readInfo(), _InfoCollector());

  Future<void> dispose() async {
    _queue.dispose();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await _telemetry.close();
    await _lights.close();
    await _notices.close();
  }
}

/// Verständliche Meldung für Fehler aus Befehlen und Verbindung.
String describeZipError(Object error) {
  if (error is ZipCommandException) return error.message;
  if (error is ZipTimeoutException) return error.message;
  if (error is ZipDisconnectedException) return error.message;
  return 'Unerwarteter Fehler: $error';
}
