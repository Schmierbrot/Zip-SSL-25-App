import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../features/trips/trips_controller.dart';
import 'providers.dart';

/// Koordiniert, was nach jedem Verbinden passiert: Info lesen (0x06),
/// Warngrenze abgleichen, Fahrten synchronisieren. Hält die zuletzt
/// gelesene Geräteinfo für die Einstellungen.
class ZipSession extends Notifier<DeviceInfo?> {
  @override
  DeviceInfo? build() {
    final client = ref.watch(zipClientProvider);

    ref.listen(linkStateProvider, (previous, next) {
      final wasConnected = previous?.isConnected ?? false;
      if (next.isConnected && !wasConnected) unawaited(_onConnected());
    });

    // Fahrt auf dem Roller beendet → gleich übertragen.
    ref.listen(telemetryProvider.select((t) => t?.tripRunning), (previous, next) {
      if (previous == true && next == false) {
        unawaited(ref.read(tripSyncProvider.notifier).sync());
      }
    });

    if (client.linkState.isConnected) scheduleMicrotask(_onConnected);
    return null;
  }

  Future<void> _onConnected() async {
    final client = ref.read(zipClientProvider);
    try {
      final info = await client.readInfo();
      if (!ref.mounted) return;
      state = info;
      await ref.read(settingsProvider.notifier).syncTempLimit(info, client);
    } catch (e) {
      debugPrint('Info konnte nicht gelesen werden: $e');
    }
    if (!ref.mounted) return;
    unawaited(ref.read(tripSyncProvider.notifier).sync());
  }

  /// Info erneut lesen (z. B. nach dem Setzen der Gesamtkilometer).
  Future<void> refreshInfo() async {
    try {
      final info = await ref.read(zipClientProvider).readInfo();
      if (ref.mounted) state = info;
    } catch (e) {
      debugPrint('Info konnte nicht gelesen werden: $e');
    }
  }
}

final zipSessionProvider = NotifierProvider<ZipSession, DeviceInfo?>(ZipSession.new);
