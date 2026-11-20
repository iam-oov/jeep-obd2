import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeep_obd2/core/auth/brain_session.dart';
import 'package:jeep_obd2/core/auth/identity_provider.dart';
import 'package:jeep_obd2/core/core_shell.dart';
import 'package:jeep_obd2/core/mailbox/cerebro_client.dart';
import 'package:jeep_obd2/core/user_app_spec.dart';

http.Response jsonResponse(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class FakeIdentity implements IdentityProvider {
  String? silent;
  Object? interactiveError;
  int signOuts = 0;

  @override
  Future<String?> silentIdToken() async => silent;

  @override
  Future<String> interactiveIdToken() async {
    final error = interactiveError;
    if (error != null) throw error;
    return 'id-osvaldo';
  }

  @override
  Future<void> signOut() async => signOuts++;
}

class FakeBrain {
  final requests = <Map<String, Object?>>[];
  final seen = <http.Request>[];
  bool tokenValid = true;
  int logins = 0;

  late final client = MockClient((req) async {
    seen.add(req);
    final path = req.url.path;
    if (path == '/api/login/google') {
      final body = jsonDecode(req.body) as Map;
      if (body['idToken'] != 'id-osvaldo') return jsonResponse({'error': 'No se pudo verificar tu cuenta de Google.'}, 401);
      logins++;
      tokenValid = true;
      return jsonResponse({
        'token': 'tok$logins',
        'user': {'name': 'osvaldo'},
        'apps': [],
      });
    }
    if (!tokenValid || !(req.headers['authorization'] ?? '').startsWith('Bearer tok')) {
      return jsonResponse({'error': 'Sesión vencida. Vuelve a entrar.'}, 401);
    }
    if (path == '/api/apps') {
      return jsonResponse({
        'apps': [
          {
            'slug': 'jeep-obd2',
            'name': 'Jeep OBD2',
            'latest': {'versionCode': 7, 'commit': 'abc1234', 'createdAt': 1700000000000},
          },
        ],
      });
    }
    if (path == '/api/apps/jeep-obd2/requests' && req.method == 'GET') return jsonResponse({'requests': requests});
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
      return jsonResponse({'request': r}, 201);
    }
    if (path == '/api/apps/jeep-obd2/download-link') {
      return jsonResponse({'url': 'https://cerebro.example/apks/jeep-obd2/latest.apk?dl=one-time'});
    }
    return jsonResponse({'error': 'no'}, 404);
  });

  CerebroClient get cerebro => CerebroClient(httpClient: client, baseUrl: 'https://cerebro.example');
}

class FakeHome extends StatelessWidget {
  const FakeHome({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Inicio')),
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(appBar: AppBar(title: const Text('Otra pantalla'))),
              ),
            ),
            child: const Text('Ir a otra pantalla'),
          ),
        ),
      );
}

UserAppSpec fakeSpec() => UserAppSpec(
      title: 'Jeep OBD2',
      theme: ThemeData(useMaterial3: true),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: const FakeHome(),
    );

CoreShell shellWith(BrainSession session) => CoreShell(spec: fakeSpec(), session: session);
