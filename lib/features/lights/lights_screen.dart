import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/settings_group.dart';
import '../../widgets/zip_card.dart';
import '../common/connect_flow.dart';
import 'lights_controller.dart';

class LightsScreen extends ConsumerWidget {
  const LightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkStateProvider);
    final lights = ref.watch(lightsControllerProvider);
    final connected = link.isConnected;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final displayed = lights.displayed;

    return SafeArea(
      bottom: false,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          ZipSpacing.page,
          0,
          ZipSpacing.page,
          bottomInset + ZipSpacing.l,
        ),
        children: [
          const LargeTitle('Licht'),
          AnimatedSize(
            duration: ZipMotion.slow,
            curve: ZipMotion.curve,
            alignment: Alignment.topCenter,
            child: connected
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(bottom: ZipSpacing.m),
                    child: link.isBlocked
                        ? BluetoothNotice(link: link)
                        : _NotConnectedHint(busy: link.isBusy),
                  ),
          ),
          for (final channel in LightChannel.values)
            Padding(
              padding: const EdgeInsets.only(bottom: ZipSpacing.s),
              child: LightCard(
                channel: channel,
                on: connected && displayed.isOn(channel),
                enabled: connected,
                onChanged: (on) => ref.read(lightsControllerProvider.notifier).toggle(channel, on),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotConnectedHint extends ConsumerWidget {
  const _NotConnectedHint({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ZipCard(
      padding: const EdgeInsets.all(ZipSpacing.m + 2),
      child: Row(
        children: [
          const Icon(CupertinoIcons.info_circle, color: ZipColors.textSecondary),
          const SizedBox(width: ZipSpacing.s),
          Expanded(
            child: Text(
              busy ? 'Verbindung wird aufgebaut …' : 'Nicht verbunden – das Licht lässt sich nur schalten, wenn die Zip verbunden ist.',
              style: ZipText.footnote,
            ),
          ),
          if (!busy) ...[
            const SizedBox(width: ZipSpacing.s),
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 44),
              onPressed: () => unawaited(startConnect(context, ref)),
              child: Text(
                'Verbinden',
                style: ZipText.inter(size: 15, weight: FontWeight.w600, color: ZipColors.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Große Karte mit Icon, Name und Schalter für einen Lichtkanal.
class LightCard extends StatelessWidget {
  const LightCard({
    super.key,
    required this.channel,
    required this.on,
    required this.enabled,
    required this.onChanged,
  });

  final LightChannel channel;
  final bool on;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  IconData get _icon => switch (channel) {
    LightChannel.parking => CupertinoIcons.sun_min,
    LightChannel.headlight => CupertinoIcons.sun_max,
    LightChannel.hazard => CupertinoIcons.exclamationmark_triangle,
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: on,
      enabled: enabled,
      label: channel.label,
      child: ZipCard(
        color: on ? ZipColors.cardActive : ZipColors.card,
        padding: const EdgeInsets.symmetric(horizontal: ZipSpacing.m + 2, vertical: ZipSpacing.l),
        onTap: enabled ? () => onChanged(!on) : null,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.4,
          duration: ZipMotion.normal,
          child: Row(
            children: [
              _LightIcon(icon: _icon, on: on, blink: on && channel == LightChannel.hazard),
              const SizedBox(width: ZipSpacing.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(channel.label, style: ZipText.headline),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: ZipMotion.fast,
                      child: Text(
                        on ? 'An' : 'Aus',
                        key: ValueKey(on),
                        style: ZipText.caption.copyWith(
                          color: on ? ZipColors.accent : ZipColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ZipSwitch(value: on, onChanged: enabled ? onChanged : null),
            ],
          ),
        ),
      ),
    );
  }
}

class _LightIcon extends StatefulWidget {
  const _LightIcon({required this.icon, required this.on, required this.blink});

  final IconData icon;
  final bool on;
  final bool blink;

  @override
  State<_LightIcon> createState() => _LightIconState();
}

class _LightIconState extends State<_LightIcon> with SingleTickerProviderStateMixin {
  // Typischer Blinkrhythmus: ca. 1,5 Hz.
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 330),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_LightIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (widget.blink && !_blink.isAnimating) {
      _blink.repeat(reverse: true);
    } else if (!widget.blink && _blink.isAnimating) {
      _blink
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.on ? ZipColors.accent : ZipColors.textSecondary;
    return AnimatedContainer(
      duration: ZipMotion.normal,
      curve: ZipMotion.curve,
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: widget.on ? ZipColors.accent.withValues(alpha: 0.16) : ZipColors.elevated,
        borderRadius: const BorderRadius.all(Radius.circular(ZipRadii.icon)),
      ),
      child: FadeTransition(
        opacity: Tween<double>(
          begin: 1,
          end: 0.15,
        ).animate(CurvedAnimation(parent: _blink, curve: Curves.easeInOut)),
        child: Icon(widget.icon, color: color, size: 26),
      ),
    );
  }
}
