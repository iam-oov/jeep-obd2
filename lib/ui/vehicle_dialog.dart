import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../vehicle/catalog.dart';
import '../vehicle/vehicle.dart';
import 'option_picker.dart';

/// Catálogo compartido (cachea los modelos ya consultados).
VehicleCatalog vehicleCatalog = VehicleCatalog();

/// Modal para capturar o corregir el vehículo. [initial] lo prellena (p. ej.
/// con lo que devolvió el VIN). Devuelve null si se cancela.
Future<Vehicle?> showVehicleDialog(
  BuildContext context, {
  Vehicle? initial,
  String? note,
}) =>
    showDialog<Vehicle>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VehicleDialog(initial: initial, note: note, catalog: vehicleCatalog),
    );

/// Devuelve el vehículo activo. Si no hay, pide elegir uno de los guardados
/// o agregar uno nuevo. null si el usuario cancela.
Future<Vehicle?> ensureVehicle(BuildContext context) async {
  final state = context.read<AppState>();
  if (state.vehicle != null) return state.vehicle;
  if (state.vehicles.isNotEmpty) {
    return showGarageSheet(context, title: '¿Qué vehículo estás diagnosticando?');
  }
  return _addVehicle(context, note: 'Para buscar videos de tu vehículo necesito saber cuál es.');
}

/// Después de conectar: el VIN reconocido ya lo activó AppState; si no, se
/// pregunta cuál es (agregar o elegir) según lo que haya guardado.
Future<void> chooseVehicleAfterConnect(BuildContext context) async {
  final state = context.read<AppState>();
  if (state.vinMatch != null) return;
  if (state.suggestedVehicle != null) {
    await _addVehicle(
      context,
      initial: state.suggestedVehicle,
      note: 'El vehículo entregó su VIN. Confirma los datos para guardarlo.',
    );
  } else if (state.vehicles.isEmpty) {
    await _addVehicle(
      context,
      note: state.vin != null
          ? 'El vehículo entregó su VIN pero no se pudo decodificar. ¿Cuál es?'
          : 'Este vehículo no entrega su VIN por OBD2. ¿Cuál es?',
    );
  } else if (state.vehicles.length > 1) {
    await showGarageSheet(context, title: '¿Qué vehículo estás diagnosticando?');
  }
}

Future<Vehicle?> _addVehicle(BuildContext context, {Vehicle? initial, String? note}) async {
  final state = context.read<AppState>();
  final v = await showVehicleDialog(context, initial: initial, note: note);
  if (v == null) return null;
  return state.addVehicle(v);
}

/// Panel "Mis vehículos": elegir el activo, agregar, editar y borrar.
/// Devuelve el vehículo elegido (o null si se cierra sin elegir).
Future<Vehicle?> showGarageSheet(BuildContext context, {String title = 'Mis vehículos'}) =>
    showModalBottomSheet<Vehicle>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _GarageSheet(title: title),
    );

class _GarageSheet extends StatelessWidget {
  const _GarageSheet({required this.title});

  final String title;

  Future<void> _confirmDelete(BuildContext context, Vehicle v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Borrar vehículo?'),
        content: Text(v.description),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok == true && context.mounted) await context.read<AppState>().deleteVehicle(v.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final active = state.vehicle;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            if (state.vehicles.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text('Todavía no has agregado vehículos.'),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final v in state.vehicles)
                    ListTile(
                      leading: Icon(
                        v.id == active?.id ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: v.id == active?.id ? theme.colorScheme.primary : null,
                      ),
                      title: Text(v.shortName),
                      subtitle: Text([
                        if (v.engine != null) v.engine!,
                        if (v.vin != null) 'VIN ${v.vin}',
                      ].join(' · ')),
                      onTap: () async {
                        await state.selectVehicle(v.id);
                        if (context.mounted) Navigator.pop(context, state.vehicle);
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Editar',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              final edited = await showVehicleDialog(context, initial: v);
                              if (edited != null) await state.updateVehicle(edited);
                            },
                          ),
                          IconButton(
                            tooltip: 'Borrar',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _confirmDelete(context, v),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Agregar vehículo'),
                onPressed: () async {
                  final added = await _addVehicle(
                    context,
                    initial: state.vinMatch == null ? state.suggestedVehicle : null,
                  );
                  if (added != null && context.mounted) Navigator.pop(context, added);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VehicleDialog extends StatefulWidget {
  const _VehicleDialog({this.initial, this.note, required this.catalog});

  final Vehicle? initial;
  final String? note;
  final VehicleCatalog catalog;

  @override
  State<_VehicleDialog> createState() => _VehicleDialogState();
}

class _VehicleDialogState extends State<_VehicleDialog> {
  late int? _year = widget.initial?.year;
  late String _make = widget.initial?.make ?? '';
  late String _model = widget.initial?.model ?? '';
  late double? _liters = widget.initial?.liters;
  late int? _cylinders = widget.initial?.cylinders;

  List<String> _models = const [];
  bool _loadingModels = false;
  String? _makeError;
  String? _modelError;
  int _request = 0;

  static final _years = [for (var y = DateTime.now().year + 1; y >= 1981; y--) '$y'];

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  /// Trae los modelos de la marca (y año, si hay) elegidos ahora.
  Future<void> _loadModels() async {
    final req = ++_request;
    if (_make.trim().isEmpty) {
      setState(() => _models = const []);
      return;
    }
    setState(() => _loadingModels = true);
    final list = await widget.catalog.models(_make, year: _year);
    if (!mounted || req != _request) return;
    setState(() {
      _models = list;
      _loadingModels = false;
    });
  }

  Future<void> _pickYear() async {
    final v = await showOptionPicker(
      context,
      title: 'Año',
      options: _years,
      current: _year?.toString(),
      allowCustom: false,
      yearMode: true,
      clearLabel: 'No sé / no aplica',
      keyboardType: TextInputType.number,
      note: 'Escribe "98" para 1998',
    );
    if (v == null) return;
    setState(() => _year = int.tryParse(v));
    _loadModels();
  }

  Future<void> _pickMake() async {
    final v = await showOptionPicker(context, title: 'Marca', options: commonMakes, current: _make);
    if (v == null || v.isEmpty) return;
    setState(() {
      if (v != _make) _model = '';
      _make = v;
      _makeError = null;
    });
    _loadModels();
  }

  Future<void> _pickModel() async {
    final v = await showOptionPicker(
      context,
      title: 'Modelo',
      options: _models,
      current: _model,
      note: _models.isEmpty ? 'Sin lista para esta marca/año: escríbelo' : null,
    );
    if (v == null || v.isEmpty) return;
    setState(() {
      _model = v;
      _modelError = null;
    });
  }

  Future<void> _pickLiters() async {
    final v = await showOptionPicker(
      context,
      title: 'Motor (litros)',
      options: [for (final l in commonLiters) l.toStringAsFixed(1)],
      current: _liters?.toStringAsFixed(1),
      clearLabel: 'No sé',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      note: 'Ej. 1.6 o 4.0',
    );
    if (v == null) return;
    if (v.isNotEmpty && parseLiters(v) == null) {
      _snack('"$v" no parece una cilindrada (ej. 1.6)');
      return;
    }
    setState(() => _liters = v.isEmpty ? null : parseLiters(v));
  }

  Future<void> _pickCylinders() async {
    final v = await showOptionPicker(
      context,
      title: 'Cilindros',
      options: [for (final c in commonCylinders) '$c'],
      current: _cylinders?.toString(),
      clearLabel: 'No sé',
      keyboardType: TextInputType.number,
    );
    if (v == null) return;
    final c = int.tryParse(v);
    if (v.isNotEmpty && (c == null || c < 1 || c > 16)) {
      _snack('"$v" no es un número de cilindros válido');
      return;
    }
    setState(() => _cylinders = v.isEmpty ? null : c);
  }

  void _snack(String msg) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

  void _save() {
    setState(() {
      _makeError = _make.trim().isEmpty ? 'Elige la marca' : null;
      _modelError = _model.trim().isEmpty ? 'Elige o escribe el modelo' : null;
    });
    if (_makeError != null || _modelError != null) return;
    Navigator.pop(
      context,
      Vehicle(
        id: widget.initial?.id ?? '',
        make: _make.trim(),
        model: _model.trim(),
        year: _year,
        liters: _liters,
        cylinders: _cylinders,
        vin: widget.initial?.vin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vin = widget.initial?.vin;
    final theme = Theme.of(context);
    const gap = SizedBox(height: 12);

    return AlertDialog(
      title: const Text('Tu vehículo'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.note != null) ...[Text(widget.note!), const SizedBox(height: 8)],
          if (vin != null) ...[
            Text('Prellenado con el VIN $vin. Corrige lo que haga falta.',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
          PickerField(
            key: const Key('vehicle-year'),
            label: 'Año',
            value: _year?.toString(),
            hint: 'Opcional',
            onTap: _pickYear,
          ),
          gap,
          PickerField(
            key: const Key('vehicle-make'),
            label: 'Marca',
            value: _make,
            errorText: _makeError,
            onTap: _pickMake,
          ),
          gap,
          PickerField(
            key: const Key('vehicle-model'),
            label: 'Modelo',
            value: _model,
            hint: _make.isEmpty ? 'Primero elige la marca' : null,
            helperText: _loadingModels ? 'Cargando modelos…' : null,
            errorText: _modelError,
            onTap: _pickModel,
          ),
          gap,
          PickerField(
            key: const Key('vehicle-liters'),
            label: 'Motor (litros)',
            value: _liters == null ? null : '${_liters!.toStringAsFixed(1)} L',
            hint: 'Opcional',
            onTap: _pickLiters,
          ),
          gap,
          PickerField(
            key: const Key('vehicle-cylinders'),
            label: 'Cilindros',
            value: _cylinders?.toString(),
            hint: 'Opcional',
            onTap: _pickCylinders,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _save, child: const Text('Guardar')),
      ],
    );
  }
}
