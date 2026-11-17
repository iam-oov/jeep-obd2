import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeep_obd2/app_state.dart';
import 'package:jeep_obd2/bluetooth/elm_connection.dart';
import 'package:jeep_obd2/obd/dtc_decoder.dart';
import 'package:jeep_obd2/obd/obd_service.dart';
import 'package:jeep_obd2/ui/option_picker.dart';
import 'package:jeep_obd2/ui/vehicle_dialog.dart';
import 'package:jeep_obd2/vehicle/catalog.dart';
import 'package:jeep_obd2/vehicle/vehicle.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_elm.dart';

// Example VIN with a valid format (not a real vehicle).
const sampleVin = '1N4AB41D25C712345';

String hex(String s) => s.codeUnits.map((c) => c.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// ISO 9141-2 reply to 0902: 5 lines 4902NN + 4 bytes, with 3 bytes of
/// padding at the start.
String isoVinResponse(String vin) {
  final data = '000000${hex(vin)}';
  final lines = <String>[];
  for (var i = 0; i < 5; i++) {
    lines.add('4902${(i + 1).toString().padLeft(2, '0')}${data.substring(i * 8, i * 8 + 8)}');
  }
  return lines.join('\r');
}

void main() {
  group('decodeVinResponse', () {
    test('ISO 9141-2 en 5 líneas', () {
      expect(decodeVinResponse(isoVinResponse(sampleVin)), sampleVin);
    });

    test('ISO con espacios y SEARCHING', () {
      final spaced = isoVinResponse(sampleVin).split('\r').map((l) {
        return [for (var i = 0; i < l.length; i += 2) l.substring(i, i + 2)].join(' ');
      }).join('\r');
      expect(decodeVinResponse('SEARCHING...\r$spaced\r'), sampleVin);
    });

    test('CAN multitrama', () {
      final data = '490201${hex(sampleVin)}';
      final raw = '014\r0:${data.substring(0, 12)}\r1:${data.substring(12, 26)}\r2:${data.substring(26)}\r';
      expect(decodeVinResponse(raw), sampleVin);
    });

    test('sin soporte o incompleto -> null', () {
      expect(decodeVinResponse('NO DATA'), isNull);
      expect(decodeVinResponse('?'), isNull);
      expect(decodeVinResponse('49020100000031'), isNull);
    });
  });

  test('modelYearFromVin', () {
    expect(modelYearFromVin('1J4FA49S0WP123456', currentYear: 2026), 1998); // W
    expect(modelYearFromVin(sampleVin, currentYear: 2026), 2005); // 5
    expect(modelYearFromVin('1N4AB41D2PC712345', currentYear: 2026), 2023); // P
    expect(modelYearFromVin('CORTO'), isNull);
  });

  test('ObdService.readVin', () async {
    final log = <LogEntry>[];
    final script = jeepScript()..['0902'] = [
        ['${isoVinResponse(sampleVin)}\r\r>'],
        ['NO DATA\r\r>'],
      ];
    final elm = ElmConnection(FakeElmTransport(script), onLog: log.add);
    final obd = ObdService(elm, onLog: log.add);
    expect(await obd.readVin(), sampleVin);
    expect(await obd.readVin(), isNull);
  });

  group('VinDecoder (NHTSA vPIC)', () {
    test('decodifica marca, modelo, año y motor', () async {
      late Uri asked;
      final client = MockClient((req) async {
        asked = req.url;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'Results': [
              {
                'Make': 'NISSAN',
                'Model': 'Tsuru',
                'ModelYear': '2005',
                'DisplacementL': '1.6',
                'EngineCylinders': '4',
              },
            ],
          })),
          200,
        );
      });
      final v = await VinDecoder(httpClient: client).decode(sampleVin);
      expect(asked.host, 'vpic.nhtsa.dot.gov');
      expect(asked.path, '/api/vehicles/DecodeVinValues/$sampleVin');
      expect(v!.make, 'Nissan');
      expect(v.model, 'Tsuru');
      expect(v.year, 2005);
      expect(v.liters, 1.6);
      expect(v.cylinders, 4);
      expect(v.engine, '1.6L 4 cilindros');
      expect(v.vin, sampleVin);
    });

    test('sin marca/modelo o error de red -> null', () async {
      final empty = MockClient((_) async => http.Response('{"Results":[{"Make":"","Model":""}]}', 200));
      expect(await VinDecoder(httpClient: empty).decode(sampleVin), isNull);
      final down = MockClient((_) async => throw Exception('offline'));
      expect(await VinDecoder(httpClient: down).decode(sampleVin), isNull);
      expect(await VinDecoder(httpClient: empty).decode('INVALIDO'), isNull);
    });
  });

  group('AppState: varios vehículos', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('agregar, persistir, seleccionar, editar y borrar', () async {
      final a = AppState();
      await a.loadVehicle();
      expect(a.vehicles, isEmpty);
      expect(a.vehicle, isNull);

      final tsuru = await a.addVehicle(const Vehicle(make: 'Nissan', model: 'Tsuru', year: 2005));
      final jetta = await a.addVehicle(const Vehicle(make: 'VW', model: 'Jetta', year: 2012));
      expect(tsuru.id, isNotEmpty);
      expect(tsuru.id, isNot(jetta.id));
      expect(a.vehicle!.id, jetta.id); // el recién agregado queda activo

      await a.selectVehicle(tsuru.id);
      await a.updateVehicle(Vehicle(id: tsuru.id, make: 'Nissan', model: 'Tsuru', year: 2006));

      // Another instance (like reopening the app) sees the same thing.
      final b = AppState();
      await b.loadVehicle();
      expect(b.vehicles.map((v) => v.shortName), ['Nissan Tsuru 2006', 'VW Jetta 2012']);
      expect(b.vehicle!.shortName, 'Nissan Tsuru 2006');

      // Deleting the active one leaves another one active.
      await b.deleteVehicle(tsuru.id);
      expect(b.vehicles.single.id, jetta.id);
      expect(b.vehicle!.id, jetta.id);
      await b.deleteVehicle(jetta.id);
      expect(b.vehicle, isNull);
    });

    test('migra el vehículo único de la versión anterior', () async {
      SharedPreferences.setMockInitialValues({
        'vehicle': jsonEncode({'make': 'Jeep', 'model': 'Wrangler', 'year': 1998}),
      });
      final a = AppState();
      await a.loadVehicle();
      expect(a.vehicles.single.shortName, 'Jeep Wrangler 1998');
      expect(a.vehicle!.id, isNotEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('vehicle'), isNull);
      expect(prefs.getString('vehicles'), isNotNull);
    });

    test('motor en texto libre de la versión anterior -> litros y cilindros', () async {
      SharedPreferences.setMockInitialValues({
        'vehicles': jsonEncode([
          {'id': 'a', 'make': 'Jeep', 'model': 'Wrangler', 'year': 1998, 'engine': '4.0L 6 cilindros'},
        ]),
        'active_vehicle': 'a',
      });
      final a = AppState();
      await a.loadVehicle();
      expect(a.vehicle!.liters, 4.0);
      expect(a.vehicle!.cylinders, 6);
      expect(a.vehicle!.description, 'Jeep Wrangler 1998, motor 4.0L 6 cilindros');
    });

    test('parseLiters', () {
      expect(parseLiters('4.0 L'), 4.0);
      expect(parseLiters('1,6'), 1.6);
      expect(parseLiters('2'), 2.0);
      expect(parseLiters('5.65'), 5.7);
      expect(parseLiters('abc'), isNull);
      expect(parseLiters('40'), isNull);
    });

    test('vinMatch reconoce un vehículo guardado por su VIN', () async {
      final a = AppState();
      await a.loadVehicle();
      await a.addVehicle(const Vehicle(make: 'Nissan', model: 'Tsuru', vin: sampleVin));
      a.vin = sampleVin;
      expect(a.vinMatch!.shortName, 'Nissan Tsuru');
      a.vin = '1J4FA49S0WP123456';
      expect(a.vinMatch, isNull);
    });
  });

  /// Taps a form field, types in the search box and picks.
  Future<void> pick(WidgetTester tester, String field, String query, {String? option}) async {
    await tester.tap(find.byKey(Key(field)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('picker-search')), query);
    await tester.pumpAndSettle();
    if (option == null) {
      await tester.tap(find.byKey(const Key('picker-custom')));
    } else {
      await tester.tap(find.widgetWithText(ListTile, option).last);
    }
    await tester.pumpAndSettle();
  }

  Widget host(void Function(Future<Vehicle?>) onOpen, {Vehicle? initial}) => ChangeNotifierProvider(
        create: (_) => AppState(),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => onOpen(showVehicleDialog(context, initial: initial)),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );

  testWidgets('panel Mis vehículos: elegir y agregar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    vehicleCatalog = VehicleCatalog(
      httpClient: MockClient((_) async => http.Response('{"Results":[]}', 200)),
    );
    final state = AppState();
    await state.loadVehicle();
    await state.addVehicle(const Vehicle(make: 'Nissan', model: 'Tsuru', year: 2005));
    await state.addVehicle(const Vehicle(make: 'VW', model: 'Jetta', year: 2012));

    Vehicle? picked;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showGarageSheet(context),
            child: const Text('abrir'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nissan Tsuru 2005'));
    await tester.pumpAndSettle();
    expect(picked!.shortName, 'Nissan Tsuru 2005');
    expect(state.vehicle!.shortName, 'Nissan Tsuru 2005');

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agregar vehículo'));
    await tester.pumpAndSettle();
    await pick(tester, 'vehicle-make', 'for', option: 'Ford');
    await pick(tester, 'vehicle-model', 'Ranger');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(state.vehicles, hasLength(3));
    expect(state.vehicle!.shortName, 'Ford Ranger');
    expect(picked!.shortName, 'Ford Ranger');
  });

  testWidgets('modal: prellenado por VIN, modelo de la lista y validación', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final asked = <String>[];
    vehicleCatalog = VehicleCatalog(
      httpClient: MockClient((req) async {
        asked.add(req.url.path);
        return http.Response(
          '{"Results":[{"Model_Name":"Wrangler"},{"Model_Name":"Cherokee"},{"Model_Name":"Wrangler"}]}',
          200,
        );
      }),
    );
    Vehicle? result;
    await tester.pumpWidget(host(
      (f) async => result = await f,
      initial: const Vehicle(make: 'Jeep', model: '', year: 1998, vin: sampleVin),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Prellenado con el VIN'), findsOneWidget);
    expect(asked.single, '/api/vehicles/GetModelsForMakeYear/make/Jeep/modelyear/1998');

    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Elige o escribe el modelo'), findsOneWidget);

    // The models list has no duplicates and is filtered with the search box.
    await tester.tap(find.byKey(const Key('vehicle-model')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Wrangler'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Cherokee'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('picker-search')), 'wra');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Cherokee'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Wrangler'));
    await tester.pumpAndSettle();

    await pick(tester, 'vehicle-liters', '4', option: '4.0');
    await pick(tester, 'vehicle-cylinders', '6', option: '6');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(result!.description, 'Jeep Wrangler 1998, motor 4.0L 6 cilindros');
    expect(result!.vin, sampleVin);
  });

  testWidgets('modal: valores escritos a mano (modelo y motor)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    vehicleCatalog = VehicleCatalog(
      httpClient: MockClient((_) async => http.Response('{"Results":[]}', 200)),
    );
    Vehicle? result;
    await tester.pumpWidget(host((f) async => result = await f));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await pick(tester, 'vehicle-make', 'nis', option: 'Nissan');
    await pick(tester, 'vehicle-model', 'Tsuru');
    await pick(tester, 'vehicle-liters', '1,6');
    await pick(tester, 'vehicle-cylinders', '4', option: '4');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(result!.description, 'Nissan Tsuru, motor 1.6L 4 cilindros');
  });

  testWidgets('modal: año "98" + Enter elige 1998; "No sé" lo quita', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final asked = <String>[];
    vehicleCatalog = VehicleCatalog(
      httpClient: MockClient((req) async {
        asked.add(req.url.path);
        return http.Response('{"Results":[{"Model_Name":"Wrangler"}]}', 200);
      }),
    );
    Vehicle? result;
    await tester.pumpWidget(host((f) async => result = await f));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('vehicle-year')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('picker-search')), '98');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '1998'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '1989'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('vehicle-year')), matching: find.text('1998')),
        findsOneWidget);

    await pick(tester, 'vehicle-make', 'jeep', option: 'Jeep');
    expect(asked.last, '/api/vehicles/GetModelsForMakeYear/make/Jeep/modelyear/1998');
    await pick(tester, 'vehicle-model', 'wr', option: 'Wrangler');

    // Remove the year.
    await tester.tap(find.byKey(const Key('vehicle-year')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No sé / no aplica'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(result!.description, 'Jeep Wrangler');
  });

  test('VehicleCatalog: sin repetidos, ordenado y en caché', () async {
    var calls = 0;
    final c = VehicleCatalog(
      httpClient: MockClient((_) async {
        calls++;
        return http.Response(
          '{"Results":[{"Model_Name":"Sentra"},{"Model_Name":"Altima"},{"Model_Name":"Sentra"}]}',
          200,
        );
      }),
    );
    expect(await c.models('Nissan', year: 2005), ['Altima', 'Sentra']);
    expect(await c.models('nissan', year: 2005), ['Altima', 'Sentra']);
    expect(calls, 1);
    final down = VehicleCatalog(httpClient: MockClient((_) async => throw Exception('offline')));
    expect(await down.models('Nissan'), isEmpty);
  });

  test('filterOptions', () {
    expect(filterOptions(['Jeep', 'Nissan', 'Ford'], 'ni'), ['Nissan']);
    expect(filterOptions(['Jeep', 'Nissan', 'Ford'], ''), hasLength(3));
    final years = [for (var y = 2027; y >= 1981; y--) '$y'];
    expect(filterOptions(years, '98', yearMode: true), ['1998']);
    expect(filterOptions(years, '200', yearMode: true), hasLength(10));
    expect(filterOptions(years, '1890', yearMode: true), isEmpty);
  });
}
