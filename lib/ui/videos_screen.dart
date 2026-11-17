import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../solutions/claude_client.dart';
import '../solutions/video_finder.dart';
import '../solutions/youtube_client.dart';
import '../vehicle/vehicle.dart';
import 'vehicle_dialog.dart';
import 'widgets.dart';

/// Llaves inyectadas al compilar con `--dart-define-from-file=secrets.json`.
const anthropicApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
const youtubeApiKey = String.fromEnvironment('YOUTUBE_API_KEY');

/// Abre la búsqueda de videos para [code]; si no hay vehículo guardado,
/// primero lo pide con el modal.
Future<void> openVideosFor(BuildContext context, String code, String description) async {
  final vehicle = await ensureVehicle(context);
  if (vehicle == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => VideosScreen(code: code, description: description, vehicle: vehicle),
    ),
  );
}

class VideosScreen extends StatefulWidget {
  const VideosScreen({
    super.key,
    required this.code,
    required this.description,
    required this.vehicle,
    this.finder,
  });

  final String code;
  final String description;
  final Vehicle vehicle;

  /// Para pruebas; en la app se crea con las llaves de compilación.
  final VideoFinder? finder;

  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  Future<VideoSearchResult>? _future;

  VideoFinder? get _finder =>
      widget.finder ??
      (anthropicApiKey.isEmpty || youtubeApiKey.isEmpty
          ? null
          : VideoFinder(
              claude: ClaudeClient(apiKey: anthropicApiKey),
              youtube: YoutubeClient(apiKey: youtubeApiKey),
            ));

  @override
  void initState() {
    super.initState();
    _search();
  }

  void _search({bool refresh = false}) {
    final finder = _finder;
    if (finder == null) return;
    final future =
        finder.find(widget.code, widget.description, vehicle: widget.vehicle, refresh: refresh);
    setState(() {
      _future = future;
    });
  }

  Future<void> _open(YoutubeVideo v) async {
    final ok = await launchUrl(v.url, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir YouTube')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Videos para ${widget.code}')),
      body: _finder == null
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Falta configurar las llaves de API. Compila con:\n\n'
                'flutter build apk --debug --dart-define-from-file=secrets.json\n\n'
                'donde secrets.json tiene ANTHROPIC_API_KEY y YOUTUBE_API_KEY '
                '(ver secrets.example.json).',
              ),
            )
          : FutureBuilder<VideoSearchResult>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return ListView(children: const [
                    ProgressCard(text: 'Haiku está buscando videos en YouTube… (~10 s)'),
                  ]);
                }
                if (snap.hasError) {
                  final e = snap.error;
                  final msg = e is ClaudeException || e is YoutubeException
                      ? e.toString()
                      : 'Error inesperado: $e';
                  return ListView(children: [
                    ErrorBanner(message: msg, onClose: _search),
                    Center(
                      child: FilledButton.icon(
                        onPressed: _search,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    ),
                  ]);
                }
                return _Results(
                  code: widget.code,
                  description: widget.description,
                  vehicle: widget.vehicle.description,
                  result: snap.data!,
                  onOpen: _open,
                  onRetry: () => _search(refresh: true),
                );
              },
            ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({
    required this.code,
    required this.description,
    required this.vehicle,
    required this.result,
    required this.onOpen,
    required this.onRetry,
  });

  final String code;
  final String description;
  final String vehicle;
  final VideoSearchResult result;
  final void Function(YoutubeVideo) onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$code · $description', style: theme.textTheme.titleSmall),
                Text(vehicle, style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Text(result.likelyFix),
              ],
            ),
          ),
        ),
        if (result.picks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Text('Haiku no encontró un video que sirva para este código.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Buscar otra vez'),
                ),
              ],
            ),
          )
        else
          for (final (i, p) in result.picks.indexed)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onOpen(p.video),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      children: [
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.network(
                            p.video.thumbnailUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const ColoredBox(color: Colors.black26),
                          ),
                        ),
                        if (p.video.duration != null)
                          Positioned(
                            right: 8,
                            bottom: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              color: Colors.black87,
                              child: Text(
                                p.video.duration!,
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ),
                          ),
                        if (i == 0)
                          Positioned(
                            left: 8,
                            top: 8,
                            child: Chip(
                              label: const Text('Mejor opción'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: theme.colorScheme.primaryContainer,
                            ),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.video.title, style: theme.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            [
                              p.video.channel,
                              if (p.video.views != null) '${_compact(p.video.views!)} vistas',
                            ].join(' · '),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Text(p.reason),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'Búsquedas: ${result.queries.join(' · ')}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  static String _compact(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)} M'
      : n >= 1000
          ? '${(n / 1000).toStringAsFixed(0)} k'
          : '$n';
}
