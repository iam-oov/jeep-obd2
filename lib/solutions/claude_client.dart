import 'dart:convert';

import 'package:http/http.dart' as http;

class ClaudeException implements Exception {
  ClaudeException(this.message);

  /// Plain-language message for the user.
  final String message;

  @override
  String toString() => message;
}

/// Minimal client for the Claude Messages API over HTTP (Dart has no
/// official Anthropic SDK). It only does what the app needs: one request with
/// JSON output validated against a schema (structured outputs).
class ClaudeClient {
  ClaudeClient({required this.apiKey, http.Client? httpClient, this.model = 'claude-haiku-5-5'})
      : _http = httpClient ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _http;

  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  /// Sends [prompt] (with [system]) and returns the JSON that matches [schema].
  Future<Map<String, dynamic>> json({
    required String system,
    required String prompt,
    required Map<String, dynamic> schema,
    int maxTokens = 4000,
  }) async {
    final body = {
      'model': model,
      'max_tokens': maxTokens,
      // Haiku 5.5 thinks by default (adaptive); choosing searches and
      // videos needs little reasoning.
      'output_config': {
        'effort': 'low',
        'format': {'type': 'json_schema', 'schema': schema},
      },
      'system': system,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    };

    // One retry on 5xx/529 (overload), as in the Proyector app.
    http.Response? res;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        res = await _http
            .post(
              _endpoint,
              headers: {
                'content-type': 'application/json',
                'x-api-key': apiKey,
                'anthropic-version': '2026-10-21',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        if (attempt == 2) {
          throw ClaudeException('No se pudo contactar a Claude. Revisa tu conexión a internet.');
        }
        continue;
      }
      if (res.statusCode < 500) break;
    }
    if (res == null) {
      throw ClaudeException('No se pudo contactar a Claude. Revisa tu conexión a internet.');
    }

    final data = _decode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      final type = (data?['error'] as Map?)?['type'];
      throw ClaudeException(switch (res.statusCode) {
        401 => 'La llave de Anthropic no es válida (revisa ANTHROPIC_API_KEY).',
        429 => 'Claude está limitando las peticiones. Espera un momento y reintenta.',
        >= 500 => 'Claude no está disponible en este momento. Reintenta en un rato.',
        _ => 'Claude rechazó la petición (${res.statusCode} $type).',
      });
    }

    final stop = data?['stop_reason'];
    if (stop == 'refusal') {
      throw ClaudeException('Claude no quiso responder esta consulta.');
    }
    if (stop == 'max_tokens') {
      throw ClaudeException('La respuesta de Claude quedó incompleta. Reintenta.');
    }

    final content = (data?['content'] as List?) ?? const [];
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String)
        .join();
    final parsed = _decode(text);
    if (parsed == null) {
      throw ClaudeException('Claude devolvió una respuesta que no se pudo leer.');
    }
    return parsed;
  }

  static Map<String, dynamic>? _decode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } on FormatException {
      return null;
    }
  }
}
