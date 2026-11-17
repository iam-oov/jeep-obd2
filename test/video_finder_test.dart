import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jeep_obd2/solutions/claude_client.dart';
import 'package:jeep_obd2/solutions/video_finder.dart';
import 'package:jeep_obd2/solutions/youtube_client.dart';
import 'package:jeep_obd2/vehicle/vehicle.dart';

const testVehicle = Vehicle(make: 'Nissan', model: 'Tsuru', year: 2005, liters: 1.6, cylinders: 4);

http.Response claudeReply(Map<String, dynamic> json, {String stop = 'end_turn'}) => http.Response(
      jsonEncode({
        'type': 'message',
        'stop_reason': stop,
        'content': [
          {'type': 'thinking', 'thinking': ''},
          {'type': 'text', 'text': jsonEncode(json)},
        ],
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> searchItem(String id, String title) => {
      'id': {'kind': 'youtube#video', 'videoId': id},
      'snippet': {
        'title': title,
        'channelTitle': 'Canal $id',
        'description': 'desc $id',
        'thumbnails': {
          'medium': {'url': 'https://i.ytimg.com/vi/$id/mqdefault.jpg'},
        },
      },
    };

const utf8Json = {'content-type': 'application/json; charset=UTF-8'};

void main() {
  late List<http.Request> claudeRequests;
  late List<Uri> youtubeRequests;
  late List<http.Response> claudeQueue;

  VideoFinder finder({Map<String, List<Map<String, dynamic>>>? searchResults}) {
    claudeRequests = [];
    youtubeRequests = [];
    final client = MockClient((req) async {
      if (req.url.host == 'api.anthropic.com') {
        claudeRequests.add(req);
        return claudeQueue.removeAt(0);
      }
      youtubeRequests.add(req.url);
      if (req.url.path.endsWith('/search')) {
        final q = req.url.queryParameters['q']!;
        return http.Response(jsonEncode({'items': searchResults?[q] ?? []}), 200, headers: utf8Json);
      }
      // videos.list
      final ids = req.url.queryParameters['id']!.split(',');
      return http.Response(
        jsonEncode({
          'items': [
            for (final id in ids)
              {
                'id': id,
                'contentDetails': {'duration': 'PT12M5S'},
                'statistics': {'viewCount': '54321'},
              },
          ],
        }),
        200,
      );
    });
    return VideoFinder(
      claude: ClaudeClient(apiKey: 'sk-test', httpClient: client),
      youtube: YoutubeClient(apiKey: 'yt-test', httpClient: client),
    );
  }

  final plan = {
    'queries': [
      {'query': 'P1282 Jeep Wrangler relé bomba gasolina', 'language': 'es'},
      {'query': 'P1282 Jeep TJ fuel pump relay', 'language': 'en'},
      {'query': 'tercera query que se ignora', 'language': 'en'},
    ],
    'likely_fix': 'Suele ser el relé de la bomba o su conector en el PDC.',
  };

  setUp(VideoFinder.clearCache);

  test('flujo completo: queries -> YouTube -> ranking', () async {
    claudeQueue = [
      claudeReply(plan),
      claudeReply({
        'picks': [
          {'video_id': 'bbb', 'reason': 'Muestra cómo probar el relé en un TJ.'},
          {'video_id': 'inventado', 'reason': 'no existe'},
          {'video_id': 'aaa', 'reason': 'Explica el código P1282.'},
          {'video_id': 'bbb', 'reason': 'repetido'},
        ],
      }),
    ];
    final f = finder(searchResults: {
      'P1282 Jeep Wrangler relé bomba gasolina': [searchItem('aaa', 'P1282 Jeep &amp; relé')],
      'P1282 Jeep TJ fuel pump relay': [searchItem('bbb', 'TJ fuel pump relay'), searchItem('aaa', 'dup')],
    });

    final r = await f.find('P1282', 'Circuito de control del relé de la bomba de gasolina', vehicle: testVehicle);

    expect(r.picks.map((p) => p.video.id), ['bbb', 'aaa']);
    expect(r.picks.first.reason, contains('relé'));
    expect(r.picks.last.video.title, 'P1282 Jeep & relé'); // entidades HTML
    expect(r.picks.first.video.duration, '12:05');
    expect(r.picks.first.video.views, 54321);
    expect(r.likelyFix, contains('relé'));
    expect(r.queries, hasLength(2));

    // 2 searches (max) + 1 videos.list
    expect(youtubeRequests.where((u) => u.path.endsWith('/search')), hasLength(2));
    expect(youtubeRequests.last.queryParameters['id'], 'aaa,bbb');
    expect(youtubeRequests.first.queryParameters['relevanceLanguage'], 'es');
    expect(youtubeRequests.first.queryParameters['key'], 'yt-test');

    // Request to Claude: model, headers and structured output.
    final req = claudeRequests.first;
    expect(req.headers['x-api-key'], 'sk-test');
    expect(req.headers['anthropic-version'], '2026-10-21');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['model'], 'claude-haiku-5-5');
    expect(body['output_config']['effort'], 'low');
    expect(body['output_config']['format']['type'], 'json_schema');
    expect(body.containsKey('thinking'), isFalse);
    expect((jsonDecode(claudeRequests.last.body)['messages'][0]['content'] as String),
        contains('id: bbb'));
    for (final r in claudeRequests) {
      final prompt = jsonDecode(r.body)['messages'][0]['content'] as String;
      expect(prompt, contains('Nissan Tsuru 2005, motor 1.6L 4 cilindros'));
      // The instructions contain no fixed vehicle (the simulated
      // video titles do say "Jeep", so they are removed).
      final instructions = prompt.replaceAll(RegExp(r'^- id: .*$', multiLine: true), '');
      expect(instructions, isNot(matches(RegExp('Jeep|Wrangler|TJ|Chrysler'))));
    }
  });

  test('caché: el mismo código no vuelve a llamar a las APIs', () async {
    claudeQueue = [
      claudeReply(plan),
      claudeReply({
        'picks': [
          {'video_id': 'aaa', 'reason': 'ok'},
        ],
      }),
    ];
    final f = finder(searchResults: {
      'P1282 Jeep TJ fuel pump relay': [searchItem('aaa', 'P1282 TJ')],
    });
    await f.find('P0999', 'x', vehicle: testVehicle);
    final calls = claudeRequests.length + youtubeRequests.length;
    final again = await f.find('P0999', 'x', vehicle: testVehicle);
    expect(again.picks.single.video.id, 'aaa');
    expect(claudeRequests.length + youtubeRequests.length, calls);
  });

  test('acentos: la respuesta se lee como UTF-8 aunque no traiga charset', () async {
    claudeQueue = [
      http.Response.bytes(
        utf8.encode(jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': jsonEncode({'queries': [], 'likely_fix': 'relé'})},
          ],
        })),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ];
    await expectLater(finder().find('P0001', 'x', vehicle: testVehicle), throwsA(isA<ClaudeException>()));
    // Without queries it throws, but it decoded correctly first: we test the client directly.
    claudeQueue = [
      http.Response.bytes(
        utf8.encode(jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': jsonEncode({'x': 'relé de la bomba'})},
          ],
        })),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ];
    final client = MockClient((_) async => claudeQueue.removeAt(0));
    final out = await ClaudeClient(apiKey: 'k', httpClient: client)
        .json(system: 's', prompt: 'p', schema: const {});
    expect(out['x'], 'relé de la bomba');
  });

  test('reintenta una vez ante 529', () async {
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return calls == 1
          ? http.Response('{"type":"error","error":{"type":"overloaded_error"}}', 529)
          : claudeReply({'ok': true});
    });
    final out = await ClaudeClient(apiKey: 'k', httpClient: client)
        .json(system: 's', prompt: 'p', schema: const {});
    expect(out['ok'], isTrue);
    expect(calls, 2);
  });

  test('sin resultados en YouTube: no llama al ranking', () async {
    claudeQueue = [claudeReply(plan)];
    final r = await finder().find('P1282', 'x', vehicle: testVehicle);
    expect(r.picks, isEmpty);
    expect(claudeRequests, hasLength(1));
  });

  test('refusal de Claude -> ClaudeException clara', () async {
    claudeQueue = [claudeReply({}, stop: 'refusal')];
    await expectLater(finder().find('P1282', 'x', vehicle: testVehicle), throwsA(isA<ClaudeException>()));
  });

  test('llave de Anthropic inválida -> mensaje claro', () async {
    claudeQueue = [
      http.Response(jsonEncode({'type': 'error', 'error': {'type': 'authentication_error'}}), 401),
    ];
    await expectLater(
      finder().find('P1282', 'x', vehicle: testVehicle),
      throwsA(isA<ClaudeException>().having((e) => e.message, 'message', contains('ANTHROPIC_API_KEY'))),
    );
  });

  test('cuota de YouTube agotada -> mensaje claro', () async {
    claudeQueue = [claudeReply(plan)];
    final client = MockClient((req) async {
      if (req.url.host == 'api.anthropic.com') return claudeQueue.removeAt(0);
      return http.Response(
        jsonEncode({
          'error': {
            'code': 403,
            'errors': [
              {'reason': 'quotaExceeded'},
            ],
          },
        }),
        403,
      );
    });
    final f = VideoFinder(
      claude: ClaudeClient(apiKey: 'k', httpClient: client),
      youtube: YoutubeClient(apiKey: 'k', httpClient: client),
    );
    await expectLater(
      f.find('P1282', 'x', vehicle: testVehicle),
      throwsA(isA<YoutubeException>().having((e) => e.message, 'message', contains('cuota'))),
    );
  });

  test('formatIsoDuration', () {
    expect(formatIsoDuration('PT12M5S'), '12:05');
    expect(formatIsoDuration('PT1H2M3S'), '1:02:03');
    expect(formatIsoDuration('PT45S'), '0:45');
    expect(formatIsoDuration('P1D'), isNull);
  });
}
