import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/app_state.dart';
import 'package:jeep_obd2/bluetooth/elm_connection.dart';
import 'package:jeep_obd2/obd/live_data.dart';
import 'package:jeep_obd2/obd/obd_service.dart';
import 'package:jeep_obd2/ui/live_data_screen.dart';
import 'package:provider/provider.dart';

import 'fake_elm.dart';

LiveParam param(String key) => liveParams.firstWhere((p) => p.key == key);

const fast = ObdTimeouts(
  reset: Duration(milliseconds: 100),
  atCommand: Duration(milliseconds: 100),
  firstQuery: Duration(milliseconds: 100),
  autoProtocolQuery: Duration(milliseconds: 100),
  query: Duration(milliseconds: 100),
);

/// Vehicle that supports 05, 0C, 0D (BE3EB811 no; mask set by hand):
/// 0100 -> 41 00 18 18 00 00  => PIDs 04,05,0C,0D.
Map<String, List<FakeReply>> liveScript({String rpm = '410C0BB8'}) => {
      ...jeepScript(probe: [
        ['41001818000000\r\r>'],
      ]),
      'ATRV': [
        ['14.1V\r\r>'],
      ],
      '0104': [
        ['410480\r\r>'],
      ],
      '0105': [
        ['41057B\r\r>'],
      ],
      '010C': [
        ['$rpm\r\r>'],
      ],
      '010D': [
        ['NO DATA\r\r>'],
      ],
    };

void main() {
  group('parseo', () {
    test('máscara de PIDs soportados', () {
      expect(parseSupportedPids('4100BE3EB811', 0x00),
          containsAll([0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x20]));
      expect(parseSupportedPids('41 00 18 18 00 00', 0x00), {0x04, 0x05, 0x0C, 0x0D});
      expect(parseSupportedPids('4120 80 00 00 01', 0x20), {0x21, 0x40});
      expect(parseSupportedPids('NO DATA', 0x00), isEmpty);
    });

    test('respuesta de un PID, con espacios y varias computadoras', () {
      expect(parsePidResponse('41 05 7B', 0x05), [0x7B]);
      expect(parsePidResponse('SEARCHING...\r410C0BB8\r410C0BC0', 0x0C), [0x0B, 0xB8]);
      expect(parsePidResponse('NO DATA', 0x05), isNull);
      expect(parsePidResponse('410D', 0x0D), isNull);
    });

    test('ATRV', () {
      expect(parseAtrv('12.6V'), 12.6);
      expect(parseAtrv('14V'), 14.0);
      expect(parseAtrv('?'), isNull);
    });

    test('fórmulas', () {
      expect(param('coolant').decode!([0x7B]), 83); // 123 - 40
      expect(param('rpm').decode!([0x0B, 0xB8]), 750);
      expect(param('load').decode!([0xFF]), 100);
      expect(param('ecu_volt').decode!([0x36, 0xB0]), 14.0);
    });
  });

  group('alertas', () {
    Level lv(String k, double v, {bool running = true}) => param(k).level!(v, engineRunning: running);

    test('refrigerante', () {
      expect(lv('coolant', 92), Level.ok);
      expect(lv('coolant', 108), Level.warn);
      expect(lv('coolant', 118), Level.danger);
    });

    test('voltaje según motor encendido o apagado', () {
      expect(lv('atrv', 14.1), Level.ok);
      expect(lv('atrv', 12.9), Level.warn); // alternador no carga bien
      expect(lv('atrv', 12.0), Level.danger);
      expect(lv('atrv', 15.6), Level.danger);
      expect(lv('atrv', 12.6, running: false), Level.ok);
      expect(lv('atrv', 12.0, running: false), Level.warn);
      expect(lv('atrv', 11.5, running: false), Level.danger);
    });
  });

  test('poller: descubre soportados, consulta en ciclo y lleva mín/máx', () async {
    final log = <LogEntry>[];
    final fake = FakeElmTransport(liveScript());
    final elm = ElmConnection(fake, onLog: log.add);
    final obd = ObdService(elm, timeouts: fast, onLog: log.add);
    await obd.initialize();
    final logBefore = log.length;

    final poller = LiveDataPoller(obd);
    await poller.discover();
    expect(poller.active.map((p) => p.key), ['atrv', 'coolant', 'rpm', 'speed', 'load']);
    expect(poller.unsupported.map((p) => p.key), containsAll(['iat', 'throttle', 'ecu_volt']));

    final ok = await poller.pollOnce();
    expect(ok, 4); // speed: NO DATA
    expect(poller.values['coolant']!.value, 83);
    expect(poller.values['rpm']!.value, 750);
    expect(poller.values['atrv']!.value, 14.1);
    expect(poller.values.containsKey('speed'), isFalse);
    expect(poller.engineRunning, isTrue);
    expect(poller.levelOf(param('atrv')), Level.ok);

    // Live readings do not fill the log.
    expect(log.length, logBefore);
  });

  testWidgets('pantalla sin conexión muestra el aviso', (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => AppState(),
      child: const MaterialApp(home: LiveDataScreen()),
    ));
    expect(find.text('No hay conexión con el adaptador.'), findsOneWidget);
  });
}
