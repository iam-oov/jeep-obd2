import 'dart:async';
import 'dart:convert';

/// Byte channel to the adapter. The real implementation is Bluetooth SPP
/// (see `bluetooth_transport.dart`); tests use a simulated ELM.
abstract class ElmTransport {
  /// Received bytes. Listened to only once.
  Stream<List<int>> get input;

  Future<void> write(List<int> bytes);

  Future<void> close();
}

enum LogKind { sent, received, info, error }

class LogEntry {
  LogEntry(this.kind, this.text) : time = DateTime.now();

  final DateTime time;
  final LogKind kind;
  final String text;
}

class ElmException implements Exception {
  ElmException(this.message);

  /// Plain-language message to show the user.
  final String message;

  @override
  String toString() => message;
}

class ElmTimeoutException extends ElmException {
  ElmTimeoutException(String command)
      : super('El adaptador no respondió a tiempo al comando $command.');
}

class ElmDisconnectedException extends ElmException {
  ElmDisconnectedException() : super('Se perdió la conexión Bluetooth con el adaptador.');
}

/// Sends text commands to the ELM327 and returns the full reply
/// (everything received before the `>` prompt).
///
/// Only one command in flight at a time: calls to [send] are queued.
class ElmConnection {
  ElmConnection(this._transport, {this.onLog}) {
    _sub = _transport.input.listen(
      _onData,
      onError: (Object e) => _fail(ElmException('Error de Bluetooth: $e')),
      onDone: () {
        _closed = true;
        _log(LogKind.error, 'Conexión cerrada por el adaptador');
        _fail(ElmDisconnectedException());
      },
    );
  }

  final ElmTransport _transport;
  final void Function(LogEntry)? onLog;
  late final StreamSubscription<List<int>> _sub;

  final _buffer = StringBuffer();
  Completer<String>? _pending;
  Future<void> _queue = Future.value();
  bool _closed = false;

  bool get isClosed => _closed;

  /// Sends [command] (without `\r`) and waits for the `>` prompt.
  ///
  /// Throws [ElmTimeoutException] if it does not arrive within [timeout], and
  /// [ElmDisconnectedException] if the connection drops.
  ///
  /// With [quiet], neither the command nor its reply is logged (for
  /// live readings, which would fill the log); errors are still logged.
  Future<String> send(
    String command, {
    Duration timeout = const Duration(seconds: 5),
    bool quiet = false,
  }) {
    final result = _queue.then((_) => _sendNow(command, timeout, quiet));
    // The queue keeps going even if this command fails.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _sendNow(String command, Duration timeout, bool quiet) async {
    if (_closed) throw ElmDisconnectedException();

    _buffer.clear();
    final completer = Completer<String>();
    _pending = completer;

    if (!quiet) _log(LogKind.sent, command);
    try {
      await _transport.write(latin1.encode('$command\r'));
    } catch (e) {
      _pending = null;
      throw ElmException('No se pudo enviar el comando $command: $e');
    }

    try {
      final raw = await completer.future.timeout(timeout);
      final cleaned = _stripEcho(raw, command);
      if (!quiet) _log(LogKind.received, cleaned.isEmpty ? '(vacío)' : cleaned);
      return cleaned;
    } on TimeoutException {
      _pending = null;
      _buffer.clear();
      _log(LogKind.error, 'Timeout (${timeout.inSeconds}s) esperando respuesta a $command');
      throw ElmTimeoutException(command);
    }
  }

  void _onData(List<int> bytes) {
    // Clones sometimes send 0x00 bytes or garbage; latin1 never fails.
    final text = latin1.decode(bytes.where((b) => b != 0).toList());
    _buffer.write(text);

    final all = _buffer.toString();
    final promptAt = all.indexOf('>');
    if (promptAt < 0) return;

    final response = all.substring(0, promptAt);
    _buffer.clear();

    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(response);
    } else if (response.trim().isNotEmpty) {
      // Reply that arrived after a timeout: it is not mixed with the
      // next command; it only stays in the log.
      _log(LogKind.info, 'Respuesta tardía descartada: ${_oneLine(response)}');
    }
  }

  void _fail(ElmException e) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.completeError(e);
  }

  /// Removes empty lines and the command echo (in case the clone ignores ATE0).
  static String _stripEcho(String raw, String command) {
    final lines = raw
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    String norm(String s) => s.replaceAll(' ', '').toUpperCase();
    if (lines.isNotEmpty && norm(lines.first) == norm(command)) lines.removeAt(0);
    return lines.join('\n');
  }

  static String _oneLine(String s) => s.trim().replaceAll(RegExp(r'[\r\n]+'), ' | ');

  void _log(LogKind kind, String text) => onLog?.call(LogEntry(kind, text));

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fail(ElmDisconnectedException());
    await _sub.cancel();
    await _transport.close();
  }
}
