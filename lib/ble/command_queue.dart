import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'zip_protocol.dart';

/// Was ein Kollektor mit einer Antwort gemacht hat.
enum CollectStatus {
  /// Gehört nicht zu diesem Befehl.
  ignored,

  /// Übernommen, es kommen noch weitere Antworten.
  accepted,

  /// Befehl vollständig beantwortet.
  complete,

  /// Antwort unvollständig/inkonsistent – Befehl wiederholen.
  retry,
}

/// Sammelt die Antworten zu genau einem Befehl.
abstract class ResponseCollector<T> {
  /// Opcode des Befehls, um 0xFF-Fehler zuordnen zu können.
  int get commandOpcode;

  /// Vor jedem (erneuten) Senden aufgerufen.
  void reset();

  /// Wertet eine Antwort aus. Darf [ZipCommandException] werfen.
  CollectStatus onResponse(ZipResponse response);

  /// Ergebnis, sobald [CollectStatus.complete] gemeldet wurde –
  /// oder bei [completesOnIdle] auch ein Teilergebnis.
  T get result;

  /// Wurde bereits etwas Verwertbares empfangen?
  bool get hasProgress => false;

  /// Bei Funkstille nach Teilempfang das Teilergebnis liefern statt zu wiederholen.
  bool get completesOnIdle => false;

  /// Wartezeit nach der letzten Antwort, wenn bereits etwas empfangen wurde.
  /// `null` = Standard-Timeout.
  Duration? get idleTimeout => null;
}

/// Der Roller hat nicht (rechtzeitig) geantwortet.
class ZipTimeoutException implements Exception {
  const ZipTimeoutException(this.commandOpcode);

  final int commandOpcode;

  String get message => 'Der Roller antwortet nicht.';

  @override
  String toString() => 'ZipTimeoutException(0x${commandOpcode.toRadixString(16)})';
}

/// Die Verbindung wurde getrennt, während ein Befehl offen war.
class ZipDisconnectedException implements Exception {
  const ZipDisconnectedException();

  String get message => 'Keine Verbindung zum Roller.';

  @override
  String toString() => 'ZipDisconnectedException';
}

/// Warteschlange für Befehle an die Steuer-Characteristic:
/// immer nur ein offener Befehl, Timeout (Standard 5 s) mit einer Wiederholung.
class ZipCommandQueue {
  ZipCommandQueue({
    required this.write,
    this.timeout = const Duration(seconds: 5),
    this.retries = 1,
    this.busyDelay = const Duration(milliseconds: 400),
  });

  /// Schreibt einen Befehl auf die Steuer-Characteristic.
  final Future<void> Function(Uint8List data) write;
  final Duration timeout;
  final int retries;
  final Duration busyDelay;

  final Queue<_Job<Object?>> _pending = Queue();
  _Job<Object?>? _active;
  bool _running = false;
  bool _closed = false;

  /// Anzahl offener + wartender Befehle.
  int get length => _pending.length + (_active == null ? 0 : 1);

  /// Stellt einen Befehl in die Warteschlange.
  Future<T> send<T>(Uint8List command, ResponseCollector<T> collector) {
    if (_closed) return Future<T>.error(const ZipDisconnectedException());
    final job = _Job<T>(command, collector);
    _pending.add(job);
    _pump();
    return job.completer.future;
  }

  /// Leitet eine empfangene Antwort an den offenen Befehl weiter.
  void handleResponse(ZipResponse response) => _active?.handle(response);

  /// Bricht alle offenen und wartenden Befehle ab (z. B. bei Verbindungsabbruch).
  void cancelAll([Object error = const ZipDisconnectedException()]) {
    final active = _active;
    if (active != null) active.abort(error);
    while (_pending.isNotEmpty) {
      _pending.removeFirst().fail(error);
    }
  }

  void dispose() {
    _closed = true;
    cancelAll();
  }

  void _pump() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (_pending.isNotEmpty) {
      final job = _pending.removeFirst();
      _active = job;
      await _run(job);
      _active = null;
    }
    _running = false;
  }

  Future<void> _run(_Job<Object?> job) async {
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (job.isDone) return;
      final outcome = job.startAttempt(timeout);
      try {
        await write(job.command);
      } catch (e) {
        // Schreibfehler = Verbindungsproblem, keine Wiederholung.
        job.fail(e);
        return;
      }
      final result = await outcome;
      switch (result) {
        case _AttemptResult.done:
          return;
        case _AttemptResult.timeout:
        case _AttemptResult.retry:
          continue;
        case _AttemptResult.busy:
          if (attempt < retries) await Future<void>.delayed(busyDelay);
          continue;
      }
    }
    job.failWithLastError(ZipTimeoutException(job.collector.commandOpcode));
  }
}

enum _AttemptResult { done, timeout, retry, busy }

class _Job<T> {
  _Job(this.command, this.collector);

  final Uint8List command;
  final ResponseCollector<T> collector;
  final Completer<T> completer = Completer<T>();

  Completer<_AttemptResult>? _attempt;
  Timer? _timer;
  Duration _timeout = const Duration(seconds: 5);
  Object? _lastError;

  bool get isDone => completer.isCompleted;

  Future<_AttemptResult> startAttempt(Duration timeout) {
    _timeout = timeout;
    collector.reset();
    final attempt = Completer<_AttemptResult>();
    _attempt = attempt;
    _restartTimer(timeout);
    return attempt.future;
  }

  void handle(ZipResponse response) {
    final attempt = _attempt;
    if (attempt == null || attempt.isCompleted) return;

    if (response is ErrorResponse && response.commandOpcode == collector.commandOpcode) {
      final error = ZipCommandException(response.commandOpcode, response.code);
      if (response.code == ZipErrorCode.busy) {
        _lastError = error;
        _finishAttempt(_AttemptResult.busy);
      } else {
        fail(error);
      }
      return;
    }

    final CollectStatus status;
    try {
      status = collector.onResponse(response);
    } catch (e) {
      fail(e);
      return;
    }
    switch (status) {
      case CollectStatus.ignored:
        return;
      case CollectStatus.accepted:
        _restartTimer(collector.hasProgress ? (collector.idleTimeout ?? _timeout) : _timeout);
      case CollectStatus.complete:
        _complete(collector.result);
      case CollectStatus.retry:
        _finishAttempt(_AttemptResult.retry);
    }
  }

  void _restartTimer(Duration d) {
    _timer?.cancel();
    _timer = Timer(d, _onTimeout);
  }

  void _onTimeout() {
    if (collector.completesOnIdle && collector.hasProgress) {
      _complete(collector.result);
    } else {
      _finishAttempt(_AttemptResult.timeout);
    }
  }

  void _finishAttempt(_AttemptResult r) {
    _timer?.cancel();
    final attempt = _attempt;
    if (attempt != null && !attempt.isCompleted) attempt.complete(r);
  }

  void _complete(T value) {
    _timer?.cancel();
    if (!completer.isCompleted) completer.complete(value);
    _finishAttempt(_AttemptResult.done);
  }

  void fail(Object error) {
    _timer?.cancel();
    if (!completer.isCompleted) completer.completeError(error);
    _finishAttempt(_AttemptResult.done);
  }

  void failWithLastError(Object fallback) => fail(_lastError ?? fallback);

  void abort(Object error) => fail(error);
}
