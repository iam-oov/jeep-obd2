import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// The vehicle being diagnosed. The user fills it in a dialog
/// (pre-filled with the VIN if the ECU provides it) and is saved on the
/// phone; no vehicle data is hard-coded in the source.
class Vehicle {
  const Vehicle({
    this.id = '',
    required this.make,
    required this.model,
    this.year,
    this.liters,
    this.cylinders,
    this.vin,
  });

  /// Local identifier (assigned on save).
  final String id;
  final String make;
  final String model;
  final int? year;

  /// Engine displacement in liters (e.g. 4.0).
  final double? liters;
  final int? cylinders;
  final String? vin;

  /// Formatted engine text (UI text stays in Spanish): "4.0L 6 cilindros", "1.6L", "4 cilindros", or null.
  String? get engine {
    final parts = [
      if (liters != null) '${liters!.toStringAsFixed(1)}L',
      if (cylinders != null) '$cylinders cilindros',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// "Nissan Tsuru 2005, motor 1.6L 4 cilindros" — used in prompts and UI.
  String get description => [
        '$make $model${year == null ? '' : ' $year'}',
        if (engine != null) 'motor $engine',
      ].join(', ');

  String get shortName => '$make $model${year == null ? '' : ' $year'}';

  Vehicle copyWith({String? id, String? vin}) => Vehicle(
        id: id ?? this.id,
        make: make,
        model: model,
        year: year,
        liters: liters,
        cylinders: cylinders,
        vin: vin ?? this.vin,
      );

  Map<String, Object?> toJson() =>
      {
        'id': id,
        'make': make,
        'model': model,
        'year': year,
        'liters': liters,
        'cylinders': cylinders,
        'vin': vin,
      };

  static Vehicle? fromJson(Map<String, Object?> j) {
    final make = j['make'], model = j['model'];
    if (make is! String || model is! String || make.isEmpty || model.isEmpty) return null;
    return Vehicle(
      id: j['id'] as String? ?? '',
      make: make,
      model: model,
      year: j['year'] as int?,
      liters: (j['liters'] as num?)?.toDouble() ?? _legacyLiters(j['engine']),
      cylinders: j['cylinders'] as int? ?? _legacyCylinders(j['engine']),
      vin: j['vin'] as String?,
    );
  }
}

/// Previous version: engine as free text ("4.0L 6 cilindros").
double? _legacyLiters(Object? engine) {
  final m = RegExp(r'(\d+(?:[.,]\d)?)\s*L', caseSensitive: false).firstMatch('${engine ?? ''}');
  return m == null ? null : double.tryParse(m.group(1)!.replaceAll(',', '.'));
}

int? _legacyCylinders(Object? engine) {
  final m = RegExp(r'(\d+)\s*cil', caseSensitive: false).firstMatch('${engine ?? ''}');
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Garage saved on the phone: list of vehicles and which one is active.
class Garage {
  const Garage(this.vehicles, this.activeId);

  final List<Vehicle> vehicles;
  final String? activeId;

  Vehicle? get active => vehicles.where((v) => v.id == activeId).firstOrNull;
}

/// Persistence in SharedPreferences.
class VehicleStore {
  static const _listKey = 'vehicles';
  static const _activeKey = 'active_vehicle';

  /// Previous version: a single vehicle.
  static const _legacyKey = 'vehicle';

  Future<Garage> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_listKey);
      if (raw == null) {
        // Migrate the single vehicle from the previous version.
        final legacy = prefs.getString(_legacyKey);
        final v = legacy == null
            ? null
            : Vehicle.fromJson((jsonDecode(legacy) as Map).cast<String, Object?>());
        if (v == null) return const Garage([], null);
        final migrated = v.copyWith(id: newVehicleId());
        final garage = Garage([migrated], migrated.id);
        await save(garage);
        await prefs.remove(_legacyKey);
        return garage;
      }
      final list = [
        for (final item in jsonDecode(raw) as List)
          ?Vehicle.fromJson((item as Map).cast<String, Object?>()),
      ];
      return Garage(list, prefs.getString(_activeKey));
    } catch (_) {
      return const Garage([], null);
    }
  }

  Future<void> save(Garage g) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listKey, jsonEncode([for (final v in g.vehicles) v.toJson()]));
    if (g.activeId == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, g.activeId!);
    }
  }
}

var _idCounter = 0;

String newVehicleId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idCounter++).toRadixString(36)}';

final _vinPattern = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

bool isValidVin(String vin) => _vinPattern.hasMatch(vin);

/// Model year from VIN position 10. The 30-year cycle is ambiguous
/// (W = 1998 or 2028): the most recent year not in the future is chosen.
int? modelYearFromVin(String vin, {int? currentYear}) {
  if (!isValidVin(vin)) return null;
  const codes = 'ABCDEFGHJKLMNPRSTVWXY123456789';
  final i = codes.indexOf(vin[9]);
  if (i < 0) return null;
  final now = currentYear ?? DateTime.now().year;
  var year = 1980 + i;
  while (year + 30 <= now + 1) {
    year += 30;
  }
  return year;
}

/// Decodes a VIN with the public NHTSA API (vPIC, no key needed).
/// Returns null on failure; the dialog stays empty and the user fills it in.
class VinDecoder {
  VinDecoder({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<Vehicle?> decode(String vin) async {
    if (!isValidVin(vin)) return null;
    try {
      final res = await _http
          .get(Uri.https('vpic.nhtsa.dot.gov', '/api/vehicles/DecodeVinValues/$vin', {'format': 'json'}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final r = ((data['Results'] as List?)?.firstOrNull as Map?)?.cast<String, dynamic>();
      if (r == null) return null;

      String? field(String k) {
        final v = (r[k] as String?)?.trim();
        return v == null || v.isEmpty || v == 'Not Applicable' ? null : v;
      }

      final make = field('Make');
      final model = field('Model');
      if (make == null || model == null) return null;

      final liters = double.tryParse(field('DisplacementL') ?? '');
      final cyl = int.tryParse(field('EngineCylinders') ?? '');

      return Vehicle(
        make: _titleCase(make),
        model: model,
        year: int.tryParse(field('ModelYear') ?? '') ?? modelYearFromVin(vin),
        liters: liters == null ? null : (liters * 10).round() / 10,
        cylinders: cyl,
        vin: vin,
      );
    } catch (_) {
      return null;
    }
  }

  /// vPIC returns the make in uppercase ("JEEP").
  static String _titleCase(String s) => s
      .toLowerCase()
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
