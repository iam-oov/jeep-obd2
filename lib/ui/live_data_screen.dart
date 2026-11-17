import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../bluetooth/elm_connection.dart';
import '../obd/live_data.dart';
import '../obd/obd_service.dart';
import 'widgets.dart';

class LiveDataScreen extends StatefulWidget {
  const LiveDataScreen({super.key, this.obd});

  /// Para pruebas; en la app se toma la conexión activa de [AppState].
  final ObdService? obd;

  @override
  State<LiveDataScreen> createState() => _LiveDataScreenState();
}

class _LiveDataScreenState extends State<LiveDataScreen> {
  LiveDataPoller? _poller;
  bool _discovering = true;
  bool _paused = false;
  bool _stopped = false;
  String? _error;
  Duration? _cycle;

  @override
  void initState() {
    super.initState();
    final obd = widget.obd ?? context.read<AppState>().obd;
    if (obd == null) {
      _discovering = false;
      _error = 'No hay conexión con el adaptador.';
      return;
    }
    _poller = LiveDataPoller(obd);
    unawaited(_run());
  }

  @override
  void dispose() {
    _stopped = true;
    super.dispose();
  }

  Future<void> _run() async {
    final poller = _poller!;
    try {
      await poller.discover();
      if (!mounted) return;
      setState(() => _discovering = false);

      var failures = 0;
      while (mounted && !_stopped) {
        if (_paused) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        final sw = Stopwatch()..start();
        final ok = await poller.pollOnce();
        if (!mounted || _stopped) return;
        failures = ok == 0 ? failures + 1 : 0;
        setState(() {
          _cycle = sw.elapsed;
          if (failures >= 3) {
            _paused = true;
            _error = 'El vehículo dejó de responder. Revisa que el switch siga en ON y reanuda.';
          }
        });
        // Respiro para no saturar el bus (ISO 9141-2 es lento).
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } on ElmDisconnectedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ElmException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final poller = _poller;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lecturas en vivo'),
        actions: [
          if (poller != null && !_discovering)
            IconButton(
              tooltip: _paused ? 'Reanudar' : 'Pausar',
              icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              onPressed: () => setState(() {
                _paused = !_paused;
                if (!_paused) _error = null;
              }),
            ),
          const LogButton(),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_error != null)
            ErrorBanner(message: _error!, onClose: () => setState(() => _error = null)),
          if (_discovering)
            const ProgressCard(text: 'Preguntando al vehículo qué lecturas soporta…'),
          if (poller != null && !_discovering) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                _paused
                    ? 'En pausa'
                    : _cycle == null
                        ? 'Leyendo…'
                        : 'Actualiza cada ${(_cycle!.inMilliseconds / 1000).toStringAsFixed(1)} s'
                            '${poller.engineRunning ? ' · motor encendido' : ' · motor apagado'}',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                children: [
                  for (final p in poller.active)
                    FractionallySizedBox(
                      widthFactor: 0.5,
                      child: _ParamCard(param: p, value: poller.values[p.key], level: poller.levelOf(p)),
                    ),
                ],
              ),
            ),
            const _InfoCard(
              icon: Icons.oil_barrel_outlined,
              text: 'Presión de aceite: no existe en OBD2 genérico. Si "CHECK GAUGES" '
                  'coincide con la aguja de aceite en cero, revisa el sensor de presión '
                  'de aceite o mide la presión con un manómetro.',
            ),
            const _InfoCard(
              icon: Icons.battery_charging_full,
              text: 'Voltaje con motor encendido: 13.2–14.8 V es normal. Menos indica '
                  'alternador o regulador; más, sobrecarga. Con motor apagado, una '
                  'batería sana marca 12.4–12.7 V.',
            ),
            if (poller.unsupported.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Tu vehículo no reporta: ${poller.unsupported.map((p) => p.name).join(', ')}.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ParamCard extends StatelessWidget {
  const _ParamCard({required this.param, required this.value, required this.level});

  final LiveParam param;
  final LiveValue? value;
  final Level? level;

  String _fmt(double v) => v.toStringAsFixed(param.decimals);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (level) {
      Level.danger => theme.colorScheme.error,
      Level.warn => Colors.orange,
      Level.ok => Colors.green,
      null => theme.colorScheme.outlineVariant,
    };
    final v = value;
    return Card(
      margin: const EdgeInsets.all(4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color, width: level == null ? 1 : 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(param.name, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  v == null ? '—' : _fmt(v.value),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: level == null || level == Level.ok ? null : color,
                  ),
                ),
                const SizedBox(width: 4),
                Text(param.unit, style: theme.textTheme.bodyMedium),
              ],
            ),
            Text(
              v == null ? 'sin dato' : 'mín ${_fmt(v.min)} · máx ${_fmt(v.max)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: ListTile(leading: Icon(icon), title: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
      );
}
