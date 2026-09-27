import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../ble/trip_sync.dart';
import 'models.dart';
import 'trip_file_parser.dart';

/// Lokale Speicherung der Fahrten mit sqflite.
///
/// Tabellen:
/// - `trips`: Zusammenfassung pro Fahrt (für die Liste)
/// - `trip_files`: Rohdatei pro Fahrt (für die Detailansicht, GPX)
/// - `download_segments`: Zwischenstände abgebrochener Downloads
/// - `deleted_trips`: lokal gelöschte Fahrten (werden nicht erneut geladen)
class TripDatabase implements TripStore {
  TripDatabase(this.fileName);

  final String fileName;
  Future<Database>? _db;

  Future<Database> get _database => _db ??= _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, fileName),
      version: 1,
      onCreate: (db, version) async {
        final batch = db.batch()
          ..execute('''
            CREATE TABLE trips (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              device_trip_id INTEGER NOT NULL,
              start_unix INTEGER NOT NULL,
              duration_s INTEGER NOT NULL,
              distance_m INTEGER NOT NULL,
              max_speed_kmh REAL NOT NULL,
              max_temp_c REAL,
              avg_moving_kmh REAL,
              point_count INTEGER NOT NULL,
              file_size INTEGER NOT NULL,
              preview BLOB,
              synced_at INTEGER NOT NULL,
              UNIQUE (device_trip_id, start_unix)
            )''')
          ..execute('CREATE INDEX trips_start ON trips (start_unix DESC)')
          ..execute('''
            CREATE TABLE trip_files (
              trip_id INTEGER PRIMARY KEY,
              data BLOB NOT NULL
            )''')
          ..execute('''
            CREATE TABLE download_segments (
              device_trip_id INTEGER NOT NULL,
              start_unix INTEGER NOT NULL,
              byte_offset INTEGER NOT NULL,
              expected_size INTEGER NOT NULL,
              data BLOB NOT NULL,
              PRIMARY KEY (device_trip_id, start_unix, byte_offset)
            )''')
          ..execute('''
            CREATE TABLE deleted_trips (
              device_trip_id INTEGER NOT NULL,
              start_unix INTEGER NOT NULL,
              PRIMARY KEY (device_trip_id, start_unix)
            )''');
        await batch.commit(noResult: true);
      },
    );
  }

  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null) await (await db).close();
  }

  // --- Lesen für die Oberfläche ---------------------------------------------

  static const _summaryColumns = [
    'id',
    'device_trip_id',
    'start_unix',
    'duration_s',
    'distance_m',
    'max_speed_kmh',
    'max_temp_c',
    'avg_moving_kmh',
    'point_count',
    'file_size',
    'preview',
  ];

  Future<List<TripSummary>> listTrips() async {
    final db = await _database;
    final rows = await db.query('trips', columns: _summaryColumns, orderBy: 'start_unix DESC');
    return rows.map(_summaryFromRow).toList(growable: false);
  }

  Future<TripDetail?> loadTrip(int localId) async {
    final db = await _database;
    final rows = await db.query(
      'trips',
      columns: _summaryColumns,
      where: 'id = ?',
      whereArgs: [localId],
    );
    if (rows.isEmpty) return null;
    final files = await db.query(
      'trip_files',
      columns: ['data'],
      where: 'trip_id = ?',
      whereArgs: [localId],
    );
    final summary = _summaryFromRow(rows.first);
    if (files.isEmpty) return TripDetail(summary: summary, points: const []);
    final bytes = files.first['data']! as Uint8List;
    final parsed = TripFileParser.parse(bytes);
    return TripDetail(summary: summary, points: parsed.points);
  }

  TripSummary _summaryFromRow(Map<String, Object?> row) {
    final preview = row['preview'] as Uint8List?;
    return TripSummary(
      localId: row['id']! as int,
      key: TripKey(row['device_trip_id']! as int, row['start_unix']! as int),
      durationS: row['duration_s']! as int,
      distanceM: row['distance_m']! as int,
      maxSpeedKmh: (row['max_speed_kmh']! as num).toDouble(),
      maxTempC: (row['max_temp_c'] as num?)?.toDouble(),
      avgMovingSpeedKmh: (row['avg_moving_kmh'] as num?)?.toDouble(),
      pointCount: row['point_count']! as int,
      fileSize: row['file_size']! as int,
      preview: preview == null || preview.lengthInBytes < 8
          ? Float32List(0)
          : Float32List.fromList(
              Float32List.view(Uint8List.fromList(preview).buffer, 0, preview.lengthInBytes ~/ 4),
            ),
    );
  }

  /// Löscht eine Fahrt lokal. Sie wird danach nicht erneut übertragen.
  Future<void> deleteTrip(int localId) async {
    final db = await _database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'trips',
        columns: ['device_trip_id', 'start_unix'],
        where: 'id = ?',
        whereArgs: [localId],
      );
      if (rows.isEmpty) return;
      await txn.insert('deleted_trips', {
        'device_trip_id': rows.first['device_trip_id'],
        'start_unix': rows.first['start_unix'],
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.delete('trip_files', where: 'trip_id = ?', whereArgs: [localId]);
      await txn.delete('trips', where: 'id = ?', whereArgs: [localId]);
    });
  }

  /// Löscht alle lokalen Fahrten (inklusive Zwischenstände).
  Future<void> deleteAllTrips() async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.execute('''
        INSERT OR IGNORE INTO deleted_trips (device_trip_id, start_unix)
        SELECT device_trip_id, start_unix FROM trips''');
      await txn.delete('trip_files');
      await txn.delete('trips');
      await txn.delete('download_segments');
    });
  }

  // --- TripStore ------------------------------------------------------------

  @override
  Future<Map<TripKey, int>> localFileSizes() async {
    final db = await _database;
    final rows = await db.query('trips', columns: ['device_trip_id', 'start_unix', 'file_size']);
    return {
      for (final r in rows)
        TripKey(r['device_trip_id']! as int, r['start_unix']! as int): r['file_size']! as int,
    };
  }

  @override
  Future<Set<TripKey>> deletedKeys() async {
    final db = await _database;
    final rows = await db.query('deleted_trips');
    return {for (final r in rows) TripKey(r['device_trip_id']! as int, r['start_unix']! as int)};
  }

  @override
  Future<PartialDownload?> loadPartial(TripKey key) async {
    final db = await _database;
    final rows = await db.query(
      'download_segments',
      where: 'device_trip_id = ? AND start_unix = ?',
      whereArgs: [key.tripId, key.startUnix],
      orderBy: 'byte_offset ASC',
    );
    if (rows.isEmpty) return null;
    final builder = BytesBuilder(copy: false);
    final expected = rows.first['expected_size']! as int;
    for (final r in rows) {
      final offset = r['byte_offset']! as int;
      final data = r['data']! as Uint8List;
      if (r['expected_size'] != expected) break;
      if (offset > builder.length) break; // Lücke – Rest verwerfen
      final skip = builder.length - offset;
      if (skip < data.length) builder.add(Uint8List.sublistView(data, skip));
    }
    return PartialDownload(expected, builder.takeBytes());
  }

  @override
  Future<void> appendPartial(TripKey key, int offset, Uint8List data, int expectedSize) async {
    final db = await _database;
    await db.insert('download_segments', {
      'device_trip_id': key.tripId,
      'start_unix': key.startUnix,
      'byte_offset': offset,
      'expected_size': expectedSize,
      'data': data,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clearPartial(TripKey key) async {
    final db = await _database;
    await db.delete(
      'download_segments',
      where: 'device_trip_id = ? AND start_unix = ?',
      whereArgs: [key.tripId, key.startUnix],
    );
  }

  @override
  Future<void> saveTrip(TripEntry entry, Uint8List file, TripFile parsed) async {
    final db = await _database;
    final values = tripRowValues(entry, file.length, parsed.points);
    await db.transaction((txn) async {
      final existing = await txn.query(
        'trips',
        columns: ['id'],
        where: 'device_trip_id = ? AND start_unix = ?',
        whereArgs: [entry.tripId, entry.startUnix],
      );
      final int id;
      if (existing.isEmpty) {
        id = await txn.insert('trips', values);
      } else {
        id = existing.first['id']! as int;
        await txn.update('trips', values, where: 'id = ?', whereArgs: [id]);
      }
      await txn.insert('trip_files', {
        'trip_id': id,
        'data': file,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
}

/// Zeilenwerte für die Tabelle `trips`. Werte vom Roller haben Vorrang,
/// fehlende (0) werden aus den Punkten berechnet.
Map<String, Object?> tripRowValues(TripEntry entry, int fileSize, List<TripPoint> points) {
  final stats = TripStats.fromPoints(points);
  final preview = buildRoutePreview(points);
  final maxTemp = entry.maxTempDeciC != kInvalidTemperature && entry.maxTempDeciC != 0
      ? entry.maxTempDeciC / 10.0
      : stats.maxTempC;
  return {
    'device_trip_id': entry.tripId,
    'start_unix': entry.startUnix,
    'duration_s': entry.durationS > 0 ? entry.durationS : stats.durationS,
    'distance_m': entry.distanceM > 0 ? entry.distanceM : stats.distanceM,
    'max_speed_kmh': entry.maxSpeedDeciKmh > 0 ? entry.maxSpeedDeciKmh / 10.0 : stats.maxSpeedKmh,
    'max_temp_c': maxTemp,
    'avg_moving_kmh': stats.avgMovingSpeedKmh,
    'point_count': entry.pointCount > 0 ? entry.pointCount : points.length,
    'file_size': fileSize,
    'preview': preview.buffer.asUint8List(preview.offsetInBytes, preview.lengthInBytes),
    'synced_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  };
}
