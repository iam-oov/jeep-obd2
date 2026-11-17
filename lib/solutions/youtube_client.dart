import 'dart:convert';

import 'package:http/http.dart' as http;

class YoutubeException implements Exception {
  YoutubeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class YoutubeVideo {
  YoutubeVideo({
    required this.id,
    required this.title,
    required this.channel,
    required this.description,
    required this.thumbnailUrl,
    this.duration,
    this.views,
  });

  final String id;
  final String title;
  final String channel;
  final String description;
  final String thumbnailUrl;

  /// Duración ya formateada ("12:34"), si se pudo obtener.
  String? duration;
  int? views;

  Uri get url => Uri.parse('https://www.youtube.com/watch?v=$id');
}

/// Cliente mínimo de la YouTube Data API v3 (search.list + videos.list).
class YoutubeClient {
  YoutubeClient({required this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final String apiKey;
  final http.Client _http;

  /// Busca videos. Cuesta 100 unidades de la cuota diaria (10 000 gratis).
  Future<List<YoutubeVideo>> search(String query, {String? language, int max = 8}) async {
    final data = await _get('search', {
      'part': 'snippet',
      'type': 'video',
      'q': query,
      'maxResults': '$max',
      'safeSearch': 'moderate',
      'relevanceLanguage': ?language,
    });
    final items = (data['items'] as List?) ?? const [];
    return [
      for (final item in items.cast<Map<String, dynamic>>())
        if ((item['id'] as Map?)?['videoId'] case final String id)
          _fromSnippet(id, item['snippet'] as Map<String, dynamic>),
    ];
  }

  /// Completa duración y vistas (1 unidad de cuota por llamada).
  Future<void> addDetails(List<YoutubeVideo> videos) async {
    if (videos.isEmpty) return;
    final data = await _get('videos', {
      'part': 'contentDetails,statistics',
      'id': videos.map((v) => v.id).join(','),
    });
    final byId = {for (final v in videos) v.id: v};
    for (final item in ((data['items'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final v = byId[item['id']];
      if (v == null) continue;
      v.duration = formatIsoDuration((item['contentDetails'] as Map?)?['duration'] as String?);
      v.views = int.tryParse('${(item['statistics'] as Map?)?['viewCount'] ?? ''}');
    }
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, String> params) async {
    final uri = Uri.https('www.googleapis.com', '/youtube/v3/$path', {...params, 'key': apiKey});
    final http.Response res;
    try {
      res = await _http.get(uri).timeout(const Duration(seconds: 20));
    } catch (e) {
      throw YoutubeException('No se pudo contactar a YouTube. Revisa tu conexión a internet.');
    }
    Map<String, dynamic>? data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode != 200 || data == null) {
      final reason = ((((data?['error'] as Map?)?['errors'] as List?)?.firstOrNull) as Map?)?['reason'];
      throw YoutubeException(switch (reason) {
        'quotaExceeded' => 'Se agotó la cuota diaria de YouTube. Intenta mañana.',
        'keyInvalid' || 'badRequest' => 'La llave de YouTube no es válida (revisa YOUTUBE_API_KEY).',
        'accessNotConfigured' => 'La YouTube Data API v3 no está habilitada en tu proyecto de Google Cloud.',
        _ => 'YouTube rechazó la búsqueda (${res.statusCode} ${reason ?? ''}).',
      });
    }
    return data;
  }

  static YoutubeVideo _fromSnippet(String id, Map<String, dynamic> s) {
    final thumbs = (s['thumbnails'] as Map?) ?? const {};
    final thumb = (thumbs['medium'] ?? thumbs['default']) as Map?;
    return YoutubeVideo(
      id: id,
      title: _unescape(s['title'] as String? ?? ''),
      channel: _unescape(s['channelTitle'] as String? ?? ''),
      description: _unescape(s['description'] as String? ?? ''),
      thumbnailUrl: thumb?['url'] as String? ?? 'https://i.ytimg.com/vi/$id/mqdefault.jpg',
    );
  }

  /// search.list devuelve títulos con entidades HTML (&#39; &amp; ...).
  static String _unescape(String s) => s
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

/// "PT1H2M3S" -> "1:02:03", "PT12M5S" -> "12:05".
String? formatIsoDuration(String? iso) {
  if (iso == null) return null;
  final m = RegExp(r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$').firstMatch(iso);
  if (m == null) return null;
  final h = int.parse(m.group(1) ?? '0');
  final min = int.parse(m.group(2) ?? '0');
  final s = int.parse(m.group(3) ?? '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${min.toString().padLeft(2, '0')}:$ss' : '$min:$ss';
}
