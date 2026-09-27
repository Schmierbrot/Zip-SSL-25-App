import 'package:flutter/services.dart';

/// Haptisches Feedback an einer Stelle gebündelt.
abstract final class Haptics {
  /// Schalten eines Lichts.
  static Future<void> toggle() => HapticFeedback.lightImpact();

  /// Auswahl in Listen, Segmenten, Slidern.
  static Future<void> selection() => HapticFeedback.selectionClick();

  /// Eine Warnung wird ausgelöst (z. B. Zylinderkopf zu heiß): doppelter, kräftiger Impuls.
  static Future<void> warning() async {
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 140));
    await HapticFeedback.heavyImpact();
  }

  /// Eine Aktion ist fehlgeschlagen.
  static Future<void> error() => HapticFeedback.mediumImpact();
}
