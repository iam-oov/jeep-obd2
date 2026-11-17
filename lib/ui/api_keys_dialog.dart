import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../solutions/api_keys.dart';

/// Comprobador compartido (se reemplaza en pruebas).
ApiKeyChecker apiKeyChecker = ApiKeyChecker();

/// Modal para capturar las llaves de Anthropic y YouTube. Las prueba antes
/// de guardarlas. Devuelve true si se guardaron.
Future<bool> showApiKeysDialog(BuildContext context, {String? note}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ApiKeysDialog(note: note),
  );
  return saved ?? false;
}

class _ApiKeysDialog extends StatefulWidget {
  const _ApiKeysDialog({this.note});

  final String? note;

  @override
  State<_ApiKeysDialog> createState() => _ApiKeysDialogState();
}

class _ApiKeysDialogState extends State<_ApiKeysDialog> {
  late final ApiKeys _current = context.read<AppState>().apiKeys;
  late final _anthropic = TextEditingController(text: _current.anthropic);
  late final _youtube = TextEditingController(text: _current.youtube);
  bool _showAnthropic = false;
  bool _showYoutube = false;
  bool _checking = false;
  String? _anthropicError;
  String? _youtubeError;
  String? _warning;

  @override
  void dispose() {
    _anthropic.dispose();
    _youtube.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = _anthropic.text.trim();
    final y = _youtube.text.trim();
    setState(() {
      _anthropicError = a.isEmpty ? 'Pega tu llave de Anthropic' : null;
      _youtubeError = y.isEmpty ? 'Pega tu llave de YouTube' : null;
      _warning = null;
    });
    if (a.isEmpty || y.isEmpty) return;

    setState(() => _checking = true);
    final results = await Future.wait([apiKeyChecker.anthropic(a), apiKeyChecker.youtube(y)]);
    if (!mounted) return;
    final (ra, ry) = (results[0], results[1]);
    setState(() {
      _checking = false;
      _anthropicError = ra == KeyCheck.invalid ? 'Anthropic rechazó esta llave' : null;
      _youtubeError = ry == KeyCheck.invalid
          ? 'Google rechazó esta llave (¿habilitaste YouTube Data API v3?)'
          : null;
    });
    if (ra == KeyCheck.invalid || ry == KeyCheck.invalid) return;

    final state = context.read<AppState>();
    await state.saveApiKeys(ApiKeys(anthropic: a, youtube: y));
    if (!mounted) return;
    if (ra == KeyCheck.unreachable || ry == KeyCheck.unreachable) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Llaves guardadas sin probar: no hubo conexión.')),
      );
    }
    Navigator.pop(context, true);
  }

  Future<void> _clear() async {
    await context.read<AppState>().clearApiKeys();
    if (!mounted) return;
    final keys = context.read<AppState>().apiKeys;
    setState(() {
      _anthropic.text = keys.anthropic;
      _youtube.text = keys.youtube;
      _warning = 'Llaves borradas de este teléfono.';
    });
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    required String helper,
    required String? error,
    required bool visible,
    required VoidCallback onToggle,
  }) =>
      TextField(
        key: key,
        controller: controller,
        obscureText: !visible,
        autocorrect: false,
        enableSuggestions: false,
        enabled: !_checking,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          errorText: error,
          errorMaxLines: 2,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: visible ? 'Ocultar' : 'Mostrar',
            icon: Icon(visible ? Icons.visibility_off : Icons.visibility),
            onPressed: onToggle,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSaved = _current.complete;

    return AlertDialog(
      title: const Text('Llaves de API'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.note ??
                'La búsqueda de videos usa tu cuenta de Anthropic (Claude Haiku) y tu llave de '
                    'YouTube. Se guardan cifradas solo en este teléfono.',
          ),
          const SizedBox(height: 16),
          _field(
            key: const Key('key-anthropic'),
            controller: _anthropic,
            label: 'Llave de Anthropic',
            helper: 'console.anthropic.com → API Keys (empieza con sk-ant-)',
            error: _anthropicError,
            visible: _showAnthropic,
            onToggle: () => setState(() => _showAnthropic = !_showAnthropic),
          ),
          const SizedBox(height: 12),
          _field(
            key: const Key('key-youtube'),
            controller: _youtube,
            label: 'Llave de YouTube',
            helper: 'Google Cloud → habilita YouTube Data API v3 → Credenciales → API key',
            error: _youtubeError,
            visible: _showYoutube,
            onToggle: () => setState(() => _showYoutube = !_showYoutube),
          ),
          if (_checking) ...[
            const SizedBox(height: 16),
            const Row(
              children: [
                SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Text('Probando las llaves…'),
              ],
            ),
          ],
          if (_warning != null) ...[
            const SizedBox(height: 12),
            Text(_warning!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
      actions: [
        if (hasSaved)
          TextButton(
            onPressed: _checking ? null : _clear,
            child: Text('Borrar', style: TextStyle(color: theme.colorScheme.error)),
          ),
        TextButton(
          onPressed: _checking ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _checking ? null : _save, child: const Text('Guardar')),
      ],
    );
  }
}
