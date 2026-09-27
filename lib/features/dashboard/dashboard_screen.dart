import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/zip_data_source.dart';
import '../../widgets/arc_gauge.dart';
import '../../widgets/common.dart';
import '../../widgets/stat_tile.dart';
import '../../widgets/warning_banner.dart';
import '../common/connect_flow.dart';
import 'temperature_warning.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkStateProvider);
    final telemetry = ref.watch(telemetryProvider);
    final gaugeMax = ref.watch(settingsProvider.select((s) => s.gaugeMaxKmh));
    final warning = ref.watch(temperatureWarningProvider);
    final isDemo = ref.watch(zipClientProvider).isDemo;

    final connected = link.isConnected;
    final t = connected ? telemetry : null;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          ZipSpacing.page,
          ZipSpacing.xs,
          ZipSpacing.page,
          bottomInset + ZipSpacing.m,
        ),
        child: Column(
          children: [
            DashboardStatusBar(link: link, telemetry: t, demo: isDemo || (t?.simulation ?? false)),
            const SizedBox(height: ZipSpacing.s),
            WarningBanner(
              message: warning.active && warning.tempC != null
                  ? 'Zylinderkopf zu heiß – ${warning.tempC!.round()} °C'
                  : null,
            ),
            if (link.isBlocked) ...[
              BluetoothNotice(link: link),
              const SizedBox(height: ZipSpacing.s),
            ],
            Expanded(
              child: AnimatedOpacity(
                opacity: connected ? 1 : 0.35,
                duration: ZipMotion.slow,
                curve: ZipMotion.curve,
                child: Center(
                  child: ArcGauge(
                    speedKmh: t != null && t.gpsFix ? t.speedKmh : null,
                    maxKmh: gaugeMax,
                  ),
                ),
              ),
            ),
            const SizedBox(height: ZipSpacing.m),
            AnimatedOpacity(
              opacity: connected ? 1 : 0.35,
              duration: ZipMotion.slow,
              curve: ZipMotion.curve,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _TemperatureTile(telemetry: t, warning: warning.active),
                    ),
                    const SizedBox(width: ZipSpacing.s),
                    Expanded(child: _OdometerTile(telemetry: telemetry)),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: ZipMotion.slow,
              curve: ZipMotion.curve,
              child: connected || link.isBlocked
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: ZipSpacing.l),
                      child: ZipPrimaryButton(
                        label: link.isBusy ? _busyLabel(link) : 'Verbinden',
                        icon: CupertinoIcons.bluetooth,
                        busy: link.isBusy,
                        onPressed: () => unawaited(startConnect(context, ref)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _busyLabel(ZipLinkState link) =>
      link.status == LinkStatus.connecting ? 'Verbinde …' : 'Suche …';
}

class _TemperatureTile extends StatelessWidget {
  const _TemperatureTile({required this.telemetry, required this.warning});

  final Telemetry? telemetry;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final t = telemetry;
    final temp = t?.tempC;
    final sensorProblem = t != null && temp == null;
    return StatTile(
      label: 'Zylinderkopf',
      value: temp,
      format: (v) => v.round().toString(),
      text: temp == null ? '–' : null,
      unit: temp == null ? null : '°C',
      valueColor: warning ? ZipColors.accent : ZipColors.textPrimary,
      footnote: sensorProblem ? 'Sensor prüfen' : null,
      footnoteColor: ZipColors.accent,
    );
  }
}

class _OdometerTile extends StatelessWidget {
  const _OdometerTile({required this.telemetry});

  final Telemetry? telemetry;

  @override
  Widget build(BuildContext context) {
    final meters = telemetry?.odometerM;
    return StatTile(
      label: 'Gesamt',
      value: meters == null ? null : meters / 1000,
      format: (v) => formatNumber(v, decimals: 1),
      text: meters == null ? '–' : null,
      unit: meters == null ? null : 'km',
    );
  }
}

/// Schmale Statuszeile: Verbindung, GPS, laufende Fahrt, Demo-Badge.
class DashboardStatusBar extends StatelessWidget {
  const DashboardStatusBar({
    super.key,
    required this.link,
    required this.telemetry,
    required this.demo,
  });

  final ZipLinkState link;
  final Telemetry? telemetry;
  final bool demo;

  @override
  Widget build(BuildContext context) {
    final t = telemetry;
    final (Color dotColor, String label) = switch (link.status) {
      LinkStatus.connected => (ZipColors.accent, 'Verbunden'),
      LinkStatus.scanning => (ZipColors.textSecondary, 'Suche …'),
      LinkStatus.connecting => (ZipColors.textSecondary, 'Verbinde …'),
      LinkStatus.bluetoothOff => (ZipColors.textTertiary, 'Bluetooth aus'),
      _ when link.reconnecting => (ZipColors.textSecondary, 'Suche …'),
      _ => (ZipColors.textTertiary, 'Getrennt'),
    };
    final gpsFix = t?.gpsFix ?? false;
    final gpsColor = gpsFix ? ZipColors.textPrimary : ZipColors.textTertiary;

    return SizedBox(
      height: 32,
      child: Row(
        children: [
          StatusDot(color: dotColor, pulsing: link.isBusy),
          const SizedBox(width: ZipSpacing.xs),
          Text(label, style: ZipText.inter(size: 14, weight: FontWeight.w500)),
          if (t != null) ...[
            const SizedBox(width: ZipSpacing.m),
            Icon(Icons.satellite_alt_outlined, size: 16, color: gpsColor),
            const SizedBox(width: ZipSpacing.xxs),
            Text('${t.satellites}', style: ZipText.inter(size: 14, color: gpsColor, tabular: true)),
          ],
          const Spacer(),
          AnimatedSwitcher(
            duration: ZipMotion.normal,
            child: t != null && t.tripRunning
                ? Text(
                    '● Fahrt · ${formatKm(t.tripDistanceM)}',
                    key: const ValueKey('trip'),
                    style: ZipText.inter(
                      size: 14,
                      weight: FontWeight.w600,
                      color: ZipColors.accent,
                      tabular: true,
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('no-trip')),
          ),
          if (demo) ...[const SizedBox(width: ZipSpacing.xs), const ZipBadge('DEMO')],
        ],
      ),
    );
  }
}
