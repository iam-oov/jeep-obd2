import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../bluetooth/elm_connection.dart';

class LogScreen extends StatelessWidget {
  const LogScreen({super.key});

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 10).toString().padLeft(2, '0')}';

  static String _arrow(LogKind k) => switch (k) {
        LogKind.sent => '>>',
        LogKind.received => '<<',
        LogKind.info => '--',
        LogKind.error => '!!',
      };

  static String asText(List<LogEntry> log) =>
      log.map((e) => '${_time(e.time)} ${_arrow(e.kind)} ${e.text}').join('\n');

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final log = state.log;
    final scheme = Theme.of(context).colorScheme;

    Color colorFor(LogKind k) => switch (k) {
          LogKind.sent => scheme.primary,
          LogKind.received => scheme.onSurface,
          LogKind.info => scheme.outline,
          LogKind.error => scheme.error,
        };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Log'),
        actions: [
          IconButton(
            tooltip: 'Copiar',
            icon: const Icon(Icons.copy),
            onPressed: log.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: asText(log)));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Log copiado')),
                      );
                    }
                  },
          ),
          IconButton(
            tooltip: 'Limpiar',
            icon: const Icon(Icons.delete_sweep),
            onPressed: log.isEmpty ? null : state.clearLog,
          ),
        ],
      ),
      body: log.isEmpty
          ? const Center(child: Text('Sin actividad todavía.'))
          : ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: log.length,
              itemBuilder: (context, i) {
                final e = log[log.length - 1 - i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SelectableText(
                    '${_time(e.time)} ${_arrow(e.kind)} ${e.text}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: colorFor(e.kind),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
