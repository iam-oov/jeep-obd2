import 'dart:async';

import '../bluetooth/elm_connection.dart';
import 'dtc_decoder.dart';
import 'live_data.dart';

class ObdException extends ElmException {
  ObdException(super.message);
}

/// Tiempos de espera. Los de ISO 9141-2 son largos: el "5 baud init" tarda
/// ~2-3 s y la primera consulta puede tardar más.
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

/// Resultado de leer códigos (modo 03 o 07).
class CodeReadResult {
  const CodeReadResult(this.codes, {this.supported = true});

  final List<String> codes;

  /// `false` si el ECU respondió que no soporta el modo (típico de 07 en 1998).
  final bool supported;
}

/// Inicialización del ELM327 y lectura/borrado de DTC.
class ObdService {
  ObdService(this._elm, {this.timeouts = const ObdTimeouts(), this.onLog});

  final ElmConnection _elm;
  final ObdTimeouts timeouts;
  final void Function(LogEntry)? onLog;

  String? adapterVersion;

  /// Respuesta a 0100 de la inicialización (PIDs 01-20 soportados).
  String? pids0100;
  String? protocolName;
  bool isCan = false;

  /// ATZ, configuración, protocolo ISO 9141-2 y prueba con 0100.
  /// Si ISO 9141-2 falla, reintenta con detección automática (ATSP0).
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
      // Algunos clones no implementan todos los AT; se sigue adelante.
      _info('$cmd respondió "$resp" (se continúa)');
    }
  }

  /// Manda 0100 y devuelve true si llega una respuesta 41 00.
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
      // "A6" = automático + protocolo 6. Del 6 al C son CAN.
      final digit = _compact(num).replaceFirst('A', '');
      final n = int.tryParse(digit.isEmpty ? '' : digit[0], radix: 16);
      isCan = n != null && n >= 6;
    } on ElmTimeoutException {
      // No es crítico: se asume no-CAN, que es lo que usan los vehículos anteriores a 2008.
    }
  }

  /// Modo 09 PID 02: VIN. Devuelve null si el vehículo no lo soporta (lo
  /// normal antes de ~2005) o si la respuesta no trae un VIN válido.
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

  /// PIDs del modo 01 que soporta el vehículo (consulta 0100, 0120, 0140
  /// mientras el bit "siguiente bloque" esté encendido).
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

  /// Lee un PID del modo 01 y devuelve sus bytes de datos (sin "41 PID").
  /// null si no respondió o no lo soporta.
  Future<List<int>?> readPid(int pid) async {
    final hex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
    try {
      final resp = await _elm.send('01$hex', timeout: timeouts.query, quiet: true);
      return parsePidResponse(resp, pid);
    } on ElmTimeoutException {
      return null;
    }
  }

  /// Voltaje en el pin 16 del conector OBD2 (batería), medido por el propio
  /// ELM327. Funciona en cualquier vehículo.
  Future<double?> readAdapterVoltage() async {
    try {
      final resp = await _elm.send('ATRV', timeout: timeouts.atCommand, quiet: true);
      return parseAtrv(resp);
    } on ElmTimeoutException {
      return null;
    }
  }

  /// Modo 03: códigos almacenados (los que encienden el check engine).
  Future<CodeReadResult> readStoredCodes() => _readCodes(3);

  /// Modo 07: códigos pendientes. Muchos ECU de 1998 no lo soportan.
  Future<CodeReadResult> readPendingCodes() => _readCodes(7);

  Future<CodeReadResult> _readCodes(int mode) async {
    final cmd = mode.toString().padLeft(2, '0');
    final resp = await _elm.send(cmd, timeout: timeouts.query);
    final upper = resp.toUpperCase();

    if (_isUnsupported(upper)) return const CodeReadResult([], supported: false);
    if (upper.contains('NO DATA')) return const CodeReadResult([]);
    _throwIfError(upper);

    // Al menos una línea debe empezar con 43/47; si no (p. ej. headers
    // activos "486B10 43..."), decodificar daría un falso "sin códigos".
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

  /// Modo 04: borra los códigos y apaga el check engine.
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
