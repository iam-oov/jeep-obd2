import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/app_state.dart';
import 'package:jeep_obd2/data/dtc_descriptions.dart';
import 'package:jeep_obd2/solutions/claude_client.dart';
import 'package:jeep_obd2/solutions/video_finder.dart';
import 'package:jeep_obd2/solutions/youtube_client.dart';
import 'package:jeep_obd2/ui/videos_screen.dart';
import 'package:jeep_obd2/vehicle/vehicle.dart';
import 'package:provider/provider.dart';

/// Records which codes were searched, without calling any API.
class CountingFinder extends VideoFinder {
  CountingFinder()
      : super(claude: ClaudeClient(apiKey: 'x'), youtube: YoutubeClient(apiKey: 'x'));

  final codes = <String>[];

  @override
  Future<VideoSearchResult> find(
    String code,
    String description, {
    required Vehicle vehicle,
    bool refresh = false,
  }) async {
    codes.add(code);
    return VideoSearchResult(queries: const [], likelyFix: 'fix', picks: const []);
  }
}

const vehicle = Vehicle(make: 'Jeep', model: 'Wrangler', year: 1998);

void main() {
  test('similar: closest codes that exist in the table', () {
    final table = DtcDescriptions({'P1281': 'a', 'P1282': 'b', 'P0320': 'c', 'P1283X': 'd'});
    expect(table.similar('P1283'), ['P1281', 'P1282']);
    expect(table.similar('P1282'), ['P1281']);
    expect(table.similar('P1283', maxDistance: 2), ['P1281', 'P1282']);
    expect(table.similar('P9999'), isEmpty);
    expect(table.isKnown('p1282'), isTrue);
  });

  testWidgets('code not in the table: no search, suggests the real code', (tester) async {
    final state = AppState()..descriptions = DtcDescriptions({'P1281': 'a', 'P1282': 'b'});
    final finder = CountingFinder();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: VideosScreen(
          code: 'P1283',
          description: 'x',
          vehicle: vehicle,
          finder: finder,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(finder.codes, isEmpty); // Haiku is not called for an unknown code
    expect(find.textContaining('no está en la tabla'), findsOneWidget);
    expect(find.byKey(const Key('suggest-P1282')), findsOneWidget);

    await tester.tap(find.byKey(const Key('suggest-P1282')));
    await tester.pumpAndSettle();
    expect(finder.codes, ['P1282']);
    expect(find.text('Videos para P1282'), findsOneWidget);
  });

  testWidgets('code not in the table: "search anyway" still works', (tester) async {
    final state = AppState()..descriptions = DtcDescriptions({'P1282': 'b'});
    final finder = CountingFinder();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: VideosScreen(code: 'P7777', description: 'x', vehicle: vehicle, finder: finder),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Buscar videos de todos modos'));
    await tester.pumpAndSettle();
    expect(finder.codes, ['P7777']);
  });

  testWidgets('no videos found: shows similar codes and "buscar otro código"', (tester) async {
    final state = AppState()..descriptions = DtcDescriptions({'P1281': 'a', 'P1282': 'b'});
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        home: VideosScreen(
          code: 'P1282',
          description: 'b',
          vehicle: vehicle,
          finder: CountingFinder(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Buscar otro código'), findsOneWidget);
  });
}
