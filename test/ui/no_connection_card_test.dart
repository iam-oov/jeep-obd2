import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/ui/widgets.dart';

void main() {
  testWidgets('NoConnectionCard shows the no-device message', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: NoConnectionCard()),
    ));

    expect(find.byKey(const Key('no-connection')), findsOneWidget);
    expect(find.textContaining('No hay ningún dispositivo conectado'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
  });
}
