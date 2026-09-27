import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Wert für „Temperatur ungültig“ in allen int16-Temperaturfeldern.
const int kInvalidTemperature = -32768;

// ---------------------------------------------------------------------------
// Licht
// ---------------------------------------------------------------------------

/// Die drei schaltbaren Lichtkanäle mit ihrem Bit im Lichtzustand.
enum LightChannel {
  parking(0x01, 'Standlicht'),
  headlight(0x02, 'Scheinwerfer'),
  hazard(0x04, 'Warnblinker');

  const LightChannel(this.bit, this.label);

  final int bit;
  final String label;
}

/// Lichtzustand als Bitfeld (Bit0 Standlicht, Bit1 Scheinwerfer, Bit2 Warnblinker).
@immutable
class LightState {
  const LightState(int bits) : bits = bits & mask;

  static const int mask = 0x07;
  static const LightState off = LightState(0);

  final int bits;

  bool isOn(LightChannel channel) => bits & channel.bit != 0;
  bool get parking => isOn(LightChannel.parking);
  bool get headlight => isOn(LightChannel.headlight);
  bool get hazard => isOn(LightChannel.hazard);

  LightState withChannel(LightChannel channel, bool on) =>
      LightState(on ? bits | channel.bit : bits & ~channel.bit);

  @override
  bool operator ==(Object other) => other is LightState && other.bits == bits;

  @override
  int get hashCode => bits.hashCode;

  @override
  String toString() => 'LightState(0b${bits.toRadixString(2).padLeft(3, '0')})';
}

// ---------------------------------------------------------------------------
// Telemetrie
// ---------------------------------------------------------------------------

/// Bits im Flag-Byte der Telemetrie.
abstract final class TelemetryFlags {
  static const int gpsFix = 0x01;
  static const int tempWarning = 0x02;
  static const int sdOk = 0x04;
  static const int tripRunning = 0x08;
  static const int tempSensorFault = 0x10;
  static const int simulation = 0x20;
}

/// Ein Telemetrie-Paket (16 Bytes, 5 Hz).
@immutable
class Telemetry {
  const Telemetry({
    required this.protocolVersion,
    required this.flags,
    required this.speedDeciKmh,
    required this.tempDeciC,
    required this.odometerM,
    required this.tripDistanceM,
    required this.satellites,
    required this.lights,
  });

  final int protocolVersion;
  final int flags;

  /// Geschwindigkeit in 0,1 km/h.
  final int speedDeciKmh;

  /// Zylinderkopftemperatur in 0,1 °C, [kInvalidTemperature] = ungültig.
  final int tempDeciC;
  final int odometerM;
  final int tripDistanceM;
  final int satellites;
  final LightState lights;

  bool get gpsFix => flags & TelemetryFlags.gpsFix != 0;
  bool get tempWarning => flags & TelemetryFlags.tempWarning != 0;
  bool get sdOk => flags & TelemetryFlags.sdOk != 0;
  bool get tripRunning => flags & TelemetryFlags.tripRunning != 0;
  bool get tempSensorFault => flags & TelemetryFlags.tempSensorFault != 0;
  bool get simulation => flags & TelemetryFlags.simulation != 0;

  double get speedKmh => speedDeciKmh / 10.0;

  /// Temperatur in °C oder `null`, wenn ungültig bzw. Sensorfehler.
  double? get tempC =>
      tempSensorFault || tempDeciC == kInvalidTemperature ? null : tempDeciC / 10.0;

  @override
  bool operator ==(Object other) =>
      other is Telemetry &&
      other.protocolVersion == protocolVersion &&
      other.flags == flags &&
      other.speedDeciKmh == speedDeciKmh &&
      other.tempDeciC == tempDeciC &&
      other.odometerM == odometerM &&
      other.tripDistanceM == tripDistanceM &&
      other.satellites == satellites &&
      other.lights == lights;

  @override
  int get hashCode => Object.hash(
    protocolVersion,
    flags,
    speedDeciKmh,
    tempDeciC,
    odometerM,
    tripDistanceM,
    satellites,
    lights,
  );
}

// ---------------------------------------------------------------------------
// Fahrten auf dem Roller
// ---------------------------------------------------------------------------

/// Eindeutiger Schlüssel einer Fahrt. Die tripId allein reicht nicht,
/// falls die SD-Karte formatiert wird und die Zählung neu beginnt.
@immutable
class TripKey {
  const TripKey(this.tripId, this.startUnix);

  final int tripId;
  final int startUnix;

  @override
  bool operator ==(Object other) =>
      other is TripKey && other.tripId == tripId && other.startUnix == startUnix;

  @override
  int get hashCode => Object.hash(tripId, startUnix);

  @override
  String toString() => 'TripKey($tripId, $startUnix)';
}

/// Eintrag aus der Fahrtenliste des Rollers (Antwort 0x81).
@immutable
class TripEntry {
  const TripEntry({
    required this.tripId,
    required this.startUnix,
    required this.durationS,
    required this.distanceM,
    required this.maxSpeedDeciKmh,
    required this.maxTempDeciC,
    required this.pointCount,
    required this.fileSize,
  });

  final int tripId;
  final int startUnix;
  final int durationS;
  final int distanceM;
  final int maxSpeedDeciKmh;
  final int maxTempDeciC;
  final int pointCount;
  final int fileSize;

  TripKey get key => TripKey(tripId, startUnix);

  @override
  bool operator ==(Object other) =>
      other is TripEntry &&
      other.tripId == tripId &&
      other.startUnix == startUnix &&
      other.durationS == durationS &&
      other.distanceM == distanceM &&
      other.maxSpeedDeciKmh == maxSpeedDeciKmh &&
      other.maxTempDeciC == maxTempDeciC &&
      other.pointCount == pointCount &&
      other.fileSize == fileSize;

  @override
  int get hashCode => Object.hash(
    tripId,
    startUnix,
    durationS,
    distanceM,
    maxSpeedDeciKmh,
    maxTempDeciC,
    pointCount,
    fileSize,
  );
}

/// Einstellungen und Info vom Roller (Antwort 0x86).
@immutable
class DeviceInfo {
  const DeviceInfo({
    required this.protocolVersion,
    required this.firmwareVersion,
    required this.tempLimitC,
    required this.odometerM,
    required this.sdFreeMb,
  });

  final int protocolVersion;

  /// Drei Bytes: Major, Minor, Patch.
  final List<int> firmwareVersion;
  final int tempLimitC;
  final int odometerM;
  final int sdFreeMb;

  String get firmwareString => firmwareVersion.join('.');
}

// ---------------------------------------------------------------------------
// Fahrtdatei
// ---------------------------------------------------------------------------

/// Ein Messpunkt aus der Fahrtdatei (16 Bytes).
@immutable
class TripPoint {
  const TripPoint({
    required this.latE7,
    required this.lonE7,
    required this.timeMs,
    required this.speedDeciKmh,
    required this.tempDeciC,
  });

  final int latE7;
  final int lonE7;

  /// Millisekunden seit Fahrtbeginn.
  final int timeMs;
  final int speedDeciKmh;
  final int tempDeciC;

  double get lat => latE7 / 1e7;
  double get lon => lonE7 / 1e7;
  double get speedKmh => speedDeciKmh / 10.0;
  double? get tempC => tempDeciC == kInvalidTemperature ? null : tempDeciC / 10.0;

  /// 0/0 steht für „noch kein GPS-Fix“; außerdem gültigen Wertebereich prüfen.
  bool get hasPosition =>
      !(latE7 == 0 && lonE7 == 0) && latE7.abs() <= 900000000 && lonE7.abs() <= 1800000000;
}

/// Eine vollständig geparste Fahrtdatei.
@immutable
class TripFile {
  const TripFile({
    required this.formatVersion,
    required this.tripId,
    required this.startUnix,
    required this.points,
    this.trailingBytes = 0,
  });

  final int formatVersion;
  final int tripId;
  final int startUnix;
  final List<TripPoint> points;

  /// Unvollständiger letzter Datensatz (wird ignoriert).
  final int trailingBytes;

  DateTime get startUtc => DateTime.fromMillisecondsSinceEpoch(startUnix * 1000, isUtc: true);
}

// ---------------------------------------------------------------------------
// Lokal gespeicherte Fahrten
// ---------------------------------------------------------------------------

/// Zusammenfassung einer lokal gespeicherten Fahrt (für Liste und Detail).
@immutable
class TripSummary {
  const TripSummary({
    required this.localId,
    required this.key,
    required this.durationS,
    required this.distanceM,
    required this.maxSpeedKmh,
    required this.maxTempC,
    required this.avgMovingSpeedKmh,
    required this.pointCount,
    required this.fileSize,
    required this.preview,
  });

  final int localId;
  final TripKey key;
  final int durationS;
  final int distanceM;
  final double maxSpeedKmh;
  final double? maxTempC;

  /// Durchschnitt nur über die Zeit mit mehr als 2 km/h.
  final double? avgMovingSpeedKmh;
  final int pointCount;
  final int fileSize;

  /// Normierte Streckenform (x/y abwechselnd, 0..1) für die Mini-Vorschau.
  final Float32List preview;

  DateTime get startLocal =>
      DateTime.fromMillisecondsSinceEpoch(key.startUnix * 1000, isUtc: true).toLocal();
}

/// Fahrt mit allen Punkten für die Detailansicht.
@immutable
class TripDetail {
  const TripDetail({required this.summary, required this.points});

  final TripSummary summary;
  final List<TripPoint> points;
}

// ---------------------------------------------------------------------------
// Einstellungen
// ---------------------------------------------------------------------------

/// Mögliche Skalenenden des Tachos.
const List<int> kGaugeMaxOptions = [60, 80, 100, 120];

/// Einstellbereich der Warngrenze Zylinderkopf.
const int kTempLimitMin = 180;
const int kTempLimitMax = 300;
const int kTempLimitStep = 5;

@immutable
class AppSettings {
  const AppSettings({
    this.gaugeMaxKmh = 80,
    this.tempLimitC = 240,
    this.tempLimitPending = false,
    this.deleteAfterTransfer = false,
    this.demoMode = false,
    this.permissionsExplained = false,
  });

  final int gaugeMaxKmh;
  final int tempLimitC;

  /// Warngrenze wurde lokal geändert, aber noch nicht vom Roller bestätigt.
  final bool tempLimitPending;
  final bool deleteAfterTransfer;
  final bool demoMode;

  /// Der Hinweis vor der Bluetooth-Berechtigung wurde bereits gezeigt.
  final bool permissionsExplained;

  AppSettings copyWith({
    int? gaugeMaxKmh,
    int? tempLimitC,
    bool? tempLimitPending,
    bool? deleteAfterTransfer,
    bool? demoMode,
    bool? permissionsExplained,
  }) {
    return AppSettings(
      gaugeMaxKmh: gaugeMaxKmh ?? this.gaugeMaxKmh,
      tempLimitC: tempLimitC ?? this.tempLimitC,
      tempLimitPending: tempLimitPending ?? this.tempLimitPending,
      deleteAfterTransfer: deleteAfterTransfer ?? this.deleteAfterTransfer,
      demoMode: demoMode ?? this.demoMode,
      permissionsExplained: permissionsExplained ?? this.permissionsExplained,
    );
  }

  /// Warngrenze auf den gültigen Bereich und das 5er-Raster bringen.
  static int clampTempLimit(int value) {
    final clamped = value.clamp(kTempLimitMin, kTempLimitMax);
    return (clamped / kTempLimitStep).round() * kTempLimitStep;
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.gaugeMaxKmh == gaugeMaxKmh &&
      other.tempLimitC == tempLimitC &&
      other.tempLimitPending == tempLimitPending &&
      other.deleteAfterTransfer == deleteAfterTransfer &&
      other.demoMode == demoMode &&
      other.permissionsExplained == permissionsExplained;

  @override
  int get hashCode => Object.hash(
    gaugeMaxKmh,
    tempLimitC,
    tempLimitPending,
    deleteAfterTransfer,
    demoMode,
    permissionsExplained,
  );
}

// ---------------------------------------------------------------------------
// Hilfsfunktionen
// ---------------------------------------------------------------------------

/// Entfernung zweier Punkte in Metern (Haversine).
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadius = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(a)));
}

double _rad(double deg) => deg * math.pi / 180.0;
