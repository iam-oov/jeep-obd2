import 'dart:async';
import 'dart:convert';

/// Canal de bytes con el adaptador. La implementación real es Bluetooth SPP
/// (ver `bluetooth_transport.dart`); en las pruebas se usa un ELM simulado.
abstract class ElmTransport {
  /// Bytes recibidos. Se escucha una sola vez.
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

  /// Mensaje en lenguaje claro para mostrar al usuario.
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

/// Envía comandos de texto al ELM327 y devuelve la respuesta completa
/// (todo lo recibido antes del prompt `>`).
///
/// Solo hay un comando en vuelo a la vez: las llamadas a [send] se encolan.
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

  /// Manda [command] (sin `\r`) y espera el prompt `>`.
  ///
  /// Lanza [ElmTimeoutException] si no llega en [timeout] y
  /// [ElmDisconnectedException] si se cae la conexión.
  ///
  /// Con [quiet] no se registran en el log el comando ni su respuesta (para
  /// las lecturas en vivo, que llenarían el log); los errores sí.
  Future<String> send(
    String command, {
    Duration timeout = const Duration(seconds: 5),
    bool quiet = false,
  }) {
    final result = _queue.then((_) => _sendNow(command, timeout, quiet));
    // La cola sigue aunque este comando falle.
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
    // Los clones a veces mandan bytes 0x00 o basura; latin1 nunca falla.
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
      // Respuesta que llegó después de un timeout: no se mezcla con el
      // siguiente comando, solo queda en el log.
      _log(LogKind.info, 'Respuesta tardía descartada: ${_oneLine(response)}');
    }
  }

  void _fail(ElmException e) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.completeError(e);
  }

  /// Quita líneas vacías y el eco del comando (por si el clon ignora ATE0).
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
