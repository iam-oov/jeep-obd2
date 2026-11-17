import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Keys injected at build time (`--dart-define-from-file=secrets.json`).
/// The public APK is built without them: each user enters their own in the
/// app, and they are stored encrypted on their phone.
const _buildAnthropicKey = String.fromEnvironment('ANTHROPIC_API_KEY');
const _buildYoutubeKey = String.fromEnvironment('YOUTUBE_API_KEY');

class ApiKeys {
  const ApiKeys({this.anthropic = '', this.youtube = ''});

  final String anthropic;
  final String youtube;

  bool get complete => anthropic.isNotEmpty && youtube.isNotEmpty;

  /// "sk-ant-…a1b2" to display without revealing the key.
  static String mask(String key) =>
      key.length <= 10 ? '••••' : '${key.substring(0, 7)}…${key.substring(key.length - 4)}';
}

/// Stores the keys in the phone's secure storage (Android
/// Keystore). Keys entered in the app take priority over the build-time ones.
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
      // Unreadable storage (e.g. restored from another phone): it is
      // treated as empty and the key is asked for again.
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

/// Tests the keys with calls that cost nothing (Anthropic: fetch a model)
/// or almost nothing (YouTube: 1 quota unit).
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
        // 403 can also mean the quota is exhausted: the key is still valid.
        final body = utf8.decode(res.bodyBytes);
        return body.contains('quotaExceeded') ? KeyCheck.ok : KeyCheck.invalid;
      }
      return KeyCheck.unreachable;
    } catch (_) {
      return KeyCheck.unreachable;
    }
  }
}
