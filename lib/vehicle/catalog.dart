import 'dart:convert';

import 'package:http/http.dart' as http;

/// Makes commonly sold or driven in Mexico (for the form's list).
/// If one is missing, the field lets the user type it.
const commonMakes = [
  'Acura', 'Alfa Romeo', 'Audi', 'BAIC', 'BMW', 'BYD', 'Buick', 'Cadillac',
  'Chevrolet', 'Chirey', 'Chrysler', 'Cupra', 'Dodge', 'Fiat', 'Ford', 'GMC',
  'Honda', 'Hyundai', 'Infiniti', 'JAC', 'Jaguar', 'Jeep', 'Kia', 'Land Rover',
  'Lexus', 'Lincoln', 'MG', 'Mazda', 'Mercedes-Benz', 'Mini', 'Mitsubishi',
  'Nissan', 'Peugeot', 'Pontiac', 'Porsche', 'RAM', 'Renault', 'SEAT', 'Subaru',
  'Suzuki', 'Tesla', 'Toyota', 'Volkswagen', 'Volvo',
];

/// Models by make and year from the public NHTSA API (vPIC, no
/// key). This is the US catalog: Mexico-only models (Tsuru, some Aveo
/// generations...) may be missing; that is why the form allows typing.
class VehicleCatalog {
  VehicleCatalog({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final _cache = <String, List<String>>{};

  /// Sorted list without duplicates; empty if there is no network or the make does not exist.
  Future<List<String>> models(String make, {int? year}) async {
    final m = make.trim();
    if (m.isEmpty) return const [];
    final key = '${m.toLowerCase()}|$year';
    final cached = _cache[key];
    if (cached != null) return cached;

    final path = year == null
        ? '/api/vehicles/GetModelsForMake/${Uri.encodeComponent(m)}'
        : '/api/vehicles/GetModelsForMakeYear/make/${Uri.encodeComponent(m)}/modelyear/$year';
    try {
      final res = await _http
          .get(Uri.https('vpic.nhtsa.dot.gov', path, {'format': 'json'}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final names = {
        for (final r in (data['Results'] as List? ?? const []).cast<Map<String, dynamic>>())
          if ((r['Model_Name'] as String?)?.trim() case final String n when n.isNotEmpty) n,
      }.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return _cache[key] = names;
    } catch (_) {
      return const [];
    }
  }
}

/// Common displacements in liters (the list allows typing another one).
const commonLiters = [
  1.0, 1.2, 1.3, 1.4, 1.5, 1.6, 1.8, 2.0, 2.2, 2.3, 2.4, 2.5, 2.7, 2.8, 3.0, 3.3,
  3.5, 3.6, 3.7, 3.8, 4.0, 4.2, 4.3, 4.6, 4.7, 5.0, 5.3, 5.4, 5.7, 6.0, 6.2, 6.4, 7.0,
];

const commonCylinders = [3, 4, 5, 6, 8, 10, 12];

/// "4.0", "4,0", "4.0L", "4 L" -> 4.0. null if it is not a reasonable number.
double? parseLiters(String text) {
  final m = RegExp(r'^(\d{1,2}(?:[.,]\d{1,2})?)\s*l?$', caseSensitive: false).firstMatch(text.trim());
  final v = m == null ? null : double.tryParse(m.group(1)!.replaceAll(',', '.'));
  return v == null || v < 0.5 || v > 10 ? null : (v * 10).round() / 10;
}
