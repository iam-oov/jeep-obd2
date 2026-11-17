/// Decodes OBD2 responses for modes 03 / 07 into DTC codes.
///
/// ISO 9141-2 / KWP format (vehicles before 2008), with ATS0 and ATH0:
/// each line carries its own prefix (`43` or `47`) and up to 3 codes of
/// 2 bytes each, padded with `0000`. There is no count byte.
///
///     430320139100 00
///
/// CAN format (only if ATSP0 lands on a CAN protocol): after the prefix
/// comes a byte with the number of codes, and long replies arrive
/// in several numbered frames (`0:`, `1:`...) preceded by a length line.
/// Supported to avoid showing fake codes.
library;

const _letters = ['P', 'C', 'B', 'U'];

final _hexOnly = RegExp(r'^[0-9A-F]+$');
final _frameIndex = RegExp(r'^[0-9A-F]:');
final _canLength = RegExp(r'^[0-9A-F]{3}$');

/// Converts 4 hex characters (2 bytes) into a code like `P0320`.
///
/// Returns `null` if the text is not 4 hex digits or is `0000` padding.
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

/// Positive-response prefix for a mode (03 -> `43`, 07 -> `47`).
String responsePrefix(int mode) =>
    (0x40 + mode).toRadixString(16).toUpperCase().padLeft(2, '0');

/// Normalizes a line: uppercase and no spaces (in case the clone ignores ATS0).
String _compact(String line) => line.replaceAll(RegExp(r'\s'), '').toUpperCase();

/// Extracts the DTCs from the raw ELM327 reply to a mode 03/07 command.
///
/// [raw] is all the text received before the `>` prompt. Lines that are not data
/// (`SEARCHING...`, `BUS INIT: ...OK`, command echo,
/// `NO DATA`) are ignored. Repeated codes (e.g. reported by two modules) are
/// returned once, in order of appearance.
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

/// ISO/KWP: each data line starts with the prefix; the rest are words.
List<String> _isoWords(List<String> lines, String prefix) {
  final words = <String>[];
  for (final line in lines) {
    if (!_hexOnly.hasMatch(line) || !line.startsWith(prefix)) continue;
    words.addAll(_chunks(line.substring(prefix.length)));
  }
  return words;
}

/// CAN: prefix + count byte, possibly split across several frames.
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

/// Splits into complete 4-character blocks; discards an incomplete remainder.
Iterable<String> _chunks(String data) sync* {
  for (var i = 0; i + 4 <= data.length; i += 4) {
    yield data.substring(i, i + 4);
  }
}

/// Extracts the VIN from the reply to `0902` (mode 09, PID 02).
///
/// ISO 9141-2 / KWP: 5 lines `49 02 NN` + 4 bytes; the first one carries 3 bytes
/// of padding (`00 00 00`) before the first letter.
///
///     490201000000 31
///     4902024A34464134 ...
///
/// CAN: one length line (`014`) and frames `0:` `1:` `2:` with
/// `49 02 01` + 17 ASCII bytes.
///
/// Returns null if there is no VIN (`NO DATA`, `?`, incomplete reply): vehicles
/// before ~2005 rarely support this mode.
String? decodeVinResponse(String raw) {
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map(_compact)
      .where((l) => l.isNotEmpty)
      .toList();

  final bytes = <int>[];
  if (lines.any(_frameIndex.hasMatch)) {
    // CAN multi-frame: join and strip "49 02 01".
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
      // Single-line CAN: 4902 01 + 17 bytes (no message number per line).
      bytes.addAll(_hexBytes(line.substring(6)));
    }
  }

  // Bytes to ASCII; the 0x00 padding is discarded.
  final text = String.fromCharCodes(
    bytes.where((b) => (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A)),
  );
  final vin = text.length >= 17 ? text.substring(text.length - 17) : '';
  return RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(vin) ? vin : null;
}

List<int> _hexBytes(String hex) => [
      for (var i = 0; i + 2 <= hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ];
