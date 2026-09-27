import 'package:flutter/cupertino.dart';

import '../core/theme.dart';

/// Bestätigungsdialog im iOS-Stil. Gibt `true` bei Bestätigung zurück.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  String cancelLabel = 'Abbrechen',
}) async {
  final result = await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => CupertinoTheme(
      data: const CupertinoThemeData(brightness: Brightness.dark, primaryColor: ZipColors.accent),
      child: CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: ZipSpacing.xxs),
          child: Text(message),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelLabel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: destructive,
            isDefaultAction: !destructive,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}

/// Auswahl-Blatt im iOS-Stil mit mehreren Aktionen.
Future<T?> showActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<ActionSheetOption<T>> options,
  String cancelLabel = 'Abbrechen',
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (context) => CupertinoTheme(
      data: const CupertinoThemeData(brightness: Brightness.dark, primaryColor: ZipColors.accent),
      child: CupertinoActionSheet(
        title: title == null ? null : Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final o in options)
            CupertinoActionSheetAction(
              isDestructiveAction: o.destructive,
              onPressed: () => Navigator.of(context).pop(o.value),
              child: Text(o.label),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(cancelLabel),
        ),
      ),
    ),
  );
}

class ActionSheetOption<T> {
  const ActionSheetOption({required this.label, required this.value, this.destructive = false});

  final String label;
  final T value;
  final bool destructive;
}
