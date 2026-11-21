import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:jeep_obd2/core/auth/brain_session.dart';
import 'package:jeep_obd2/core/core_scope.dart';
import 'package:jeep_obd2/core/mailbox/cerebro_client.dart';
import 'package:jeep_obd2/core/mailbox/mailbox_screen.dart';

import 'fakes.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('CerebroClient', () {
    test('Google login sends the ID token and this app; app status has the latest APK', () async {
      final brain = FakeBrain();
      final c = brain.cerebro;
      final s = await c.loginWithGoogle('id-osvaldo');
      expect(s.userName, 'osvaldo');
      expect(brain.seen.single.url.toString(), 'https://cerebro.example/api/login/google');
      expect(brain.seen.single.body, contains('"app":"jeep-obd2"'));
      final app = await c.appStatus(s.token);
      expect(app.hasAccess, isTrue);
      expect(app.latest!.versionCode, 7);
    });

    test('a rejected token has a clear message; an expired session is flagged', () async {
      final brain = FakeBrain();
      final c = brain.cerebro;
      await expectLater(
        c.loginWithGoogle('forged'),
        throwsA(isA<CerebroException>().having((e) => e.message, 'message', 'No se pudo verificar tu cuenta de Google.')),
      );
      final s = await c.loginWithGoogle('id-osvaldo');
      brain.tokenValid = false;
      await expectLater(
        c.requests(s.token),
        throwsA(isA<CerebroException>().having((e) => e.sessionExpired, 'sessionExpired', isTrue)),
      );
    });

    test('send and list requests; download link', () async {
      final c = FakeBrain().cerebro;
      final s = await c.loginWithGoogle('id-osvaldo');
      final r = await c.send(s.token, 'Mostrar la fecha de la última lectura');
      expect(r.status, 'pending');
      expect(r.isOpen, isTrue);
      expect((await c.requests(s.token)).single.text, 'Mostrar la fecha de la última lectura');
      expect((await c.downloadLink(s.token)).queryParameters['dl'], 'one-time');
    });

    test('no network: clear message', () async {
      final c = CerebroClient(httpClient: MockClient((_) async => throw Exception('offline')), baseUrl: 'https://x');
      await expectLater(c.loginWithGoogle('id-osvaldo'), throwsA(isA<CerebroException>()));
    });
  });

  Future<(FakeBrain, FakeIdentity, List<Uri>)> pumpMailbox(WidgetTester tester, {VoiceDictation? dictation}) async {
    final brain = FakeBrain();
    final identity = FakeIdentity()..silent = 'id-osvaldo';
    final session = BrainSession(client: brain.cerebro, identity: identity);
    await session.restore();
    final opened = <Uri>[];
    await tester.pumpWidget(CoreScope(
      session: session,
      child: MaterialApp(
        home: MailboxScreen(
          dictation: dictation,
          openUrl: (u) async {
            opened.add(u);
            return true;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return (brain, identity, opened);
  }

  testWidgets('Sugerencias: send a request, see it, download the latest APK', (tester) async {
    final (brain, _, opened) = await pumpMailbox(tester);
    expect(find.widgetWithText(AppBar, 'Sugerencias'), findsOneWidget);
    expect(find.text('Versión más reciente: v7'), findsOneWidget);
    expect(find.textContaining('Hola, osvaldo'), findsOneWidget);
    expect(find.text('Aún no has enviado solicitudes.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('request-text')), 'corto');
    await tester.tap(find.byKey(const Key('send-request')));
    await tester.pumpAndSettle();
    expect(brain.requests, isEmpty);

    await tester.enterText(find.byKey(const Key('request-text')), 'Mostrar la fecha de la última lectura de códigos');
    await tester.tap(find.byKey(const Key('send-request')));
    await tester.pumpAndSettle();
    expect(brain.requests, hasLength(1));
    expect(find.text('Esperando aprobación'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('send-request'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('download-apk')));
    await tester.pumpAndSettle();
    expect(opened.single.queryParameters['dl'], 'one-time');
  });

  testWidgets('Sugerencias: an expired brain session signs in again with Google and retries', (tester) async {
    final (brain, _, _) = await pumpMailbox(tester);
    expect(brain.logins, 1);
    brain.tokenValid = false;
    await tester.enterText(find.byKey(const Key('request-text')), 'Agregar modo oscuro a la pantalla de log');
    await tester.tap(find.byKey(const Key('send-request')));
    await tester.pumpAndSettle();
    expect(brain.logins, 2);
    expect(brain.requests, hasLength(1));
  });

  testWidgets('Sugerencias: the mic dictates into the text field; stop ends it', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);

    await tester.enterText(find.byKey(const Key('request-text')), 'Agregar');
    await tester.tap(mic);
    await tester.pump();
    expect(dictation.starts, 1);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.stop)), findsOneWidget);

    dictation.say('modo oscuro');
    await tester.pump();
    expect(find.text('Agregar modo oscuro'), findsOneWidget);
    dictation.say('modo oscuro al log');
    await tester.pump();
    expect(find.text('Agregar modo oscuro al log'), findsOneWidget);

    await tester.tap(mic);
    await tester.pump();
    expect(dictation.stops, 1);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
  });

  testWidgets('Sugerencias: silence ends the dictation; no microphone shows an error', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));

    await tester.tap(mic);
    await tester.pump();
    dictation.say('Mostrar la temperatura');
    dictation.silence();
    await tester.pump();
    expect(find.text('Mostrar la temperatura'), findsOneWidget);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);

    dictation.available = false;
    await tester.tap(mic);
    await tester.pump();
    expect(find.textContaining('No se pudo usar el micrófono'), findsOneWidget);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
  });

  testWidgets('Sugerencias: no words yet is not silence; the dictation keeps listening', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));

    await tester.tap(mic);
    await tester.pump();
    // The recognizer often needs a moment before the first partial result.
    await tester.pump(const Duration(seconds: 5));
    expect(dictation.stops, 0);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.stop)), findsOneWidget);

    dictation.say('Mostrar');
    await tester.pump();
    expect(find.text('Mostrar'), findsOneWidget);

    await tester.tap(mic);
    await tester.pump();
  });

  testWidgets('Sugerencias: after the first words, 2 seconds of silence stop the dictation', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));

    await tester.tap(mic);
    await tester.pump();
    dictation.say('Mostrar la temperatura');
    await tester.pump(const Duration(milliseconds: 1999));
    expect(dictation.stops, 0);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.stop)), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    expect(dictation.stops, 1);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
    expect(find.text('Mostrar la temperatura'), findsOneWidget);
  });

  testWidgets('Sugerencias: new words restart the silence timer; a repeated result does not', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));

    await tester.tap(mic);
    await tester.pump();
    dictation.say('Mostrar');
    await tester.pump(const Duration(milliseconds: 1500));
    dictation.say('Mostrar la temperatura');
    await tester.pump(const Duration(milliseconds: 1500));
    expect(dictation.stops, 0);

    // The same transcription again is not new speech.
    dictation.say('Mostrar la temperatura');
    await tester.pump(const Duration(milliseconds: 500));
    expect(dictation.stops, 1);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
  });

  testWidgets('Sugerencias: a recognizer error shows its message and resets the mic', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));

    const cases = {
      'error_no_match': 'No se escuchó nada. Habla cerca del micrófono e inténtalo de nuevo.',
      'error_speech_timeout': 'No se escuchó nada. Habla cerca del micrófono e inténtalo de nuevo.',
      'error_network': 'El dictado necesita internet.',
      'error_network_timeout': 'El dictado necesita internet.',
      'error_language_not_supported': 'Tu teléfono no tiene el idioma del dictado instalado.',
      'error_language_unavailable': 'Tu teléfono no tiene el idioma del dictado instalado.',
    };
    for (final MapEntry(key: code, value: message) in cases.entries) {
      await tester.tap(mic);
      await tester.pump();
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.stop)), findsOneWidget, reason: code);
      dictation.fail(code);
      await tester.pump();
      expect(find.text(message), findsOneWidget, reason: code);
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget, reason: code);
    }

    await tester.tap(mic);
    await tester.pump();
    dictation.say('Mostrar');
    dictation.fail('error_busy');
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('error_busy'), findsOneWidget);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
    // The error already ended the dictation; the silence timer must not stop it again.
    expect(dictation.stops, 0);
  });

  group('SpeechToTextDictation on the real plugin', () {
    const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');

    List<MethodCall> mockRecognizer(WidgetTester tester) {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'initialize' || 'listen' => true,
          'locales' => ['es_MX:Español (México)', 'en_US:English (United States)'],
          _ => null,
        };
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
      return calls;
    }

    Future<void> fromRecognizer(WidgetTester tester, String method, String arguments) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
          (_) {},
        );

    testWidgets('waits for the first words instead of stopping after 2 s, in the system locale', (tester) async {
      final calls = mockRecognizer(tester);
      final dictation = SpeechToTextDictation();
      var done = 0;
      expect(await dictation.start(onWords: (_) {}, onError: (_) {}, onDone: () => done++), isTrue);

      final listen = calls.singleWhere((c) => c.method == 'listen').arguments as Map;
      expect(listen['localeId'], 'es_MX');
      expect(listen['pauseFor'], greaterThanOrEqualTo(8000));
      expect(listen['listenFor'], const Duration(minutes: 5).inMilliseconds);

      // Before the fix the plugin's own 2 s pause timer stopped here, before any words.
      await tester.pump(const Duration(seconds: 5));
      expect(calls.where((c) => c.method == 'stop'), isEmpty);
      expect(done, 0);

      await dictation.stop();
      expect(done, 1);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a permanent recognizer error reaches the current dictation, also on a later screen', (tester) async {
      mockRecognizer(tester);
      final first = SpeechToTextDictation();
      await first.start(onWords: (_) {}, onError: (_) {}, onDone: () {});
      await first.stop();
      await tester.pump(const Duration(seconds: 5));

      // A new mailbox screen gets a new dictation over the same plugin singleton.
      final second = SpeechToTextDictation();
      final errors = <String>[];
      var done = 0;
      await second.start(onWords: (_) {}, onError: errors.add, onDone: () => done++);
      await fromRecognizer(tester, 'notifyError', '{"errorMsg":"error_no_match","permanent":true}');
      await tester.pump();
      expect(errors, ['error_no_match']);
      expect(done, 1);
      await tester.pump(const Duration(seconds: 10));
    });
  });
}

class _FakeDictation implements VoiceDictation {
  bool available = true;
  int starts = 0;
  int stops = 0;
  void Function(String words)? _onWords;
  void Function(String code)? _onError;
  void Function()? _onDone;

  void say(String words) => _onWords?.call(words);

  void silence() => _end();

  void fail(String code) {
    _onError?.call(code);
    _end();
  }

  void _end() {
    final done = _onDone;
    _onDone = null;
    _onWords = null;
    _onError = null;
    done?.call();
  }

  @override
  Future<bool> start({
    required void Function(String words) onWords,
    required void Function(String code) onError,
    required void Function() onDone,
  }) async {
    starts++;
    if (!available) return false;
    _onWords = onWords;
    _onError = onError;
    _onDone = onDone;
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    _end();
  }
}
