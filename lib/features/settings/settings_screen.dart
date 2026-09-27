import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/zip_client.dart';
import '../../ble/zip_protocol.dart';
import '../../core/format.dart';
import '../../core/haptics.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../core/zip_session.dart';
import '../../data/models.dart';
import '../../data/zip_data_source.dart';
import '../../widgets/common.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/settings_group.dart';
import '../common/connect_flow.dart';
import '../trips/trips_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkStateProvider);
    final settings = ref.watch(settingsProvider);
    final info = ref.watch(zipSessionProvider);
    final appVersion = ref.watch(appVersionProvider).value ?? '–';
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      bottom: false,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          ZipSpacing.page,
          0,
          ZipSpacing.page,
          bottomInset + ZipSpacing.l,
        ),
        children: [
          const LargeTitle('Einstellungen'),
          _ConnectionSection(link: link, demo: settings.demoMode),
          SettingsSection(
            header: 'Tacho',
            footer: 'Skalenende des Bogen-Tachos auf dem Dashboard.',
            children: [
              Padding(
                padding: const EdgeInsets.all(ZipSpacing.s),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: settings.gaugeMaxKmh,
                    backgroundColor: ZipColors.background,
                    thumbColor: ZipColors.elevated,
                    onValueChanged: (v) {
                      if (v == null) return;
                      unawaited(Haptics.selection());
                      ref.read(settingsProvider.notifier).setGaugeMax(v);
                    },
                    children: {
                      for (final v in kGaugeMaxOptions)
                        v: Padding(
                          padding: const EdgeInsets.symmetric(vertical: ZipSpacing.xs),
                          child: Text(
                            '$v km/h',
                            style: ZipText.inter(size: 14, weight: FontWeight.w500, tabular: true),
                          ),
                        ),
                    },
                  ),
                ),
              ),
            ],
          ),
          _TempLimitSection(settings: settings),
          SettingsSection(
            header: 'Kilometer',
            footer: 'Überschreibt den Kilometerstand im Roller, z. B. nach dem Einbau.',
            children: [
              SettingsRow(
                title: 'Gesamtkilometer setzen',
                value: ref.watch(telemetryProvider)?.odometerM == null
                    ? null
                    : formatKm(ref.watch(telemetryProvider)!.odometerM),
                showChevron: true,
                enabled: link.isConnected,
                onTap: () => unawaited(_setOdometer(context, ref)),
              ),
            ],
          ),
          SettingsSection(
            header: 'Fahrten',
            footer:
                'Fahrten werden erst gelöscht, nachdem sie vollständig übertragen, '
                'geprüft (CRC) und gespeichert wurden.',
            children: [
              SettingsRow(
                title: 'Nach Übertragung auf dem Roller löschen',
                trailing: ZipSwitch(
                  value: settings.deleteAfterTransfer,
                  onChanged: (v) {
                    unawaited(Haptics.selection());
                    ref.read(settingsProvider.notifier).setDeleteAfterTransfer(v);
                  },
                ),
              ),
              SettingsRow(
                title: 'Alle lokalen Fahrten löschen',
                destructive: true,
                onTap: () => unawaited(_deleteAllTrips(context, ref)),
              ),
            ],
          ),
          SettingsSection(
            header: 'Entwicklung',
            footer:
                'Simuliert Roller, Live-Daten und Beispielfahrten – zum Ausprobieren ohne ESP. '
                'Demo-Fahrten werden getrennt von echten Fahrten gespeichert.',
            children: [
              SettingsRow(
                title: 'Demo-Modus',
                trailing: ZipSwitch(
                  value: settings.demoMode,
                  onChanged: (v) {
                    unawaited(Haptics.selection());
                    ref.read(settingsProvider.notifier).setDemoMode(v);
                  },
                ),
              ),
            ],
          ),
          SettingsSection(
            header: 'Info',
            children: [
              SettingsRow(title: 'App-Version', value: appVersion),
              SettingsRow(title: 'Firmware-Version', value: info?.firmwareString ?? '–'),
              SettingsRow(
                title: 'Protokollversion',
                value: info == null
                    ? 'App: $kProtocolVersion'
                    : '${info.protocolVersion} (App: $kProtocolVersion)',
              ),
              SettingsRow(
                title: 'Freier SD-Speicher',
                value: info == null ? '–' : formatStorageMb(info.sdFreeMb),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _setOdometer(BuildContext context, WidgetRef ref) async {
    final current = ref.read(telemetryProvider)?.odometerM;
    final meters = await showOdometerDialog(context, currentMeters: current);
    if (meters == null || !context.mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Gesamtkilometer setzen?',
      message: 'Der Kilometerstand im Roller wird auf ${formatKm(meters)} gesetzt.',
      confirmLabel: 'Setzen',
    );
    if (!ok) return;
    try {
      await ref.read(zipClientProvider).setOdometer(meters);
      showToast('Gesamtkilometer auf ${formatKm(meters)} gesetzt');
      unawaited(ref.read(zipSessionProvider.notifier).refreshInfo());
    } catch (e) {
      showToast(describeZipError(e), isError: true);
    }
  }

  Future<void> _deleteAllTrips(BuildContext context, WidgetRef ref) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Alle lokalen Fahrten löschen?',
      message:
          'Die Fahrten werden aus der App gelöscht. Fahrten, die noch auf dem Roller liegen, '
          'werden danach nicht erneut übertragen.',
      confirmLabel: 'Alle löschen',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(tripSyncProvider.notifier).deleteAllLocal();
  }
}

class _ConnectionSection extends ConsumerWidget {
  const _ConnectionSection({required this.link, required this.demo});

  final ZipLinkState link;
  final bool demo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (Color dot, String status) = switch (link.status) {
      LinkStatus.connected => (ZipColors.accent, 'Verbunden'),
      LinkStatus.scanning => (ZipColors.textSecondary, 'Suche …'),
      LinkStatus.connecting => (ZipColors.textSecondary, 'Verbinde …'),
      LinkStatus.bluetoothOff => (ZipColors.textTertiary, 'Bluetooth aus'),
      LinkStatus.unauthorized => (ZipColors.textTertiary, 'Kein Zugriff'),
      LinkStatus.unsupported => (ZipColors.textTertiary, 'Nicht verfügbar'),
      _ when link.reconnecting => (ZipColors.textSecondary, 'Suche …'),
      _ => (ZipColors.textTertiary, 'Getrennt'),
    };
    final device = link.savedDeviceName ?? link.deviceName;
    final deviceId = link.savedDeviceId;

    return SettingsSection(
      header: 'Verbindung',
      footer: demo ? 'Im Demo-Modus wird ein Roller simuliert.' : 'Die Zip wird gekoppelt (6-stellige PIN) und beim nächsten Start automatisch verbunden.',
      children: [
        SettingsRow(
          title: 'Status',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusDot(color: dot, pulsing: link.isBusy),
              const SizedBox(width: ZipSpacing.xs),
              Text(status, style: ZipText.body.copyWith(color: ZipColors.textSecondary)),
            ],
          ),
        ),
        SettingsRow(title: 'Gekoppeltes Gerät', subtitle: deviceId, value: device ?? 'Keines'),
        SettingsRow(
          title: 'Suchen und verbinden',
          accent: true,
          enabled: !link.isBusy,
          onTap: () => unawaited(startConnect(context, ref, scan: true)),
        ),
        if (link.isConnected)
          SettingsRow(
            title: 'Trennen',
            onTap: () => unawaited(ref.read(zipClientProvider).source.disconnect()),
          ),
        SettingsRow(
          title: 'Gerät vergessen',
          destructive: true,
          enabled: deviceId != null,
          onTap: () => unawaited(_forget(context, ref)),
        ),
      ],
    );
  }

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    final isIos = !kIsWeb && Platform.isIOS;
    final ok = await showConfirmDialog(
      context,
      title: 'Gerät vergessen?',
      message: isIos
          ? 'Die App verbindet sich nicht mehr automatisch. Um auch die Kopplung zu entfernen, '
                'die Zip zusätzlich in den iOS-Einstellungen unter Bluetooth ignorieren.'
          : 'Die App trennt die Verbindung, entfernt die Kopplung und verbindet sich nicht mehr '
                'automatisch.',
      confirmLabel: 'Vergessen',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(zipClientProvider).source.forgetDevice();
    showToast('Gerät vergessen.');
  }
}

class _TempLimitSection extends ConsumerStatefulWidget {
  const _TempLimitSection({required this.settings});

  final AppSettings settings;

  @override
  ConsumerState<_TempLimitSection> createState() => _TempLimitSectionState();
}

class _TempLimitSectionState extends ConsumerState<_TempLimitSection> {
  /// Wert während des Ziehens – gesendet wird erst beim Loslassen.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final stored = widget.settings.tempLimitC.clamp(kTempLimitMin, kTempLimitMax).toDouble();
    final value = _dragValue ?? stored;
    return SettingsSection(
      header: 'Warnungen',
      footer: widget.settings.tempLimitPending
          ? 'Noch nicht übertragen – wird beim nächsten Verbinden an den Roller gesendet.'
          : 'Über dieser Temperatur erscheint auf dem Dashboard eine Warnung.',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ZipSpacing.m,
            ZipSpacing.s,
            ZipSpacing.m,
            ZipSpacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Warngrenze Zylinderkopf', style: ZipText.body)),
                  Text(
                    '${value.round()} °C',
                    style: ZipText.body.copyWith(
                      color: ZipColors.accent,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              SizedBox(
                width: double.infinity,
                child: CupertinoSlider(
                  value: value,
                  min: kTempLimitMin.toDouble(),
                  max: kTempLimitMax.toDouble(),
                  divisions: (kTempLimitMax - kTempLimitMin) ~/ kTempLimitStep,
                  activeColor: ZipColors.accent,
                  onChanged: (v) {
                    if (_dragValue?.round() != v.round()) {
                      unawaited(Haptics.selection());
                    }
                    setState(() => _dragValue = v);
                  },
                  onChangeEnd: (v) {
                    setState(() => _dragValue = null);
                    final celsius = v.round();
                    if (celsius != widget.settings.tempLimitC || widget.settings.tempLimitPending) {
                      unawaited(ref.read(settingsProvider.notifier).setTempLimit(celsius));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Dialog zur Eingabe der Gesamtkilometer. Gibt Meter zurück.
Future<int?> showOdometerDialog(BuildContext context, {int? currentMeters}) {
  return showCupertinoDialog<int>(
    context: context,
    builder: (context) => _OdometerDialog(currentMeters: currentMeters),
  );
}

class _OdometerDialog extends StatefulWidget {
  const _OdometerDialog({this.currentMeters});

  final int? currentMeters;

  @override
  State<_OdometerDialog> createState() => _OdometerDialogState();
}

class _OdometerDialogState extends State<_OdometerDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentMeters == null
        ? ''
        : formatNumber(widget.currentMeters! / 1000, decimals: 1),
  );
  String? _error;

  /// Maximal darstellbar: uint32 Meter.
  static const double _maxKm = 0xFFFFFFFF / 1000;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final km = parseLocalizedNumber(_controller.text);
    if (km == null) {
      setState(() => _error = 'Bitte eine Zahl eingeben, z. B. 1.284,6');
      return;
    }
    if (km > _maxKm) {
      setState(() => _error = 'Der Wert ist zu groß.');
      return;
    }
    Navigator.of(context).pop((km * 1000).round());
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoTheme(
      data: const CupertinoThemeData(brightness: Brightness.dark, primaryColor: ZipColors.accent),
      child: CupertinoAlertDialog(
        title: const Text('Gesamtkilometer'),
        content: Padding(
          padding: const EdgeInsets.only(top: ZipSpacing.s),
          child: Column(
            children: [
              const Text('Neuer Kilometerstand in km (eine Nachkommastelle).'),
              const SizedBox(height: ZipSpacing.s),
              CupertinoTextField(
                controller: _controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                suffix: const Padding(
                  padding: EdgeInsets.only(right: ZipSpacing.xs),
                  child: Text('km'),
                ),
                style: ZipText.body.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                decoration: const BoxDecoration(
                  color: ZipColors.elevated,
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: ZipSpacing.xs),
                  child: Text(_error!, style: ZipText.caption.copyWith(color: ZipColors.accent)),
                ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Abbrechen'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: _submit,
            child: const Text('Weiter'),
          ),
        ],
      ),
    );
  }
}
