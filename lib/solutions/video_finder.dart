import '../vehicle/vehicle.dart';
import 'claude_client.dart';
import 'youtube_client.dart';

class VideoPick {
  VideoPick(this.video, this.reason);

  final YoutubeVideo video;

  /// Why Haiku picked it, in Spanish.
  final String reason;
}

class VideoSearchResult {
  VideoSearchResult({required this.picks, required this.queries, required this.likelyFix});

  final List<VideoPick> picks;
  final List<String> queries;

  /// Haiku summary: likely cause and what to check first.
  final String likelyFix;
}

/// Finds YouTube videos to repair a DTC:
/// 1. Haiku proposes searches (Spanish and English) for that code and vehicle.
/// 2. They are searched on YouTube and the results are merged.
/// 3. Haiku picks the videos that really help and explains why.
class VideoFinder {
  VideoFinder({required this.claude, required this.youtube});

  final ClaudeClient claude;
  final YoutubeClient youtube;

  /// Results from this app session: reopening a code does not spend
  /// YouTube quota or Claude calls.
  static final _cache = <String, VideoSearchResult>{};

  static void clearCache() => _cache.clear();

  static const _system =
      'Eres un mecánico automotriz experto que ayuda a un dueño a reparar su propio vehículo. '
      'Respondes en español de México, de forma breve y concreta.';

  static const _querySchema = {
    'type': 'object',
    'properties': {
      'queries': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'language': {
              'type': 'string',
              'enum': ['es', 'en'],
            },
          },
          'required': ['query', 'language'],
          'additionalProperties': false,
        },
      },
      'likely_fix': {'type': 'string'},
    },
    'required': ['queries', 'likely_fix'],
    'additionalProperties': false,
  };

  static const _pickSchema = {
    'type': 'object',
    'properties': {
      'picks': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'video_id': {'type': 'string'},
            'reason': {'type': 'string'},
          },
          'required': ['video_id', 'reason'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['picks'],
    'additionalProperties': false,
  };

  Future<VideoSearchResult> find(
    String code,
    String description, {
    required Vehicle vehicle,
    bool refresh = false,
  }) async {
    final key = '$code|${vehicle.description}';
    final cached = refresh ? null : _cache[key];
    if (cached != null) return cached;
    final result = await _find(code, description, vehicle.description);
    if (result.picks.isNotEmpty) _cache[key] = result;
    return result;
  }

  Future<VideoSearchResult> _find(String code, String description, String vehicle) async {
    // 1) Searches.
    final plan = await claude.json(
      system: _system,
      schema: _querySchema,
      prompt: '''
Vehículo: $vehicle.
Código de falla: $code — $description

Propón 2 búsquedas de YouTube para encontrar videos que expliquen cómo diagnosticar y reparar esta falla en este vehículo:
- 1 en español y 1 en inglés (suele haber más contenido de reparación en inglés).
- Incluye el código, la marca y el modelo (o el nombre de su generación/plataforma si es como lo busca la gente); agrega el componente probable (relé, sensor, arnés...) si lo sabes.
- Cada búsqueda de máximo 8 palabras, como la escribiría una persona en YouTube.
- No agregues palabras de relleno ("tutorial", "video", "full") que cambien los resultados.

En "likely_fix" escribe en 2 o 3 frases la causa más probable de este código en este vehículo y qué revisar primero.''',
    );

    final queries = [
      for (final q in (plan['queries'] as List).cast<Map<String, dynamic>>())
        (query: q['query'] as String, language: q['language'] as String),
    ].take(2).toList();
    if (queries.isEmpty) {
      throw ClaudeException('Claude no propuso búsquedas. Reintenta.');
    }

    // 2) YouTube: merge results without duplicates.
    final candidates = <String, YoutubeVideo>{};
    for (final q in queries) {
      // Each search.list costs 100 of the 10,000 daily units.
      final found = await youtube.search(q.query, language: q.language, max: 8);
      for (final v in found) {
        candidates.putIfAbsent(v.id, () => v);
      }
    }
    if (candidates.isEmpty) {
      return VideoSearchResult(
        picks: [],
        queries: queries.map((q) => q.query).toList(),
        likelyFix: plan['likely_fix'] as String,
      );
    }
    await youtube.addDetails(candidates.values.toList());

    // 3) Haiku picks.
    final list = candidates.values.map((v) {
      final desc = v.description.replaceAll(RegExp(r'\s+'), ' ');
      final shortDesc = desc.length > 200 ? '${desc.substring(0, 200)}…' : desc;
      return '- id: ${v.id} | "${v.title}" | canal: ${v.channel} | '
          'duración: ${v.duration ?? '?'} | vistas: ${v.views ?? '?'} | $shortDesc';
    }).join('\n');

    final ranked = await claude.json(
      system: _system,
      schema: _pickSchema,
      prompt: '''
Vehículo: $vehicle.
Código de falla: $code — $description

Estos son videos de YouTube encontrados:
$list

Elige hasta 3 videos que más ayuden a diagnosticar y reparar ESTE código en ESTE vehículo, el mejor primero.
- Primero el título: debe mencionar el código ($code) o el componente/síntoma concreto, Y el mismo vehículo o uno de la misma marca, generación y plataforma (que comparta computadora y arneses).
- Descarta Shorts (menos de 1:00), videos de otros códigos o vehículos sin relación, reseñas de escáneres y publicidad.
- Ante dos opciones parecidas, prefiere la que muestra la prueba o reparación paso a paso.
- Si ninguno sirve, devuelve la lista vacía.
- Usa el id exacto de la lista. En "reason" explica en una frase qué muestra el video y por qué sirve.''',
    );

    final picks = <VideoPick>[];
    for (final p in (ranked['picks'] as List).cast<Map<String, dynamic>>()) {
      final video = candidates[p['video_id']];
      // Ignore invented or repeated ids.
      if (video != null && picks.every((x) => x.video.id != video.id)) {
        picks.add(VideoPick(video, p['reason'] as String));
      }
      if (picks.length == 3) break;
    }

    return VideoSearchResult(
      picks: picks,
      queries: queries.map((q) => q.query).toList(),
      likelyFix: plan['likely_fix'] as String,
    );
  }
}
