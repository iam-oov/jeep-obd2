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
import 'solutions/api_keys.dart';
import 'vehicle/vehicle.dart';

enum ConnectionStatus { disconnected, connecting, initializing, ready }

enum DeviceKind { classic, ble }

/// A candidate adapter: paired over Bluetooth Classic or found
/// in a BLE scan.
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

/// Global app state: devices, connection, codes and log.
class AppState extends ChangeNotifier {
  AppState({
    classic.FlutterBlueClassic? bluetooth,
    VehicleStore? vehicleStore,
    VinDecoder? vinDecoder,
    ApiKeyStore? apiKeyStore,
  })  : _apiKeyStore = apiKeyStore ?? ApiKeyStore(),
        _bluetooth = bluetooth ?? classic.FlutterBlueClassic(),
        _vehicleStore = vehicleStore ?? VehicleStore(),
        _vinDecoder = vinDecoder ?? VinDecoder();

  final VehicleStore _vehicleStore;
  final ApiKeyStore _apiKeyStore;

  /// Anthropic and YouTube keys for video search.
  ApiKeys apiKeys = const ApiKeys();

  Future<void> loadApiKeys() async {
    apiKeys = await _apiKeyStore.load();
    notifyListeners();
  }

  Future<void> saveApiKeys(ApiKeys keys) async {
    await _apiKeyStore.save(keys);
    apiKeys = keys;
    _log(LogKind.info, 'Llaves de API guardadas');
    notifyListeners();
  }

  Future<void> clearApiKeys() async {
    await _apiKeyStore.clear();
    apiKeys = await _apiKeyStore.load();
    notifyListeners();
  }
  final VinDecoder _vinDecoder;

  /// Vehicles saved by the user (modal form).
  List<Vehicle> vehicles = [];
  String? _activeId;

  /// The vehicle being diagnosed.
  Vehicle? get vehicle => vehicles.where((v) => v.id == _activeId).firstOrNull;

  /// VIN read from the connected vehicle (mode 09), if it returned one.
  String? vin;

  /// What NHTSA returned for the VIN, to pre-fill the dialog.
  Vehicle? suggestedVehicle;

  /// Saved vehicle whose VIN matches the one read on connect.
  Vehicle? get vinMatch => vin == null ? null : vehicles.where((v) => v.vin == vin).firstOrNull;

  Future<void> loadVehicle() async {
    final g = await _vehicleStore.load();
    vehicles = g.vehicles;
    _activeId = g.active?.id ?? (vehicles.isEmpty ? null : vehicles.first.id);
    notifyListeners();
  }

  Future<void> _persist() => _vehicleStore.save(Garage(vehicles, _activeId));

  /// Adds a new vehicle and makes it active. The VIN arrives in [v] when
  /// the form was pre-filled with the VIN read.
  Future<Vehicle> addVehicle(Vehicle v) async {
    final saved = v.copyWith(id: newVehicleId());
    vehicles = [...vehicles, saved];
    _activeId = saved.id;
    await _persist();
    _log(LogKind.info, 'Vehículo agregado: ${saved.description}');
    notifyListeners();
    return saved;
  }

  /// Replaces the data of [v] (same id).
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
  Future<bool>? _turningOn;
  bool _turnOnDeclined = false;

  DtcDescriptions? descriptions;

  // Devices
  List<ObdDevice> devices = [];
  bool loadingDevices = false;
  List<ObdDevice> nearby = [];
  bool scanning = false;

  // Connection
  ConnectionStatus status = ConnectionStatus.disconnected;
  ObdDevice? device;
  ElmConnection? _elm;
  ObdService? _obd;

  /// OBD service of the active connection (for live readings).
  ObdService? get obd => status == ConnectionStatus.ready ? _obd : null;
  String? adapterVersion;
  String? protocolName;

  // Diagnosis
  bool busy = false;
  CodeReadResult? stored;
  CodeReadResult? pending;
  DateTime? lastRead;

  /// Last error in plain language; the UI shows it and clears it.
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

  /// Requests permissions, turns Bluetooth on if needed, and lists paired devices.
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

  /// Scans for nearby adapters for ~12 s: Bluetooth Classic (like Settings,
  /// including unpaired ones) and Bluetooth LE, at the same time.
  Future<void> scanNearby({bool userAsked = false}) async {
    if (scanning || status != ConnectionStatus.disconnected) return;
    scanning = true;
    notifyListeners();
    final found = <String, ObdDevice>{};
    final subs = <StreamSubscription<dynamic>>[];

    void add(ObdDevice d) {
      if (d.name.isEmpty) return; // sin nombre: casi nunca es un OBD
      // A dual-mode adapter can show up in both: Classic is preferred.
      final prev = found[d.address];
      if (prev != null && prev.kind == DeviceKind.classic && d.kind == DeviceKind.ble) return;
      found[d.address] = d;
      nearby = found.values.toList()..sort(_compare);
      notifyListeners();
    }

    try {
      if (!await _ensureBluetoothReady(userAsked: userAsked)) return;

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

      // Android's Classic discovery lasts ~12 s.
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

  /// OBD-looking devices first, then by signal (BLE) and name.
  static int _compare(ObdDevice a, ObdDevice b) {
    if (a.looksLikeObd != b.looksLikeObd) return a.looksLikeObd ? -1 : 1;
    final rssi = (b.rssi ?? -999).compareTo(a.rssi ?? -999);
    if (rssi != 0) return rssi;
    return a.name.compareTo(b.name);
  }

  Future<bool> _ensureBluetoothReady({bool userAsked = false}) async {
    if (!await _bluetooth.isSupported) {
      error = 'Este teléfono no tiene Bluetooth.';
      return false;
    }
    // Android 12+: the plugin's connect() calls cancelDiscovery(), which requires
    // BLUETOOTH_SCAN too. Both appear in a single
    // "Nearby devices" dialog. On Android 11 or older they are granted automatically.
    final perms = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    if (!perms.values.every((p) => p.isGranted)) {
      error = perms.values.any((p) => p.isPermanentlyDenied)
          ? 'Sin permiso de Bluetooth. Actívalo en Ajustes > Apps > Jeep OBD2 > Permisos.'
          : 'La app necesita el permiso de "Dispositivos cercanos" para usar Bluetooth.';
      return false;
    }
    if (await _bluetooth.isEnabled) return true;
    if (userAsked) _turnOnDeclined = false;
    final on = !_turnOnDeclined && await (_turningOn ??= _turnOn().whenComplete(() => _turningOn = null));
    if (!on) error = 'Bluetooth está apagado. Enciéndelo y vuelve a intentar.';
    return on;
  }

  Future<bool> _turnOn() async {
    if (!await _bluetooth.turnOn()) {
      _turnOnDeclined = true;
      return false;
    }
    if (await _bluetooth.isEnabled) return true;
    try {
      await _bluetooth.adapterState
          .firstWhere((s) => s == classic.BluetoothAdapterState.on)
          .timeout(const Duration(seconds: 15));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Connects over SPP and initializes the ELM327. Returns true if ready.
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
      if (!await _ensureBluetoothReady(userAsked: true)) {
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

      // VIN (mode 09). Almost no vehicles before ~2005 return it.
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
    // If the adapter drops the connection, reflect it in the UI.
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

  /// Reads stored (03) and pending (07) codes.
  Future<void> readCodes() => _run(() async {
        stored = await _obd!.readStoredCodes();
        try {
          pending = await _obd!.readPendingCodes();
        } on ObdException {
          // A failure in 07 must not hide the 03 codes.
          pending = const CodeReadResult([], supported: false);
        }
        lastRead = DateTime.now();
      });

  /// Clears (04) and reads again to confirm.
  Future<bool> clearCodes() async {
    var ok = false;
    await _run(() async {
      await _obd!.clearCodes();
      _log(LogKind.info, 'Códigos borrados');
      ok = true;
      // If the re-read fails, do not show the list from before clearing.
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
