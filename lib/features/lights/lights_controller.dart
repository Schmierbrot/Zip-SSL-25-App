import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/zip_client.dart';
import '../../core/haptics.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import '../../data/models.dart';

@immutable
class LightsUiState {
  const LightsUiState({this.actual, this.pending});

  /// Zustand laut ESP (Notify).
  final LightState? actual;

  /// Optimistisch angezeigter Wunschzustand, bis der ESP ihn bestätigt.
  final LightState? pending;

  LightState get displayed => pending ?? actual ?? LightState.off;
}

/// Optimistisches Schalten: Die Oberfläche zeigt sofort den Wunschzustand.
/// Weicht die Rückmeldung des ESP ab oder schlägt das Schreiben fehl,
/// wird auf den tatsächlichen Zustand zurückgesetzt und eine Meldung gezeigt.
class LightsController extends Notifier<LightsUiState> {
  static const Duration confirmTimeout = Duration(seconds: 2);

  LightState? _desired;
  bool _writing = false;
  Completer<LightState>? _nextNotify;

  @override
  LightsUiState build() {
    // Anzeige: tatsächlicher Zustand (Notify, ersatzweise Telemetrie).
    ref.listen(lightStateProvider, (_, next) {
      if (next == null) return;
      state = LightsUiState(actual: next, pending: state.pending);
    });
    // Bestätigung eines Schaltbefehls: nur das Notify der Licht-Characteristic.
    final notifySub = ref.watch(zipClientProvider).lights.listen((confirmed) {
      final waiter = _nextNotify;
      if (waiter != null && !waiter.isCompleted) waiter.complete(confirmed);
    });
    ref.onDispose(notifySub.cancel);
    ref.listen(linkStateProvider.select((s) => s.isConnected), (_, connected) {
      if (!connected) {
        _desired = null;
        state = LightsUiState(actual: state.actual);
      }
    });
    _desired = null;
    _writing = false;
    return LightsUiState(actual: ref.read(lightStateProvider));
  }

  void toggle(LightChannel channel, bool on) {
    if (!ref.read(linkStateProvider).isConnected) return;
    final target = state.displayed.withChannel(channel, on);
    _desired = target;
    state = LightsUiState(actual: state.actual, pending: target);
    unawaited(Haptics.toggle());
    if (!_writing) unawaited(_pump());
  }

  /// Schreibt nacheinander den jeweils neuesten Wunschzustand.
  Future<void> _pump() async {
    _writing = true;
    try {
      while (_desired != null) {
        final target = _desired!;
        final client = ref.read(zipClientProvider);
        _nextNotify = Completer<LightState>();
        try {
          await client.writeLights(target);
        } catch (e) {
          _fail(target, 'Licht konnte nicht geschaltet werden: ${describeZipError(e)}');
          return;
        }

        LightState? confirmed;
        try {
          confirmed = await _nextNotify!.future.timeout(confirmTimeout);
        } on TimeoutException {
          // Keine Rückmeldung: Zustand aktiv lesen.
          try {
            await client.readLights();
            confirmed = await _waitForNotify(const Duration(seconds: 1));
          } catch (_) {
            confirmed = null;
          }
        }
        if (!ref.mounted) return;

        // Inzwischen erneut umgeschaltet → neuen Wunsch schreiben.
        if (_desired != target) continue;

        _desired = null;
        if (confirmed == null) {
          _fail(target, 'Keine Rückmeldung vom Roller – Licht bitte prüfen.');
        } else if (confirmed != target) {
          _fail(target, 'Der Roller hat den Schaltbefehl nicht übernommen.');
        } else {
          state = LightsUiState(actual: confirmed);
        }
      }
    } finally {
      _writing = false;
      _nextNotify = null;
    }
  }

  Future<LightState?> _waitForNotify(Duration timeout) async {
    final c = Completer<LightState>();
    _nextNotify = c;
    try {
      return await c.future.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  void _fail(LightState target, String message) {
    _desired = null;
    if (!ref.mounted) return;
    state = LightsUiState(actual: state.actual);
    unawaited(Haptics.error());
    showToast(message, isError: true);
  }
}

final lightsControllerProvider = NotifierProvider<LightsController, LightsUiState>(
  LightsController.new,
);
