/// Decodificación de respuestas OBD2 de modos 03 / 07 a códigos DTC.
///
/// Formato ISO 9141-2 / KWP (vehículos anteriores a 2008), con ATS0 y ATH0:
/// cada línea trae su propio prefijo (`43` o `47`) y hasta 3 códigos de
/// 2 bytes, rellenando con `0000`. No hay byte de conteo.
///
///     430320139100 00
///
/// Formato CAN (solo si ATSP0 cae en un protocolo CAN): después del prefijo
/// viene un byte con la cantidad de códigos, y las respuestas largas llegan
/// en varias tramas numeradas (`0:`, `1:`...) precedidas por una línea de
/// longitud. Se soporta para no mostrar códigos
/// falsos.
library;

const _letters = ['P', 'C', 'B', 'U'];

final _hexOnly = RegExp(r'^[0-9A-F]+$');
final _frameIndex = RegExp(r'^[0-9A-F]:');
final _canLength = RegExp(r'^[0-9A-F]{3}$');

/// Convierte 4 caracteres hex (2 bytes) en un código tipo `P0320`.
///
/// Devuelve `null` si el texto no son 4 dígitos hex o si es relleno `0000`.
String? decodeDtcWord(String hex4) {
  final word = hex4.toUpperCase();
  if (word.length != 4 || !_hexOnly.hasMatch(word) || word == '0000') {
    return null;
  }
  final first = int.parse(word[0], radix: 16);
  final letter = _letters[first >> 2];
  final digit = first & 0x3;
  return '$letter$digit${word.substring(1)}';
}

/// Prefijo de respuesta positiva para un modo (03 -> `43`, 07 -> `47`).
String responsePrefix(int mode) =>
    (0x40 + mode).toRadixString(16).toUpperCase().padLeft(2, '0');

/// Normaliza una línea: mayúsculas y sin espacios (por si el clon ignora ATS0).
String _compact(String line) => line.replaceAll(RegExp(r'\s'), '').toUpperCase();

/// Extrae los DTC de la respuesta cruda del ELM327 a un comando de modo 03/07.
///
/// [raw] es todo el texto recibido antes del prompt `>`. Se ignoran líneas
/// que no son datos (`SEARCHING...`, `BUS INIT: ...OK`, eco del comando,
/// `NO DATA`). Los códigos repetidos (p. ej. reportados por dos módulos) se
/// devuelven una sola vez, en orden de aparición.
List<String> decodeDtcResponse(String raw, {required int mode, bool can = false}) {
  final prefix = responsePrefix(mode);
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map(_compact)
      .where((l) => l.isNotEmpty)
      .toList();

  final words = can ? _canWords(lines, prefix) : _isoWords(lines, prefix);

  final codes = <String>[];
  for (final w in words) {
    final code = decodeDtcWord(w);
    if (code != null && !codes.contains(code)) codes.add(code);
  }
  return codes;
}

/// ISO/KWP: cada línea de datos empieza con el prefijo; lo demás son palabras.
List<String> _isoWords(List<String> lines, String prefix) {
  final words = <String>[];
  for (final line in lines) {
    if (!_hexOnly.hasMatch(line) || !line.startsWith(prefix)) continue;
    words.addAll(_chunks(line.substring(prefix.length)));
  }
  return words;
}

/// CAN: prefijo + byte de conteo, posiblemente partido en varias tramas.
List<String> _canWords(List<String> lines, String prefix) {
  final multiFrame = lines.any(_frameIndex.hasMatch);
  final messages = <String>[];

  if (multiFrame) {
    final joined = StringBuffer();
    for (final line in lines) {
      if (_canLength.hasMatch(line)) continue;
      if (_frameIndex.hasMatch(line)) {
        joined.write(line.substring(2));
      } else if (_hexOnly.hasMatch(line)) {
        joined.write(line);
      }
    }
    messages.add(joined.toString());
  } else {
    messages.addAll(lines.where(_hexOnly.hasMatch));
  }

  final words = <String>[];
  for (final msg in messages) {
    if (!msg.startsWith(prefix) || msg.length < prefix.length + 2) continue;
    final count = int.parse(msg.substring(prefix.length, prefix.length + 2), radix: 16);
    final data = msg.substring(prefix.length + 2);
    words.addAll(_chunks(data).take(count));
  }
  return words;
}

/// Parte en bloques completos de 4 caracteres; descarta un resto incompleto.
Iterable<String> _chunks(String data) sync* {
  for (var i = 0; i + 4 <= data.length; i += 4) {
    yield data.substring(i, i + 4);
  }
}

/// Extrae el VIN de la respuesta a `0902` (modo 09, PID 02).
///
/// ISO 9141-2 / KWP: 5 líneas `49 02 NN` + 4 bytes; la primera trae 3 bytes
/// de relleno (`00 00 00`) antes de la primera letra.
///
///     490201000000 31
///     4902024A34464134 ...
///
/// CAN: una línea de longitud (`014`) y tramas `0:` `1:` `2:` con
/// `49 02 01` + 17 bytes ASCII.
///
/// Devuelve null si no hay VIN (`NO DATA`, `?`, respuesta incompleta): los
/// vehículos anteriores a ~2005 rara vez soportan este modo.
String? decodeVinResponse(String raw) {
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map(_compact)
      .where((l) => l.isNotEmpty)
      .toList();

  final bytes = <int>[];
  if (lines.any(_frameIndex.hasMatch)) {
    // CAN multitrama: juntar y quitar "49 02 01".
    final joined = StringBuffer();
    for (final line in lines) {
      if (_canLength.hasMatch(line)) continue;
      if (_frameIndex.hasMatch(line)) joined.write(line.substring(2));
    }
    final data = joined.toString();
    final at = data.indexOf('4902');
    if (at < 0) return null;
    bytes.addAll(_hexBytes(data.substring(at + 6)));
  } else {
    for (final line in lines) {
      if (!_hexOnly.hasMatch(line) || !line.startsWith('4902') || line.length < 6) continue;
      // CAN de una sola línea: 4902 01 + 17 bytes (sin número de mensaje por línea).
      bytes.addAll(_hexBytes(line.substring(6)));
    }
  }

  // Bytes a ASCII; el relleno 0x00 se descarta.
  final text = String.fromCharCodes(
    bytes.where((b) => (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A)),
  );
  final vin = text.length >= 17 ? text.substring(text.length - 17) : '';
  return RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(vin) ? vin : null;
}

List<int> _hexBytes(String hex) => [
      for (var i = 0; i + 2 <= hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ];
