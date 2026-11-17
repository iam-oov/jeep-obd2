import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'videos_screen.dart';

import 'log_screen.dart';

class LogButton extends StatelessWidget {
  const LogButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Log de comandos',
        icon: const Icon(Icons.terminal),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const LogScreen()),
        ),
      );
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Icon(Icons.error_outline, color: scheme.onErrorContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, color: scheme.onErrorContainer),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class ProgressCard extends StatelessWidget {
  const ProgressCard({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      );
}

/// Formats a date and time as "dd/mm/aaaa HH:mm" (24 h), e.g. "05/03/2026 09:07".
String formatDateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Enter a code by hand (e.g. read with another scanner) and search videos.
final _manualCodePattern = RegExp(r'^[PCBU][0-3][0-9A-F]{3}$');

/// Asks for a code by hand and opens its video search.
Future<void> askCodeAndOpen(BuildContext context) async {
  final controller = TextEditingController();
  final code = await showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() {
        final c = controller.text.trim().toUpperCase();
        if (_manualCodePattern.hasMatch(c)) Navigator.pop(ctx, c);
      }

      return AlertDialog(
        title: const Text('Buscar un código'),
        content: TextField(
          key: const Key('manual-code'),
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(hintText: 'P1282', helperText: 'Letra + 4 dígitos'),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: submit, child: const Text('Buscar videos')),
        ],
      );
    },
  );
  if (code == null || !context.mounted) return;
  final desc = context.read<AppState>().descriptions?.describe(code) ?? code;
  await openVideosFor(context, code, desc);
}

class ManualCodeButton extends StatelessWidget {
  const ManualCodeButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Buscar un código a mano',
        icon: const Icon(Icons.manage_search),
        onPressed: () => askCodeAndOpen(context),
      );
}
