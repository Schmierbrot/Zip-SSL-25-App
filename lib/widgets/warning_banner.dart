import 'package:flutter/cupertino.dart';

import '../core/theme.dart';

/// Roter Warnbanner, der weich ein- und ausfährt. `message == null` blendet aus.
class WarningBanner extends StatelessWidget {
  const WarningBanner({super.key, required this.message, this.icon = CupertinoIcons.thermometer});

  final String? message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: ZipMotion.slow,
      curve: ZipMotion.curve,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: ZipMotion.normal,
        switchInCurve: ZipMotion.curve,
        switchOutCurve: ZipMotion.curve,
        child: message == null
            ? const SizedBox(key: ValueKey('none'), width: double.infinity)
            : Padding(
                key: const ValueKey('banner'),
                padding: const EdgeInsets.only(bottom: ZipSpacing.s),
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: ZipSpacing.m,
                      vertical: ZipSpacing.s + 2,
                    ),
                    decoration: const BoxDecoration(
                      color: ZipColors.accent,
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                    child: Row(
                      children: [
                        Icon(icon, color: ZipColors.textPrimary, size: 20),
                        const SizedBox(width: ZipSpacing.s),
                        Expanded(
                          child: Text(
                            message!,
                            style: ZipText.inter(size: 15, weight: FontWeight.w600, tabular: true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
