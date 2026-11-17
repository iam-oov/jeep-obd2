import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../data/dtc_descriptions.dart';
import '../obd/obd_service.dart';
import 'live_data_screen.dart';
import 'vehicle_dialog.dart';
import 'videos_screen.dart';
import 'widgets.dart';

class DiagnosisScreen extends StatelessWidget {
  const DiagnosisScreen({super.key});

  Future<void> _confirmClear(BuildContext context) async {
    final state = context.read<AppState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar códigos?'),
        content: const Text(
          'Se borran los códigos almacenados y se apaga el check engine. '
          'También se reinician los monitores de emisiones, así que el carro no '
          'pasará verificación hasta que vuelvan a completarse (varios días de manejo).\n\n'
          'Si la falla sigue, el código volverá a aparecer.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await state.clearCodes();
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Códigos borrados')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ready = state.status == ConnectionStatus.ready;
    final canAct = ready && !state.busy;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnóstico'),
        actions: const [LogButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _ConnectionCard(state: state),
          if (state.error != null)
            ErrorBanner(message: state.error!, onClose: state.clearError),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canAct ? state.readCodes : null,
                    icon: const Icon(Icons.search),
                    label: const Text('Leer códigos'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('clear-codes'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: canAct
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).disabledColor,
                      ),
                    ),
                    onPressed: canAct ? () => _confirmClear(context) : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Borrar códigos'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: canAct
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const LiveDataScreen()),
                      )
                  : null,
              icon: const Icon(Icons.speed),
              label: const Text('Lecturas en vivo (temperatura, voltaje…)'),
            ),
          ),
          if (state.busy) const ProgressCard(text: 'Consultando la computadora del carro…'),
          if (state.stored != null) ...[
            _CodeSection(
              title: 'Almacenados (modo 03)',
              result: state.stored!,
              descriptions: state.descriptions,
              emptyText: 'Sin códigos almacenados. El check engine no debería estar encendido.',
            ),
            if (state.stored!.codes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: FilledButton.tonalIcon(
                  key: const Key('clear-codes-below'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  onPressed: canAct ? () => _confirmClear(context) : null,
                  icon: const Icon(Icons.delete_sweep),
                  label: Text(
                    'Borrar ${state.stored!.codes.length == 1 ? 'este código' : 'estos ${state.stored!.codes.length} códigos'} y apagar el check engine',
                  ),
                ),
              ),
            if (state.pending != null)
              _CodeSection(
                title: 'Pendientes (modo 07)',
                result: state.pending!,
                descriptions: state.descriptions,
                emptyText: 'Sin códigos pendientes.',
                unsupportedText:
                    'La computadora no reporta códigos pendientes (común en modelos 1998).',
              ),
            if (state.lastRead != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Última lectura: ${TimeOfDay.fromDateTime(state.lastRead!).format(context)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ] else if (ready && !state.busy)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Toca "Leer códigos" para consultar la computadora.',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ready = state.status == ConnectionStatus.ready;
    final name = state.device?.displayName ?? 'Adaptador';
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: ListTile(
        leading: Icon(
          ready ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: ready ? Colors.green : Theme.of(context).colorScheme.error,
        ),
        title: Text(name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ready
                  ? [state.adapterVersion, state.protocolName].whereType<String>().join(' · ')
                  : 'Desconectado',
            ),
            InkWell(
              onTap: () => showGarageSheet(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.directions_car, size: 16),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        state.vehicle?.shortName ?? 'Agregar vehículo',
                        style: TextStyle(color: Theme.of(context).colorScheme.primary),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.swap_horiz, size: 16, color: Theme.of(context).colorScheme.primary),
                  ],
                ),
              ),
            ),
          ],
        ),
        trailing: ready
            ? TextButton(onPressed: state.disconnect, child: const Text('Desconectar'))
            : TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Reconectar'),
              ),
      ),
    );
  }
}

class _CodeSection extends StatelessWidget {
  const _CodeSection({
    required this.title,
    required this.result,
    required this.descriptions,
    required this.emptyText,
    this.unsupportedText,
  });

  final String title;
  final CodeReadResult result;
  final DtcDescriptions? descriptions;
  final String emptyText;
  final String? unsupportedText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '$title${result.codes.isEmpty ? '' : ' · ${result.codes.length}'}',
            style: theme.textTheme.titleMedium,
          ),
        ),
        if (result.codes.isEmpty)
          ListTile(
            leading: Icon(
              result.supported ? Icons.check_circle_outline : Icons.info_outline,
              color: result.supported ? Colors.green : null,
            ),
            title: Text(
              result.supported ? emptyText : (unsupportedText ?? 'No soportado.'),
            ),
          )
        else
          for (final code in result.codes)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: ListTile(
                leading: Text(
                  code,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.error,
                  ),
                ),
                title: Text(descriptions?.describe(code) ?? 'Cargando descripción…'),
                trailing: const Icon(Icons.ondemand_video),
                onTap: () => openVideosFor(context, code, descriptions?.describe(code) ?? code),
              ),
            ),
      ],
    );
  }
}
