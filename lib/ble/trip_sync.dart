import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/trip_file_parser.dart';
import 'zip_client.dart';
import 'zip_protocol.dart';

/// Teilweise heruntergeladene Datei (lückenlos ab Offset 0).
class PartialDownload {
  const PartialDownload(this.expectedSize, this.data);

  final int expectedSize;
  final Uint8List data;
}

/// Speicher, den die Synchronisation braucht (umgesetzt von [TripDatabase],
/// in Tests durch eine In-Memory-Variante ersetzt).
abstract class TripStore {
  /// Dateigrößen aller lokal gespeicherten Fahrten.
  Future<Map<TripKey, int>> localFileSizes();

  /// Lokal gelöschte Fahrten, die nicht erneut übertragen werden sollen.
  Future<Set<TripKey>> deletedKeys();

  Future<PartialDownload?> loadPartial(TripKey key);

  Future<void> appendPartial(TripKey key, int offset, Uint8List data, int expectedSize);

  Future<void> clearPartial(TripKey key);

  /// Speichert (oder ersetzt) eine vollständig übertragene Fahrt.
  Future<void> saveTrip(TripEntry entry, Uint8List file, TripFile parsed);
}

/// Fortschritt der Synchronisation für die Oberfläche.
@immutable
class SyncProgress {
  const SyncProgress({required this.current, required this.total, required this.fraction});

  /// Nummer der aktuell übertragenen Fahrt (1-basiert).
  final int current;
  final int total;

  /// Gesamtfortschritt 0..1.
  final double fraction;
}

/// Ergebnis eines Synchronisationslaufs.
@immutable
class SyncResult {
  const SyncResult({
    required this.listed,
    required this.downloaded,
    required this.failed,
    required this.deletedOnScooter,
    required this.remainingOnScooter,
    this.errors = const [],
  });

  /// Alle Fahrten, die der Roller gemeldet hat.
  final List<TripEntry> listed;
  final int downloaded;
  final int failed;
  final int deletedOnScooter;

  /// Fahrten, die nach dem Lauf noch auf dem Roller liegen.
  final Set<TripKey> remainingOnScooter;
  final List<String> errors;
}

class TripSyncException implements Exception {
  const TripSyncException(this.message);

  final String message;

  @override
  String toString() => 'TripSyncException: $message';
}

/// Lädt fehlende Fahrten vom Roller:
/// Liste holen (0x01) → pro fehlender Fahrt in Fenstern zu 32 Stücken lesen
/// (0x02), nach jedem Fenster ab dem letzten lückenlosen Offset weiter,
/// Lücken werden dadurch automatisch neu angefordert → CRC32 prüfen →
/// parsen → speichern → optional auf dem Roller löschen (0x03).
///
/// Zwischenstände werden nach jedem Fenster gespeichert, abgebrochene
/// Downloads setzen beim nächsten Mal dort wieder an.
class TripSync {
  TripSync({
    required this.client,
    required this.store,
    required this.deleteAfterTransfer,
    required this.isTripRunning,
    this.windowChunks = ZipClient.windowChunks,
    this.maxStalls = 3,
  });

  final ZipClient client;
  final TripStore store;
  final bool Function() deleteAfterTransfer;

  /// Zeichnet der Roller gerade eine Fahrt auf? Dann wird die neueste
  /// Fahrt nicht gelöscht, da sie womöglich noch geschrieben wird.
  final bool Function() isTripRunning;
  final int windowChunks;

  /// Fenster ohne Fortschritt, bevor eine Fahrt als fehlgeschlagen gilt.
  final int maxStalls;

  Future<SyncResult> run({
    void Function(SyncProgress progress)? onProgress,
    void Function(TripEntry entry)? onTripSaved,
  }) async {
    final listed = await client.listTrips();
    final local = await store.localFileSizes();
    final deleted = await store.deletedKeys();

    final todo = <TripEntry>[
      for (final e in listed)
        if (!deleted.contains(e.key) && (!local.containsKey(e.key) || e.fileSize > local[e.key]!))
          e,
    ]..sort((a, b) => a.startUnix.compareTo(b.startUnix));

    final newestId = listed.isEmpty ? null : listed.map((e) => e.tripId).reduce(math.max);

    var downloaded = 0;
    var failed = 0;
    var deletedOnScooter = 0;
    final remaining = {for (final e in listed) e.key};
    final errors = <String>[];

    for (var i = 0; i < todo.length; i++) {
      final entry = todo[i];
      void report(double tripFraction) => onProgress?.call(
        SyncProgress(
          current: i + 1,
          total: todo.length,
          fraction: ((i + tripFraction.clamp(0.0, 1.0)) / todo.length),
        ),
      );
      report(0);
      try {
        final bytes = await downloadTrip(entry, onProgress: report);
        final parsed = TripFileParser.parse(bytes);
        await store.saveTrip(entry, bytes, parsed);
        await store.clearPartial(entry.key);
        downloaded++;
        report(1);
        onTripSaved?.call(entry);

        final mayStillRecord = isTripRunning() && entry.tripId == newestId;
        if (deleteAfterTransfer() && !mayStillRecord) {
          try {
            await client.deleteTrip(entry.tripId);
            deletedOnScooter++;
            remaining.remove(entry.key);
          } catch (e) {
            errors.add(
              'Fahrt ${entry.tripId} konnte auf dem Roller nicht gelöscht werden: '
              '${describeSyncError(e)}',
            );
          }
        }
      } on TripFileFormatException catch (e) {
        await store.clearPartial(entry.key);
        failed++;
        errors.add('Fahrt ${entry.tripId}: Datei ungültig (${e.message})');
      } catch (e) {
        failed++;
        errors.add('Fahrt ${entry.tripId}: ${describeSyncError(e)}');
        // Verbindung weg: Rest beim nächsten Verbinden fortsetzen.
        if (!client.linkState.isConnected) break;
      }
    }

    return SyncResult(
      listed: listed,
      downloaded: downloaded,
      failed: failed,
      deletedOnScooter: deletedOnScooter,
      remainingOnScooter: remaining,
      errors: errors,
    );
  }

  /// Lädt eine einzelne Fahrtdatei und prüft die CRC32.
  @visibleForTesting
  Future<Uint8List> downloadTrip(
    TripEntry entry, {
    void Function(double fraction)? onProgress,
  }) async {
    final key = entry.key;
    var builder = BytesBuilder(copy: false);
    final partial = await store.loadPartial(key);
    if (partial != null &&
        partial.expectedSize == entry.fileSize &&
        partial.data.length <= entry.fileSize) {
      builder.add(partial.data);
    } else if (partial != null) {
      // Datei hat sich geändert – von vorne beginnen.
      await store.clearPartial(key);
    }

    var offset = builder.length;
    var stalls = 0;
    var crcRetries = 0;
    var expectedSize = entry.fileSize;

    while (true) {
      final window = await client.readTripWindow(
        entry.tripId,
        offset,
        maxChunks: windowChunks,
        expectedSize: expectedSize,
      );
      final data = window.contiguousFrom(offset);
      if (data.isNotEmpty) {
        builder.add(data);
        await store.appendPartial(key, offset, data, entry.fileSize);
        offset += data.length;
        stalls = 0;
      }

      final eof = window.endOfFile;
      if (eof != null) expectedSize = eof.totalSize;
      onProgress?.call(expectedSize > 0 ? offset / expectedSize : 0);

      if (eof != null && offset >= eof.totalSize) {
        final bytes = builder.toBytes();
        if (offset == eof.totalSize && Crc32.compute(bytes) == eof.crc32) {
          return bytes;
        }
        // Größe oder Prüfsumme passt nicht: Zwischenstand verwerfen, einmal neu.
        await store.clearPartial(key);
        if (crcRetries++ >= 1) {
          throw const TripSyncException('Prüfsumme der Fahrtdatei stimmt nicht');
        }
        builder = BytesBuilder(copy: false);
        offset = 0;
        stalls = 0;
        continue;
      }

      if (data.isEmpty && ++stalls >= maxStalls) {
        throw const TripSyncException('Übertragung kommt nicht voran');
      }
    }
  }
}

String describeSyncError(Object error) {
  if (error is TripSyncException) return error.message;
  if (error is TripFileFormatException) return error.message;
  return describeZipError(error);
}
