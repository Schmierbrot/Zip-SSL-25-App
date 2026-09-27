import 'package:flutter/cupertino.dart';

import '../core/theme.dart';

/// Großer Seitentitel im iOS-Stil.
class LargeTitle extends StatelessWidget {
  const LargeTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(ZipSpacing.xxs, ZipSpacing.xs, 0, ZipSpacing.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Text(text, style: ZipText.largeTitle)),
          ?trailing,
        ],
      ),
    );
  }
}

/// Punkt für den Verbindungsstatus; pulsiert optional (z. B. „Suche …“).
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.color, this.pulsing = false, this.size = 8});

  final Color color;
  final bool pulsing;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 1,
        end: 0.25,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: AnimatedContainer(
        duration: ZipMotion.normal,
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// Kleines Badge, z. B. „DEMO“.
class ZipBadge extends StatelessWidget {
  const ZipBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: const BoxDecoration(
        color: ZipColors.elevated,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      child: Text(
        text,
        style: ZipText.inter(
          size: 10,
          weight: FontWeight.w700,
          letterSpacing: 1.2,
          color: ZipColors.textSecondary,
        ),
      ),
    );
  }
}

/// Rote, gefüllte Pillen-Schaltfläche (Hauptaktion).
class ZipPrimaryButton extends StatelessWidget {
  const ZipPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      opacity: enabled || busy ? 1 : 0.4,
      duration: ZipMotion.fast,
      child: CupertinoButton(
        onPressed: enabled ? onPressed : null,
        color: ZipColors.accent,
        disabledColor: busy ? ZipColors.elevated : ZipColors.accentDark,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        padding: const EdgeInsets.symmetric(horizontal: ZipSpacing.l, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const Padding(
                padding: EdgeInsets.only(right: ZipSpacing.xs),
                child: CupertinoActivityIndicator(color: ZipColors.textSecondary, radius: 9),
              )
            else if (icon != null)
              Padding(
                padding: const EdgeInsets.only(right: ZipSpacing.xs),
                child: Icon(icon, size: 20, color: ZipColors.textPrimary),
              ),
            Text(
              label,
              style: ZipText.inter(
                size: 17,
                weight: FontWeight.w600,
                color: busy ? ZipColors.textSecondary : ZipColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dezente Schaltfläche auf erhöhter Fläche (Nebenaktion).
class ZipSecondaryButton extends StatelessWidget {
  const ZipSecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? ZipColors.accent : ZipColors.textPrimary;
    return CupertinoButton(
      onPressed: onPressed,
      color: ZipColors.card,
      borderRadius: const BorderRadius.all(Radius.circular(ZipRadii.control + 2)),
      padding: const EdgeInsets.symmetric(horizontal: ZipSpacing.m, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: color),
            const SizedBox(width: ZipSpacing.xs),
          ],
          Text(
            label,
            style: ZipText.inter(size: 17, weight: FontWeight.w500, color: color),
          ),
        ],
      ),
    );
  }
}
