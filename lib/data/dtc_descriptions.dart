import 'dart:convert';

import 'package:flutter/services.dart';

/// Spanish descriptions of the DTCs, loaded from `assets/dtc_es.json`.
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

  /// Description of the code, or text explaining why there is none.
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

  /// Codes in the table that look like [code] (same length, small edit
  /// distance), closest first. Used to suggest a correction for a mistyped code.
  List<String> similar(String code, {int max = 3, int maxDistance = 2}) {
    final target = code.toUpperCase();
    final scored = <(int, String)>[];
    for (final k in _map.keys) {
      if (k.length != target.length || k == target) continue;
      final d = _editDistance(target, k);
      if (d <= maxDistance) scored.add((d, k));
    }
    if (scored.isEmpty) return const [];
    // Only the closest distance: a farther match is more likely noise.
    final best = scored.map((s) => s.$1).reduce((a, b) => a < b ? a : b);
    final closest = [for (final s in scored) if (s.$1 == best) s.$2]..sort();
    return closest.take(max).toList();
  }

  static int _editDistance(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        var best = prev[j] + 1;
        if (cur[j - 1] + 1 < best) best = cur[j - 1] + 1;
        if (prev[j - 1] + cost < best) best = prev[j - 1] + cost;
        cur[j] = best;
      }
      prev = cur;
    }
    return prev[b.length];
  }

  /// P1xxx, P3xxx, B1/B2, C1/C2, U1/U2 are manufacturer-defined.
  static bool isManufacturerSpecific(String code) {
    if (code.length != 5) return false;
    final letter = code[0].toUpperCase();
    final digit = code[1];
    if (letter == 'P') return digit == '1' || digit == '3';
    return digit == '1' || digit == '2';
  }
}
