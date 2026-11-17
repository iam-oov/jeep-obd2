import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/data/dtc_descriptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('el asset está declarado en pubspec y carga por rootBundle', () async {
    final loaded = await DtcDescriptions.load();
    expect(loaded.isKnown('P0320'), isTrue);
  });

  final d = DtcDescriptions.fromJson(File('assets/dtc_es.json').readAsStringSync());

  test('el JSON carga y tiene los códigos del Jeep', () {
    expect(d.length, greaterThan(100));
    for (final code in ['P0320', 'P1391', 'P0340', 'P0300', 'P0306', 'P0171', 'P0174']) {
      expect(d.isKnown(code), isTrue, reason: code);
    }
    for (var c = 440; c <= 456; c++) {
      if ([444, 445, 447, 448, 449, 454].contains(c)) continue;
      expect(d.isKnown('P0$c'), isTrue, reason: 'P0$c');
    }
  });

  test('código desconocido de fabricante vs genérico', () {
    expect(d.describe('P1999'), contains('específico del fabricante'));
    expect(d.describe('B1234'), contains('específico del fabricante'));
    expect(d.describe('P0999'), contains('no disponible'));
    expect(d.describe('P0999'), isNot(contains('fabricante')));
  });
}
