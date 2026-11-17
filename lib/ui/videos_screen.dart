import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data/dtc_descriptions.dart';
import '../solutions/claude_client.dart';
import '../solutions/video_finder.dart';
import '../solutions/youtube_client.dart';
import '../vehicle/vehicle.dart';
import 'api_keys_dialog.dart';
import 'vehicle_dialog.dart';
import 'widgets.dart';

/// Opens the video search for [code]. First asks, with their dialogs, for the
/// vehicle and the API keys if they are missing.
Future<void> openVideosFor(BuildContext context, String code, String description) async {
  final vehicle = await ensureVehicle(context);
  if (vehicle == null || !context.mounted) return;
  if (!context.read<AppState>().apiKeys.complete) {
    final ok = await showApiKeysDialog(
      context,
      note: 'Para buscar videos necesitas tus llaves de Anthropic (Claude Haiku) y de '
          'YouTube. Se guardan cifradas solo en este teléfono.',
    );
    if (!ok || !context.mounted) return;
  }
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

  /// For tests; in the app it is created with the saved keys.
  final VideoFinder? finder;

  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  Future<VideoSearchResult>? _future;

  /// The user chose to search a code that is not in the local table.
  bool _searchAnyway = false;

  DtcDescriptions? get _table => context.read<AppState>().descriptions;

  /// Codes missing from the table (e.g. typed by mistake) are not sent to
  /// Haiku, so it cannot invent a repair for them. With no table loaded, any
  /// code is allowed.
  bool get _known => _table?.isKnown(widget.code) ?? true;

  List<String> get _suggestions => _table?.similar(widget.code) ?? const [];

  VideoFinder? get _finder {
    if (widget.finder != null) return widget.finder;
    final keys = context.read<AppState>().apiKeys;
    if (!keys.complete) return null;
    return VideoFinder(
      claude: ClaudeClient(apiKey: keys.anthropic),
      youtube: YoutubeClient(apiKey: keys.youtube),
    );
  }

  Future<void> _editKeys() async {
    final saved = await showApiKeysDialog(context);
    if (saved && mounted) _search(refresh: true);
  }

  @override
  void initState() {
    super.initState();
    if (_known) _search();
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

  void _searchAnywayNow() {
    setState(() => _searchAnyway = true);
    _search();
  }

  /// Replaces this screen with the search for a suggested code.
  void _pickCode(String code) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => VideosScreen(
          code: code,
          description: _table?.describe(code) ?? code,
          vehicle: widget.vehicle,
          finder: widget.finder,
        ),
      ),
    );
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
    final unknown = !_known && !_searchAnyway;
    return Scaffold(
      appBar: AppBar(
        title: Text('Videos para ${widget.code}'),
        actions: [
          if (widget.finder == null)
            IconButton(
              tooltip: 'Llaves de API',
              icon: const Icon(Icons.key),
              onPressed: _editKeys,
            ),
        ],
      ),
      body: unknown
          ? _UnknownCode(
              code: widget.code,
              suggestions: _suggestions,
              onPick: _pickCode,
              onAnother: () => askCodeAndOpen(context),
              onSearchAnyway: _finder == null ? null : _searchAnywayNow,
            )
          : _finder == null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Faltan tus llaves de Anthropic y YouTube para buscar videos.'),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _editKeys,
                        icon: const Icon(Icons.key),
                        label: const Text('Configurar llaves'),
                      ),
                    ],
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
                      suggestions: _suggestions,
                      onOpen: _open,
                      onRetry: () => _search(refresh: true),
                      onPick: _pickCode,
                      onAnother: () => askCodeAndOpen(context),
                    );
                  },
                ),
    );
  }
}

/// Shown instead of a search when the code is not in the local table.
class _UnknownCode extends StatelessWidget {
  const _UnknownCode({
    required this.code,
    required this.suggestions,
    required this.onPick,
    required this.onAnother,
    this.onSearchAnyway,
  });

  final String code;
  final List<String> suggestions;
  final ValueChanged<String> onPick;
  final VoidCallback onAnother;
  final VoidCallback? onSearchAnyway;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$code no está en la tabla de códigos.', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                const Text(
                  'Puede que lo hayas escrito mal. Sin el código en la tabla no buscamos '
                  'videos, para no inventar una reparación.',
                ),
              ],
            ),
          ),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Quizá quisiste decir:', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _CodeChips(codes: suggestions, onPick: onPick),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onAnother,
          icon: const Icon(Icons.manage_search),
          label: const Text('Buscar otro código'),
        ),
        if (onSearchAnyway != null)
          TextButton(
            onPressed: onSearchAnyway,
            child: const Text('Buscar videos de todos modos'),
          ),
      ],
    );
  }
}

/// Tappable codes, used for "did you mean" suggestions.
class _CodeChips extends StatelessWidget {
  const _CodeChips({required this.codes, required this.onPick});

  final List<String> codes;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in codes)
            ActionChip(
              key: Key('suggest-$c'),
              label: Text(c),
              onPressed: () => onPick(c),
            ),
        ],
      );
}

class _Results extends StatelessWidget {
  const _Results({
    required this.code,
    required this.description,
    required this.vehicle,
    required this.result,
    required this.suggestions,
    required this.onOpen,
    required this.onRetry,
    required this.onPick,
    required this.onAnother,
  });

  final String code;
  final String description;
  final String vehicle;
  final VideoSearchResult result;
  final List<String> suggestions;
  final void Function(YoutubeVideo) onOpen;
  final VoidCallback onRetry;
  final ValueChanged<String> onPick;
  final VoidCallback onAnother;

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
                const SizedBox(height: 8),
                TextButton(onPressed: onAnother, child: const Text('Buscar otro código')),
                if (suggestions.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Códigos parecidos:', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  _CodeChips(codes: suggestions, onPick: onPick),
                ],
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
