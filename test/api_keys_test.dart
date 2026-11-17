import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeep_obd2/app_state.dart';
import 'package:jeep_obd2/solutions/api_keys.dart';
import 'package:jeep_obd2/ui/api_keys_dialog.dart';
import 'package:provider/provider.dart';

const anthropicKey = 'sk-ant-api03-PRUEBA-1234';
const youtubeKey = 'AIzaPRUEBA-5678';

/// Fake checker: [anthropicStatus]/[youtubeStatus] are the HTTP codes.
ApiKeyChecker fakeChecker({int anthropicStatus = 200, int youtubeStatus = 200, String youtubeBody = '{}'}) =>
    ApiKeyChecker(
      httpClient: MockClient((req) async {
        if (req.url.host == 'api.anthropic.com') return http.Response('{}', anthropicStatus);
        return http.Response(youtubeBody, youtubeStatus);
      }),
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('ApiKeyStore: vacío, guardar, leer y borrar', () async {
    final store = ApiKeyStore();
    expect((await store.load()).complete, isFalse);
    await store.save(const ApiKeys(anthropic: anthropicKey, youtube: youtubeKey));
    final k = await store.load();
    expect(k.anthropic, anthropicKey);
    expect(k.youtube, youtubeKey);
    expect(k.complete, isTrue);
    await store.clear();
    expect((await store.load()).complete, isFalse);
  });

  test('mask no revela la llave', () {
    expect(ApiKeys.mask(anthropicKey), 'sk-ant-…1234');
    expect(ApiKeys.mask('corta'), '••••');
  });

  group('ApiKeyChecker', () {
    test('Anthropic', () async {
      expect(await fakeChecker().anthropic('k'), KeyCheck.ok);
      expect(await fakeChecker(anthropicStatus: 401).anthropic('k'), KeyCheck.invalid);
      expect(await fakeChecker(anthropicStatus: 503).anthropic('k'), KeyCheck.unreachable);
      final offline = ApiKeyChecker(httpClient: MockClient((_) async => throw Exception('x')));
      expect(await offline.anthropic('k'), KeyCheck.unreachable);
    });

    test('YouTube', () async {
      expect(await fakeChecker().youtube('k'), KeyCheck.ok);
      expect(await fakeChecker(youtubeStatus: 400).youtube('k'), KeyCheck.invalid);
      expect(
        await fakeChecker(youtubeStatus: 403, youtubeBody: '{"error":{"errors":[{"reason":"quotaExceeded"}]}}')
            .youtube('k'),
        KeyCheck.ok,
      );
    });
  });

  testWidgets('modal: valida, rechaza la llave mala y guarda la buena', (tester) async {
    final state = AppState();
    await state.loadApiKeys();
    bool? saved;
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => saved = await showApiKeysDialog(context),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    // Empty -> does not save.
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Pega tu llave de Anthropic'), findsOneWidget);

    // Anthropic rejects the key -> error on that field, dialog stays open.
    apiKeyChecker = fakeChecker(anthropicStatus: 401);
    await tester.enterText(find.byKey(const Key('key-anthropic')), anthropicKey);
    await tester.enterText(find.byKey(const Key('key-youtube')), youtubeKey);
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Anthropic rechazó esta llave'), findsOneWidget);
    expect(state.apiKeys.complete, isFalse);

    // Now they are valid.
    apiKeyChecker = fakeChecker();
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(state.apiKeys.anthropic, anthropicKey);
    expect((await ApiKeyStore().load()).youtube, youtubeKey);
  });
}
