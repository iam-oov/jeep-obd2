import 'dart:async';
import 'dart:convert';

import 'package:jeep_obd2/bluetooth/elm_connection.dart';

/// Respuesta del ELM simulado a un comando: trozos de texto que se entregan
/// por separado (como llegan por Bluetooth). `null` = no responde (timeout).
typedef FakeReply = List<String>?;

/// ELM327 simulado. [script] mapea comando -> respuestas sucesivas; si un
/// comando se manda más veces que respuestas hay, se repite la última.
class FakeElmTransport implements ElmTransport {
  FakeElmTransport(this.script, {this.echo = false});

  final Map<String, List<FakeReply>> script;
  final bool echo;
  final sent = <String>[];
  final _calls = <String, int>{};
  final _controller = StreamController<List<int>>();
  bool closed = false;

  @override
  Stream<List<int>> get input => _controller.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final cmd = latin1.decode(bytes).trim();
    sent.add(cmd);
    final replies = script[cmd];
    if (replies == null) {
      _emit(['?\r\r>']);
      return;
    }
    final i = _calls.update(cmd, (n) => n + 1, ifAbsent: () => 0);
    final reply = replies[i < replies.length ? i : replies.length - 1];
    if (reply == null) return;
    _emit([if (echo) '$cmd\r', ...reply]);
  }

  void _emit(List<String> chunks) {
    // Entrega asíncrona y en trozos.
    Future<void>(() async {
      for (final c in chunks) {
        await Future<void>.delayed(Duration.zero);
        if (!_controller.isClosed) _controller.add(latin1.encode(c));
      }
    });
  }

  /// Simula que el adaptador corta la conexión.
  Future<void> drop() => _controller.close();

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }
}

/// Respuestas típicas de un clon ELM327 con un Jeep TJ (ISO 9141-2).
Map<String, List<FakeReply>> jeepScript({
  List<FakeReply>? mode03,
  List<FakeReply>? mode07,
  List<FakeReply>? mode04,
  List<FakeReply>? probe,
}) =>
    {
      'ATZ': [
        ['\r\rELM327 v1.5\r\r>'],
      ],
      'ATE0': [
        ['ATE0\rOK\r\r>'],
      ],
      'ATL0': [
        ['OK\r\r>'],
      ],
      'ATS0': [
        ['OK\r\r>'],
      ],
      'ATH0': [
        ['OK\r\r>'],
      ],
      'ATSP3': [
        ['OK\r\r>'],
      ],
      'ATSP0': [
        ['OK\r\r>'],
      ],
      '0100': probe ??
          [
            ['BUS INIT: ', '...OK\r4100BE3EB8', '11\r\r>'],
          ],
      'ATDP': [
        ['ISO 9141-2\r\r>'],
      ],
      'ATDPN': [
        ['3\r\r>'],
      ],
      '03': mode03 ??
          [
            ['43032013910000\r\r>'],
          ],
      '07': mode07 ??
          [
            ['NO DATA\r\r>'],
          ],
      '04': mode04 ??
          [
            ['44\r\r>'],
          ],
    };
