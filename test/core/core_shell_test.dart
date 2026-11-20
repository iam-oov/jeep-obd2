import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/core/auth/brain_session.dart';
import 'package:jeep_obd2/core/auth/identity_provider.dart';

import 'fakes.dart';

void main() {
  late FakeBrain brain;
  late FakeIdentity identity;

  BrainSession session() => BrainSession(client: brain.cerebro, identity: identity);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    brain = FakeBrain();
    identity = FakeIdentity();
  });

  testWidgets('without a session only the Google sign-in is shown', (tester) async {
    await tester.pumpWidget(shellWith(session()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('core-sign-in')), findsOneWidget);
    expect(find.text('Inicio'), findsNothing);
    expect(find.byKey(const Key('core-suggestions')), findsNothing);

    await tester.tap(find.byKey(const Key('core-sign-in')));
    await tester.pumpAndSettle();
    expect(find.text('Inicio'), findsOneWidget);
    expect(brain.logins, 1);
    expect(await const FlutterSecureStorage().read(key: 'cerebro_token'), 'tok1');
  });

  testWidgets('a saved session opens the app without network and drops the old code', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'cerebro_token': 'tok9', 'cerebro_user': 'osvaldo', 'cerebro_code': '1234'});
    await tester.pumpWidget(shellWith(session()));
    await tester.pumpAndSettle();
    expect(find.text('Inicio'), findsOneWidget);
    expect(brain.seen, isEmpty);
    expect(await const FlutterSecureStorage().read(key: 'cerebro_code'), isNull);
  });

  testWidgets('a silent Google account signs in by itself', (tester) async {
    identity.silent = 'id-osvaldo';
    await tester.pumpWidget(shellWith(session()));
    await tester.pumpAndSettle();
    expect(find.text('Inicio'), findsOneWidget);
    expect(brain.logins, 1);
  });

  testWidgets('the suggestions button is on every screen and opens Sugerencias', (tester) async {
    identity.silent = 'id-osvaldo';
    await tester.pumpWidget(shellWith(session()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('core-suggestions')), findsOneWidget);

    await tester.tap(find.text('Ir a otra pantalla'));
    await tester.pumpAndSettle();
    expect(find.text('Otra pantalla'), findsOneWidget);
    expect(find.byKey(const Key('core-suggestions')), findsOneWidget);

    await tester.tap(find.byKey(const Key('core-suggestions')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Sugerencias'), findsOneWidget);
  });

  testWidgets('signing out returns to the sign-in screen and forgets the session', (tester) async {
    identity.silent = 'id-osvaldo';
    await tester.pumpWidget(shellWith(session()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('core-suggestions')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('core-sign-out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('core-sign-in')), findsOneWidget);
    expect(find.byKey(const Key('core-suggestions')), findsNothing);
    expect(identity.signOuts, 1);
    expect(await const FlutterSecureStorage().read(key: 'cerebro_token'), isNull);
  });

  testWidgets('a canceled sign-in stays quiet; a failed one explains why', (tester) async {
    identity.interactiveError = SignInCanceled();
    await tester.pumpWidget(shellWith(session()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('core-sign-in')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('core-sign-in')), findsOneWidget);
    expect(find.textContaining('No se pudo'), findsNothing);

    identity.interactiveError = SignInFailed('No se pudo entrar con Google (clientConfigurationError).');
    await tester.tap(find.byKey(const Key('core-sign-in')));
    await tester.pumpAndSettle();
    expect(find.textContaining('clientConfigurationError'), findsOneWidget);
  });

  testWidgets('the brain refusing the account shows its message', (tester) async {
    identity.silent = 'id-someone-else';
    await tester.pumpWidget(shellWith(session()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('core-sign-in')), findsOneWidget);
    expect(find.text('No se pudo verificar tu cuenta de Google.'), findsOneWidget);
  });
}
