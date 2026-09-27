import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/zip_data_source.dart';
import '../../widgets/common.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/zip_card.dart';

/// Verbinden auf Wunsch des Nutzers. Vor der ersten Systemabfrage erklärt
/// die App, wozu sie Bluetooth braucht.
Future<void> startConnect(BuildContext context, WidgetRef ref, {bool scan = false}) async {
  final client = ref.read(zipClientProvider);
  if (!client.isDemo && !ref.read(settingsProvider).permissionsExplained) {
    final ok = await showConfirmDialog(
      context,
      title: 'Bluetooth-Zugriff',
      message: _rationaleText,
      confirmLabel: 'Weiter',
    );
    if (!ok) return;
    ref.read(settingsProvider.notifier).markPermissionsExplained();
  }
  final source = client.source;
  unawaited(scan ? source.scanAndConnect() : source.connect());
}

String get _rationaleText {
  if (!kIsWeb && Platform.isAndroid) {
    return 'Damit die App deine Zip finden und sich mit ihr verbinden kann, fragt Android gleich '
        'nach der Berechtigung „Geräte in der Nähe“. Bluetooth wird nur für die Verbindung zum '
        'Roller genutzt – dein Standort wird nicht ermittelt.\n\nAuf Android 11 und älter heißt '
        'die Berechtigung „Standort“ und der Standort muss für die Suche eingeschaltet sein.';
  }
  return 'Damit die App deine Zip finden und sich mit ihr verbinden kann, fragt iOS gleich nach '
      'dem Bluetooth-Zugriff. Bluetooth wird nur für die Verbindung zum Roller genutzt.';
}

/// Hinweis, wenn Bluetooth aus, verboten oder nicht vorhanden ist.
class BluetoothNotice extends ConsumerWidget {
  const BluetoothNotice({super.key, required this.link});

  final ZipLinkState link;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(zipClientProvider).source;
    final (IconData icon, String title, String text) = switch (link.status) {
      LinkStatus.bluetoothOff => (
        CupertinoIcons.bluetooth,
        'Bluetooth ist ausgeschaltet',
        source.canTurnOnBluetooth
            ? 'Zum Verbinden mit deiner Zip wird Bluetooth benötigt.'
            : 'Bitte Bluetooth im Kontrollzentrum oder in den Einstellungen einschalten.',
      ),
      LinkStatus.unauthorized => (
        CupertinoIcons.lock,
        'Bluetooth-Zugriff fehlt',
        !kIsWeb && Platform.isAndroid
            ? 'Ohne die Berechtigung „Geräte in der Nähe“ kann die App deine Zip weder finden '
                  'noch sich mit ihr verbinden. Bitte in den Android-Einstellungen unter '
                  'Apps → Zip → Berechtigungen erlauben und erneut versuchen.'
            : 'Ohne Bluetooth-Zugriff kann die App deine Zip nicht finden. Bitte in den '
                  'iOS-Einstellungen unter Zip → Bluetooth erlauben.',
      ),
      _ => (
        CupertinoIcons.nosign,
        'Bluetooth LE nicht verfügbar',
        'Dieses Gerät unterstützt kein Bluetooth Low Energy. Im Demo-Modus lässt sich die App '
            'trotzdem ausprobieren.',
      ),
    };

    return ZipCard(
      padding: const EdgeInsets.all(ZipSpacing.m + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: ZipColors.accent, size: 22),
              const SizedBox(width: ZipSpacing.s),
              Expanded(child: Text(title, style: ZipText.headline)),
            ],
          ),
          const SizedBox(height: ZipSpacing.xs),
          Text(text, style: ZipText.footnote),
          if (link.status == LinkStatus.bluetoothOff && source.canTurnOnBluetooth) ...[
            const SizedBox(height: ZipSpacing.m),
            ZipPrimaryButton(
              label: 'Bluetooth einschalten',
              icon: CupertinoIcons.bluetooth,
              onPressed: () => unawaited(source.turnOnBluetooth()),
            ),
          ],
          if (link.status == LinkStatus.unauthorized) ...[
            const SizedBox(height: ZipSpacing.m),
            ZipPrimaryButton(
              label: 'Erneut versuchen',
              onPressed: () => unawaited(startConnect(context, ref)),
            ),
          ],
        ],
      ),
    );
  }
}
