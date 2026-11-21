import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'api_keys_dialog.dart';
import 'diagnosis_screen.dart';
import 'log_screen.dart';
import 'vehicle_dialog.dart';
import 'widgets.dart';

/// App version shown at the bottom of the devices screen.
/// Keep in sync with the `version` field of pubspec.yaml.
const String appVersion = '1.0.0';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final state = context.read<AppState>();
    await state.loadBondedDevices();
    await state.scanNearby();
  }

  Future<void> _connect(ObdDevice device) async {
    final state = context.read<AppState>();
    // Already connected to this same adapter: do not reopen the socket (clones
    // usually reject an immediate reconnection).
    final alreadyReady = state.status == ConnectionStatus.ready &&
        state.device?.address == device.address;
    final ok = alreadyReady || await state.connect(device);
    if (ok && mounted && !alreadyReady) await chooseVehicleAfterConnect(context);
    if (ok && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const DiagnosisScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connecting = state.status == ConnectionStatus.connecting ||
        state.status == ConnectionStatus.initializing;
    final theme = Theme.of(context);

    Widget header(String text, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
          child: Row(
            children: [
              Expanded(child: Text(text, style: theme.textTheme.titleSmall)),
              ?trailing,
            ],
          ),
        );

    Widget tile(ObdDevice d) => ListTile(
          enabled: !connecting,
          leading: Icon(d.looksLikeObd ? Icons.car_repair : Icons.bluetooth),
          title: Text(d.displayName),
          subtitle: Text([
            d.address,
            if (d.kind == DeviceKind.ble) 'BLE',
            if (d.rssi != null) '${d.rssi} dBm',
          ].join(' · ')),
          trailing: state.device?.address == d.address && state.status == ConnectionStatus.ready
              ? const Icon(Icons.check_circle, color: Colors.green)
              : const Icon(Icons.chevron_right),
          onTap: () => _connect(d),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Elegir adaptador'),
        actions: [
          IconButton(
            tooltip: 'Mis vehículos',
            icon: const Icon(Icons.garage_outlined),
            onPressed: () => showGarageSheet(context),
          ),
          const ManualCodeButton(),
          PopupMenuButton<String>(
            key: const Key('more-menu'),
            tooltip: 'Más opciones',
            onSelected: (v) {
              if (v == 'keys') {
                showApiKeysDialog(context);
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LogScreen()),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'keys',
                child: ListTile(leading: Icon(Icons.key), title: Text('Llaves de API')),
              ),
              PopupMenuItem(
                value: 'log',
                child: ListTile(leading: Icon(Icons.terminal), title: Text('Log de comandos')),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                'Conecta el adaptador al puerto OBD2 bajo el tablero y pon el switch en ON. '
                'Cierra otras apps OBD: el adaptador acepta una sola conexión.',
              ),
            ),
            if (state.error != null)
              ErrorBanner(message: state.error!, onClose: state.clearError),
            if (state.status == ConnectionStatus.disconnected) const NoConnectionCard(),
            if (connecting)
              ProgressCard(
                text: state.status == ConnectionStatus.connecting
                    ? 'Conectando por Bluetooth…'
                    : 'Inicializando el ELM327 (ISO 9141-2 puede tardar ~10 s)…',
              ),

            // --- BLE ---
            header(
              'Cercanos (no hace falta emparejar)',
              trailing: state.scanning
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: 'Buscar de nuevo',
                      icon: const Icon(Icons.radar),
                      onPressed: connecting ? null : () => state.scanNearby(userAsked: true),
                    ),
            ),
            if (state.nearby.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  state.scanning
                      ? 'Buscando… (~12 s)'
                      : 'No se encontró ninguno. Revisa que la luz del adaptador esté '
                          'encendida y toca el radar para buscar otra vez.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (final d in state.nearby) tile(d),

            // --- Classic ---
            header('Emparejados en este teléfono'),
            if (state.loadingDevices)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No hay dispositivos emparejados.', style: theme.textTheme.bodySmall),
              )
            else
              for (final d in state.devices) tile(d),

            // --- App version ---
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              child: Text(
                'Versión $appVersion',
                key: const Key('app-version'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
