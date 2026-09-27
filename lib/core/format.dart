/// Formatierung für die deutsche Darstellung (ohne intl-Paket).
library;

const List<String> _monthNames = [
  'Januar',
  'Februar',
  'März',
  'April',
  'Mai',
  'Juni',
  'Juli',
  'August',
  'September',
  'Oktober',
  'November',
  'Dezember',
];

const List<String> _monthShort = [
  'Jan.',
  'Feb.',
  'März',
  'Apr.',
  'Mai',
  'Juni',
  'Juli',
  'Aug.',
  'Sept.',
  'Okt.',
  'Nov.',
  'Dez.',
];

const List<String> _weekdayShort = ['Mo.', 'Di.', 'Mi.', 'Do.', 'Fr.', 'Sa.', 'So.'];

const List<String> _weekdayLong = [
  'Montag',
  'Dienstag',
  'Mittwoch',
  'Donnerstag',
  'Freitag',
  'Samstag',
  'Sonntag',
];

/// Zahl mit Tausenderpunkt und Dezimalkomma, z. B. `1.284,6`.
String formatNumber(num value, {int decimals = 0}) {
  final fixed = value.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final digits = parts[0];
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  var result = buffer.toString();
  if (decimals > 0) result = '$result,${parts[1]}';
  // „-0“ vermeiden: nur negativ, wenn nach dem Runden etwas übrig bleibt.
  final isZero = double.parse(fixed) == 0;
  return value < 0 && !isZero ? '-$result' : result;
}

/// Meter als Kilometer mit einer Nachkommastelle, z. B. `12,4 km`.
String formatKm(int meters, {int decimals = 1}) =>
    '${formatNumber(meters / 1000, decimals: decimals)} km';

/// Dauer kompakt: `45 s`, `32 min`, `1 h 04 min`.
String formatDuration(int seconds) {
  if (seconds < 60) return '$seconds s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = (minutes % 60).toString().padLeft(2, '0');
  return '$hours h $rest min';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Uhrzeit `14:32`.
String formatClock(DateTime local) => '${_two(local.hour)}:${_two(local.minute)}';

/// Kurzes Datum `Sa., 27. Sept.`.
String formatDateShort(DateTime local) =>
    '${_weekdayShort[local.weekday - 1]} ${local.day}. ${_monthShort[local.month - 1]}';

/// Langes Datum `Samstag, 27. September 2026`.
String formatDateLong(DateTime local) =>
    '${_weekdayLong[local.weekday - 1]}, ${local.day}. ${_monthNames[local.month - 1]} ${local.year}';

/// `September 2026`.
String formatMonthYear(DateTime local) => '${_monthNames[local.month - 1]} ${local.year}';

/// Monatsname ohne Jahr.
String formatMonth(DateTime local) => _monthNames[local.month - 1];

/// Freier SD-Speicher: `850 MB` oder `29,2 GB`.
String formatStorageMb(int mb) {
  if (mb >= 1024) return '${formatNumber(mb / 1024, decimals: 1)} GB';
  return '${formatNumber(mb)} MB';
}

/// Liest eine Zahl in deutscher oder englischer Schreibweise
/// (`1.284,6`, `1284,6`, `1284.6`, `1.284`). Gibt `null` bei ungültiger Eingabe.
double? parseLocalizedNumber(String input) {
  var s = input.trim().replaceAll(' ', '').replaceAll(' ', '');
  if (s.isEmpty) return null;
  if (s.contains(',')) {
    // Deutsch: Punkte sind Tausendertrenner, Komma ist Dezimaltrenner.
    s = s.replaceAll('.', '').replaceAll(',', '.');
  } else {
    final dots = '.'.allMatches(s).length;
    if (dots > 1) {
      s = s.replaceAll('.', '');
    } else if (dots == 1 && RegExp(r'^\d{1,3}\.\d{3}$').hasMatch(s)) {
      // „1.284“ ist im Deutschen eine Tausendergruppe.
      s = s.replaceAll('.', '');
    }
  }
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return null;
  return double.tryParse(s);
}
