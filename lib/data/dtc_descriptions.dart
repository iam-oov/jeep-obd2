import 'dart:convert';

import 'package:flutter/services.dart';

/// Descripciones en español de los DTC, cargadas de `assets/dtc_es.json`.
class DtcDescriptions {
  DtcDescriptions(this._map);

  factory DtcDescriptions.fromJson(String json) =>
      DtcDescriptions((jsonDecode(json) as Map<String, dynamic>).cast<String, String>());

  static Future<DtcDescriptions> load([AssetBundle? bundle]) async {
    final json = await (bundle ?? rootBundle).loadString('assets/dtc_es.json');
    return DtcDescriptions.fromJson(json);
  }

  final Map<String, String> _map;

  int get length => _map.length;

  /// Descripción del código, o un texto que explica por qué no la hay.
  String describe(String code) {
    final known = _map[code.toUpperCase()];
    if (known != null) return known;
    if (isManufacturerSpecific(code)) {
      return 'Descripción no disponible (código específico del fabricante). '
          'Búscalo como "$code Jeep".';
    }
    return 'Descripción no disponible en la tabla local.';
  }

  bool isKnown(String code) => _map.containsKey(code.toUpperCase());

  /// P1xxx, P3xxx, B1/B2, C1/C2, U1/U2 son definidos por el fabricante.
  static bool isManufacturerSpecific(String code) {
    if (code.length != 5) return false;
    final letter = code[0].toUpperCase();
    final digit = code[1];
    if (letter == 'P') return digit == '1' || digit == '3';
    return digit == '1' || digit == '2';
  }
}
