import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ble/command_queue.dart';
import '../ble/zip_protocol.dart';
import 'models.dart';
import 'zip_data_source.dart';

/// Demo-Modus: emuliert die Firmware der Zip vollständig auf Byte-Ebene.
///
/// Telemetrie, Licht und alle Befehle laufen als echte Protokoll-Pakete –
/// Parser, Befehlswarteschlange und Fahrten-Synchronisation werden damit
/// genauso durchlaufen wie mit dem echten Roller.
class DemoSource implements ZipDataSource {
  DemoSource({DemoScooter? scooter, this.connectDelay = const Duration(milliseconds: 700)})
    : scooter = scooter ?? DemoScooter();

  static const String demoDeviceId = 'DEMO';
  static const String demoDeviceName = 'Zip (Demo)';

  final DemoScooter scooter;
  final Duration connectDelay;

  ZipLinkState _state = const ZipLinkState(
    savedDeviceId: demoDeviceId,
    savedDeviceName: demoDeviceName,
  );

  final StreamController<ZipLinkState> _states = StreamController.broadcast();
  final StreamController<Uint8List> _telemetry = StreamController.broadcast();
  final StreamController<Uint8List> _light = StreamController.broadcast();
  final StreamController<Uint8List> _response = StreamController.broadcast();
  final StreamController<ZipNotice> _notices = StreamController.broadcast();

  Timer? _telemetryTimer;
  bool _disposed = false;
  int _session = 0;

  @override
  bool get isDemo => true;

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
  Future<void> start() async {
    if (_state.savedDeviceId != null) await connect();
  }

  @override
  Future<void> connect() async {
    if (_disposed || _state.isConnected || _state.isBusy) return;
    final session = ++_session;
    _emit(_state.copyWith(status: LinkStatus.scanning));
    await Future<void>.delayed(connectDelay);
    if (_disposed || session != _session) return;
    _emit(
      _state.copyWith(
        status: LinkStatus.connecting,
        deviceId: demoDeviceId,
        deviceName: demoDeviceName,
      ),
    );
    await Future<void>.delayed(connectDelay ~/ 2);
    if (_disposed || session != _session) return;
    _emit(
      _state.copyWith(
        status: LinkStatus.connected,
        savedDeviceId: demoDeviceId,
        savedDeviceName: demoDeviceName,
      ),
    );
    scooter.onConnected();
    _telemetryTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      scooter.tick(0.2);
      _add(_telemetry, encodeTelemetry(scooter.telemetry()));
    });
    _add(_light, encodeLightState(scooter.lights));
  }

  @override
  Future<void> scanAndConnect() async {
    await disconnect();
    await connect();
  }

  @override
  Future<void> disconnect() async {
    _session++;
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    scooter.cancelStreaming();
    _emit(_state.copyWith(status: LinkStatus.disconnected, reconnecting: false, clearDevice: true));
  }

  @override
  Future<void> forgetDevice() async {
    await disconnect();
    _emit(_state.copyWith(clearSaved: true));
  }

  @override
  Future<void> writeLights(int bits) async {
    _requireConnected();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    scooter.lights = LightState(bits);
    // Wie die Firmware: tatsächlichen Zustand per Notify zurückmelden.
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      if (_state.isConnected) _add(_light, encodeLightState(scooter.lights));
    });
  }

  @override
  Future<void> readLights() async {
    _requireConnected();
    _add(_light, encodeLightState(scooter.lights));
  }

  @override
  Future<void> writeControl(Uint8List command) async {
    _requireConnected();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    final session = _session;
    scooter.handleCommand(command, (packet) {
      if (session == _session && _state.isConnected) _add(_response, packet);
    });
  }

  @override
  Future<void> turnOnBluetooth() async {}

  @override
  void setForeground(bool foreground) {}

  @override
  Future<void> dispose() async {
    await disconnect();
    _disposed = true;
    await _states.close();
    await _telemetry.close();
    await _light.close();
    await _response.close();
    await _notices.close();
  }

  void _requireConnected() {
    if (!_state.isConnected) throw const ZipDisconnectedException();
  }

  void _emit(ZipLinkState s) {
    if (_disposed || s == _state) return;
    _state = s;
    _states.add(s);
  }

  void _add(StreamController<Uint8List> c, Uint8List data) {
    if (!c.isClosed) c.add(data);
  }
}

// ---------------------------------------------------------------------------
// Emulierte Firmware
// ---------------------------------------------------------------------------

/// Emulierter Roller: Fahrsimulation, Licht, SD-Karte mit Beispielfahrten
/// und die Befehlsverarbeitung wie in der Firmware.
class DemoScooter {
  DemoScooter({
    List<DemoTrip>? trips,
    int? seed,
    this.chunkSize = 235,
    this.chunkDelay = const Duration(milliseconds: 6),
    this.dropRate = 0.0,
    DateTime? now,
  }) : _random = math.Random(seed ?? 7),
       trips = trips ?? DemoTripGenerator(seed: seed ?? 42, now: now).generate();

  /// Fahrten auf der emulierten SD-Karte.
  final List<DemoTrip> trips;

  /// Nutzdaten pro 0x83-Paket (MTU 247 − 3 ATT − 9 Header).
  final int chunkSize;
  final Duration chunkDelay;

  /// Anteil verlorener Datenstücke (zum Testen der Lückenerkennung).
  final double dropRate;

  final math.Random _random;

  LightState lights = LightState.off;
  int odometerM = 1284600;
  int tempLimitC = 240;
  final List<int> firmwareVersion = const [1, 0, 0];
  int sdFreeMb = 29812;

  /// Anzahl absichtlich verworfener Datenstücke (für Tests).
  int droppedChunks = 0;

  final _LiveRide _ride = _LiveRide();
  bool _busy = false;
  int _streamGeneration = 0;

  void onConnected() {
    _ride.resetGps();
  }

  void cancelStreaming() {
    _streamGeneration++;
    _busy = false;
  }

  /// Simulationsschritt für die Live-Telemetrie.
  void tick(double dt) {
    final before = _ride.distanceM;
    _ride.step(dt, _random);
    odometerM += (_ride.distanceM - before).round();
  }

  Telemetry telemetry() {
    final temp = _ride.tempC;
    var flags = TelemetryFlags.sdOk | TelemetryFlags.simulation;
    if (_ride.gpsFix) flags |= TelemetryFlags.gpsFix;
    if (temp > tempLimitC) flags |= TelemetryFlags.tempWarning;
    if (_ride.tripRunning) flags |= TelemetryFlags.tripRunning;
    return Telemetry(
      protocolVersion: kProtocolVersion,
      flags: flags,
      speedDeciKmh: _ride.gpsFix ? (_ride.speedKmh * 10).round().clamp(0, 0xFFFF) : 0,
      tempDeciC: (temp * 10).round(),
      odometerM: odometerM,
      tripDistanceM: _ride.distanceM.round(),
      satellites: _ride.satellites,
      lights: lights,
    );
  }

  /// Verarbeitet einen Befehl und sendet die Antworten über [send].
  void handleCommand(Uint8List bytes, void Function(Uint8List packet) send) {
    final ZipCommand command;
    try {
      command = parseCommand(bytes);
    } on ZipCommandException catch (e) {
      send(encodeError(e.commandOpcode, e.code));
      return;
    }
    if (_busy) {
      send(encodeError(bytes[0], ZipErrorCode.busy));
      return;
    }
    switch (command) {
      case ListTripsCommand():
        unawaited(_sendList(send));
      case ReadTripCommand(:final tripId, :final offset, :final maxChunks):
        unawaited(_sendChunks(tripId, offset, maxChunks, send));
      case DeleteTripCommand(:final tripId):
        final before = trips.length;
        trips.removeWhere((t) => t.entry.tripId == tripId);
        if (trips.length == before) {
          send(encodeError(ZipOpcode.deleteTrip, ZipErrorCode.tripNotFound));
        } else {
          sdFreeMb += 1;
          send(encodeAck(ZipOpcode.deleteTrip, 0));
        }
      case SetOdometerCommand(:final meters):
        odometerM = meters;
        send(encodeAck(ZipOpcode.setOdometer, 0));
      case SetTempLimitCommand(:final celsius):
        if (celsius < 50 || celsius > 400) {
          send(encodeAck(ZipOpcode.setTempLimit, 1));
        } else {
          tempLimitC = celsius;
          send(encodeAck(ZipOpcode.setTempLimit, 0));
        }
      case ReadInfoCommand():
        send(
          encodeInfo(
            DeviceInfo(
              protocolVersion: kProtocolVersion,
              firmwareVersion: firmwareVersion,
              tempLimitC: tempLimitC,
              odometerM: odometerM,
              sdFreeMb: sdFreeMb,
            ),
          ),
        );
    }
  }

  Future<void> _sendList(void Function(Uint8List) send) async {
    final generation = ++_streamGeneration;
    _busy = true;
    try {
      for (final t in List.of(trips)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (generation != _streamGeneration) return;
        send(encodeTripEntry(t.entry));
      }
      send(encodeListEnd(trips.length));
    } finally {
      if (generation == _streamGeneration) _busy = false;
    }
  }

  Future<void> _sendChunks(
    int tripId,
    int offset,
    int maxChunks,
    void Function(Uint8List) send,
  ) async {
    final trip = trips.where((t) => t.entry.tripId == tripId).firstOrNull;
    if (trip == null) {
      send(encodeError(ZipOpcode.readTrip, ZipErrorCode.tripNotFound));
      return;
    }
    final file = trip.file;
    if (offset > file.length) {
      send(encodeError(ZipOpcode.readTrip, ZipErrorCode.wrongLength));
      return;
    }
    final generation = ++_streamGeneration;
    _busy = true;
    try {
      var pos = offset;
      for (var i = 0; i < maxChunks && pos < file.length; i++) {
        await Future<void>.delayed(chunkDelay);
        if (generation != _streamGeneration) return;
        final end = math.min(pos + chunkSize, file.length);
        final dropped = dropRate > 0 && _random.nextDouble() < dropRate;
        if (dropped) {
          droppedChunks++;
        } else {
          send(encodeChunk(tripId, pos, Uint8List.sublistView(file, pos, end)));
        }
        pos = end;
      }
      if (pos >= file.length) {
        await Future<void>.delayed(chunkDelay);
        if (generation != _streamGeneration) return;
        send(encodeEndOfFile(tripId, file.length, trip.crc32));
      }
    } finally {
      if (generation == _streamGeneration) _busy = false;
    }
  }
}

/// Live-Fahrsimulation: Stadtfahrt 0–60 km/h mit Ampelstopps, Motor wird
/// warm, gelegentliche Steigungen treiben die Temperatur über die Warngrenze.
class _LiveRide {
  double speedKmh = 0;
  double tempC = 38;
  double distanceM = 0;
  bool tripRunning = false;
  bool gpsFix = false;
  int satellites = 0;

  double _gpsTimer = 0;
  double _phaseTimer = 4;
  double _targetKmh = 0;
  _Phase _phase = _Phase.stopped;
  double _hillTimer = 0;
  double _nextHill = 70;
  double _satTimer = 0;

  void resetGps() {
    gpsFix = false;
    satellites = 0;
    _gpsTimer = 0;
  }

  void step(double dt, math.Random rnd) {
    // GPS: erst nach einigen Sekunden ein Fix.
    _gpsTimer += dt;
    _satTimer += dt;
    if (!gpsFix) {
      satellites = math.min(3, (_gpsTimer * 0.8).floor());
      if (_gpsTimer > 4) {
        gpsFix = true;
        satellites = 8;
      }
    } else if (_satTimer > 3) {
      _satTimer = 0;
      satellites = (satellites + rnd.nextInt(3) - 1).clamp(6, 12);
    }

    // Fahrphasen.
    _phaseTimer -= dt;
    switch (_phase) {
      case _Phase.stopped:
        speedKmh = math.max(0, speedKmh - 12 * dt);
        if (_phaseTimer <= 0) {
          _phase = _Phase.accelerating;
          _targetKmh = 28 + rnd.nextDouble() * 32; // 28–60 km/h
        }
      case _Phase.accelerating:
        speedKmh += (6 + rnd.nextDouble() * 3) * dt * (1 - speedKmh / 75);
        if (speedKmh >= _targetKmh) {
          _phase = _Phase.cruising;
          _phaseTimer = 8 + rnd.nextDouble() * 20;
        }
      case _Phase.cruising:
        speedKmh += (rnd.nextDouble() - 0.5) * 2.4 * dt * 5;
        speedKmh = speedKmh.clamp(_targetKmh - 3, math.min(_targetKmh + 3, 62));
        if (_phaseTimer <= 0) {
          if (rnd.nextDouble() < 0.45) {
            _phase = _Phase.braking;
            _targetKmh = 0;
          } else {
            _phase = _Phase.accelerating;
            _targetKmh = 25 + rnd.nextDouble() * 35;
            if (_targetKmh < speedKmh) _phase = _Phase.braking;
          }
        }
      case _Phase.braking:
        speedKmh -= (9 + rnd.nextDouble() * 4) * dt;
        if (speedKmh <= _targetKmh) {
          speedKmh = math.max(0, _targetKmh);
          if (_targetKmh <= 0) {
            _phase = _Phase.stopped;
            _phaseTimer = 5 + rnd.nextDouble() * 15;
          } else {
            _phase = _Phase.cruising;
            _phaseTimer = 6 + rnd.nextDouble() * 12;
          }
        }
    }
    speedKmh = speedKmh.clamp(0, 65);
    if (speedKmh > 1) tripRunning = true;
    distanceM += speedKmh / 3.6 * dt;

    // Gelegentliche Steigung → mehr Last → heißer.
    _nextHill -= dt;
    if (_nextHill <= 0) {
      _hillTimer = 20 + rnd.nextDouble() * 15;
      _nextHill = 80 + rnd.nextDouble() * 70;
    }
    final hill = _hillTimer > 0 ? 45.0 : 0.0;
    if (_hillTimer > 0) _hillTimer -= dt;

    // Zylinderkopf nähert sich einer lastabhängigen Zieltemperatur an.
    final moving = speedKmh > 3;
    final target = moving ? 105 + speedKmh * 2.0 + hill : 125.0;
    final tau = target > tempC ? 35.0 : 70.0;
    tempC += (target - tempC) * dt / tau + (rnd.nextDouble() - 0.5) * 0.3;
  }
}

enum _Phase { stopped, accelerating, cruising, braking }

// ---------------------------------------------------------------------------
// Beispielfahrten
// ---------------------------------------------------------------------------

/// Eine Fahrt auf der emulierten SD-Karte.
class DemoTrip {
  DemoTrip(this.entry, this.file) : crc32 = Crc32.compute(file);

  final TripEntry entry;
  final Uint8List file;
  final int crc32;
}

/// Erzeugt realistische Beispielfahrten mit Route, Geschwindigkeit und
/// Temperaturverlauf (deterministisch über den Seed).
class DemoTripGenerator {
  DemoTripGenerator({int seed = 42, DateTime? now})
    : _rnd = math.Random(seed),
      _now = now ?? DateTime.now();

  final math.Random _rnd;
  final DateTime _now;

  /// Ausgangspunkt der Beispielrouten.
  static const double _baseLat = 51.3155;
  static const double _baseLon = 9.4876;

  List<DemoTrip> generate() {
    final today = DateTime(_now.year, _now.month, _now.day);
    final specs = <_TripSpec>[
      _TripSpec(
        id: 101,
        start: today.subtract(const Duration(days: 34)).add(const Duration(hours: 15, minutes: 12)),
        lengthM: 21500,
        cruiseKmh: 55,
        stopSpacingM: 2200,
        hot: true,
      ),
      _TripSpec(
        id: 102,
        start: today.subtract(const Duration(days: 9)).add(const Duration(hours: 7, minutes: 41)),
        lengthM: 6300,
        cruiseKmh: 45,
        noFixAtStart: true,
      ),
      _TripSpec(
        id: 103,
        start: today.subtract(const Duration(days: 3)).add(const Duration(hours: 18, minutes: 5)),
        lengthM: 13800,
        cruiseKmh: 50,
        stopSpacingM: 1100,
        sensorGlitch: true,
      ),
      _TripSpec(
        id: 104,
        start: today.subtract(const Duration(days: 1)).add(const Duration(hours: 10, minutes: 27)),
        lengthM: 2400,
        cruiseKmh: 38,
        warmStart: true,
      ),
    ];
    return [for (final s in specs) _build(s)];
  }

  DemoTrip _build(_TripSpec spec) {
    final path = _buildPath(spec.lengthM);
    final points = _simulate(spec, path);
    final startUnix = spec.start.toUtc().millisecondsSinceEpoch ~/ 1000;
    final file = encodeTripFile(tripId: spec.id, startUnix: startUnix, points: points);

    var distance = 0.0;
    TripPoint? last;
    var maxSpeed = 0;
    var maxTemp = kInvalidTemperature;
    for (final p in points) {
      if (p.hasPosition) {
        if (last != null) distance += haversineMeters(last.lat, last.lon, p.lat, p.lon);
        last = p;
      }
      maxSpeed = math.max(maxSpeed, p.speedDeciKmh);
      if (p.tempDeciC != kInvalidTemperature) maxTemp = math.max(maxTemp, p.tempDeciC);
    }

    return DemoTrip(
      TripEntry(
        tripId: spec.id,
        startUnix: startUnix,
        durationS: points.last.timeMs ~/ 1000,
        distanceM: distance.round(),
        maxSpeedDeciKmh: maxSpeed,
        maxTempDeciC: maxTemp,
        pointCount: points.length,
        fileSize: file.length,
      ),
      file,
    );
  }

  /// Stadtähnlicher Streckenverlauf: gerade Abschnitte auf einem leicht
  /// gedrehten Raster mit Abbiegungen. Liefert Punkte in Metern (x Ost, y Nord).
  List<math.Point<double>> _buildPath(double lengthM) {
    const gridAngle = 0.3; // Rasterdrehung in Radiant
    final start = math.Point<double>(
      (_rnd.nextDouble() - 0.5) * 1500,
      (_rnd.nextDouble() - 0.5) * 1500,
    );
    final pts = <math.Point<double>>[start];
    var heading = _rnd.nextInt(4);
    var total = 0.0;
    var pos = start;
    while (total < lengthM) {
      final seg = 180 + _rnd.nextDouble() * 650;
      final a = gridAngle + heading * math.pi / 2;
      // Leichte Krümmung, damit es nicht wie ein Schachbrett aussieht.
      const steps = 6;
      final bend = (_rnd.nextDouble() - 0.5) * 0.25;
      for (var i = 1; i <= steps; i++) {
        final ai = a + bend * math.sin(i / steps * math.pi);
        pos = math.Point(pos.x + math.cos(ai) * seg / steps, pos.y + math.sin(ai) * seg / steps);
        pts.add(pos);
      }
      total += seg;
      // Abbiegen oder geradeaus, nicht umkehren; grob Richtung Ausgangsgebiet halten.
      final r = _rnd.nextDouble();
      final distFromOrigin = math.sqrt(pos.x * pos.x + pos.y * pos.y);
      if (distFromOrigin > 4500) {
        final toOrigin = math.atan2(-pos.y, -pos.x) - gridAngle;
        heading = ((toOrigin / (math.pi / 2)).round()) % 4;
      } else if (r < 0.35) {
        heading = (heading + 1) % 4;
      } else if (r < 0.7) {
        heading = (heading + 3) % 4;
      }
    }
    return pts;
  }

  List<TripPoint> _simulate(_TripSpec spec, List<math.Point<double>> path) {
    // Kumulierte Distanz entlang des Pfads.
    final cum = <double>[0];
    for (var i = 1; i < path.length; i++) {
      cum.add(cum.last + path[i].distanceTo(path[i - 1]));
    }
    final total = cum.last;

    // Stopps (Ampeln) an zufälligen Stellen.
    final stops = <double>[];
    for (var d = 400.0; d < total - 200; d += spec.stopSpacingM * (0.5 + _rnd.nextDouble())) {
      if (_rnd.nextDouble() < 0.6) stops.add(d);
    }

    final points = <TripPoint>[];
    var s = 0.0; // Position entlang des Pfads (m)
    var v = 0.0; // m/s
    var temp = spec.warmStart ? 150.0 : 32.0;
    var t = 0;
    var stopWait = 0;
    var stopIndex = 0;
    var hill = 0;
    final cruise = spec.cruiseKmh / 3.6;

    while (s < total) {
      // Zielgeschwindigkeit: vor dem nächsten Stopp bremsen.
      var target = cruise + math.sin(t / 37) * 2.5;
      if (stopIndex < stops.length) {
        final dStop = stops[stopIndex] - s;
        final brakeV = math.sqrt(math.max(0, 2 * 2.6 * dStop));
        target = math.min(target, brakeV);
        if (dStop <= 2) {
          if (stopWait == 0) stopWait = 5 + _rnd.nextInt(20);
          target = 0;
        }
      }
      if (stopWait > 0) {
        v = 0;
        stopWait--;
        if (stopWait == 0) stopIndex++;
      } else if (v < target) {
        v = math.min(target, v + 2.1 * (1 - v / 20));
      } else {
        v = math.max(target, v - 3.0);
      }
      s += v;

      if (hill <= 0 && _rnd.nextDouble() < (spec.hot ? 0.012 : 0.004)) hill = 25 + _rnd.nextInt(30);
      final hillBonus = hill > 0 ? (spec.hot ? 36.0 : 28.0) : 0.0;
      if (hill > 0) hill--;
      final kmh = v * 3.6;
      final tempTarget = kmh > 3 ? 105 + kmh * 2.2 + hillBonus : 120.0;
      final tau = tempTarget > temp ? 40.0 : 75.0;
      temp += (tempTarget - temp) / tau + (_rnd.nextDouble() - 0.5) * 0.6;

      final pos = _pointAt(path, cum, math.min(s, total));
      final jitterX = (_rnd.nextDouble() - 0.5) * 3;
      final jitterY = (_rnd.nextDouble() - 0.5) * 3;
      final latLon = _toLatLon(pos.x + jitterX, pos.y + jitterY);

      final noFix = spec.noFixAtStart && t < 4;
      final glitch = spec.sensorGlitch && t >= 300 && t < 312;
      points.add(
        TripPoint(
          latE7: noFix ? 0 : (latLon.$1 * 1e7).round(),
          lonE7: noFix ? 0 : (latLon.$2 * 1e7).round(),
          timeMs: t * 1000,
          speedDeciKmh: noFix
              ? 0
              : (kmh * 10 + (_rnd.nextDouble() - 0.5) * 6).round().clamp(0, 900),
          tempDeciC: glitch ? kInvalidTemperature : (temp * 10).round(),
        ),
      );
      t++;
      if (t > 4 * 3600) break; // Sicherheitsnetz
    }
    // Ausrollen bis zum Stillstand.
    for (var i = 0; i < 3; i++) {
      final p = points.last;
      points.add(
        TripPoint(
          latE7: p.latE7,
          lonE7: p.lonE7,
          timeMs: p.timeMs + 1000,
          speedDeciKmh: 0,
          tempDeciC: p.tempDeciC == kInvalidTemperature ? kInvalidTemperature : p.tempDeciC - 5,
        ),
      );
    }
    return points;
  }

  math.Point<double> _pointAt(List<math.Point<double>> path, List<double> cum, double s) {
    var lo = 0;
    var hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segLen = cum[hi] - cum[lo];
    final f = segLen <= 0 ? 0.0 : (s - cum[lo]) / segLen;
    return math.Point(
      path[lo].x + (path[hi].x - path[lo].x) * f,
      path[lo].y + (path[hi].y - path[lo].y) * f,
    );
  }

  (double, double) _toLatLon(double x, double y) {
    const metersPerDegLat = 111320.0;
    final metersPerDegLon = metersPerDegLat * math.cos(_baseLat * math.pi / 180);
    return (_baseLat + y / metersPerDegLat, _baseLon + x / metersPerDegLon);
  }
}

@immutable
class _TripSpec {
  const _TripSpec({
    required this.id,
    required this.start,
    required this.lengthM,
    required this.cruiseKmh,
    this.stopSpacingM = 700,
    this.hot = false,
    this.noFixAtStart = false,
    this.sensorGlitch = false,
    this.warmStart = false,
  });

  final int id;
  final DateTime start;
  final double lengthM;
  final double cruiseKmh;

  /// Mittlerer Abstand möglicher Stopps (Ampeln, Kreuzungen).
  final double stopSpacingM;
  final bool hot;
  final bool noFixAtStart;
  final bool sensorGlitch;
  final bool warmStart;
}
