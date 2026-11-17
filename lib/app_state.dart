import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart' as classic;
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:permission_handler/permission_handler.dart';

import 'bluetooth/ble_transport.dart';
import 'bluetooth/bluetooth_transport.dart';
import 'bluetooth/elm_connection.dart';
import 'data/dtc_descriptions.dart';
import 'obd/obd_service.dart';
import 'vehicle/vehicle.dart';

enum ConnectionStatus { disconnected, connecting, initializing, ready }

enum DeviceKind { classic, ble }

/// Un adaptador candidato: emparejado por Bluetooth Classic o encontrado
/// en un escaneo BLE.
class ObdDevice {
  ObdDevice.classic(classic.BluetoothDevice d)
      : name = d.name ?? d.alias ?? '',
        address = d.address,
        kind = DeviceKind.classic,
        rssi = d.rssi,
        bleDevice = null;

  ObdDevice.ble(ble.ScanResult r)
      : name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName,
        address = r.device.remoteId.str,
        kind = DeviceKind.ble,
        rssi = r.rssi,
        bleDevice = r.device;

  final String name;
  final String address;
  final DeviceKind kind;
  final int? rssi;
  final ble.BluetoothDevice? bleDevice;

  String get displayName => name.isEmpty ? 'Sin nombre' : name;

  bool get looksLikeObd {
    final n = name.toUpperCase();
    return ['OBD', 'ELM', 'V-LINK', 'VLINK', 'KONNWEI', 'VGATE', 'ICAR', 'VEEPEAK', 'CAR']
        .any(n.contains);
  }
}

/// Estado global de la app: dispositivos, conexión, códigos y log.
class AppState extends ChangeNotifier {
  AppState({
    classic.FlutterBlueClassic? bluetooth,
    VehicleStore? vehicleStore,
    VinDecoder? vinDecoder,
  })  : _bluetooth = bluetooth ?? classic.FlutterBlueClassic(),
        _vehicleStore = vehicleStore ?? VehicleStore(),
        _vinDecoder = vinDecoder ?? VinDecoder();

  final VehicleStore _vehicleStore;
  final VinDecoder _vinDecoder;

  /// Vehículos guardados por el usuario (formulario modal).
  List<Vehicle> vehicles = [];
  String? _activeId;

  /// El vehículo que se está diagnosticando.
  Vehicle? get vehicle => vehicles.where((v) => v.id == _activeId).firstOrNull;

  /// VIN leído del vehículo conectado (modo 09), si lo entregó.
  String? vin;

  /// Lo que dijo la NHTSA del VIN, para prellenar el modal.
  Vehicle? suggestedVehicle;

  /// Vehículo guardado cuyo VIN coincide con el leído al conectar.
  Vehicle? get vinMatch => vin == null ? null : vehicles.where((v) => v.vin == vin).firstOrNull;

  Future<void> loadVehicle() async {
    final g = await _vehicleStore.load();
    vehicles = g.vehicles;
    _activeId = g.active?.id ?? (vehicles.isEmpty ? null : vehicles.first.id);
    notifyListeners();
  }

  Future<void> _persist() => _vehicleStore.save(Garage(vehicles, _activeId));

  /// Agrega un vehículo nuevo y lo deja activo. El VIN llega en [v] cuando
  /// el formulario se prellenó con el VIN leído.
  Future<Vehicle> addVehicle(Vehicle v) async {
    final saved = v.copyWith(id: newVehicleId());
    vehicles = [...vehicles, saved];
    _activeId = saved.id;
    await _persist();
    _log(LogKind.info, 'Vehículo agregado: ${saved.description}');
    notifyListeners();
    return saved;
  }

  /// Reemplaza los datos de [v] (mismo id).
  Future<void> updateVehicle(Vehicle v) async {
    vehicles = [for (final x in vehicles) x.id == v.id ? v : x];
    await _persist();
    notifyListeners();
  }

  Future<void> deleteVehicle(String id) async {
    vehicles = vehicles.where((v) => v.id != id).toList();
    if (_activeId == id) _activeId = vehicles.isEmpty ? null : vehicles.first.id;
    await _persist();
    notifyListeners();
  }

  Future<void> selectVehicle(String id) async {
    if (!vehicles.any((v) => v.id == id)) return;
    _activeId = id;
    await _persist();
    _log(LogKind.info, 'Diagnosticando: ${vehicle!.description}');
    notifyListeners();
  }

  final classic.FlutterBlueClassic _bluetooth;

  DtcDescriptions? descriptions;

  // Dispositivos
  List<ObdDevice> devices = [];
  bool loadingDevices = false;
  List<ObdDevice> nearby = [];
  bool scanning = false;

  // Conexión
  ConnectionStatus status = ConnectionStatus.disconnected;
  ObdDevice? device;
  ElmConnection? _elm;
  ObdService? _obd;

  /// Servicio OBD de la conexión activa (para lecturas en vivo).
  ObdService? get obd => status == ConnectionStatus.ready ? _obd : null;
  String? adapterVersion;
  String? protocolName;

  // Diagnóstico
  bool busy = false;
  CodeReadResult? stored;
  CodeReadResult? pending;
  DateTime? lastRead;

  /// Último error en lenguaje claro; la UI lo muestra y lo limpia.
  String? error;

  // Log
  static const _maxLog = 1000;
  final List<LogEntry> log = [];

  Future<void> loadDescriptions() async {
    try {
      descriptions = await DtcDescriptions.load();
    } catch (e) {
      _log(LogKind.error, 'No se pudo cargar la tabla de descripciones: $e');
    }
    notifyListeners();
  }

  void addLog(LogEntry entry) {
    log.add(entry);
    if (log.length > _maxLog) log.removeRange(0, log.length - _maxLog);
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  /// Pide permisos, enciende Bluetooth si hace falta y lista los emparejados.
  Future<void> loadBondedDevices() async {
    loadingDevices = true;
    error = null;
    notifyListeners();
    try {
      if (!await _ensureBluetoothReady()) return;
      final list = (await _bluetooth.bondedDevices ?? []).map(ObdDevice.classic).toList();
      list.sort(_compare);
      devices = list;
      _log(LogKind.info, '${list.length} dispositivos emparejados');
    } catch (e) {
      error = 'No se pudo leer la lista de dispositivos Bluetooth: $e';
    } finally {
      loadingDevices = false;
      notifyListeners();
    }
  }

  /// Busca adaptadores cercanos ~12 s: Bluetooth clásico (como Ajustes,
  /// incluye los no emparejados) y Bluetooth LE, a la vez.
  Future<void> scanNearby() async {
    if (scanning || status != ConnectionStatus.disconnected) return;
    scanning = true;
    notifyListeners();
    final found = <String, ObdDevice>{};
    final subs = <StreamSubscription<dynamic>>[];

    void add(ObdDevice d) {
      if (d.name.isEmpty) return; // sin nombre: casi nunca es un OBD
      // Un adaptador doble puede salir en ambos: se prefiere el clásico.
      final prev = found[d.address];
      if (prev != null && prev.kind == DeviceKind.classic && d.kind == DeviceKind.ble) return;
      found[d.address] = d;
      nearby = found.values.toList()..sort(_compare);
      notifyListeners();
    }

    try {
      if (!await _ensureBluetoothReady()) return;

      subs.add(_bluetooth.scanResults.listen((d) => add(ObdDevice.classic(d))));
      _bluetooth.startScan();

      subs.add(ble.FlutterBluePlus.onScanResults.listen(
        (results) => results.map(ObdDevice.ble).forEach(add),
        onError: (Object e) => _log(LogKind.error, 'Error en escaneo BLE: $e'),
      ));
      try {
        await ble.FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
      } catch (e) {
        _log(LogKind.error, 'No se pudo iniciar el escaneo BLE: $e');
      }

      // El descubrimiento clásico de Android dura ~12 s.
      await Future<void>.delayed(const Duration(seconds: 12));
      final classicCount = found.values.where((d) => d.kind == DeviceKind.classic).length;
      _log(LogKind.info,
          'Cercanos: $classicCount clásicos, ${found.length - classicCount} BLE (con nombre)');
    } catch (e) {
      error = 'No se pudo buscar dispositivos cercanos: $e';
    } finally {
      _bluetooth.stopScan();
      if (ble.FlutterBluePlus.isScanningNow) await ble.FlutterBluePlus.stopScan();
      for (final s in subs) {
        await s.cancel();
      }
      scanning = false;
      notifyListeners();
    }
  }

  /// Primero los que parecen OBD, luego por señal (BLE) y nombre.
  static int _compare(ObdDevice a, ObdDevice b) {
    if (a.looksLikeObd != b.looksLikeObd) return a.looksLikeObd ? -1 : 1;
    final rssi = (b.rssi ?? -999).compareTo(a.rssi ?? -999);
    if (rssi != 0) return rssi;
    return a.name.compareTo(b.name);
  }

  Future<bool> _ensureBluetoothReady() async {
    if (!await _bluetooth.isSupported) {
      error = 'Este teléfono no tiene Bluetooth.';
      return false;
    }
    // Android 12+: connect() del plugin llama cancelDiscovery(), que exige
    // también BLUETOOTH_SCAN. Ambos salen en un solo diálogo de
    // "Dispositivos cercanos". En Android 11 o anterior se conceden solos.
    final perms = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    if (!perms.values.every((p) => p.isGranted)) {
      error = perms.values.any((p) => p.isPermanentlyDenied)
          ? 'Sin permiso de Bluetooth. Actívalo en Ajustes > Apps > Jeep OBD2 > Permisos.'
          : 'La app necesita el permiso de "Dispositivos cercanos" para usar Bluetooth.';
      return false;
    }
    if (!await _bluetooth.isEnabled) {
      _bluetooth.turnOn();
      // Esperar a que el usuario acepte el diálogo del sistema.
      try {
        await _bluetooth.adapterState
            .firstWhere((s) => s == classic.BluetoothAdapterState.on)
            .timeout(const Duration(seconds: 15));
      } on TimeoutException {
        error = 'Bluetooth está apagado. Enciéndelo y vuelve a intentar.';
        return false;
      }
    }
    return true;
  }

  /// Conecta por SPP e inicializa el ELM327. Devuelve true si quedó listo.
  Future<bool> connect(ObdDevice target) async {
    if (status != ConnectionStatus.disconnected) await disconnect();
    device = target;
    error = null;
    stored = null;
    pending = null;
    lastRead = null;
    status = ConnectionStatus.connecting;
    notifyListeners();

    try {
      if (!await _ensureBluetoothReady()) {
        status = ConnectionStatus.disconnected;
        return false;
      }
      _bluetooth.stopScan(); // el descubrimiento clásico estorba al conectar
      if (ble.FlutterBluePlus.isScanningNow) await ble.FlutterBluePlus.stopScan();
      final kindName = target.kind == DeviceKind.ble ? 'BLE' : 'Bluetooth clásico';
      _log(LogKind.info, 'Conectando a ${target.displayName} ($kindName)…');
      final ElmTransport transport = target.kind == DeviceKind.ble
          ? await BleElmTransport.connect(target.bleDevice!, onLog: addLog)
          : await BluetoothElmTransport.connect(target.address);
      if (transport is BluetoothElmTransport) {
        _log(LogKind.info, 'Conectado por socket RFCOMM ${transport.method}');
      }
      final elm = ElmConnection(transport, onLog: _onElmLog);
      _elm = elm;
      _obd = ObdService(elm, onLog: addLog);

      status = ConnectionStatus.initializing;
      notifyListeners();
      await _obd!.initialize();

      adapterVersion = _obd!.adapterVersion;
      protocolName = _obd!.protocolName;

      // VIN (modo 09). Casi ningún vehículo anterior a ~2005 lo entrega.
      vin = await _obd!.readVin();
      suggestedVehicle = null;
      final match = vinMatch;
      if (match != null) {
        _activeId = match.id;
        await _persist();
        _log(LogKind.info, 'VIN reconocido: ${match.description}');
      } else if (vin != null) {
        suggestedVehicle = await _vinDecoder.decode(vin!);
        _log(LogKind.info, suggestedVehicle == null
            ? 'No se pudo decodificar el VIN con la NHTSA'
            : 'NHTSA: ${suggestedVehicle!.description}');
      }
      status = ConnectionStatus.ready;
      _log(LogKind.info, 'Listo: ${adapterVersion ?? 'ELM327'} · ${protocolName ?? '?'}');
      return true;
    } on ElmException catch (e) {
      error = e.message;
      await _teardown();
      return false;
    } catch (e) {
      error = 'Error inesperado al conectar: $e';
      await _teardown();
      return false;
    } finally {
      notifyListeners();
    }
  }

  void _onElmLog(LogEntry entry) {
    addLog(entry);
    // Si el adaptador corta la conexión, reflejarlo en la UI.
    if (_elm?.isClosed == true && status != ConnectionStatus.disconnected) {
      status = ConnectionStatus.disconnected;
      error ??= 'Se perdió la conexión con el adaptador.';
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _teardown();
    _log(LogKind.info, 'Desconectado');
    notifyListeners();
  }

  Future<void> _teardown() async {
    final elm = _elm;
    _elm = null;
    _obd = null;
    status = ConnectionStatus.disconnected;
    try {
      await elm?.close();
    } catch (_) {}
  }

  /// Lee almacenados (03) y pendientes (07).
  Future<void> readCodes() => _run(() async {
        stored = await _obd!.readStoredCodes();
        try {
          pending = await _obd!.readPendingCodes();
        } on ObdException {
          // Un fallo en 07 no debe ocultar los códigos de 03.
          pending = const CodeReadResult([], supported: false);
        }
        lastRead = DateTime.now();
      });

  /// Borra (04) y vuelve a leer para confirmar.
  Future<bool> clearCodes() async {
    var ok = false;
    await _run(() async {
      await _obd!.clearCodes();
      _log(LogKind.info, 'Códigos borrados');
      ok = true;
      // Si la relectura falla, no mostrar la lista de antes del borrado.
      stored = null;
      pending = null;
      lastRead = null;
      stored = await _obd!.readStoredCodes();
      lastRead = DateTime.now();
    });
    return ok;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_obd == null || status != ConnectionStatus.ready) {
      error = 'No hay conexión con el adaptador.';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } on ElmDisconnectedException catch (e) {
      error = e.message;
      await _teardown();
    } on ElmException catch (e) {
      error = e.message;
    } catch (e) {
      error = 'Error inesperado: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _log(LogKind kind, String text) => addLog(LogEntry(kind, text));

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
