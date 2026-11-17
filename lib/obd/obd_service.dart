import 'dart:async';

import '../bluetooth/elm_connection.dart';
import 'dtc_decoder.dart';
import 'live_data.dart';

class ObdException extends ElmException {
  ObdException(super.message);
}

/// Timeouts. The ISO 9141-2 ones are long: the "5 baud init" takes
/// ~2-3 s and the first query can take longer.
class ObdTimeouts {
  const ObdTimeouts({
    this.reset = const Duration(seconds: 5),
    this.atCommand = const Duration(seconds: 3),
    this.firstQuery = const Duration(seconds: 10),
    this.autoProtocolQuery = const Duration(seconds: 20),
    this.query = const Duration(seconds: 8),
  });

  final Duration reset;
  final Duration atCommand;
  final Duration firstQuery;
  final Duration autoProtocolQuery;
  final Duration query;
}

/// Result of reading codes (mode 03 or 07).
class CodeReadResult {
  const CodeReadResult(this.codes, {this.supported = true});

  final List<String> codes;

  /// `false` if the ECU replied that it does not support the mode (typical of 07 in 1998).
  final bool supported;
}

/// ELM327 initialization and DTC read/clear.
class ObdService {
  ObdService(this._elm, {this.timeouts = const ObdTimeouts(), this.onLog});

  final ElmConnection _elm;
  final ObdTimeouts timeouts;
  final void Function(LogEntry)? onLog;

  String? adapterVersion;

  /// Reply to 0100 during initialization (PIDs 01-20 supported).
  String? pids0100;
  String? protocolName;
  bool isCan = false;

  /// ATZ, configuration, ISO 9141-2 protocol and a 0100 test.
  /// If ISO 9141-2 fails, retries with automatic detection (ATSP0).
  Future<void> initialize() async {
    final reset = await _resetWithRetry();
    adapterVersion = RegExp(r'ELM327[^\r\n>]*').firstMatch(reset)?.group(0)?.trim();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    for (final cmd in ['ATE0', 'ATL0', 'ATS0', 'ATH0']) {
      await _at(cmd);
    }

    await _at('ATSP3');
    var ok = await _probe(timeouts.firstQuery);
    if (!ok) {
      _info('ISO 9141-2 no respondió; probando detección automática (ATSP0)');
      await _at('ATSP0');
      ok = await _probe(timeouts.autoProtocolQuery);
    }
    if (!ok) {
      throw ObdException(
        'El adaptador está conectado pero la computadora del carro no responde. '
        'Pon el switch en ON (o enciende el motor) y vuelve a intentar.',
      );
    }

    await _detectProtocol();
  }

  Future<String> _resetWithRetry() async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        return await _elm.send('ATZ', timeout: timeouts.reset);
      } on ElmTimeoutException {
        if (attempt == 2) {
          throw ObdException(
            'El adaptador no responde. Verifica que sea un ELM327 y que tenga '
            'corriente (la luz debe estar encendida).',
          );
        }
        _info('ATZ sin respuesta, reintentando');
      }
    }
    throw StateError('inalcanzable');
  }

  Future<void> _at(String cmd) async {
    final resp = await _elm.send(cmd, timeout: timeouts.atCommand);
    if (!resp.toUpperCase().contains('OK')) {
      // Some clones do not implement every AT command; continue anyway.
      _info('$cmd respondió "$resp" (se continúa)');
    }
  }

  /// Sends 0100 and returns true if a 41 00 reply arrives.
  Future<bool> _probe(Duration timeout) async {
    try {
      final resp = await _elm.send('0100', timeout: timeout);
      pids0100 = resp;
      return _compact(resp).contains('4100');
    } on ElmTimeoutException {
      return false;
    }
  }

  Future<void> _detectProtocol() async {
    try {
      final desc = await _elm.send('ATDP', timeout: timeouts.atCommand);
      protocolName = desc.trim();
      final num = await _elm.send('ATDPN', timeout: timeouts.atCommand);
      // "A6" = automatic + protocol 6. 6 through C are CAN.
      final digit = _compact(num).replaceFirst('A', '');
      final n = int.tryParse(digit.isEmpty ? '' : digit[0], radix: 16);
      isCan = n != null && n >= 6;
    } on ElmTimeoutException {
      // Not critical: assume non-CAN, which is what vehicles before 2008 use.
    }
  }

  /// Mode 09 PID 02: VIN. Returns null if the vehicle does not support it (which is
  /// normal before ~2005) or if the reply does not contain a valid VIN.
  Future<String?> readVin() async {
    try {
      final resp = await _elm.send('0902', timeout: timeouts.query);
      final vin = decodeVinResponse(resp);
      _info(vin == null ? 'El vehículo no entregó VIN (modo 09)' : 'VIN: $vin');
      return vin;
    } on ElmTimeoutException {
      _info('Sin respuesta al VIN (modo 09)');
      return null;
    }
  }

  /// Mode 01 PIDs the vehicle supports (queries 0100, 0120, 0140
  /// while the "next block" bit is set).
  Future<Set<int>> supportedPids() async {
    final supported = <int>{};
    for (final base in [0x00, 0x20, 0x40]) {
      if (base != 0 && !supported.contains(base)) break;
      final cmd = '01${base.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      String resp;
      if (base == 0 && pids0100 != null) {
        resp = pids0100!;
      } else {
        try {
          resp = await _elm.send(cmd, timeout: timeouts.query);
        } on ElmTimeoutException {
          break;
        }
      }
      supported.addAll(parseSupportedPids(resp, base));
    }
    return supported;
  }

  /// Reads a mode 01 PID and returns its data bytes (without "41 PID").
  /// null if it did not reply or does not support it.
  Future<List<int>?> readPid(int pid) async {
    final hex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
    try {
      final resp = await _elm.send('01$hex', timeout: timeouts.query, quiet: true);
      return parsePidResponse(resp, pid);
    } on ElmTimeoutException {
      return null;
    }
  }

  /// Voltage on OBD2 connector pin 16 (battery), measured by the adapter
  /// itself. Works on any vehicle.
  Future<double?> readAdapterVoltage() async {
    try {
      final resp = await _elm.send('ATRV', timeout: timeouts.atCommand, quiet: true);
      return parseAtrv(resp);
    } on ElmTimeoutException {
      return null;
    }
  }

  /// Mode 03: stored codes (the ones that turn on the check engine light).
  Future<CodeReadResult> readStoredCodes() => _readCodes(3);

  /// Mode 07: pending codes. Many 1998 ECUs do not support it.
  Future<CodeReadResult> readPendingCodes() => _readCodes(7);

  Future<CodeReadResult> _readCodes(int mode) async {
    final cmd = mode.toString().padLeft(2, '0');
    final resp = await _elm.send(cmd, timeout: timeouts.query);
    final upper = resp.toUpperCase();

    if (_isUnsupported(upper)) return const CodeReadResult([], supported: false);
    if (upper.contains('NO DATA')) return const CodeReadResult([]);
    _throwIfError(upper);

    // At least one line must start with 43/47; otherwise (e.g. headers
    // enabled "486B10 43..."), decoding would give a false "no codes".
    final prefix = responsePrefix(mode);
    final hasDataLine = resp
        .split('\n')
        .map(_compact)
        .any((l) => l.startsWith(prefix) || RegExp(r'^[0-9A-F]:' + prefix).hasMatch(l));
    if (!hasDataLine) {
      throw ObdException('Respuesta inesperada al modo $cmd. Revisa el log.');
    }
    return CodeReadResult(decodeDtcResponse(resp, mode: mode, can: isCan));
  }

  /// Mode 04: clears the codes and turns off the check engine light.
  Future<void> clearCodes() async {
    final resp = await _elm.send('04', timeout: timeouts.query);
    final upper = resp.toUpperCase();
    _throwIfError(upper);
    if (!_compact(resp).contains('44')) {
      throw ObdException(
        'La computadora no confirmó el borrado. En algunos vehículos hay que '
        'tener el switch en ON con el motor apagado.',
      );
    }
  }

  bool _isUnsupported(String upper) => upper.split('\n').any((l) => l.trim() == '?');

  void _throwIfError(String upper) {
    if (upper.contains('UNABLE TO CONNECT')) {
      throw ObdException('El adaptador no pudo comunicarse con la computadora del carro. '
          'Revisa que el switch esté en ON.');
    }
    if (upper.contains('BUS INIT') && upper.contains('ERROR')) {
      throw ObdException('Falló la inicialización del bus OBD2 (ISO 9141-2). '
          'Apaga el switch, espera 5 segundos, enciéndelo y vuelve a intentar.');
    }
    if (upper.contains('BUS BUSY') || upper.contains('BUS ERROR') ||
        upper.contains('CAN ERROR') || upper.contains('DATA ERROR') ||
        upper.contains('FB ERROR')) {
      throw ObdException('Error de comunicación en el bus OBD2. Intenta de nuevo.');
    }
    if (upper.contains('STOPPED')) {
      throw ObdException('La consulta se interrumpió. Intenta de nuevo.');
    }
  }

  static String _compact(String s) => s.replaceAll(RegExp(r'\s'), '').toUpperCase();

  void _info(String text) => onLog?.call(LogEntry(LogKind.info, text));
}
