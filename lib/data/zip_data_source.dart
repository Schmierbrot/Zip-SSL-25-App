import 'package:flutter/foundation.dart';

/// Verbindungsstatus zur Zip.
enum LinkStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  bluetoothOff,

  /// Bluetooth-Berechtigung fehlt oder wurde abgelehnt.
  unauthorized,

  /// Gerät hat kein (nutzbares) Bluetooth LE.
  unsupported,
}

@immutable
class ZipLinkState {
  const ZipLinkState({
    this.status = LinkStatus.disconnected,
    this.reconnecting = false,
    this.deviceName,
    this.deviceId,
    this.savedDeviceId,
    this.savedDeviceName,
  });

  final LinkStatus status;

  /// Automatischer Wiederverbindungsversuch läuft (zwischen zwei Versuchen).
  final bool reconnecting;

  /// Aktuell verbundenes bzw. angesprochenes Gerät.
  final String? deviceName;
  final String? deviceId;

  /// Gespeichertes Gerät für das automatische Verbinden beim Start.
  final String? savedDeviceId;
  final String? savedDeviceName;

  bool get isConnected => status == LinkStatus.connected;

  /// Scannen, Verbinden oder Warten auf die nächste Wiederverbindung.
  bool get isBusy =>
      status == LinkStatus.scanning ||
      status == LinkStatus.connecting ||
      (status == LinkStatus.disconnected && reconnecting);

  /// Bluetooth ist grundsätzlich nicht nutzbar (aus, verboten, fehlt).
  bool get isBlocked =>
      status == LinkStatus.bluetoothOff ||
      status == LinkStatus.unauthorized ||
      status == LinkStatus.unsupported;

  ZipLinkState copyWith({
    LinkStatus? status,
    bool? reconnecting,
    String? deviceName,
    String? deviceId,
    String? savedDeviceId,
    String? savedDeviceName,
    bool clearDevice = false,
    bool clearSaved = false,
  }) {
    return ZipLinkState(
      status: status ?? this.status,
      reconnecting: reconnecting ?? this.reconnecting,
      deviceName: clearDevice ? null : (deviceName ?? this.deviceName),
      deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
      savedDeviceId: clearSaved ? null : (savedDeviceId ?? this.savedDeviceId),
      savedDeviceName: clearSaved ? null : (savedDeviceName ?? this.savedDeviceName),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ZipLinkState &&
      other.status == status &&
      other.reconnecting == reconnecting &&
      other.deviceName == deviceName &&
      other.deviceId == deviceId &&
      other.savedDeviceId == savedDeviceId &&
      other.savedDeviceName == savedDeviceName;

  @override
  int get hashCode =>
      Object.hash(status, reconnecting, deviceName, deviceId, savedDeviceId, savedDeviceName);
}

/// Arten von einmaligen Hinweisen an die Oberfläche.
enum ZipNoticeKind {
  firmwareMismatch,
  pairingFailed,
  permissionDenied,
  locationServicesOff,
  bluetoothOff,
  deviceNotFound,
  notAZip,
  connectionFailed,
  info,
}

@immutable
class ZipNotice {
  const ZipNotice(this.kind, this.message);

  final ZipNoticeKind kind;
  final String message;

  static const firmwareMismatch = ZipNotice(
    ZipNoticeKind.firmwareMismatch,
    'Firmware-Version passt nicht zur App',
  );
  static const pairingFailed = ZipNotice(
    ZipNoticeKind.pairingFailed,
    'Kopplung fehlgeschlagen – PIN prüfen',
  );
}

/// Abstraktion über die Datenquelle: echtes BLE ([ZipConnection]) oder
/// Demo-Modus ([DemoSource]). Die Quelle liefert rohe Pakete genau wie
/// die Characteristics der Firmware – Parsen, Befehlswarteschlange und
/// Fahrten-Synchronisation laufen darüber identisch für beide Varianten.
abstract class ZipDataSource {
  bool get isDemo;

  ZipLinkState get state;

  /// Änderungen des Verbindungsstatus (ohne Startwert – [state] lesen).
  Stream<ZipLinkState> get states;

  /// Rohdaten der Telemetrie-Characteristic (0002).
  Stream<Uint8List> get telemetryPackets;

  /// Rohdaten der Licht-Characteristic (0003).
  Stream<Uint8List> get lightPackets;

  /// Rohdaten der Antwort-Characteristic (0006).
  Stream<Uint8List> get responsePackets;

  /// Einmalige Hinweise (Kopplung fehlgeschlagen, Berechtigung fehlt …).
  Stream<ZipNotice> get notices;

  /// Initialisieren und – falls ein Gerät gespeichert ist – automatisch verbinden.
  Future<void> start();

  /// Verbinden: gespeichertes Gerät direkt, sonst Scan.
  Future<void> connect();

  /// Immer neu suchen und mit dem ersten gefundenen Gerät verbinden.
  Future<void> scanAndConnect();

  /// Trennen und automatisches Wiederverbinden beenden.
  Future<void> disconnect();

  /// Gespeichertes Gerät vergessen und trennen.
  Future<void> forgetDevice();

  /// Lichtzustand schreiben (1 Byte).
  Future<void> writeLights(int bits);

  /// Lichtzustand lesen. Der Wert erscheint zusätzlich in [lightPackets].
  Future<void> readLights();

  /// Befehl an die Steuer-Characteristic (0005) schreiben.
  Future<void> writeControl(Uint8List command);

  /// Kann die App Bluetooth selbst einschalten (nur Android)?
  bool get canTurnOnBluetooth;

  Future<void> turnOnBluetooth();

  /// App im Vorder-/Hintergrund – Auto-Reconnect nur im Vordergrund.
  void setForeground(bool foreground);

  Future<void> dispose();
}
