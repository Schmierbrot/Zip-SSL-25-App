import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Karte ohne Rahmen und Schatten mit großem Radius.
class ZipCard extends StatelessWidget {
  const ZipCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(ZipSpacing.m),
    this.color = ZipColors.card,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = AnimatedContainer(
      duration: ZipMotion.normal,
      curve: ZipMotion.curve,
      padding: padding,
      decoration: BoxDecoration(color: color, borderRadius: ZipRadii.cardRadius),
      child: child,
    );
    if (onTap == null) return content;
    return _Pressable(onTap: onTap!, child: content);
  }
}

/// Dezentes iOS-artiges Feedback beim Antippen (leicht abdunkeln).
class _Pressable extends StatefulWidget {
  const _Pressable({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _pressed = false;

  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      child: AnimatedOpacity(
        opacity: _pressed ? 0.6 : 1,
        duration: ZipMotion.fast,
        curve: ZipMotion.curve,
        child: widget.child,
      ),
    );
  }
}
