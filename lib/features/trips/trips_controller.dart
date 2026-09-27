import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/trip_sync.dart';
import '../../ble/zip_client.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import '../../data/models.dart';

@immutable
class TripSyncState {
  const TripSyncState({
    this.running = false,
    this.progress,
    this.onScooter = const {},
    this.lastError,
  });

  final bool running;
  final SyncProgress? progress;

  /// Fahrten, die laut letzter Liste noch auf dem Roller liegen.
  final Set<TripKey> onScooter;
  final String? lastError;

  TripSyncState copyWith({
    bool? running,
    SyncProgress? progress,
    bool clearProgress = false,
    Set<TripKey>? onScooter,
    String? lastError,
    bool clearError = false,
  }) {
    return TripSyncState(
      running: running ?? this.running,
      progress: clearProgress ? null : (progress ?? this.progress),
      onScooter: onScooter ?? this.onScooter,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

/// Steuert die Fahrten-Synchronisation (automatisch nach dem Verbinden und
/// per Pull-to-Refresh).
class TripSyncController extends Notifier<TripSyncState> {
  Future<void>? _running;

  @override
  TripSyncState build() {
    // Neue Datenquelle (Demo an/aus) → Zustand zurücksetzen.
    ref.watch(zipClientProvider);
    ref.watch(tripDatabaseProvider);
    return const TripSyncState();
  }

  /// Startet eine Synchronisation (läuft bereits eine, wird diese zurückgegeben).
  Future<void> sync({bool userInitiated = false}) {
    return _running ??= _run(userInitiated).whenComplete(() => _running = null);
  }

  Future<void> _run(bool userInitiated) async {
    final client = ref.read(zipClientProvider);
    if (!client.linkState.isConnected) {
      if (userInitiated) {
        showToast('Nicht verbunden – Fahrten werden beim nächsten Verbinden übertragen.');
      }
      return;
    }
    final db = ref.read(tripDatabaseProvider);
    state = state.copyWith(running: true, clearProgress: true, clearError: true);

    final sync = TripSync(
      client: client,
      store: db,
      deleteAfterTransfer: () => ref.read(settingsProvider).deleteAfterTransfer,
      isTripRunning: () => client.lastTelemetry?.tripRunning ?? false,
    );

    try {
      final result = await sync.run(
        onProgress: (p) {
          if (ref.mounted) state = state.copyWith(progress: p);
        },
        onTripSaved: (_) {
          if (ref.mounted) ref.invalidate(tripListProvider);
        },
      );
      if (!ref.mounted) return;
      state = TripSyncState(
        onScooter: result.remainingOnScooter,
        lastError: result.errors.isEmpty ? null : result.errors.first,
      );
      if (result.errors.isNotEmpty) {
        showToast(result.errors.first, isError: true);
      } else if (userInitiated) {
        showToast(
          result.downloaded == 0
              ? 'Alle Fahrten sind aktuell.'
              : result.downloaded == 1
              ? '1 neue Fahrt übertragen.'
              : '${result.downloaded} neue Fahrten übertragen.',
        );
      }
    } catch (e) {
      if (!ref.mounted) return;
      final message = describeSyncError(e);
      state = state.copyWith(running: false, clearProgress: true, lastError: message);
      if (userInitiated || client.linkState.isConnected) {
        showToast('Fahrten konnten nicht übertragen werden: $message', isError: true);
      }
    }
  }

  /// Löscht eine Fahrt lokal und optional auf dem Roller. Läuft im Notifier,
  /// damit es auch weiterläuft, wenn das auslösende Widget verschwindet.
  Future<void> deleteTrip(TripSummary trip, TripDeleteMode mode) async {
    final db = ref.read(tripDatabaseProvider);
    final client = ref.read(zipClientProvider);
    await db.deleteTrip(trip.localId);
    if (!ref.mounted) return;
    ref.invalidate(tripListProvider);
    if (mode == TripDeleteMode.alsoOnScooter) {
      try {
        await client.deleteTrip(trip.key.tripId);
        if (ref.mounted) {
          state = state.copyWith(onScooter: {...state.onScooter}..remove(trip.key));
        }
        showToast('Fahrt gelöscht – auch auf dem Roller.');
      } catch (e) {
        showToast('Auf dem Roller nicht gelöscht: ${describeZipError(e)}', isError: true);
      }
    } else {
      showToast('Fahrt gelöscht.');
    }
  }

  /// Löscht alle lokalen Fahrten (sie werden nicht erneut übertragen).
  Future<void> deleteAllLocal() async {
    await ref.read(tripDatabaseProvider).deleteAllTrips();
    if (!ref.mounted) return;
    ref.invalidate(tripListProvider);
    showToast('Alle lokalen Fahrten gelöscht.');
  }
}

final tripSyncProvider = NotifierProvider<TripSyncController, TripSyncState>(
  TripSyncController.new,
);

/// Wie eine Fahrt gelöscht werden soll.
enum TripDeleteMode { localOnly, alsoOnScooter }

/// Darf eine Fahrt zusätzlich auf dem Roller gelöscht werden?
bool canDeleteOnScooter(WidgetRef ref, TripSummary trip) {
  final connected = ref.read(linkStateProvider).isConnected;
  return connected && ref.read(tripSyncProvider).onScooter.contains(trip.key);
}
