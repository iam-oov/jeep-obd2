import 'dart:async';

import 'package:flutter/services.dart';

import 'elm_connection.dart';

/// [ElmTransport] over Bluetooth Classic SPP (RFCOMM), using the native channel
/// of `android/app/src/main/kotlin/.../SppBridge.kt`.
///
/// Does not require the adapter to be paired: it first tries an
/// "insecure" RFCOMM socket (no bond), which is how OBD apps connect to the
/// clones that fail to pair from Settings.
class BluetoothElmTransport implements ElmTransport {
  BluetoothElmTransport._(this._id, this.method);

  static const _methods = MethodChannel('jeep_obd2/spp');
  static const _events = EventChannel('jeep_obd2/spp/input');

  /// A single native listener for the whole app; each connection filters by its id.
  static final Stream<Map<Object?, Object?>> _allEvents =
      _events.receiveBroadcastStream().cast<Map<Object?, Object?>>().asBroadcastStream();

  final int _id;

  /// Socket variant that worked: "insecure", "secure" or "channel 1".
  final String method;

  final _input = StreamController<List<int>>();
  StreamSubscription<Map<Object?, Object?>>? _sub;

  static Future<BluetoothElmTransport> connect(String address) async {
    // Subscribe before connecting so the first bytes are not lost.
    BluetoothElmTransport? created;
    final pending = <Map<Object?, Object?>>[];
    final sub = _allEvents.listen((e) {
      final t = created;
      t == null ? pending.add(e) : t._onEvent(e);
    });
    try {
      final result = await _methods.invokeMapMethod<String, Object?>(
        'connect',
        {'address': address},
      );
      final transport = BluetoothElmTransport._(result!['id']! as int, result['method']! as String);
      transport._sub = sub;
      pending.forEach(transport._onEvent);
      created = transport;
      return transport;
    } on PlatformException catch (e) {
      await sub.cancel();
      throw ElmException(
        'No se pudo conectar al adaptador. Revisa que esté conectado al puerto '
        'OBD2 con la luz encendida y cierra otras apps OBD (solo acepta una conexión).\n'
        'Detalle: ${e.message}',
      );
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (event['id'] != _id || _input.isClosed) return;
    final data = event['data'];
    if (data is Uint8List) _input.add(data);
    if (event['closed'] == true) _input.close();
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(List<int> bytes) async {
    try {
      await _methods.invokeMethod<void>('write', {'data': Uint8List.fromList(bytes)});
    } on PlatformException {
      throw ElmDisconnectedException();
    }
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    if (!_input.isClosed) await _input.close();
    await _methods.invokeMethod<void>('close');
  }
}
