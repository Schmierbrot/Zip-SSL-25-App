import 'package:flutter/cupertino.dart';

import '../core/theme.dart';

/// Gruppierte Liste im Stil der iPhone-Einstellungen.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, this.header, this.footer, required this.children});

  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          const Padding(
            padding: EdgeInsets.only(left: ZipSpacing.m),
            child: SizedBox(
              height: 0.5,
              width: double.infinity,
              child: ColoredBox(color: ZipColors.separator),
            ),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: ZipSpacing.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(ZipSpacing.m, 0, ZipSpacing.m, ZipSpacing.xs),
              child: Text(header!.toUpperCase(), style: ZipText.label),
            ),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(ZipRadii.control + 2)),
            child: ColoredBox(
              color: ZipColors.card,
              child: Column(children: rows),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(ZipSpacing.m, ZipSpacing.xs, ZipSpacing.m, 0),
              child: Text(footer!, style: ZipText.footnote),
            ),
        ],
      ),
    );
  }
}

/// Eine Zeile in einer [SettingsSection].
class SettingsRow extends StatefulWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.accent = false,
    this.showChevron = false,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;

  /// Grauer Wert rechts (z. B. „1.0.0“).
  final String? value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Titel rot (z. B. „Gerät vergessen“).
  final bool destructive;

  /// Titel als rote Aktion (z. B. „Suchen und verbinden“).
  final bool accent;
  final bool showChevron;
  final bool enabled;

  @override
  State<SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<SettingsRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final tappable = w.onTap != null && w.enabled;
    final titleColor = !w.enabled
        ? ZipColors.textTertiary
        : (w.destructive || w.accent)
        ? ZipColors.accent
        : ZipColors.textPrimary;

    final row = AnimatedContainer(
      duration: ZipMotion.fast,
      curve: ZipMotion.curve,
      color: _pressed ? ZipColors.elevated : ZipColors.card,
      constraints: const BoxConstraints(minHeight: 50),
      padding: const EdgeInsets.symmetric(horizontal: ZipSpacing.m, vertical: ZipSpacing.s),
      child: Row(
        children: [
          if (w.leading != null) ...[w.leading!, const SizedBox(width: ZipSpacing.s)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(w.title, style: ZipText.body.copyWith(color: titleColor)),
                if (w.subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(w.subtitle!, style: ZipText.caption),
                  ),
              ],
            ),
          ),
          if (w.value != null)
            Padding(
              padding: const EdgeInsets.only(left: ZipSpacing.xs),
              child: Text(
                w.value!,
                style: ZipText.body.copyWith(
                  color: ZipColors.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          if (w.trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: ZipSpacing.xs),
              child: w.trailing!,
            ),
          if (w.showChevron)
            const Padding(
              padding: EdgeInsets.only(left: ZipSpacing.xs),
              child: Icon(CupertinoIcons.chevron_forward, size: 16, color: ZipColors.textTertiary),
            ),
        ],
      ),
    );

    if (!tappable) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: w.onTap,
      child: row,
    );
  }
}

/// iOS-Schalter mit Rot statt Grün.
class ZipSwitch extends StatelessWidget {
  const ZipSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return CupertinoSwitch(
      value: value,
      onChanged: onChanged,
      activeTrackColor: ZipColors.accent,
      inactiveTrackColor: ZipColors.elevated,
    );
  }
}
