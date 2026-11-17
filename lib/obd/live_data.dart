/// Live readings: mode 01 PID definitions, reply parsing and
/// a "poller" that queries them in a cycle.
library;

import 'obd_service.dart';

enum Level { ok, warn, danger }

/// A live reading (mode 01 PID, or the adapter voltage).
class LiveParam {
  const LiveParam({
    required this.key,
    required this.name,
    required this.unit,
    this.pid,
    this.minBytes = 1,
    this.decode,
    this.decimals = 0,
    this.level,
  });

  final String key;
  final String name;
  final String unit;

  /// Mode 01 PID; null for the adapter voltage (ATRV).
  final int? pid;
  final int minBytes;
  final double Function(List<int> b)? decode;
  final int decimals;

  /// Alert level based on the value; [engineRunning] changes the voltage
  /// ranges (with the engine running, the alternator must charge).
  final Level Function(double value, {required bool engineRunning})? level;
}

Level _voltageLevel(double v, {required bool engineRunning}) {
  if (engineRunning) {
    if (v < 12.5 || v > 15.2) return Level.danger;
    if (v < 13.2 || v > 14.8) return Level.warn;
    return Level.ok;
  }
  if (v < 11.8) return Level.danger;
  if (v < 12.2) return Level.warn;
  return Level.ok;
}

Level _coolantLevel(double c, {required bool engineRunning}) =>
    c > 112 ? Level.danger : (c > 105 ? Level.warn : Level.ok);

/// Available readings, in display order.
final liveParams = <LiveParam>[
  const LiveParam(
    key: 'atrv',
    name: 'Voltaje batería',
    unit: 'V',
    decimals: 1,
    level: _voltageLevel,
  ),
  LiveParam(
    key: 'coolant',
    name: 'Temp. refrigerante',
    unit: '°C',
    pid: 0x05,
    decode: (b) => b[0] - 40.0,
    level: _coolantLevel,
  ),
  LiveParam(
    key: 'rpm',
    name: 'RPM',
    unit: 'rpm',
    pid: 0x0C,
    minBytes: 2,
    decode: (b) => (b[0] * 256 + b[1]) / 4,
  ),
  LiveParam(
    key: 'speed',
    name: 'Velocidad',
    unit: 'km/h',
    pid: 0x0D,
    decode: (b) => b[0].toDouble(),
  ),
  LiveParam(
    key: 'load',
    name: 'Carga del motor',
    unit: '%',
    pid: 0x04,
    decode: (b) => b[0] * 100 / 255,
  ),
  LiveParam(
    key: 'iat',
    name: 'Temp. aire admisión',
    unit: '°C',
    pid: 0x0F,
    decode: (b) => b[0] - 40.0,
  ),
  LiveParam(
    key: 'throttle',
    name: 'Acelerador',
    unit: '%',
    pid: 0x11,
    decode: (b) => b[0] * 100 / 255,
  ),
  LiveParam(
    key: 'ecu_volt',
    name: 'Voltaje computadora',
    unit: 'V',
    pid: 0x42,
    minBytes: 2,
    decimals: 1,
    decode: (b) => (b[0] * 256 + b[1]) / 1000,
    level: _voltageLevel,
  ),
];

String _compact(String s) => s.replaceAll(RegExp(r'\s'), '').toUpperCase();

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

List<int> _bytes(String hex) => [
      for (var i = 0; i + 2 <= hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ];

final _hexOnly = RegExp(r'^[0-9A-F]+$');

/// Data bytes of the reply to `01 PID` (what follows "41 PID").
/// If several ECUs reply, the first one is used.
List<int>? parsePidResponse(String raw, int pid) {
  final prefix = '41${_hex2(pid)}';
  for (final line in raw.split(RegExp(r'[\r\n]+')).map(_compact)) {
    if (_hexOnly.hasMatch(line) && line.startsWith(prefix) && line.length > prefix.length) {
      return _bytes(line.substring(prefix.length));
    }
  }
  return null;
}

/// Supported PIDs from the 4-byte mask of `01 00` / `01 20` / ...
/// The highest bit of the first byte is PID base+1.
Set<int> parseSupportedPids(String raw, int base) {
  final data = parsePidResponse(raw, base);
  if (data == null || data.length < 4) return {};
  final out = <int>{};
  for (var i = 0; i < 32; i++) {
    if (data[i ~/ 8] & (0x80 >> (i % 8)) != 0) out.add(base + i + 1);
  }
  return out;
}

/// "12.6V" -> 12.6
double? parseAtrv(String raw) {
  final m = RegExp(r'(\d{1,2}(?:\.\d)?)\s*V', caseSensitive: false).firstMatch(raw);
  return m == null ? null : double.parse(m.group(1)!);
}

class LiveValue {
  LiveValue(this.value) : min = value, max = value;

  double value;
  double min;
  double max;

  void update(double v) {
    value = v;
    if (v < min) min = v;
    if (v > max) max = v;
  }
}

/// Cyclically queries the readings the vehicle supports.
class LiveDataPoller {
  LiveDataPoller(this._obd);

  final ObdService _obd;

  /// Readings to query (supported ones plus the voltage).
  List<LiveParam> active = [];

  /// Readings the vehicle does not support (to explain it in the UI).
  List<LiveParam> unsupported = [];

  final values = <String, LiveValue>{};

  bool get engineRunning => (values['rpm']?.value ?? 0) > 400;

  Future<void> discover() async {
    final supported = await _obd.supportedPids();
    active = [
      for (final p in liveParams)
        if (p.pid == null || supported.contains(p.pid)) p,
    ];
    unsupported = [
      for (final p in liveParams)
        if (p.pid != null && !supported.contains(p.pid)) p,
    ];
  }

  /// One cycle: queries each active reading once. Returns how many
  /// replied.
  Future<int> pollOnce() async {
    var ok = 0;
    for (final p in active) {
      double? v;
      if (p.pid == null) {
        v = await _obd.readAdapterVoltage();
      } else {
        final b = await _obd.readPid(p.pid!);
        if (b != null && b.length >= p.minBytes) v = p.decode!(b);
      }
      if (v == null) continue;
      ok++;
      (values[p.key] ??= LiveValue(v)).update(v);
    }
    return ok;
  }

  Level? levelOf(LiveParam p) {
    final v = values[p.key];
    if (v == null || p.level == null) return null;
    return p.level!(v.value, engineRunning: engineRunning);
  }
}
