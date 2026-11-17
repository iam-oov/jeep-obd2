import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/app_state.dart';
import 'package:jeep_obd2/data/dtc_descriptions.dart';
import 'package:jeep_obd2/obd/obd_service.dart';
import 'package:jeep_obd2/ui/diagnosis_screen.dart';
import 'package:jeep_obd2/ui/log_screen.dart';
import 'package:jeep_obd2/bluetooth/elm_connection.dart';
import 'package:provider/provider.dart';
import 'package:jeep_obd2/solutions/claude_client.dart';
import 'package:jeep_obd2/solutions/video_finder.dart';
import 'package:jeep_obd2/solutions/youtube_client.dart';
import 'package:jeep_obd2/ui/videos_screen.dart';
import 'package:jeep_obd2/vehicle/vehicle.dart';

Widget wrap(AppState state, Widget child) => ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(home: child),
    );

void main() {
  videosScreenTests();

  testWidgets('Diagnóstico muestra códigos con descripción', (tester) async {
    final state = AppState()
      ..descriptions = DtcDescriptions({'P0320': 'Sin señal CKP'})
      ..stored = const CodeReadResult(['P0320', 'P1999'])
      ..pending = const CodeReadResult([], supported: false)
      ..lastRead = DateTime(2026, 11, 16, 19, 30);

    await tester.pumpWidget(wrap(state, const DiagnosisScreen()));

    expect(find.text('P0320'), findsOneWidget);
    expect(find.text('Sin señal CKP'), findsOneWidget);
    expect(find.text('P1999'), findsOneWidget);
    expect(find.textContaining('específico del fabricante'), findsOneWidget);
    expect(find.textContaining('no reporta códigos pendientes'), findsOneWidget);
    // Desconectado: los botones de acción están deshabilitados.
    final read = tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text('Leer códigos'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
    );
    expect(read.onPressed, isNull);
  });

  testWidgets('Borrar códigos: dos botones y confirmación', (tester) async {
    final state = AppState()
      ..status = ConnectionStatus.ready
      ..stored = const CodeReadResult(['P1282', 'P0320']);
    await tester.pumpWidget(wrap(state, const DiagnosisScreen()));

    expect(find.text('Borrar códigos'), findsOneWidget);
    expect(find.text('Borrar estos 2 códigos y apagar el check engine'), findsOneWidget);

    await tester.tap(find.byKey(const Key('clear-codes-below')));
    await tester.pumpAndSettle();
    expect(find.text('¿Borrar códigos?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('¿Borrar códigos?'), findsNothing);
    expect(state.stored!.codes, hasLength(2)); // cancelar no borra
  });

  testWidgets('Diagnóstico sin códigos', (tester) async {
    final state = AppState()
      ..stored = const CodeReadResult([])
      ..pending = const CodeReadResult([]);
    await tester.pumpWidget(wrap(state, const DiagnosisScreen()));
    expect(find.textContaining('Sin códigos almacenados'), findsOneWidget);
    expect(find.text('Sin códigos pendientes.'), findsOneWidget);
  });

  testWidgets('Log muestra entradas', (tester) async {
    final state = AppState()
      ..addLog(LogEntry(LogKind.sent, '03'))
      ..addLog(LogEntry(LogKind.received, '43032000000000'));
    await tester.pumpWidget(wrap(state, const LogScreen()));
    expect(find.textContaining('>> 03'), findsOneWidget);
    expect(find.textContaining('<< 43032000000000'), findsOneWidget);
  });
}

class _FakeFinder extends VideoFinder {
  _FakeFinder()
      : super(claude: ClaudeClient(apiKey: 'x'), youtube: YoutubeClient(apiKey: 'x'));

  int calls = 0;

  @override
  Future<VideoSearchResult> find(
    String code,
    String description, {
    required Vehicle vehicle,
    bool refresh = false,
  }) async {
    calls++;
    return VideoSearchResult(
      queries: ['P1282 Jeep TJ fuel pump relay'],
      likelyFix: 'Revisa el relé de la bomba en el PDC.',
      picks: [
        VideoPick(
          YoutubeVideo(
            id: 'abc',
            title: 'P1282 Jeep Wrangler TJ fuel pump relay',
            channel: 'Canal',
            description: '',
            thumbnailUrl: 'https://invalid.local/x.jpg',
            duration: '12:05',
            views: 54321,
          ),
          'Muestra cómo probar el relé.',
        ),
      ],
    );
  }
}

void videosScreenTests() {
  testWidgets('VideosScreen busca al abrir y muestra resultados', (tester) async {
    final finder = _FakeFinder();
    await tester.pumpWidget(MaterialApp(
      home: VideosScreen(
        code: 'P1282',
        description: 'Relé bomba',
        vehicle: const Vehicle(make: 'Nissan', model: 'Tsuru'),
        finder: finder,
      ),
    ));
    await tester.pumpAndSettle();
    expect(finder.calls, 1);
    expect(find.text('Revisa el relé de la bomba en el PDC.'), findsOneWidget);
    expect(find.text('P1282 Jeep Wrangler TJ fuel pump relay'), findsOneWidget);
    expect(find.text('Muestra cómo probar el relé.'), findsOneWidget);
    expect(find.text('Mejor opción'), findsOneWidget);
  });
}
