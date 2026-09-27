import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/dialogs.dart';
import '../../widgets/route_preview.dart';
import '../../widgets/zip_card.dart';
import 'trip_detail_screen.dart';
import 'trips_controller.dart';

class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key});

  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen> {
  /// Weggewischte Fahrten sofort ausblenden (die Liste lädt asynchron neu).
  final Set<int> _dismissed = {};

  Future<void> _refresh() async {
    final sync = ref.read(tripSyncProvider.notifier).sync(userInitiated: true);
    // Der Spinner muss nicht die ganze Übertragung stehen – dafür gibt es
    // den Fortschrittsbalken.
    await Future.any([sync, Future<void>.delayed(const Duration(milliseconds: 1200))]);
  }

  @override
  Widget build(BuildContext context) {
    final trips = ref.watch(tripListProvider);
    final sync = ref.watch(tripSyncProvider);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    final all = (trips.value ?? const <TripSummary>[])
        .where((t) => !_dismissed.contains(t.localId))
        .toList(growable: false);

    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          CupertinoSliverRefreshControl(onRefresh: _refresh),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: ZipSpacing.page),
            sliver: SliverList.list(
              children: [
                const LargeTitle('Fahrten'),
                _SyncProgressBar(state: sync),
                if (trips.hasError && all.isEmpty)
                  _Message(
                    icon: CupertinoIcons.exclamationmark_triangle,
                    title: 'Fahrten konnten nicht geladen werden',
                    text: '${trips.error}',
                  )
                else if (!trips.hasValue)
                  const Padding(
                    padding: EdgeInsets.only(top: ZipSpacing.xxl),
                    child: CupertinoActivityIndicator(),
                  )
                else if (all.isEmpty)
                  const _Message(
                    icon: CupertinoIcons.map,
                    title: 'Noch keine Fahrten',
                    text:
                        'Sobald deine Zip verbunden ist, werden aufgezeichnete Fahrten '
                        'automatisch übertragen. Zum Ausprobieren ohne Roller gibt es in den '
                        'Einstellungen den Demo-Modus.',
                  )
                else ...[
                  _MonthSummary(trips: all),
                  const SizedBox(height: ZipSpacing.l),
                  ..._buildGroups(all),
                ],
                SizedBox(height: bottomInset + ZipSpacing.l),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildGroups(List<TripSummary> trips) {
    final widgets = <Widget>[];
    String? currentMonth;
    for (final trip in trips) {
      final local = trip.startLocal;
      final month = formatMonthYear(local);
      if (month != currentMonth) {
        currentMonth = month;
        widgets.add(
          Padding(
            padding: EdgeInsets.only(
              left: ZipSpacing.xxs,
              bottom: ZipSpacing.xs,
              top: widgets.isEmpty ? 0 : ZipSpacing.m,
            ),
            child: Text(month.toUpperCase(), style: ZipText.label),
          ),
        );
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: ZipSpacing.s),
          child: _DismissibleTrip(
            key: ValueKey(trip.localId),
            trip: trip,
            onDismissed: () => setState(() => _dismissed.add(trip.localId)),
          ),
        ),
      );
    }
    return widgets;
  }
}

class _DismissibleTrip extends ConsumerWidget {
  const _DismissibleTrip({super.key, required this.trip, required this.onDismissed});

  final TripSummary trip;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey('dismiss-${trip.localId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: ZipSpacing.l),
        decoration: const BoxDecoration(color: ZipColors.accent, borderRadius: ZipRadii.cardRadius),
        child: const Icon(CupertinoIcons.delete, color: ZipColors.textPrimary),
      ),
      confirmDismiss: (_) async {
        final mode = await confirmTripDelete(context, ref, trip);
        if (mode == null) return false;
        unawaited(ref.read(tripSyncProvider.notifier).deleteTrip(trip, mode));
        return true;
      },
      onDismissed: (_) => onDismissed(),
      child: TripCard(
        trip: trip,
        onTap: () => Navigator.of(context)
            .push(CupertinoPageRoute<void>(builder: (_) => TripDetailScreen(tripId: trip.localId))),
      ),
    );
  }
}

/// Fragt, wie gelöscht werden soll (lokal / auch auf dem Roller).
Future<TripDeleteMode?> confirmTripDelete(BuildContext context, WidgetRef ref, TripSummary trip) {
  final onScooter = canDeleteOnScooter(ref, trip);
  return showActionSheet<TripDeleteMode>(
    context,
    title: 'Fahrt löschen?',
    message: onScooter
        ? 'Die Fahrt liegt noch auf dem Roller und kann dort ebenfalls gelöscht werden.'
        : 'Die Fahrt wird aus der App gelöscht.',
    options: [
      ActionSheetOption(
        label: onScooter ? 'Nur in der App löschen' : 'Löschen',
        value: TripDeleteMode.localOnly,
        destructive: true,
      ),
      if (onScooter)
        const ActionSheetOption(
          label: 'Auch auf dem Roller löschen',
          value: TripDeleteMode.alsoOnScooter,
          destructive: true,
        ),
    ],
  );
}

class TripCard extends StatelessWidget {
  const TripCard({super.key, required this.trip, this.onTap});

  final TripSummary trip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final local = trip.startLocal;
    return ZipCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(
        ZipSpacing.m + 2,
        ZipSpacing.m,
        ZipSpacing.m,
        ZipSpacing.m,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${formatDateShort(local)} · ${formatClock(local)}', style: ZipText.caption),
                const SizedBox(height: ZipSpacing.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      formatNumber(trip.distanceM / 1000, decimals: 1),
                      style: ZipText.number(34),
                    ),
                    const SizedBox(width: ZipSpacing.xxs + 2),
                    Text('km', style: ZipText.bodySecondary),
                  ],
                ),
                const SizedBox(height: ZipSpacing.xs),
                Text(
                  '${formatDuration(trip.durationS)} · max ${trip.maxSpeedKmh.round()} km/h',
                  style: ZipText.caption.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: ZipSpacing.m),
          RoutePreview(points: trip.preview),
        ],
      ),
    );
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.trips});

  final List<TripSummary> trips;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final thisMonth = trips.where((t) {
      final l = t.startLocal;
      return l.year == now.year && l.month == now.month;
    }).toList();
    final km = thisMonth.fold<int>(0, (sum, t) => sum + t.distanceM) / 1000;

    Widget figure(String value, String label) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: ZipText.number(40, weight: FontWeight.w200)),
        const SizedBox(height: ZipSpacing.xxs),
        Text(label, style: ZipText.label),
      ],
    );

    return ZipCard(
      padding: const EdgeInsets.all(ZipSpacing.m + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${formatMonth(now)} bisher'.toUpperCase(), style: ZipText.label),
          const SizedBox(height: ZipSpacing.s),
          Row(
            children: [
              Expanded(
                child: figure('${thisMonth.length}', thisMonth.length == 1 ? 'FAHRT' : 'FAHRTEN'),
              ),
              Expanded(child: figure(formatNumber(km, decimals: 1), 'KILOMETER')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SyncProgressBar extends StatelessWidget {
  const _SyncProgressBar({required this.state});

  final TripSyncState state;

  @override
  Widget build(BuildContext context) {
    final p = state.progress;
    final visible = state.running;
    return AnimatedSize(
      duration: ZipMotion.slow,
      curve: ZipMotion.curve,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: ZipSpacing.m),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(2)),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: p?.fraction ?? 0),
                      duration: ZipMotion.slow,
                      curve: ZipMotion.curve,
                      builder: (context, value, _) => LinearProgressIndicator(
                        value: p == null ? null : value,
                        minHeight: 3,
                        color: ZipColors.accent,
                        backgroundColor: ZipColors.elevated,
                      ),
                    ),
                  ),
                  const SizedBox(height: ZipSpacing.xs),
                  Text(
                    p == null || p.total == 0
                        ? 'Fahrten werden abgeglichen …'
                        : p.total == 1
                        ? 'Fahrt wird übertragen …'
                        : 'Fahrt ${p.current} von ${p.total} wird übertragen …',
                    style: ZipText.caption.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: ZipSpacing.xxl, left: ZipSpacing.l, right: ZipSpacing.l),
      child: Column(
        children: [
          Icon(icon, size: 44, color: ZipColors.textTertiary),
          const SizedBox(height: ZipSpacing.m),
          Text(title, style: ZipText.title, textAlign: TextAlign.center),
          const SizedBox(height: ZipSpacing.xs),
          Text(text, style: ZipText.footnote, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
