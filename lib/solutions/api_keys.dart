import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Llaves inyectadas al compilar (`--dart-define-from-file=secrets.json`).
/// El APK público se compila sin ellas: cada quien captura las suyas en la
/// app y se guardan cifradas en su teléfono.
const _buildAnthropicKey = String.fromEnvironment('ANTHROPIC_API_KEY');
const _buildYoutubeKey = String.fromEnvironment('YOUTUBE_API_KEY');

class ApiKeys {
  const ApiKeys({this.anthropic = '', this.youtube = ''});

  final String anthropic;
  final String youtube;

  bool get complete => anthropic.isNotEmpty && youtube.isNotEmpty;

  /// "sk-ant-…a1b2" para mostrar sin revelar la llave.
  static String mask(String key) =>
      key.length <= 10 ? '••••' : '${key.substring(0, 7)}…${key.substring(key.length - 4)}';
}

/// Guarda las llaves en el almacenamiento seguro del teléfono (Android
/// Keystore). Las capturadas en la app tienen prioridad sobre las de
/// compilación.
class ApiKeyStore {
  ApiKeyStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _anthropicKey = 'anthropic_api_key';
  static const _youtubeKey = 'youtube_api_key';

  Future<ApiKeys> load() async {
    String? a, y;
    try {
      a = await _storage.read(key: _anthropicKey);
      y = await _storage.read(key: _youtubeKey);
    } catch (_) {
      // Almacenamiento ilegible (p. ej. restaurado de otro teléfono): se
      // trata como vacío y se vuelve a pedir.
    }
    return ApiKeys(
      anthropic: (a == null || a.isEmpty) ? _buildAnthropicKey : a,
      youtube: (y == null || y.isEmpty) ? _buildYoutubeKey : y,
    );
  }

  Future<void> save(ApiKeys keys) async {
    await _storage.write(key: _anthropicKey, value: keys.anthropic);
    await _storage.write(key: _youtubeKey, value: keys.youtube);
  }

  Future<void> clear() async {
    await _storage.delete(key: _anthropicKey);
    await _storage.delete(key: _youtubeKey);
  }
}

enum KeyCheck { ok, invalid, unreachable }

/// Prueba las llaves con llamadas que no cuestan (Anthropic: consultar un
/// modelo) o casi nada (YouTube: 1 unidad de cuota).
class ApiKeyChecker {
  ApiKeyChecker({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  Future<KeyCheck> anthropic(String key) async {
    try {
      final res = await _http.get(
        Uri.https('api.anthropic.com', '/v1/models/claude-haiku-5-5'),
        headers: {'x-api-key': key, 'anthropic-version': '2026-10-21'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) return KeyCheck.ok;
      if (res.statusCode == 401 || res.statusCode == 403) return KeyCheck.invalid;
      return KeyCheck.unreachable;
    } catch (_) {
      return KeyCheck.unreachable;
    }
  }

  Future<KeyCheck> youtube(String key) async {
    try {
      final res = await _http
          .get(Uri.https('www.googleapis.com', '/youtube/v3/videos',
              {'part': 'id', 'id': 'dQw4w9WgXcQ', 'key': key}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) return KeyCheck.ok;
      if (res.statusCode == 400 || res.statusCode == 403) {
        // 403 también puede ser cuota agotada: la llave sí es válida.
        final body = utf8.decode(res.bodyBytes);
        return body.contains('quotaExceeded') ? KeyCheck.ok : KeyCheck.invalid;
      }
      return KeyCheck.unreachable;
    } catch (_) {
      return KeyCheck.unreachable;
    }
  }
}
