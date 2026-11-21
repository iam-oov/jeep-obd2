import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart' as classic;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeep_obd2/app_state.dart';

// Bluetooth is off; each turnOn() answers with whatever the test decides,
// like the system "turn on Bluetooth?" dialog.
class _FakeBluetooth extends classic.FlutterBlueClassic {
  bool enabled = false;
  int turnOnCalls = 0;
  int bondedCalls = 0;
  Completer<bool> answer = Completer<bool>();
  final _state = StreamController<classic.BluetoothAdapterState>.broadcast();

  void accept() {
    enabled = true;
    answer.complete(true);
    _state.add(classic.BluetoothAdapterState.on);
  }

  void deny() => answer.complete(false);

  @override
  Future<bool> get isSupported async => true;

  @override
  Future<bool> get isEnabled async => enabled;

  @override
  Stream<classic.BluetoothAdapterState> get adapterState => _state.stream;

  @override
  Future<bool> turnOn() {
    turnOnCalls++;
    return answer.future;
  }

  @override
  Future<List<classic.BluetoothDevice>?> get bondedDevices async {
    bondedCalls++;
    return const [];
  }

  @override
  Stream<classic.BluetoothDevice> get scanResults => const Stream.empty();

  @override
  void startScan() {}

  @override
  void stopScan() {}
}

const _off = 'Bluetooth está apagado. Enciéndelo y vuelve a intentar.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => {for (final id in call.arguments as List) id as int: 1},
    );
  });

  test('a refresh asks once; Deny ends it right away and the second flow does not ask again', () async {
    final bt = _FakeBluetooth();
    final state = AppState(bluetooth: bt);

    final refresh = () async {
      await state.loadBondedDevices();
      await state.scanNearby();
    }();
    await pumpEventQueue();
    expect(bt.turnOnCalls, 1);
    bt.deny();
    // Before the fix the app kept waiting up to 15 s for the adapter, then asked again.
    await refresh.timeout(const Duration(seconds: 1));

    expect(bt.turnOnCalls, 1);
    expect(state.error, _off);
    expect(state.loadingDevices, isFalse);
    expect(state.scanning, isFalse);

    await state.loadBondedDevices().timeout(const Duration(seconds: 1));
    expect(bt.turnOnCalls, 1);
    expect(state.error, _off);
  });

  test('callers while a turn-on request is open share it instead of asking again', () async {
    final bt = _FakeBluetooth();
    final state = AppState(bluetooth: bt);

    final first = state.loadBondedDevices();
    final second = state.loadBondedDevices();
    await pumpEventQueue();
    expect(bt.turnOnCalls, 1);
    bt.accept();
    await Future.wait([first, second]).timeout(const Duration(seconds: 1));

    expect(bt.turnOnCalls, 1);
    expect(bt.bondedCalls, 2);
    expect(state.error, isNull);
  });

  test('after a Deny, the radar button asks again; a new app launch does too', () async {
    final bt = _FakeBluetooth();
    final state = AppState(bluetooth: bt);
    final load = state.loadBondedDevices();
    await pumpEventQueue();
    bt.deny();
    await load;
    expect(bt.turnOnCalls, 1);

    bt.answer = Completer<bool>();
    final radar = state.scanNearby(userAsked: true);
    await pumpEventQueue();
    expect(bt.turnOnCalls, 2);
    bt.deny();
    await radar.timeout(const Duration(seconds: 1));
    expect(state.error, _off);

    bt.answer = Completer<bool>();
    final relaunched = AppState(bluetooth: bt);
    final again = relaunched.loadBondedDevices();
    await pumpEventQueue();
    expect(bt.turnOnCalls, 3);
    bt.deny();
    await again;
  });

  test('accepting the dialog lists the paired devices', () async {
    final bt = _FakeBluetooth();
    final state = AppState(bluetooth: bt);
    final load = state.loadBondedDevices();
    await pumpEventQueue();
    bt.accept();
    await load.timeout(const Duration(seconds: 1));
    expect(bt.bondedCalls, 1);
    expect(state.error, isNull);
  });
}
