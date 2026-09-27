import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Globaler Messenger, damit auch Controller kurze Meldungen zeigen können.
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Zeigt eine kurze, unaufdringliche Meldung am unteren Rand.
void showToast(String message, {bool isError = false}) {
  final messenger = scaffoldMessengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            Icon(
              isError ? CupertinoIcons.exclamationmark_circle : CupertinoIcons.checkmark_circle,
              color: isError ? ZipColors.accent : ZipColors.textSecondary,
              size: 20,
            ),
            const SizedBox(width: ZipSpacing.s),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}
