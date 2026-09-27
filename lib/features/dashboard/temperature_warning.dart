import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models.dart';

@immutable
class TemperatureWarning {
  const TemperatureWarning({required this.active, this.tempC});

  static const none = TemperatureWarning(active: false);

  final bool active;
  final double? tempC;

  @override
  bool operator ==(Object other) =>
      other is TemperatureWarning && other.active == active && other.tempC == tempC;

  @override
  int get hashCode => Object.hash(active, tempC);
}

/// Warnung „Zylinderkopf zu heiß“: aktiv, wenn der ESP das Warn-Flag setzt
/// oder die Temperatur die Warngrenze überschreitet. 2 °C Hysterese, damit
/// der Banner an der Grenze nicht flackert.
class TemperatureWarningController extends Notifier<TemperatureWarning> {
  static const double hysteresisC = 2;

  @override
  TemperatureWarning build() {
    ref.listen(telemetryProvider, (_, t) => _update(t));
    ref.listen(linkStateProvider, (_, _) => _update(ref.read(telemetryProvider)));
    ref.listen(settingsProvider.select((s) => s.tempLimitC), (_, _) {
      _update(ref.read(telemetryProvider));
    });
    return TemperatureWarning.none;
  }

  void _update(Telemetry? t) {
    final connected = ref.read(linkStateProvider).isConnected;
    final temp = t?.tempC;
    if (!connected || t == null || temp == null) {
      if (state.active) state = TemperatureWarning.none;
      return;
    }
    final limit = ref.read(settingsProvider).tempLimitC;
    final threshold = state.active ? limit - hysteresisC : limit.toDouble();
    final active = t.tempWarning || temp > threshold;
    state = TemperatureWarning(active: active, tempC: temp);
  }
}

final temperatureWarningProvider =
    NotifierProvider<TemperatureWarningController, TemperatureWarning>(
      TemperatureWarningController.new,
    );
