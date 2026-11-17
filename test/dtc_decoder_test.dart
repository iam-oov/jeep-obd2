import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/obd/dtc_decoder.dart';

void main() {
  group('decodeDtcWord', () {
    test('ejemplos del Jeep', () {
      expect(decodeDtcWord('0320'), 'P0320');
      expect(decodeDtcWord('1391'), 'P1391');
    });

    test('las cuatro letras y el segundo dígito', () {
      expect(decodeDtcWord('0171'), 'P0171');
      expect(decodeDtcWord('3456'), 'P3456');
      expect(decodeDtcWord('4123'), 'C0123');
      expect(decodeDtcWord('5123'), 'C1123');
      expect(decodeDtcWord('8001'), 'B0001');
      expect(decodeDtcWord('A100'), 'B2100');
      expect(decodeDtcWord('C073'), 'U0073');
      expect(decodeDtcWord('F00F'), 'U300F');
    });

    test('dígitos hex A-F se conservan', () {
      expect(decodeDtcWord('04AB'), 'P04AB');
      expect(decodeDtcWord('d1ef'), 'U11EF');
    });

    test('relleno e inválidos', () {
      expect(decodeDtcWord('0000'), isNull);
      expect(decodeDtcWord('032'), isNull);
      expect(decodeDtcWord('03G0'), isNull);
    });
  });

  group('decodeDtcResponse ISO 9141-2', () {
    test('un código con relleno', () {
      expect(decodeDtcResponse('43032000000000', mode: 3), ['P0320']);
    });

    test('tres códigos en una línea', () {
      expect(decodeDtcResponse('43 03 20 13 91 03 40', mode: 3), ['P0320', 'P1391', 'P0340']);
    });

    test('varias líneas de 3 códigos', () {
      const raw = '43030003010302\r\n43030303040305\r\n43030600000000\r\n';
      expect(decodeDtcResponse(raw, mode: 3),
          ['P0300', 'P0301', 'P0302', 'P0303', 'P0304', 'P0305', 'P0306']);
    });

    test('no confunde el prefijo 43 dentro de los datos (P0443)', () {
      expect(decodeDtcResponse('43044300000000', mode: 3), ['P0443']);
      expect(decodeDtcResponse('43 01 43 00 00 00 00', mode: 3), ['P0143']);
    });

    test('modo 07 usa prefijo 47', () {
      expect(decodeDtcResponse('47017101740000', mode: 7), ['P0171', 'P0174']);
      expect(decodeDtcResponse('43017101740000', mode: 7), isEmpty);
    });

    test('ignora SEARCHING, BUS INIT, eco y espacios', () {
      const raw = '03\rSEARCHING...\rBUS INIT: ...OK\r43 03 20 00 00 00 00\r';
      expect(decodeDtcResponse(raw, mode: 3), ['P0320']);
    });

    test('todo relleno o NO DATA = sin códigos', () {
      expect(decodeDtcResponse('43000000000000', mode: 3), isEmpty);
      expect(decodeDtcResponse('NO DATA', mode: 3), isEmpty);
      expect(decodeDtcResponse('', mode: 3), isEmpty);
    });

    test('duplicados de dos módulos se reportan una vez', () {
      const raw = '43032000000000\r43032000000000\r';
      expect(decodeDtcResponse(raw, mode: 3), ['P0320']);
    });

    test('resto incompleto se descarta', () {
      expect(decodeDtcResponse('43032013', mode: 3), ['P0320']);
    });
  });

  group('decodeDtcResponse CAN', () {
    test('trama única con byte de conteo', () {
      expect(decodeDtcResponse('4302032013910000', mode: 3, can: true), ['P0320', 'P1391']);
    });

    test('sin códigos', () {
      expect(decodeDtcResponse('4300', mode: 3, can: true), isEmpty);
    });

    test('multitrama', () {
      const raw = '00E\r0:430603000301\r1:03020303030403\r2:05000000000000\r';
      expect(decodeDtcResponse(raw, mode: 3, can: true),
          ['P0300', 'P0301', 'P0302', 'P0303', 'P0304', 'P0305']);
    });
  });
}
