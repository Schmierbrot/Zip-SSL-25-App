import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'animated_number.dart';
import 'zip_card.dart';

/// Kachel mit kleiner grauer Beschriftung und großer, dünner Zahl.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    this.value,
    this.format,
    this.text,
    this.unit,
    this.footnote,
    this.valueColor = ZipColors.textPrimary,
    this.footnoteColor = ZipColors.textSecondary,
    this.valueSize = 40,
    this.padding = const EdgeInsets.fromLTRB(
      ZipSpacing.m + 2,
      ZipSpacing.m,
      ZipSpacing.m,
      ZipSpacing.m + 2,
    ),
  }) : assert(value != null && format != null || text != null);

  final String label;

  /// Animierter Zahlenwert (mit [format]) …
  final double? value;
  final String Function(double value)? format;

  /// … oder fester Text (z. B. „–“).
  final String? text;
  final String? unit;
  final String? footnote;
  final Color valueColor;
  final Color footnoteColor;
  final double valueSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final style = ZipText.number(valueSize, color: valueColor);
    return ZipCard(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: ZipText.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: ZipSpacing.s),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                AnimatedDefaultTextStyle(
                  style: style,
                  duration: ZipMotion.normal,
                  curve: ZipMotion.curve,
                  child: text != null
                      ? Text(text!)
                      : AnimatedNumber(value: value!, format: format!),
                ),
                if (unit != null) ...[
                  const SizedBox(width: ZipSpacing.xxs + 2),
                  Text(unit!, style: ZipText.bodySecondary),
                ],
              ],
            ),
          ),
          AnimatedSize(
            duration: ZipMotion.normal,
            curve: ZipMotion.curve,
            alignment: Alignment.topLeft,
            child: footnote == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: ZipSpacing.xxs),
                    child: Text(footnote!, style: ZipText.caption.copyWith(color: footnoteColor)),
                  ),
          ),
        ],
      ),
    );
  }
}
