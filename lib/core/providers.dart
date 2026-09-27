import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/zip_client.dart';
import '../ble/zip_connection.dart';
import '../data/demo_source.dart';
import '../data/models.dart';
import '../data/trip_database.dart';
import '../data/zip_data_source.dart';
import 'toast.dart';

/// Wird in `main()` mit der geladenen Instanz überschrieben.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider in main() überschreiben'),
);

// ---------------------------------------------------------------------------
// Einstellungen
// ---------------------------------------------------------------------------

class SettingsController extends Notifier<AppSettings> {
  static const _kGaugeMax = 'settings.gaugeMaxKmh';
  static const _kTempLimit = 'settings.tempLimitC';
  static const _kTempPending = 'settings.tempLimitPending';
  static const _kDeleteAfter = 'settings.deleteAfterTransfer';
  static const _kDemo = 'settings.demoMode';
  static const _kExplained = 'settings.permissionsExplained';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final gauge = prefs.getInt(_kGaugeMax);
    return AppSettings(
      gaugeMaxKmh: kGaugeMaxOptions.contains(gauge) ? gauge! : 80,
      tempLimitC: prefs.getInt(_kTempLimit) ?? 240,
      tempLimitPending: prefs.getBool(_kTempPending) ?? false,
      deleteAfterTransfer: prefs.getBool(_kDeleteAfter) ?? false,
      demoMode: prefs.getBool(_kDemo) ?? false,
      permissionsExplained: prefs.getBool(_kExplained) ?? false,
    );
  }

  void setGaugeMax(int kmh) {
    if (!kGaugeMaxOptions.contains(kmh)) return;
    state = state.copyWith(gaugeMaxKmh: kmh);
    unawaited(_prefs.setInt(_kGaugeMax, kmh));
  }

  void setDeleteAfterTransfer(bool value) {
    state = state.copyWith(deleteAfterTransfer: value);
    unawaited(_prefs.setBool(_kDeleteAfter, value));
  }

  void setDemoMode(bool value) {
    state = state.copyWith(demoMode: value);
    unawaited(_prefs.setBool(_kDemo, value));
  }

  void markPermissionsExplained() {
    state = state.copyWith(permissionsExplained: true);
    unawaited(_prefs.setBool(_kExplained, true));
  }

  void _setTempLimit(int celsius, {required bool pending}) {
    state = state.copyWith(tempLimitC: celsius, tempLimitPending: pending);
    unawaited(_prefs.setInt(_kTempLimit, celsius));
    unawaited(_prefs.setBool(_kTempPending, pending));
  }

  /// Warngrenze aus den Einstellungen ändern und per 0x05 an den Roller senden.
  /// Ohne Verbindung wird sie beim nächsten Verbinden übertragen.
  Future<void> setTempLimit(int celsius) async {
    final value = AppSettings.clampTempLimit(celsius);
    _setTempLimit(value, pending: true);
    final client = ref.read(zipClientProvider);
    if (!client.linkState.isConnected) {
      showToast('Nicht verbunden – die Warngrenze wird beim nächsten Verbinden übertragen.');
      return;
    }
    try {
      await client.setTempLimit(value);
      if (!ref.mounted) return;
      if (state.tempLimitC == value) _setTempLimit(value, pending: false);
      showToast('Warngrenze auf $value °C gesetzt');
    } catch (e) {
      showToast(describeZipError(e), isError: true);
    }
  }

  /// Nach dem Verbinden: Warngrenze mit dem Roller abgleichen. Eine lokal
  /// noch nicht übertragene Änderung gewinnt, sonst gilt der Wert des Rollers.
  Future<void> syncTempLimit(DeviceInfo info, ZipClient client) async {
    if (state.tempLimitPending) {
      try {
        await client.setTempLimit(state.tempLimitC);
        if (ref.mounted) _setTempLimit(state.tempLimitC, pending: false);
      } catch (e) {
        debugPrint('Warngrenze konnte nicht übertragen werden: $e');
      }
    } else if (info.tempLimitC != state.tempLimitC && info.tempLimitC > 0) {
      _setTempLimit(info.tempLimitC, pending: false);
    }
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

// ---------------------------------------------------------------------------
// Datenquelle und Client
// ---------------------------------------------------------------------------

/// Echte BLE-Verbindung oder Demo-Modus – je nach Einstellung.
final dataSourceProvider = Provider<ZipDataSource>((ref) {
  final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
  final ZipDataSource source = demo
      ? DemoSource(scooter: DemoScooter(dropRate: 0.01))
      : ZipConnection(ref.watch(sharedPreferencesProvider));
  ref.onDispose(() => unawaited(source.dispose()));
  return source;
});

final zipClientProvider = Provider<ZipClient>((ref) {
  final source = ref.watch(dataSourceProvider);
  final client = ZipClient(source);
  ref.onDispose(() => unawaited(client.dispose()));
  // Erst starten, wenn der Client lauscht – so geht kein Ereignis verloren.
  unawaited(source.start());
  return client;
});

class LinkStateNotifier extends Notifier<ZipLinkState> {
  @override
  ZipLinkState build() {
    final client = ref.watch(zipClientProvider);
    final sub = client.linkStates.listen((s) => state = s);
    ref.onDispose(sub.cancel);
    return client.linkState;
  }
}

final linkStateProvider = NotifierProvider<LinkStateNotifier, ZipLinkState>(LinkStateNotifier.new);

/// Letzte Telemetrie (bleibt nach einem Verbindungsabbruch erhalten,
/// die Oberfläche zeigt sie dann gedimmt).
class TelemetryNotifier extends Notifier<Telemetry?> {
  @override
  Telemetry? build() {
    final client = ref.watch(zipClientProvider);
    final sub = client.telemetry.listen((t) => state = t);
    ref.onDispose(sub.cancel);
    return client.lastTelemetry;
  }
}

final telemetryProvider = NotifierProvider<TelemetryNotifier, Telemetry?>(TelemetryNotifier.new);

/// Tatsächlicher Lichtzustand laut ESP. Maßgeblich ist das Notify der
/// Licht-Characteristic; das Lichtbyte der Telemetrie dient als Rückfallebene
/// (z. B. vor dem ersten Notify), wird aber kurz nach einem Notify ignoriert,
/// damit ein älteres Telemetrie-Paket die Anzeige nicht flackern lässt.
class LightStateNotifier extends Notifier<LightState?> {
  static const Duration notifyPriority = Duration(milliseconds: 1500);

  DateTime? _lastNotify;
  LightState? _lastTelemetryLights;

  @override
  LightState? build() {
    final client = ref.watch(zipClientProvider);
    _lastNotify = null;
    _lastTelemetryLights = null;
    final notifySub = client.lights.listen((s) {
      _lastNotify = DateTime.now();
      state = s;
    });
    final telemetrySub = client.telemetry.listen(_onTelemetry);
    ref.onDispose(notifySub.cancel);
    ref.onDispose(telemetrySub.cancel);
    return client.lastLights ?? client.lastTelemetry?.lights;
  }

  void _onTelemetry(Telemetry t) {
    final lights = t.lights;
    // Erst übernehmen, wenn zwei Pakete in Folge denselben Zustand melden.
    final stable = lights == _lastTelemetryLights;
    _lastTelemetryLights = lights;
    final last = _lastNotify;
    final notifyIsFresh = last != null && DateTime.now().difference(last) < notifyPriority;
    if ((stable || state == null) && !notifyIsFresh && lights != state) state = lights;
  }
}

final lightStateProvider = NotifierProvider<LightStateNotifier, LightState?>(
  LightStateNotifier.new,
);

// ---------------------------------------------------------------------------
// Speicher
// ---------------------------------------------------------------------------

/// Getrennte Datenbanken für echte Fahrten und den Demo-Modus.
final tripDatabaseProvider = Provider<TripDatabase>((ref) {
  final demo = ref.watch(settingsProvider.select((s) => s.demoMode));
  final db = TripDatabase(demo ? 'zip_demo.db' : 'zip_trips.db');
  ref.onDispose(() => unawaited(db.close()));
  return db;
});

final tripListProvider = FutureProvider<List<TripSummary>>((ref) {
  return ref.watch(tripDatabaseProvider).listTrips();
});

final tripDetailProvider = FutureProvider.autoDispose.family<TripDetail?, int>((ref, id) {
  return ref.watch(tripDatabaseProvider).loadTrip(id);
});

final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
});
