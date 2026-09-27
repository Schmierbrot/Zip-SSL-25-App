import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../data/zip_data_source.dart';
import 'command_queue.dart';
import 'zip_protocol.dart';

/// Echte BLE-Verbindung zur Zip über flutter_blue_plus.
///
/// Aufgaben: Scannen (Filter auf die Service-UUID), Verbinden, MTU 247
/// (Android), Kopplung mit Passkey, Service-Discovery, Notifies abonnieren,
/// gespeichertes Gerät beim Start direkt verbinden (ohne Scan) und
/// Auto-Reconnect, solange die App im Vordergrund ist.
class ZipConnection implements ZipDataSource {
  ZipConnection(this._prefs)
    : _state = ZipLinkState(
        savedDeviceId: _prefs.getString(_kRemoteId),
        savedDeviceName: _prefs.getString(_kDeviceName),
      );

  static const _kRemoteId = 'zip.remoteId';
  static const _kDeviceName = 'zip.deviceName';

  static const Duration _connectTimeout = Duration(seconds: 12);
  static const Duration _scanTimeout = Duration(seconds: 15);
  static const int _mtu = 247;

  /// Wartezeiten zwischen automatischen Wiederverbindungsversuchen.
  static const List<int> _reconnectDelaysS = [1, 2, 4, 8, 15];

  final SharedPreferences _prefs;
  ZipLinkState _state;

  final StreamController<ZipLinkState> _states = StreamController.broadcast();
  final StreamController<Uint8List> _telemetry = StreamController.broadcast();
  final StreamController<Uint8List> _light = StreamController.broadcast();
  final StreamController<Uint8List> _response = StreamController.broadcast();
  final StreamController<ZipNotice> _notices = StreamController.broadcast();

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  final List<StreamSubscription<List<int>>> _sessionSubs = [];

  BluetoothDevice? _device;
  BluetoothCharacteristic? _lightChar;
  BluetoothCharacteristic? _controlChar;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool _started = false;
  bool _disposed = false;
  bool _foreground = true;
  bool _connecting = false;

  /// Der Nutzer möchte verbunden sein → nach Abbrüchen neu verbinden.
  bool _wantConnection = false;

  /// Nach fehlgeschlagener Kopplung o. Ä. nicht endlos neu versuchen –
  /// erst wieder, wenn der Nutzer selbst auf „Verbinden“ tippt.
  bool _suspendAutoReconnect = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  // --- ZipDataSource --------------------------------------------------------

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
  bool get canTurnOnBluetooth => _isAndroid;

  /// Beim App-Start nur dann Bluetooth initialisieren, wenn ein Gerät
  /// gespeichert ist. Sonst erscheint die Berechtigungsabfrage (iOS) erst,
  /// nachdem die App erklärt hat, wozu sie Bluetooth braucht.
  @override
  Future<void> start() async {
    if (_state.savedDeviceId != null) await _initAdapter();
  }

  Future<void> _initAdapter() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      await FlutterBluePlus.setLogLevel(LogLevel.warning, color: false);
    } catch (_) {
      // Logging ist unkritisch.
    }
    bool supported;
    try {
      supported = await FlutterBluePlus.isSupported;
    } catch (_) {
      supported = false;
    }
    if (_disposed) return;
    if (!supported) {
      _emit(_state.copyWith(status: LinkStatus.unsupported));
      return;
    }
    _wantConnection = _wantConnection || _state.savedDeviceId != null;
    _adapterSub = FlutterBluePlus.adapterState.listen(
      _onAdapterState,
      onError: (Object e) => debugPrint('Adapterstatus nicht lesbar: $e'),
    );
  }

  @override
  Future<void> connect() async {
    _wantConnection = true;
    _suspendAutoReconnect = false;
    _reconnectAttempt = 0;
    if (_connecting || _state.status == LinkStatus.scanning) return;
    if (!await _ensureAdapterOn()) return;
    // Die automatische Verbindung kann inzwischen schon laufen.
    if (_connecting || _state.isConnected) return;

    final saved = _state.savedDeviceId;
    if (saved != null) {
      final ok = await _connectTo(BluetoothDevice.fromId(saved), name: _state.savedDeviceName);
      if (ok || _suspendAutoReconnect || _state.isBlocked) return;
      // Gespeichertes Gerät nicht erreichbar (z. B. neue Adresse) → neu suchen.
    }
    await _scanAndConnect();
  }

  @override
  Future<void> scanAndConnect() async {
    _wantConnection = true;
    _suspendAutoReconnect = false;
    _reconnectAttempt = 0;
    if (_connecting || _state.status == LinkStatus.scanning) return;
    if (!await _ensureAdapterOn()) return;
    if (_connecting) return;
    await _scanAndConnect();
  }

  @override
  Future<void> disconnect() async {
    _wantConnection = false;
    _cancelReconnect();
    await _stopScanQuietly();
    await _disconnectDevice();
    _emit(_state.copyWith(status: _idleStatus(), reconnecting: false));
  }

  @override
  Future<void> forgetDevice() async {
    final saved = _state.savedDeviceId;
    final device = _device ?? (saved == null ? null : BluetoothDevice.fromId(saved));
    await disconnect();
    if (device != null && _isAndroid) {
      try {
        await device.removeBond();
      } catch (e) {
        debugPrint('Kopplung konnte nicht entfernt werden: $e');
      }
    }
    await _prefs.remove(_kRemoteId);
    await _prefs.remove(_kDeviceName);
    await _connectionSub?.cancel();
    _connectionSub = null;
    _device = null;
    _emit(
      _state.copyWith(
        status: _idleStatus(),
        reconnecting: false,
        clearDevice: true,
        clearSaved: true,
      ),
    );
  }

  @override
  Future<void> writeLights(int bits) async {
    final c = _lightChar;
    if (c == null || !_state.isConnected) throw const ZipDisconnectedException();
    await c.write([bits & LightState.mask]);
  }

  @override
  Future<void> readLights() async {
    final c = _lightChar;
    if (c == null || !_state.isConnected) throw const ZipDisconnectedException();
    await c.read(); // Wert kommt über onValueReceived → lightPackets
  }

  @override
  Future<void> writeControl(Uint8List command) async {
    final c = _controlChar;
    if (c == null || !_state.isConnected) throw const ZipDisconnectedException();
    await c.write(command);
  }

  @override
  Future<void> turnOnBluetooth() async {
    if (!_isAndroid) return;
    try {
      await FlutterBluePlus.turnOn();
    } catch (e) {
      debugPrint('Bluetooth einschalten fehlgeschlagen: $e');
      if (_isPermissionError(e)) {
        _notices.add(_permissionNotice);
      }
    }
  }

  @override
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      _cancelReconnect();
      if (_state.reconnecting) _emit(_state.copyWith(reconnecting: false));
    } else if (!_state.isConnected) {
      _reconnectAttempt = 0;
      _scheduleReconnect(immediate: true);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _cancelReconnect();
    await _stopScanQuietly();
    await _disconnectDevice();
    _disposed = true;
    await _adapterSub?.cancel();
    await _connectionSub?.cancel();
    await _states.close();
    await _telemetry.close();
    await _light.close();
    await _response.close();
    await _notices.close();
  }

  // --- Adapter ----------------------------------------------------------------

  void _onAdapterState(BluetoothAdapterState s) {
    _adapterState = s;
    switch (s) {
      case BluetoothAdapterState.on:
        if (_state.isBlocked) _emit(_state.copyWith(status: LinkStatus.disconnected));
        if (_wantConnection && !_state.isConnected) {
          _reconnectAttempt = 0;
          _scheduleReconnect(immediate: true);
        }
      case BluetoothAdapterState.off:
      case BluetoothAdapterState.turningOff:
        _cancelReconnect();
        _emit(_state.copyWith(status: LinkStatus.bluetoothOff, reconnecting: false));
      case BluetoothAdapterState.unauthorized:
        _cancelReconnect();
        _emit(_state.copyWith(status: LinkStatus.unauthorized, reconnecting: false));
      case BluetoothAdapterState.unavailable:
        _cancelReconnect();
        _emit(_state.copyWith(status: LinkStatus.unsupported, reconnecting: false));
      case BluetoothAdapterState.unknown:
      case BluetoothAdapterState.turningOn:
        break;
    }
  }

  LinkStatus _idleStatus() {
    switch (_adapterState) {
      case BluetoothAdapterState.off:
      case BluetoothAdapterState.turningOff:
        return LinkStatus.bluetoothOff;
      case BluetoothAdapterState.unauthorized:
        return LinkStatus.unauthorized;
      case BluetoothAdapterState.unavailable:
        return LinkStatus.unsupported;
      default:
        return LinkStatus.disconnected;
    }
  }

  Future<bool> _ensureAdapterOn() async {
    await _initAdapter();
    if (_adapterState == BluetoothAdapterState.unknown ||
        _adapterState == BluetoothAdapterState.turningOn) {
      // iOS meldet den Zustand nach dem Start etwas verzögert.
      try {
        _adapterState = await FlutterBluePlus.adapterState
            .where(
              (s) => s != BluetoothAdapterState.unknown && s != BluetoothAdapterState.turningOn,
            )
            .first
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        // Weiter mit dem bekannten Zustand.
      }
    }
    switch (_adapterState) {
      case BluetoothAdapterState.on:
        return true;
      case BluetoothAdapterState.unauthorized:
        _emit(_state.copyWith(status: LinkStatus.unauthorized));
        _notices.add(_permissionNotice);
        return false;
      case BluetoothAdapterState.unavailable:
        _emit(_state.copyWith(status: LinkStatus.unsupported));
        return false;
      default:
        _emit(_state.copyWith(status: LinkStatus.bluetoothOff));
        _notices.add(const ZipNotice(ZipNoticeKind.bluetoothOff, 'Bluetooth ist ausgeschaltet.'));
        return false;
    }
  }

  // --- Scannen ----------------------------------------------------------------

  Future<void> _scanAndConnect() async {
    _cancelReconnect();
    _emit(_state.copyWith(status: LinkStatus.scanning, reconnecting: false));
    // Eine bestehende Verbindung zuerst trennen (Status „scanning“ verhindert,
    // dass der Trennungs-Handler einen Reconnect startet).
    await _disconnectDevice();

    ScanResult? found;
    try {
      found = await _scanForZip();
    } catch (e) {
      _handleScanError(e);
      return;
    }
    if (_disposed) return;
    if (found == null) {
      _emit(_state.copyWith(status: _idleStatus()));
      _notices.add(
        const ZipNotice(
          ZipNoticeKind.deviceNotFound,
          'Keine Zip gefunden. Ist der Roller eingeschaltet und in der Nähe?',
        ),
      );
      return;
    }
    final adv = found.advertisementData.advName;
    final platformName = found.device.platformName;
    final name = adv.isNotEmpty ? adv : (platformName.isNotEmpty ? platformName : kZipDeviceName);
    await _connectTo(found.device, name: name);
  }

  Future<ScanResult?> _scanForZip() async {
    final serviceGuid = Guid(ZipUuids.service);
    final found = Completer<ScanResult?>();
    final sub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final r in results) {
          final ad = r.advertisementData;
          final isZip = ad.serviceUuids.contains(serviceGuid) || ad.advName == kZipDeviceName;
          if (isZip && !found.isCompleted) found.complete(r);
        }
      },
      onError: (Object e) {
        if (!found.isCompleted) found.completeError(e);
      },
    );
    FlutterBluePlus.cancelWhenScanComplete(sub);
    try {
      await FlutterBluePlus.startScan(withServices: [serviceGuid], timeout: _scanTimeout);
      final stopped = FlutterBluePlus.isScanning.where((s) => !s).first.then((_) => null);
      return await Future.any<ScanResult?>([found.future, stopped]);
    } finally {
      await sub.cancel();
      await _stopScanQuietly();
    }
  }

  Future<void> _stopScanQuietly() async {
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {
      // Ignorieren – Scan ist ohnehin beendet.
    }
  }

  void _handleScanError(Object e) {
    debugPrint('Scan fehlgeschlagen: $e');
    final text = _errorText(e).toLowerCase();
    if (_isPermissionError(e)) {
      _emit(_state.copyWith(status: LinkStatus.unauthorized));
      _notices.add(_permissionNotice);
    } else if (text.contains('location services')) {
      _emit(_state.copyWith(status: LinkStatus.disconnected));
      _notices.add(
        const ZipNotice(
          ZipNoticeKind.locationServicesOff,
          'Bitte den Standort einschalten – Android 11 und älter braucht ihn für die Bluetooth-Suche.',
        ),
      );
    } else if (text.contains('turned on') || text.contains('adapter is off')) {
      _emit(_state.copyWith(status: LinkStatus.bluetoothOff));
    } else {
      _emit(_state.copyWith(status: _idleStatus()));
      _notices.add(
        const ZipNotice(
          ZipNoticeKind.connectionFailed,
          'Die Suche nach der Zip ist fehlgeschlagen. Bitte erneut versuchen.',
        ),
      );
    }
  }

  // --- Verbinden --------------------------------------------------------------

  /// Baut die Verbindung auf. Gibt `true` zurück, wenn verbunden.
  Future<bool> _connectTo(BluetoothDevice device, {String? name}) async {
    if (_connecting || _disposed) return false;
    _connecting = true;
    var ok = false;
    try {
      ok = await _doConnect(device, name: name);
    } finally {
      _connecting = false;
    }
    if (!ok) _scheduleReconnect();
    return ok;
  }

  Future<bool> _doConnect(BluetoothDevice device, {String? name}) async {
    _cancelReconnect();
    if (_device != device) {
      await _connectionSub?.cancel();
      _connectionSub = null;
    }
    _device = device;
    _listenConnection(device);
    final displayName = name ?? _state.savedDeviceName ?? kZipDeviceName;
    _emit(
      _state.copyWith(
        status: LinkStatus.connecting,
        reconnecting: false,
        deviceId: device.remoteId.str,
        deviceName: displayName,
      ),
    );

    try {
      // MTU nicht über connect() (Standard wäre 512), sondern gezielt 247.
      await device.connect(license: License.nonprofit, timeout: _connectTimeout, mtu: null);
      if (_isAndroid) {
        try {
          await device.requestMtu(_mtu);
        } catch (e) {
          debugPrint('MTU-Anfrage fehlgeschlagen (nicht kritisch): $e');
        }
        await _ensureBonded(device);
      }

      final services = await device.discoverServices();
      final serviceGuid = Guid(ZipUuids.service);
      final service = services.where((s) => s.uuid == serviceGuid).firstOrNull;
      if (service == null) throw const _NotAZipException();

      BluetoothCharacteristic? find(String uuid) {
        final guid = Guid(uuid);
        return service.characteristics.where((c) => c.uuid == guid).firstOrNull;
      }

      final telemetry = find(ZipUuids.telemetry);
      final light = find(ZipUuids.light);
      final control = find(ZipUuids.control);
      final response = find(ZipUuids.response);
      if (telemetry == null || light == null || control == null || response == null) {
        throw const _NotAZipException();
      }

      await _subscribe(device, [(telemetry, _telemetry), (light, _light), (response, _response)]);
      _lightChar = light;
      _controlChar = control;

      await _saveDevice(device.remoteId.str, displayName);
      _reconnectAttempt = 0;
      _emit(
        _state.copyWith(
          status: LinkStatus.connected,
          reconnecting: false,
          deviceId: device.remoteId.str,
          deviceName: displayName,
        ),
      );

      // Anfangswerte lesen – sie laufen über dieselben Notify-Streams.
      unawaited(_readQuietly(light));
      unawaited(_readQuietly(telemetry));
      return true;
    } catch (e) {
      await _handleConnectError(device, e);
      return false;
    }
  }

  Future<void> _readQuietly(BluetoothCharacteristic c) async {
    try {
      await c.read();
    } catch (e) {
      debugPrint('Lesen von ${c.uuid} fehlgeschlagen: $e');
    }
  }

  /// Android: Kopplung mit Passkey sicherstellen. Der Systemdialog zur
  /// PIN-Eingabe erscheint dabei automatisch.
  Future<void> _ensureBonded(BluetoothDevice device) async {
    final current = await device.bondState.first;
    if (current == BluetoothBondState.bonded) return;
    try {
      await device.createBond(timeout: 90);
    } catch (e) {
      throw _PairingException(e);
    }
    // Hat der Roller die Kopplung selbst angestoßen, kehrt createBond sofort
    // zurück – dann auf das Ende des Vorgangs warten.
    final result = await device.bondState
        .firstWhere((s) => s != BluetoothBondState.bonding)
        .timeout(const Duration(seconds: 90), onTimeout: () => BluetoothBondState.none);
    if (result != BluetoothBondState.bonded) throw _PairingException(result);
  }

  Future<void> _subscribe(
    BluetoothDevice device,
    List<(BluetoothCharacteristic, StreamController<Uint8List>)> targets,
  ) async {
    await _cancelSessionSubs();
    // Erst lauschen, dann Notify einschalten – so geht kein Paket verloren.
    for (final (char, sink) in targets) {
      final sub = char.onValueReceived.listen((value) {
        if (!sink.isClosed) sink.add(Uint8List.fromList(value));
      });
      device.cancelWhenDisconnected(sub);
      _sessionSubs.add(sub);
    }
    for (final (char, _) in targets) {
      // Großzügiges Timeout: auf iOS erscheint hier ggf. der Kopplungsdialog.
      await char.setNotifyValue(true, timeout: 60);
    }
  }

  Future<void> _cancelSessionSubs() async {
    final subs = List.of(_sessionSubs);
    _sessionSubs.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }

  Future<void> _handleConnectError(BluetoothDevice device, Object e) async {
    debugPrint('Verbindung fehlgeschlagen: $e');
    _lightChar = null;
    _controlChar = null;
    await _cancelSessionSubs();
    try {
      await device.disconnect();
    } catch (_) {
      // War vermutlich gar nicht verbunden.
    }
    if (_disposed) return;

    if (e is _PairingException || _looksLikePairingError(_errorText(e))) {
      _suspendAutoReconnect = true;
      _notices.add(ZipNotice.pairingFailed);
    } else if (e is _NotAZipException) {
      _suspendAutoReconnect = true;
      _notices.add(
        const ZipNotice(
          ZipNoticeKind.notAZip,
          'Das Gerät bietet den Zip-Dienst nicht an – Firmware-Version passt nicht zur App?',
        ),
      );
    } else if (_isPermissionError(e)) {
      _suspendAutoReconnect = true;
      _emit(_state.copyWith(status: LinkStatus.unauthorized, reconnecting: false));
      _notices.add(_permissionNotice);
      return;
    }
    _emit(_state.copyWith(status: _idleStatus(), reconnecting: false));
  }

  void _listenConnection(BluetoothDevice device) {
    if (_connectionSub != null) return;
    _connectionSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) _onDisconnected(device);
    });
  }

  void _onDisconnected(BluetoothDevice device) {
    if (_disposed || device != _device) return;
    final wasConnected = _state.isConnected;
    _lightChar = null;
    _controlChar = null;
    unawaited(_cancelSessionSubs());
    // Während des Aufbaus behandelt _doConnect die Fehler selbst.
    if (!wasConnected) return;

    final reason = device.disconnectReason;
    if (reason != null && _looksLikePairingError('${reason.code} ${reason.description}')) {
      _suspendAutoReconnect = true;
      _notices.add(ZipNotice.pairingFailed);
    }
    _emit(_state.copyWith(status: _idleStatus(), reconnecting: false));
    _scheduleReconnect();
  }

  Future<void> _disconnectDevice() async {
    final d = _device;
    _lightChar = null;
    _controlChar = null;
    await _cancelSessionSubs();
    if (d == null) return;
    try {
      await d.disconnect();
    } catch (e) {
      debugPrint('Trennen fehlgeschlagen: $e');
    }
  }

  Future<void> _saveDevice(String id, String name) async {
    await _prefs.setString(_kRemoteId, id);
    await _prefs.setString(_kDeviceName, name);
    _state = _state.copyWith(savedDeviceId: id, savedDeviceName: name);
  }

  // --- Auto-Reconnect ---------------------------------------------------------

  void _scheduleReconnect({bool immediate = false}) {
    if (_disposed || !_wantConnection || _suspendAutoReconnect || !_foreground) return;
    if (_adapterState != BluetoothAdapterState.on) return;
    if (_connecting || _state.isConnected || _state.status == LinkStatus.scanning) return;
    final id = _state.savedDeviceId;
    if (id == null) return;

    _reconnectTimer?.cancel();
    final delay = immediate
        ? Duration.zero
        : Duration(
            seconds: _reconnectDelaysS[math.min(_reconnectAttempt, _reconnectDelaysS.length - 1)],
          );
    _reconnectAttempt++;
    _emit(_state.copyWith(reconnecting: true));
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_connectTo(BluetoothDevice.fromId(id), name: _state.savedDeviceName));
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // --- Hilfen -----------------------------------------------------------------

  void _emit(ZipLinkState s) {
    if (_disposed || s == _state) {
      _state = s;
      return;
    }
    _state = s;
    _states.add(s);
  }

  static String _errorText(Object e) {
    if (e is PlatformException) return '${e.code} ${e.message ?? ''}';
    if (e is FlutterBluePlusException) return '${e.function} ${e.code} ${e.description ?? ''}';
    return e.toString();
  }

  static bool _isPermissionError(Object e) => _errorText(e).toLowerCase().contains('permission');

  /// Heuristik: Die Plattformen melden fehlgeschlagene Kopplung mit
  /// unterschiedlichen Codes, aber stets mit diesen Begriffen im Text
  /// (z. B. AUTHENTICATION_FAILURE, PIN_OR_KEY_MISSING, GATT_INSUFFICIENT_ENCRYPTION,
  /// „Peer removed pairing information“).
  static bool _looksLikePairingError(String text) {
    final t = text.toLowerCase();
    return t.contains('auth') ||
        t.contains('encrypt') ||
        t.contains('pin_or_key') ||
        t.contains('security') ||
        t.contains('pairing') ||
        t.contains('bond');
  }

  ZipNotice get _permissionNotice => ZipNotice(
    ZipNoticeKind.permissionDenied,
    _isAndroid
        ? 'Ohne die Berechtigung „Geräte in der Nähe“ kann die App deine Zip nicht finden. '
              'Bitte in den Android-Einstellungen unter Apps → Zip → Berechtigungen erlauben.'
        : 'Bluetooth-Zugriff verweigert. Bitte in den iOS-Einstellungen unter Zip → Bluetooth erlauben.',
  );
}

class _PairingException implements Exception {
  const _PairingException(this.cause);

  final Object cause;

  @override
  String toString() => 'Kopplung fehlgeschlagen: $cause';
}

class _NotAZipException implements Exception {
  const _NotAZipException();
}
