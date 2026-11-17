import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/bluetooth/elm_connection.dart';
import 'package:jeep_obd2/obd/obd_service.dart';

import 'fake_elm.dart';

const fast = ObdTimeouts(
  reset: Duration(milliseconds: 100),
  atCommand: Duration(milliseconds: 100),
  firstQuery: Duration(milliseconds: 100),
  autoProtocolQuery: Duration(milliseconds: 100),
  query: Duration(milliseconds: 100),
);

({FakeElmTransport fake, ElmConnection elm, ObdService obd, List<LogEntry> log}) setup(
  Map<String, List<FakeReply>> script, {
  bool echo = false,
}) {
  final log = <LogEntry>[];
  final fake = FakeElmTransport(script, echo: echo);
  final elm = ElmConnection(fake, onLog: log.add);
  final obd = ObdService(elm, timeouts: fast, onLog: log.add);
  return (fake: fake, elm: elm, obd: obd, log: log);
}

void main() {
  group('ElmConnection', () {
    test('junta trozos hasta el prompt y quita el eco', () async {
      final s = setup(jeepScript(), echo: true);
      expect(await s.elm.send('03'), '43032013910000');
    });

    test('ignora bytes 0x00 y quita líneas vacías', () async {
      final s = setup({
        'ATI': [
          ['\u0000ELM327 v2.1\r\r>'],
        ],
      });
      expect(await s.elm.send('ATI'), 'ELM327 v2.1');
    });

    test('timeout lanza ElmTimeoutException y no contamina el siguiente comando', () async {
      final s = setup({
        'SLOW': [null],
        'ATI': [
          ['ELM327 v1.5\r\r>'],
        ],
      });
      await expectLater(
        s.elm.send('SLOW', timeout: const Duration(milliseconds: 50)),
        throwsA(isA<ElmTimeoutException>()),
      );
      expect(await s.elm.send('ATI'), 'ELM327 v1.5');
    });

    test('comandos concurrentes se encolan', () async {
      final s = setup(jeepScript());
      final results = await Future.wait([s.elm.send('ATDP'), s.elm.send('03'), s.elm.send('07')]);
      expect(results, ['ISO 9141-2', '43032013910000', 'NO DATA']);
      expect(s.fake.sent, ['ATDP', '03', '07']);
    });

    test('desconexión falla el comando en vuelo', () async {
      final s = setup({'SLOW': [null]});
      final future = s.elm.send('SLOW', timeout: const Duration(seconds: 5));
      await s.fake.drop();
      await expectLater(future, throwsA(isA<ElmDisconnectedException>()));
      expect(s.elm.isClosed, isTrue);
    });
  });

  group('ObdService.initialize', () {
    test('secuencia ISO 9141-2 completa', () async {
      final s = setup(jeepScript());
      await s.obd.initialize();
      expect(s.fake.sent,
          ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP3', '0100', 'ATDP', 'ATDPN']);
      expect(s.obd.adapterVersion, 'ELM327 v1.5');
      expect(s.obd.protocolName, 'ISO 9141-2');
      expect(s.obd.isCan, isFalse);
    });

    test('ATSP3 falla -> reintenta con ATSP0', () async {
      final s = setup(jeepScript(probe: [
        ['BUS INIT: ...ERROR\r\r>'],
        ['SEARCHING...\r4100BE3EB811\r\r>'],
      ]));
      await s.obd.initialize();
      expect(s.fake.sent, containsAllInOrder(['ATSP3', '0100', 'ATSP0', '0100']));
    });

    test('ATZ sin respuesta se reintenta una vez', () async {
      final script = jeepScript()
        ..['ATZ'] = [
          null,
          ['ELM327 v1.5\r\r>'],
        ];
      final s = setup(script);
      await s.obd.initialize();
      expect(s.fake.sent.take(2), ['ATZ', 'ATZ']);
    });

    test('ATZ nunca responde -> mensaje claro', () async {
      final s = setup(jeepScript()..['ATZ'] = [null]);
      await expectLater(
        s.obd.initialize(),
        throwsA(isA<ObdException>().having((e) => e.message, 'message', contains('no responde'))),
      );
    });

    test('ECU no responde con ningún protocolo -> mensaje de switch en ON', () async {
      final s = setup(jeepScript(probe: [
        ['UNABLE TO CONNECT\r\r>'],
      ]));
      await expectLater(
        s.obd.initialize(),
        throwsA(isA<ObdException>().having((e) => e.message, 'message', contains('switch en ON'))),
      );
    });

    test('detecta CAN si ATSP0 cae en protocolo 6', () async {
      final s = setup(jeepScript()
        ..['ATDPN'] = [
          ['A6\r\r>'],
        ]);
      await s.obd.initialize();
      expect(s.obd.isCan, isTrue);
    });
  });

  group('lectura y borrado', () {
    test('modo 03 con códigos', () async {
      final s = setup(jeepScript());
      final r = await s.obd.readStoredCodes();
      expect(r.codes, ['P0320', 'P1391']);
      expect(r.supported, isTrue);
    });

    test('modo 03 en varias líneas', () async {
      final s = setup(jeepScript(mode03: [
        ['4303000301', '0302\r43030300000000\r\r>'],
      ]));
      expect((await s.obd.readStoredCodes()).codes, ['P0300', 'P0301', 'P0302', 'P0303']);
    });

    test('modo 03 NO DATA = sin códigos', () async {
      final s = setup(jeepScript(mode03: [
        ['NO DATA\r\r>'],
      ]));
      final r = await s.obd.readStoredCodes();
      expect(r.codes, isEmpty);
      expect(r.supported, isTrue);
    });

    test('modo 07 no soportado (?)', () async {
      final s = setup(jeepScript(mode07: [
        ['?\r\r>'],
      ]));
      final r = await s.obd.readPendingCodes();
      expect(r.codes, isEmpty);
      expect(r.supported, isFalse);
    });

    test('modo 07 con pendientes', () async {
      final s = setup(jeepScript(mode07: [
        ['47017100000000\r\r>'],
      ]));
      expect((await s.obd.readPendingCodes()).codes, ['P0171']);
    });

    test('error de bus en lectura -> ObdException', () async {
      final s = setup(jeepScript(mode03: [
        ['BUS INIT: ...ERROR\r\r>'],
      ]));
      await expectLater(s.obd.readStoredCodes(), throwsA(isA<ObdException>()));
    });

    test('headers activos (sin línea que empiece con 43) -> error, no falso "sin códigos"', () async {
      final s = setup(jeepScript(mode03: [
        ['486B1043032000000000A1\r\r>'],
      ]));
      await expectLater(
        s.obd.readStoredCodes(),
        throwsA(isA<ObdException>().having((e) => e.message, 'message', contains('inesperada'))),
      );
    });

    test('borrado confirmado con 44', () async {
      final s = setup(jeepScript());
      await s.obd.clearCodes();
      expect(s.fake.sent, ['04']);
    });

    test('borrado sin confirmación -> ObdException', () async {
      final s = setup(jeepScript(mode04: [
        ['NO DATA\r\r>'],
      ]));
      await expectLater(s.obd.clearCodes(), throwsA(isA<ObdException>()));
    });
  });
}
