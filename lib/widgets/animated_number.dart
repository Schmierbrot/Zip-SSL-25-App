import 'package:flutter/widgets.dart';

import '../core/theme.dart';

/// Zahl, die beim Ändern weich „hochzählt“ statt zu springen.
class AnimatedNumber extends StatelessWidget {
  const AnimatedNumber({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.duration = ZipMotion.slow,
  });

  final double value;
  final String Function(double value) format;
  final TextStyle? style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: duration,
      curve: ZipMotion.curve,
      builder: (context, v, _) => Text(format(v), style: style),
    );
  }
}
