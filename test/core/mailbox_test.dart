import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:jeep_obd2/core/auth/brain_session.dart';
import 'package:jeep_obd2/core/core_scope.dart';
import 'package:jeep_obd2/core/mailbox/cerebro_client.dart';
import 'package:jeep_obd2/core/mailbox/mailbox_screen.dart';
import 'package:speech_to_text/speech_to_text.dart';

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

  testWidgets('Sugerencias: the mic dictates into the text field, replacing typed text once words arrive; stop ends it', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));
    final field = find.byKey(const Key('request-text'));
    String text() => tester.widget<TextField>(field).controller!.text;
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);

    await tester.enterText(field, 'Agregar');
    await tester.tap(mic);
    await tester.pump();
    expect(dictation.starts, 1);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.stop)), findsOneWidget);
    // The tap alone does not clear the field.
    expect(text(), 'Agregar');

    dictation.say('modo oscuro');
    await tester.pump();
    expect(text(), 'Modo oscuro');
    dictation.say('modo oscuro al log');
    await tester.pump();
    expect(text(), 'Modo oscuro al log');
    expect(tester.widget<TextField>(field).controller!.selection, const TextSelection.collapsed(offset: 18));

    await tester.tap(mic);
    await tester.pump();
    expect(dictation.stops, 1);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
  });

  testWidgets('Sugerencias: a second dictation replaces the first one; an empty one keeps it', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    final mic = find.byKey(const Key('dictate-request'));
    String text() => tester.widget<TextField>(find.byKey(const Key('request-text'))).controller!.text;

    await tester.tap(mic);
    await tester.pump();
    // The recognizer sends lowercase; only the first letter is capitalized.
    dictation.say('agregar un modo oscuro a la aplicación');
    await tester.pump(const Duration(seconds: 2));
    expect(dictation.stops, 1);
    expect(text(), 'Agregar un modo oscuro a la aplicación');

    await tester.tap(mic);
    await tester.pump();
    dictation.say('mostrar la temperatura del motor');
    await tester.pump();
    expect(text(), 'Mostrar la temperatura del motor');
    await tester.pump(const Duration(seconds: 2));

    // A session that hears nothing leaves the text alone and says so.
    await tester.tap(mic);
    await tester.pump();
    dictation.say('');
    dictation.fail('error_no_match');
    await tester.pump();
    expect(text(), 'Mostrar la temperatura del motor');
    expect(find.text('No se escuchó nada. Habla cerca del micrófono e inténtalo de nuevo.'), findsOneWidget);
    expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
  });

  testWidgets('Sugerencias: only the first dictated letter is capitalized, Spanish letters included', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    String text() => tester.widget<TextField>(find.byKey(const Key('request-text'))).controller!.text;
    await tester.tap(find.byKey(const Key('dictate-request')));
    await tester.pump();
    for (final (said, shown) in [
      ('ñandú en la pantalla de GPS', 'Ñandú en la pantalla de GPS'),
      ('árbol de códigos OBD', 'Árbol de códigos OBD'),
      ('Ya empieza con mayúscula', 'Ya empieza con mayúscula'),
      ('2 segundos de silencio', '2 segundos de silencio'),
    ]) {
      dictation.say(said);
      await tester.pump();
      expect(text(), shown);
    }
    await tester.tap(find.byKey(const Key('dictate-request')));
    await tester.pump();
  });

  testWidgets('Sugerencias: dictated text is capped at 280 characters', (tester) async {
    final dictation = _FakeDictation();
    await pumpMailbox(tester, dictation: dictation);
    await tester.tap(find.byKey(const Key('dictate-request')));
    await tester.pump();
    dictation.say('a' * 300);
    await tester.pump();
    final controller = tester.widget<TextField>(find.byKey(const Key('request-text'))).controller!;
    expect(controller.text, 'A${'a' * 279}');
    expect(controller.selection, const TextSelection.collapsed(offset: 280));
    await tester.tap(find.byKey(const Key('dictate-request')));
    await tester.pump();
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
    // Like the S10+ in English: the system locale comes first.
    const englishPhone = ['en_US:English (United States)', 'es_US:Español (Estados Unidos)', 'es_MX:Español (México)'];
    const noMatch = 'No se escuchó nada. Habla cerca del micrófono e inténtalo de nuevo.';

    List<MethodCall> mockRecognizer(
      WidgetTester tester, {
      List<String>? locales = englishPhone,
      Future<void> Function()? whileStopping,
    }) {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'stop') await whileStopping?.call();
        return switch (call.method) {
          'initialize' || 'listen' => true,
          'locales' => locales ?? (throw PlatformException(code: 'no_locales')),
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

    Future<void> result(WidgetTester tester, String words, {bool isFinal = false}) => fromRecognizer(
          tester,
          'textRecognition',
          jsonEncode({
            'alternates': [
              {'recognizedWords': words, 'confidence': 0.9},
            ],
            'resultType': isFinal ? 2 : 0,
          }),
        );

    SpeechToTextDictation fresh() => SpeechToTextDictation(speech: SpeechToText.withMethodChannel());

    testWidgets('waits for the first words instead of stopping after 2 s', (tester) async {
      final calls = mockRecognizer(tester);
      final dictation = fresh();
      var done = 0;
      expect(await dictation.start(onWords: (_) {}, onError: (_) {}, onDone: () => done++), isTrue);

      final listen = calls.singleWhere((c) => c.method == 'listen').arguments as Map;
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

    testWidgets('always listens in Spanish, even on a phone in English', (tester) async {
      const cases = <List<String>?, String>{
        englishPhone: 'es_MX',
        ['en_US:English', 'es_419:Español (Latinoamérica)', 'es_US:Español (Estados Unidos)']: 'es_US',
        ['en_US:English', 'es_419:Español (Latinoamérica)']: 'es_419',
        ['en_US:English', 'es_ES:Español (España)']: 'es_ES',
        ['en_US:English']: 'es_MX',
        null: 'es_MX',
      };
      for (final MapEntry(key: locales, value: expected) in cases.entries) {
        final calls = mockRecognizer(tester, locales: locales);
        final dictation = fresh();
        expect(await dictation.start(onWords: (_) {}, onError: (_) {}, onDone: () {}), isTrue);
        final listen = calls.singleWhere((c) => c.method == 'listen').arguments as Map;
        expect(listen['localeId'], expected, reason: '$locales');
        expect(calls.where((c) => c.method == 'systemLocale'), isEmpty);
        await dictation.stop();
        await tester.pump(const Duration(seconds: 5));
      }
    });

    testWidgets('initializes without Bluetooth headsets, so the phone mic is used', (tester) async {
      final calls = mockRecognizer(tester);
      await fresh().start(onWords: (_) {}, onError: (_) {}, onDone: () {});
      final init = calls.singleWhere((c) => c.method == 'initialize').arguments as Map;
      expect(init['noBluetooth'], isTrue);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a permanent recognizer error reaches the current dictation, also on a later screen', (tester) async {
      mockRecognizer(tester);
      final speech = SpeechToText.withMethodChannel();
      final first = SpeechToTextDictation(speech: speech);
      await first.start(onWords: (_) {}, onError: (_) {}, onDone: () {});
      await first.stop();
      await tester.pump(const Duration(seconds: 5));

      // A new mailbox screen gets a new dictation over the same plugin instance.
      final second = SpeechToTextDictation(speech: speech);
      final errors = <String>[];
      var done = 0;
      await second.start(onWords: (_) {}, onError: errors.add, onDone: () => done++);
      await fromRecognizer(tester, 'notifyError', '{"errorMsg":"error_no_match","permanent":true}');
      await tester.pump();
      expect(errors, ['error_no_match']);
      expect(done, 1);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a session that ends without words says nothing was heard and resets the mic', (tester) async {
      mockRecognizer(tester);
      await pumpMailbox(tester, dictation: fresh());
      final mic = find.byKey(const Key('dictate-request'));

      // Ambient noise: the recognizer ends with an empty final result.
      await tester.tap(mic);
      await tester.pumpAndSettle();
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.stop)), findsOneWidget);
      await result(tester, '', isFinal: true);
      await tester.pump();
      expect(find.text(noMatch), findsOneWidget);
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));

      // No result at all, only the end of the session.
      await tester.tap(mic);
      await tester.pumpAndSettle();
      expect(find.text(noMatch), findsNothing);
      await fromRecognizer(tester, 'notifyStatus', 'notListening');
      await tester.pump();
      expect(find.text(noMatch), findsOneWidget);
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('an empty final result after words keeps the text and says nothing', (tester) async {
      mockRecognizer(tester);
      await pumpMailbox(tester, dictation: fresh());
      final mic = find.byKey(const Key('dictate-request'));

      await tester.tap(mic);
      await tester.pumpAndSettle();
      await result(tester, 'Mostrar la temperatura');
      await tester.pump();
      await result(tester, '', isFinal: true);
      await tester.pump();
      expect(find.text('Mostrar la temperatura'), findsOneWidget);
      expect(find.text(noMatch), findsNothing);
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('stopping before any words is not an error', (tester) async {
      // Android reports the end of the session while the stop is still in flight.
      mockRecognizer(tester, whileStopping: () async {
        await fromRecognizer(tester, 'notifyStatus', 'notListening');
        await fromRecognizer(tester, 'notifyStatus', 'doneNoResult');
      });
      await pumpMailbox(tester, dictation: fresh());
      final mic = find.byKey(const Key('dictate-request'));

      await tester.tap(mic);
      await tester.pumpAndSettle();
      await tester.tap(mic);
      await tester.pump();
      expect(find.text(noMatch), findsNothing);
      expect(find.descendant(of: mic, matching: find.byIcon(Icons.mic)), findsOneWidget);
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
