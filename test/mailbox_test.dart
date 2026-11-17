import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeep_obd2/solutions/cerebro_client.dart';
import 'package:jeep_obd2/ui/mailbox_screen.dart';

const utf8Json = {'content-type': 'application/json; charset=utf-8'};

http.Response json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: utf8Json);

/// A fake brain with one user (code 1234) and an in-memory list of requests.
class FakeBrain {
  final requests = <Map<String, Object?>>[];
  final seen = <http.Request>[];
  bool tokenValid = true;
  int logins = 0;

  late final client = MockClient((req) async {
    seen.add(req);
    final path = req.url.path;
    if (path == '/api/login') {
      final code = (jsonDecode(req.body) as Map)['code'];
      if (code != '1234') return json({'error': 'Código incorrecto.'}, 401);
      logins++;
      tokenValid = true;
      return json({
        'token': 'tok$logins',
        'user': {'name': 'osvaldo'},
        'apps': [
          {
            'slug': 'jeep-obd2',
            'name': 'Jeep OBD2',
            'latest': {'versionCode': 7, 'commit': 'abc1234', 'createdAt': 1700000000000},
          },
        ],
      });
    }
    if (!tokenValid || !(req.headers['authorization'] ?? '').startsWith('Bearer tok')) {
      return json({'error': 'Sesión vencida. Vuelve a poner tu código.'}, 401);
    }
    if (path == '/api/apps/jeep-obd2/requests' && req.method == 'GET') return json({'requests': requests});
    if (path == '/api/apps/jeep-obd2/requests' && req.method == 'POST') {
      final text = (jsonDecode(req.body) as Map)['text'] as String;
      final r = {
        'id': requests.length + 1,
        'kind': 'change',
        'text': text,
        'status': 'pending',
        'statusLabel': 'Esperando aprobación',
        'reason': null,
        'createdAt': 1700000000000,
        'finishedAt': null,
        'build': null,
      };
      requests.insert(0, r);
      return json({'request': r}, 201);
    }
    if (path == '/api/apps/jeep-obd2/download-link') {
      return json({'url': 'https://cerebro.example/apks/jeep-obd2/latest.apk?dl=one-time'});
    }
    return json({'error': 'no'}, 404);
  });
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('CerebroClient', () {
    test('login parses the user, access and latest APK', () async {
      final brain = FakeBrain();
      final c = CerebroClient(httpClient: brain.client, baseUrl: 'https://cerebro.example');
      final s = await c.login('1234');
      expect(s.userName, 'osvaldo');
      expect(s.hasAccess, isTrue);
      expect(s.latest!.versionCode, 7);
      expect(brain.seen.single.url.toString(), 'https://cerebro.example/api/login');
    });

    test('wrong code: clear message; expired token: sessionExpired', () async {
      final brain = FakeBrain();
      final c = CerebroClient(httpClient: brain.client, baseUrl: 'https://x');
      await expectLater(
        c.login('9999'),
        throwsA(isA<CerebroException>().having((e) => e.message, 'message', 'Código incorrecto.')),
      );
      final s = await c.login('1234');
      brain.tokenValid = false;
      await expectLater(
        c.requests(s.token),
        throwsA(isA<CerebroException>().having((e) => e.sessionExpired, 'sessionExpired', isTrue)),
      );
    });

    test('send and list requests; download link', () async {
      final brain = FakeBrain();
      final c = CerebroClient(httpClient: brain.client, baseUrl: 'https://x');
      final s = await c.login('1234');
      final r = await c.send(s.token, 'Mostrar la fecha de la última lectura');
      expect(r.status, 'pending');
      expect(r.isOpen, isTrue);
      expect((await c.requests(s.token)).single.text, 'Mostrar la fecha de la última lectura');
      expect((await c.downloadLink(s.token)).queryParameters['dl'], 'one-time');
    });

    test('no network: clear message', () async {
      final c = CerebroClient(httpClient: MockClient((_) async => throw Exception('offline')), baseUrl: 'https://x');
      await expectLater(c.login('1234'), throwsA(isA<CerebroException>()));
    });
  });

  testWidgets('Buzón: code, send a request, see it, download the latest APK', (tester) async {
    final brain = FakeBrain();
    final opened = <Uri>[];
    await tester.pumpWidget(MaterialApp(
      home: MailboxScreen(
        client: CerebroClient(httpClient: brain.client, baseUrl: 'https://x'),
        codeStore: CerebroCodeStore(),
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Sugerencias'), findsOneWidget);
    expect(find.text('Buzón'), findsNothing);

    // Wrong code first.
    await tester.enterText(find.byKey(const Key('cerebro-code')), '9999');
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(find.text('Código incorrecto.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('cerebro-code')), '1234');
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();
    expect(find.text('Versión más reciente: v7'), findsOneWidget);
    expect(find.text('Aún no has enviado solicitudes.'), findsOneWidget);
    expect(await CerebroCodeStore().load(), '1234');

    // Too short: not sent.
    await tester.enterText(find.byKey(const Key('request-text')), 'corto');
    await tester.tap(find.byKey(const Key('send-request')));
    await tester.pumpAndSettle();
    expect(brain.requests, isEmpty);

    await tester.enterText(find.byKey(const Key('request-text')), 'Mostrar la fecha de la última lectura de códigos');
    await tester.tap(find.byKey(const Key('send-request')));
    await tester.pumpAndSettle();
    expect(brain.requests, hasLength(1));
    expect(find.text('Esperando aprobación'), findsOneWidget);
    // One open request: the field and the button are disabled.
    expect(tester.widget<FilledButton>(find.byKey(const Key('send-request'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('download-apk')));
    await tester.pumpAndSettle();
    expect(opened.single.queryParameters['dl'], 'one-time');
  });

  testWidgets('Buzón: a saved code logs in by itself; an expired session logs in again', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'cerebro_code': '1234'});
    final brain = FakeBrain();
    await tester.pumpWidget(MaterialApp(
      home: MailboxScreen(client: CerebroClient(httpClient: brain.client, baseUrl: 'https://x')),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hola, osvaldo'), findsOneWidget);
    expect(brain.logins, 1);

    brain.tokenValid = false;
    await tester.enterText(find.byKey(const Key('request-text')), 'Agregar modo oscuro a la pantalla de log');
    await tester.tap(find.byKey(const Key('send-request')));
    await tester.pumpAndSettle();
    expect(brain.logins, 2);
    expect(brain.requests, hasLength(1));
  });
}
