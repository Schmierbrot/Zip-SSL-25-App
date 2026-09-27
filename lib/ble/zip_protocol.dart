/// BLE-Protokoll der Zip (verbindlich, identisch in der Firmware).
///
/// Alle Mehrbyte-Werte sind Little Endian. Diese Datei enthält UUIDs,
/// Opcodes, Parser für alles, was der ESP sendet, und Builder für alles,
/// was die App sendet. Zusätzlich gibt es Encoder für die Gegenrichtung
/// (vom Demo-Modus und den Tests genutzt).
library;

import 'dart:typed_data';

import '../data/models.dart';

// ---------------------------------------------------------------------------
// UUIDs, Opcodes, Konstanten
// ---------------------------------------------------------------------------

abstract final class ZipUuids {
  static const String service = 'f00d0001-a1b2-4c3d-8e9f-5a1b2c3d4e5f';
  static const String telemetry = 'f00d0002-a1b2-4c3d-8e9f-5a1b2c3d4e5f';
  static const String light = 'f00d0003-a1b2-4c3d-8e9f-5a1b2c3d4e5f';
  static const String control = 'f00d0005-a1b2-4c3d-8e9f-5a1b2c3d4e5f';
  static const String response = 'f00d0006-a1b2-4c3d-8e9f-5a1b2c3d4e5f';
}

/// Gerätename, unter dem die Zip wirbt.
const String kZipDeviceName = 'Zip';

/// Protokollversion, die diese App versteht.
const int kProtocolVersion = 1;

/// Länge eines Telemetrie-Pakets.
const int kTelemetryLength = 16;

abstract final class ZipOpcode {
  // Befehle (App → ESP)
  static const int listTrips = 0x01;
  static const int readTrip = 0x02;
  static const int deleteTrip = 0x03;
  static const int setOdometer = 0x04;
  static const int setTempLimit = 0x05;
  static const int readInfo = 0x06;

  // Antworten (ESP → App)
  static const int tripEntry = 0x81;
  static const int listEnd = 0x82;
  static const int chunk = 0x83;
  static const int endOfFile = 0x84;
  static const int ack = 0x85;
  static const int info = 0x86;
  static const int error = 0xFF;
}

/// Fehlercodes der Antwort 0xFF.
abstract final class ZipErrorCode {
  static const int unknownCommand = 1;
  static const int wrongLength = 2;
  static const int tripNotFound = 3;
  static const int sdError = 4;
  static const int busy = 5;
}

/// Verständliche deutsche Meldung zu einem Fehlercode.
String zipErrorMessage(int code) {
  switch (code) {
    case ZipErrorCode.unknownCommand:
      return 'Der Roller kennt diesen Befehl nicht. Bitte Firmware aktualisieren.';
    case ZipErrorCode.wrongLength:
      return 'Der Roller hat den Befehl nicht verstanden (falsche Länge).';
    case ZipErrorCode.tripNotFound:
      return 'Die Fahrt wurde auf dem Roller nicht gefunden.';
    case ZipErrorCode.sdError:
      return 'Fehler beim Zugriff auf die SD-Karte im Roller.';
    case ZipErrorCode.busy:
      return 'Der Roller ist gerade beschäftigt. Bitte gleich noch einmal versuchen.';
    default:
      return 'Unbekannter Fehler vom Roller (Code $code).';
  }
}

// ---------------------------------------------------------------------------
// Ausnahmen
// ---------------------------------------------------------------------------

/// Ein Paket hat ein ungültiges Format (zu kurz, unbekannter Opcode …).
class ZipFormatException implements Exception {
  const ZipFormatException(this.message);

  final String message;

  @override
  String toString() => 'ZipFormatException: $message';
}

/// Grund, warum ein Telemetrie-Paket verworfen wurde.
enum TelemetryRejection { wrongLength, unsupportedVersion }

class TelemetryFormatException extends ZipFormatException {
  const TelemetryFormatException(this.reason, String message) : super(message);

  final TelemetryRejection reason;
}

/// Ein Befehl wurde vom ESP mit einem Fehler beantwortet.
class ZipCommandException implements Exception {
  const ZipCommandException(this.commandOpcode, this.code);

  final int commandOpcode;
  final int code;

  String get message => zipErrorMessage(code);

  @override
  String toString() => 'ZipCommandException(0x${commandOpcode.toRadixString(16)}, $code): $message';
}

// ---------------------------------------------------------------------------
// Lese-/Schreibhilfen
// ---------------------------------------------------------------------------

ByteData _view(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  return ByteData.sublistView(data);
}

void _requireLength(List<int> bytes, int length, String what) {
  if (bytes.length < length) {
    throw ZipFormatException('$what: mindestens $length Bytes erwartet, ${bytes.length} erhalten');
  }
}

void _checkRange(int value, int max, String name) {
  if (value < 0 || value > max) {
    throw ArgumentError.value(value, name, 'außerhalb 0..$max');
  }
}

class _Writer {
  _Writer(int length) : _data = ByteData(length);

  final ByteData _data;
  int _offset = 0;

  void u8(int v) {
    _data.setUint8(_offset, v);
    _offset += 1;
  }

  void u16(int v) {
    _data.setUint16(_offset, v, Endian.little);
    _offset += 2;
  }

  void i16(int v) {
    _data.setInt16(_offset, v, Endian.little);
    _offset += 2;
  }

  void u32(int v) {
    _data.setUint32(_offset, v, Endian.little);
    _offset += 4;
  }

  void i32(int v) {
    _data.setInt32(_offset, v, Endian.little);
    _offset += 4;
  }

  Uint8List get bytes => _data.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Telemetrie (0002) und Licht (0003)
// ---------------------------------------------------------------------------

/// Parst ein Telemetrie-Paket. Wirft [TelemetryFormatException] bei falscher
/// Länge oder unbekannter Protokollversion – solche Pakete werden verworfen.
Telemetry parseTelemetry(List<int> bytes) {
  if (bytes.length != kTelemetryLength) {
    throw TelemetryFormatException(
      TelemetryRejection.wrongLength,
      'Telemetrie: $kTelemetryLength Bytes erwartet, ${bytes.length} erhalten',
    );
  }
  final d = _view(bytes);
  final version = d.getUint8(0);
  if (version != kProtocolVersion) {
    throw TelemetryFormatException(
      TelemetryRejection.unsupportedVersion,
      'Telemetrie: Protokollversion $version wird nicht unterstützt',
    );
  }
  return Telemetry(
    protocolVersion: version,
    flags: d.getUint8(1),
    speedDeciKmh: d.getUint16(2, Endian.little),
    tempDeciC: d.getInt16(4, Endian.little),
    odometerM: d.getUint32(6, Endian.little),
    tripDistanceM: d.getUint32(10, Endian.little),
    satellites: d.getUint8(14),
    lights: LightState(d.getUint8(15)),
  );
}

Uint8List encodeTelemetry(Telemetry t) {
  final w = _Writer(kTelemetryLength)
    ..u8(t.protocolVersion)
    ..u8(t.flags)
    ..u16(t.speedDeciKmh)
    ..i16(t.tempDeciC)
    ..u32(t.odometerM)
    ..u32(t.tripDistanceM)
    ..u8(t.satellites)
    ..u8(t.lights.bits);
  return w.bytes;
}

/// Parst den Lichtzustand (1 Byte). Zusätzliche Bytes werden ignoriert.
LightState parseLightState(List<int> bytes) {
  _requireLength(bytes, 1, 'Licht');
  return LightState(bytes[0]);
}

Uint8List encodeLightState(LightState state) => Uint8List.fromList([state.bits]);

// ---------------------------------------------------------------------------
// Befehle (App → ESP, Characteristic 0005)
// ---------------------------------------------------------------------------

abstract final class ZipCommands {
  static Uint8List listTrips() => Uint8List.fromList([ZipOpcode.listTrips]);

  static Uint8List readTrip(int tripId, int offset, int maxChunks) {
    _checkRange(tripId, 0xFFFFFFFF, 'tripId');
    _checkRange(offset, 0xFFFFFFFF, 'offset');
    if (maxChunks < 1 || maxChunks > 255) {
      throw ArgumentError.value(maxChunks, 'maxChunks', 'außerhalb 1..255');
    }
    return (_Writer(10)
          ..u8(ZipOpcode.readTrip)
          ..u32(tripId)
          ..u32(offset)
          ..u8(maxChunks))
        .bytes;
  }

  static Uint8List deleteTrip(int tripId) {
    _checkRange(tripId, 0xFFFFFFFF, 'tripId');
    return (_Writer(5)
          ..u8(ZipOpcode.deleteTrip)
          ..u32(tripId))
        .bytes;
  }

  static Uint8List setOdometer(int meters) {
    _checkRange(meters, 0xFFFFFFFF, 'meters');
    return (_Writer(5)
          ..u8(ZipOpcode.setOdometer)
          ..u32(meters))
        .bytes;
  }

  static Uint8List setTempLimit(int celsius) {
    _checkRange(celsius, 0xFFFF, 'celsius');
    return (_Writer(3)
          ..u8(ZipOpcode.setTempLimit)
          ..u16(celsius))
        .bytes;
  }

  static Uint8List readInfo() => Uint8List.fromList([ZipOpcode.readInfo]);
}

/// Ein vom ESP empfangener Befehl (nur für den Demo-Modus/Tests).
sealed class ZipCommand {
  const ZipCommand();
}

final class ListTripsCommand extends ZipCommand {
  const ListTripsCommand();
}

final class ReadTripCommand extends ZipCommand {
  const ReadTripCommand(this.tripId, this.offset, this.maxChunks);

  final int tripId;
  final int offset;
  final int maxChunks;
}

final class DeleteTripCommand extends ZipCommand {
  const DeleteTripCommand(this.tripId);

  final int tripId;
}

final class SetOdometerCommand extends ZipCommand {
  const SetOdometerCommand(this.meters);

  final int meters;
}

final class SetTempLimitCommand extends ZipCommand {
  const SetTempLimitCommand(this.celsius);

  final int celsius;
}

final class ReadInfoCommand extends ZipCommand {
  const ReadInfoCommand();
}

/// Parst einen Befehl so, wie es die Firmware tut. Wirft
/// [ZipCommandException] mit Fehlercode 1 (unbekannt) oder 2 (Länge).
ZipCommand parseCommand(List<int> bytes) {
  if (bytes.isEmpty) {
    throw const ZipCommandException(0, ZipErrorCode.wrongLength);
  }
  final op = bytes[0];
  final d = _view(bytes);

  void expect(int length) {
    if (bytes.length != length) {
      throw ZipCommandException(op, ZipErrorCode.wrongLength);
    }
  }

  switch (op) {
    case ZipOpcode.listTrips:
      expect(1);
      return const ListTripsCommand();
    case ZipOpcode.readTrip:
      expect(10);
      return ReadTripCommand(
        d.getUint32(1, Endian.little),
        d.getUint32(5, Endian.little),
        d.getUint8(9),
      );
    case ZipOpcode.deleteTrip:
      expect(5);
      return DeleteTripCommand(d.getUint32(1, Endian.little));
    case ZipOpcode.setOdometer:
      expect(5);
      return SetOdometerCommand(d.getUint32(1, Endian.little));
    case ZipOpcode.setTempLimit:
      expect(3);
      return SetTempLimitCommand(d.getUint16(1, Endian.little));
    case ZipOpcode.readInfo:
      expect(1);
      return const ReadInfoCommand();
    default:
      throw ZipCommandException(op, ZipErrorCode.unknownCommand);
  }
}

// ---------------------------------------------------------------------------
// Antworten (ESP → App, Characteristic 0006)
// ---------------------------------------------------------------------------

sealed class ZipResponse {
  const ZipResponse();

  int get opcode;
}

/// 0x81 – ein Eintrag der Fahrtenliste.
final class TripEntryResponse extends ZipResponse {
  const TripEntryResponse(this.entry);

  final TripEntry entry;

  @override
  int get opcode => ZipOpcode.tripEntry;
}

/// 0x82 – Ende der Fahrtenliste.
final class TripListEndResponse extends ZipResponse {
  const TripListEndResponse(this.count);

  final int count;

  @override
  int get opcode => ZipOpcode.listEnd;
}

/// 0x83 – ein Datenstück einer Fahrtdatei.
final class TripChunkResponse extends ZipResponse {
  const TripChunkResponse(this.tripId, this.offset, this.data);

  final int tripId;
  final int offset;
  final Uint8List data;

  @override
  int get opcode => ZipOpcode.chunk;
}

/// 0x84 – Dateiende mit Gesamtgröße und CRC32.
final class TripEndOfFileResponse extends ZipResponse {
  const TripEndOfFileResponse(this.tripId, this.totalSize, this.crc32);

  final int tripId;
  final int totalSize;
  final int crc32;

  @override
  int get opcode => ZipOpcode.endOfFile;
}

/// 0x85 – Bestätigung eines Befehls.
final class AckResponse extends ZipResponse {
  const AckResponse(this.commandOpcode, this.status);

  final int commandOpcode;
  final int status;

  bool get ok => status == 0;

  @override
  int get opcode => ZipOpcode.ack;
}

/// 0x86 – Einstellungen/Info.
final class InfoResponse extends ZipResponse {
  const InfoResponse(this.info);

  final DeviceInfo info;

  @override
  int get opcode => ZipOpcode.info;
}

/// 0xFF – Fehler.
final class ErrorResponse extends ZipResponse {
  const ErrorResponse(this.commandOpcode, this.code);

  final int commandOpcode;
  final int code;

  String get message => zipErrorMessage(code);

  @override
  int get opcode => ZipOpcode.error;
}

/// Mindestlängen der Antworten (inklusive Opcode).
abstract final class ZipResponseLength {
  static const int tripEntry = 29;
  static const int listEnd = 3;
  static const int chunkHeader = 9;
  static const int endOfFile = 13;
  static const int ack = 3;
  static const int info = 15;
  static const int error = 3;
}

/// Parst eine Antwort. Wirft [ZipFormatException] bei zu kurzen Paketen
/// oder unbekanntem Opcode. Längere Pakete werden toleriert (Vorwärtskompatibilität),
/// außer beim Datenstück, dessen Rest die Nutzdaten sind.
ZipResponse parseResponse(List<int> bytes) {
  if (bytes.isEmpty) throw const ZipFormatException('Leere Antwort');
  final d = _view(bytes);
  final op = bytes[0];
  switch (op) {
    case ZipOpcode.tripEntry:
      _requireLength(bytes, ZipResponseLength.tripEntry, 'Fahrteintrag');
      return TripEntryResponse(
        TripEntry(
          tripId: d.getUint32(1, Endian.little),
          startUnix: d.getUint32(5, Endian.little),
          durationS: d.getUint32(9, Endian.little),
          distanceM: d.getUint32(13, Endian.little),
          maxSpeedDeciKmh: d.getUint16(17, Endian.little),
          maxTempDeciC: d.getInt16(19, Endian.little),
          pointCount: d.getUint32(21, Endian.little),
          fileSize: d.getUint32(25, Endian.little),
        ),
      );
    case ZipOpcode.listEnd:
      _requireLength(bytes, ZipResponseLength.listEnd, 'Listenende');
      return TripListEndResponse(d.getUint16(1, Endian.little));
    case ZipOpcode.chunk:
      _requireLength(bytes, ZipResponseLength.chunkHeader, 'Datenstück');
      final data = Uint8List.fromList(bytes.sublist(ZipResponseLength.chunkHeader));
      return TripChunkResponse(d.getUint32(1, Endian.little), d.getUint32(5, Endian.little), data);
    case ZipOpcode.endOfFile:
      _requireLength(bytes, ZipResponseLength.endOfFile, 'Dateiende');
      return TripEndOfFileResponse(
        d.getUint32(1, Endian.little),
        d.getUint32(5, Endian.little),
        d.getUint32(9, Endian.little),
      );
    case ZipOpcode.ack:
      _requireLength(bytes, ZipResponseLength.ack, 'Bestätigung');
      return AckResponse(d.getUint8(1), d.getUint8(2));
    case ZipOpcode.info:
      _requireLength(bytes, ZipResponseLength.info, 'Info');
      return InfoResponse(
        DeviceInfo(
          protocolVersion: d.getUint8(1),
          firmwareVersion: [d.getUint8(2), d.getUint8(3), d.getUint8(4)],
          tempLimitC: d.getUint16(5, Endian.little),
          odometerM: d.getUint32(7, Endian.little),
          sdFreeMb: d.getUint32(11, Endian.little),
        ),
      );
    case ZipOpcode.error:
      _requireLength(bytes, ZipResponseLength.error, 'Fehler');
      return ErrorResponse(d.getUint8(1), d.getUint8(2));
    default:
      throw ZipFormatException('Unbekannter Antwort-Opcode 0x${op.toRadixString(16)}');
  }
}

// --- Encoder für Antworten (Demo-Modus und Tests) ---------------------------

Uint8List encodeTripEntry(TripEntry e) =>
    (_Writer(ZipResponseLength.tripEntry)
          ..u8(ZipOpcode.tripEntry)
          ..u32(e.tripId)
          ..u32(e.startUnix)
          ..u32(e.durationS)
          ..u32(e.distanceM)
          ..u16(e.maxSpeedDeciKmh)
          ..i16(e.maxTempDeciC)
          ..u32(e.pointCount)
          ..u32(e.fileSize))
        .bytes;

Uint8List encodeListEnd(int count) =>
    (_Writer(ZipResponseLength.listEnd)
          ..u8(ZipOpcode.listEnd)
          ..u16(count))
        .bytes;

Uint8List encodeChunk(int tripId, int offset, List<int> data) {
  final header =
      (_Writer(ZipResponseLength.chunkHeader)
            ..u8(ZipOpcode.chunk)
            ..u32(tripId)
            ..u32(offset))
          .bytes;
  return Uint8List(header.length + data.length)
    ..setAll(0, header)
    ..setAll(header.length, data);
}

Uint8List encodeEndOfFile(int tripId, int totalSize, int crc32) =>
    (_Writer(ZipResponseLength.endOfFile)
          ..u8(ZipOpcode.endOfFile)
          ..u32(tripId)
          ..u32(totalSize)
          ..u32(crc32))
        .bytes;

Uint8List encodeAck(int commandOpcode, int status) =>
    Uint8List.fromList([ZipOpcode.ack, commandOpcode, status]);

Uint8List encodeInfo(DeviceInfo info) =>
    (_Writer(ZipResponseLength.info)
          ..u8(ZipOpcode.info)
          ..u8(info.protocolVersion)
          ..u8(info.firmwareVersion[0])
          ..u8(info.firmwareVersion[1])
          ..u8(info.firmwareVersion[2])
          ..u16(info.tempLimitC)
          ..u32(info.odometerM)
          ..u32(info.sdFreeMb))
        .bytes;

Uint8List encodeError(int commandOpcode, int code) =>
    Uint8List.fromList([ZipOpcode.error, commandOpcode, code]);

// ---------------------------------------------------------------------------
// Fahrtdatei-Encoder (Header 32 Bytes + Datensätze à 16 Bytes)
// ---------------------------------------------------------------------------

const int kTripFileHeaderLength = 32;
const int kTripRecordLength = 16;
const List<int> kTripFileMagic = [0x5A, 0x49, 0x50, 0x54]; // "ZIPT"
const int kTripFileFormatVersion = 1;

/// Baut eine Fahrtdatei (für Demo-Modus und Tests).
Uint8List encodeTripFile({
  required int tripId,
  required int startUnix,
  required List<TripPoint> points,
  int formatVersion = kTripFileFormatVersion,
}) {
  final w = _Writer(kTripFileHeaderLength + points.length * kTripRecordLength);
  for (final b in kTripFileMagic) {
    w.u8(b);
  }
  w
    ..u8(formatVersion)
    ..u8(0)
    ..u8(0)
    ..u8(0)
    ..u32(tripId)
    ..u32(startUnix);
  for (var i = 16; i < kTripFileHeaderLength; i++) {
    w.u8(0);
  }
  for (final p in points) {
    w
      ..i32(p.latE7)
      ..i32(p.lonE7)
      ..u32(p.timeMs)
      ..u16(p.speedDeciKmh)
      ..i16(p.tempDeciC);
  }
  return w.bytes;
}

// ---------------------------------------------------------------------------
// CRC32 (IEEE 802.3, Polynom 0xEDB88320 reflektiert)
// ---------------------------------------------------------------------------

class Crc32 {
  Crc32();

  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[n] = c;
    }
    return table;
  }

  int _crc = 0xFFFFFFFF;

  void add(List<int> data) {
    var c = _crc;
    for (final b in data) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    _crc = c;
  }

  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  static int compute(List<int> data) => (Crc32()..add(data)).value;
}
