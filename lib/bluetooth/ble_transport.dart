import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'elm_connection.dart';

/// Par de características (notificar = respuestas, escribir = comandos).
class _UartPair {
  _UartPair(this.notify, this.write);

  final BluetoothCharacteristic notify;
  final BluetoothCharacteristic write;
}

/// [ElmTransport] sobre Bluetooth LE (GATT), para los ELM327 "BLE" que no se
/// emparejan desde Ajustes y solo aparecen al buscarlos desde una app.
///
/// Estos adaptadores exponen un "UART" sobre GATT: una característica con
/// notificaciones por donde llegan las respuestas y otra donde se escriben
/// los comandos. Las respuestas llegan partidas en varias notificaciones;
/// [ElmConnection] ya junta todo hasta el prompt `>`.
class BleElmTransport implements ElmTransport {
  BleElmTransport._(this._device, this._pair);

  final BluetoothDevice _device;
  final _UartPair _pair;
  final _input = StreamController<List<int>>();
  final _subs = <StreamSubscription<dynamic>>[];

  /// Pares conocidos (servicio, notificar, escribir) de los clones comunes.
  static final _knownPairs = [
    (Guid('FFE0'), Guid('FFE1'), Guid('FFE1')), // la mayoría de clones "ELM327 BLE"
    (Guid('FFF0'), Guid('FFF1'), Guid('FFF2')), // otros clones
    (Guid('18F0'), Guid('2AF0'), Guid('2AF1')), // Vgate iCar Pro BLE
    (
      Guid('E7810A71-73AE-499D-8C15-FAA9AEF0C3F2'), // OBDLink / Vgate CX
      Guid('BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F'),
      Guid('BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F'),
    ),
  ];

  /// Servicios estándar que nunca son el UART.
  static final _standardServices = {Guid('1800'), Guid('1801'), Guid('180A'), Guid('180F')};

  static Future<BleElmTransport> connect(
    BluetoothDevice device, {
    void Function(LogEntry)? onLog,
  }) async {
    void info(String t) => onLog?.call(LogEntry(LogKind.info, t));

    try {
      await device.connect(
        // Proyecto personal: licencia sin fines de lucro de FlutterBluePlus.
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      throw ElmException(
        'No se pudo conectar por Bluetooth LE. Cierra cualquier otra app OBD '
        '(por ejemplo OBDocker): el adaptador acepta una sola conexión a la vez. '
        'Revisa también que esté conectado al puerto y con la luz encendida.\n'
        'Detalle: $e',
      );
    }

    try {
      final services = await device.discoverServices();
      for (final s in services) {
        final chars = s.characteristics.map((c) => _describe(c)).join(', ');
        info('Servicio ${s.uuid.str}: $chars');
      }
      final pair = _findPair(services);
      if (pair == null) {
        throw ElmException(
          'El dispositivo no expone un canal serie BLE reconocible. '
          '¿Seguro que es el adaptador OBD? Revisa el log para ver sus servicios.',
        );
      }
      info('Usando notificar=${pair.notify.uuid.str} escribir=${pair.write.uuid.str}');

      final transport = BleElmTransport._(device, pair);
      await transport._start();
      return transport;
    } catch (e) {
      await device.disconnect();
      if (e is ElmException) rethrow;
      throw ElmException('Falló la configuración del adaptador BLE: $e');
    }
  }

  static String _describe(BluetoothCharacteristic c) {
    final p = c.properties;
    final flags = [
      if (p.notify) 'N',
      if (p.indicate) 'I',
      if (p.write) 'W',
      if (p.writeWithoutResponse) 'w',
      if (p.read) 'R',
    ].join();
    return '${c.uuid.str}[$flags]';
  }

  static _UartPair? _findPair(List<BluetoothService> services) {
    BluetoothCharacteristic? find(BluetoothService s, Guid id) =>
        s.characteristics.where((c) => c.uuid == id).firstOrNull;

    // 1) UUIDs conocidos.
    for (final (svc, n, w) in _knownPairs) {
      final service = services.where((s) => s.uuid == svc).firstOrNull;
      if (service == null) continue;
      final notify = find(service, n);
      final write = find(service, w);
      if (notify != null && write != null) return _UartPair(notify, write);
    }

    // 2) Cualquier servicio no estándar con una característica que notifique
    //    y otra (o la misma) donde se pueda escribir.
    for (final s in services.where((s) => !_standardServices.contains(s.uuid))) {
      final notify = s.characteristics
          .where((c) => c.properties.notify || c.properties.indicate)
          .firstOrNull;
      final write = s.characteristics
          .where((c) => c.properties.write || c.properties.writeWithoutResponse)
          .firstOrNull;
      if (notify != null && write != null) return _UartPair(notify, write);
    }
    return null;
  }

  Future<void> _start() async {
    _subs.add(_pair.notify.onValueReceived.listen((value) {
      if (!_input.isClosed) _input.add(value);
    }));
    _device.cancelWhenDisconnected(_subs.last);
    await _pair.notify.setNotifyValue(true);

    _subs.add(_device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && !_input.isClosed) {
        _input.close();
      }
    }));
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(List<int> bytes) async {
    final c = _pair.write;
    final noResponse = c.properties.writeWithoutResponse && !c.properties.write;
    // Partir según el MTU negociado (3 bytes son de cabecera ATT).
    final chunk = (_device.mtuNow - 3).clamp(20, 512);
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = (i + chunk).clamp(0, bytes.length);
      await c.write(bytes.sublist(i, end), withoutResponse: noResponse);
    }
  }

  @override
  Future<void> close() async {
    for (final s in _subs) {
      await s.cancel();
    }
    if (!_input.isClosed) await _input.close();
    await _device.disconnect();
  }
}
