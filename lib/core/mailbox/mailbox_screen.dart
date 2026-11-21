import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core_scope.dart';
import '../widgets.dart';
import 'cerebro_client.dart';

abstract class VoiceDictation {
  Future<bool> start({
    required void Function(String words) onWords,
    required void Function(String code) onError,
    required void Function() onDone,
  });

  Future<void> stop();
}

class SpeechToTextDictation implements VoiceDictation {
  SpeechToTextDictation({SpeechToText? speech}) : _speech = speech ?? SpeechToText();

  static const _firstWordsWindow = Duration(seconds: 8);
  static const _preferredSpanish = ['es_MX', 'es_US', 'es_419'];
  static const _fallbackSpanish = 'es_MX';

  final SpeechToText _speech;
  bool _ready = false;
  String _localeId = _fallbackSpanish;
  bool _heard = false;
  void Function(String code)? _onError;
  void Function()? _onDone;

  @override
  Future<bool> start({
    required void Function(String words) onWords,
    required void Function(String code) onError,
    required void Function() onDone,
  }) async {
    try {
      if (!_ready) {
        _ready = await _speech.initialize(options: [SpeechToText.androidNoBluetooth]);
        if (_ready) _localeId = await _spanishLocaleId();
      }
      if (!_ready) return false;
      _speech
        ..statusListener = _status
        ..errorListener = _error;
      _heard = false;
      _onError = onError;
      _onDone = onDone;
      await _speech.listen(
        onResult: (r) {
          if (r.recognizedWords.trim().isNotEmpty) {
            _heard = true;
            onWords(r.recognizedWords);
          }
          if (r.finalResult) _end();
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
          listenFor: const Duration(minutes: 5),
          pauseFor: _firstWordsWindow,
          localeId: _localeId,
        ),
      );
      return true;
    } catch (_) {
      _onError = null;
      _onDone = null;
      return false;
    }
  }

  Future<String> _spanishLocaleId() async {
    try {
      final ids = (await _speech.locales()).map((l) => l.localeId).toList();
      for (final preferred in _preferredSpanish) {
        if (ids.contains(preferred)) return preferred;
      }
      return ids.firstWhere((id) => id.startsWith('es_'), orElse: () => _fallbackSpanish);
    } catch (_) {
      return _fallbackSpanish;
    }
  }

  void _status(String status) {
    if (status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) _end();
  }

  void _end() {
    if (!_heard) _onError?.call('error_no_match');
    _finish();
  }

  void _error(SpeechRecognitionError error) {
    if (!error.permanent) return;
    _onError?.call(error.errorMsg);
    _finish();
  }

  void _finish() {
    final done = _onDone;
    _onDone = null;
    _onError = null;
    done?.call();
  }

  @override
  Future<void> stop() async {
    final done = _onDone;
    _onDone = null;
    _onError = null;
    try {
      await _speech.stop();
    } finally {
      done?.call();
    }
  }
}

class MailboxScreen extends StatefulWidget {
  const MailboxScreen({super.key, this.openUrl, this.dictation});

  final Future<bool> Function(Uri url)? openUrl;
  final VoiceDictation? dictation;

  @override
  State<MailboxScreen> createState() => _MailboxScreenState();
}

enum _Phase { loading, ready }

class _MailboxScreenState extends State<MailboxScreen> {
  final _textField = TextEditingController();

  _Phase _phase = _Phase.loading;
  CerebroAppStatus _app = const CerebroAppStatus(hasAccess: false);
  List<CerebroRequest> _requests = const [];
  String? _error;
  bool _busy = false;
  bool _listening = false;
  String _lastWords = '';
  Timer? _silenceTimer;
  late final VoiceDictation _dictation = widget.dictation ?? SpeechToTextDictation();

  static const _minLength = 16;
  static const _maxLength = 280;
  static const _silence = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    if (_listening) {
      _listening = false;
      _dictation.stop();
    }
    _textField.dispose();
    super.dispose();
  }

  Future<void> _toggleDictation() async {
    if (_listening) {
      await _dictation.stop();
      return;
    }
    _lastWords = '';
    setState(() {
      _listening = true;
      _error = null;
    });
    final ok = await _dictation.start(
      onWords: _onDictatedWords,
      onError: _onDictationError,
      onDone: _onDictationDone,
    );
    if (!ok && mounted) {
      setState(() {
        _listening = false;
        _error = 'No se pudo usar el micrófono. Revisa el permiso de grabar audio.';
      });
    }
  }

  void _onDictatedWords(String words) {
    if (!mounted || words.trim().isEmpty) return;
    final capitalized = '${words[0].toUpperCase()}${words.substring(1)}';
    final text = capitalized.length > _maxLength ? capitalized.substring(0, _maxLength) : capitalized;
    _textField.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (words != _lastWords) {
      _lastWords = words;
      _silenceTimer?.cancel();
      _silenceTimer = Timer(_silence, _dictation.stop);
    }
  }

  void _onDictationError(String code) {
    _silenceTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _error = _dictationErrorMessage(code);
    });
  }

  void _onDictationDone() {
    _silenceTimer?.cancel();
    if (mounted && _listening) setState(() => _listening = false);
  }

  static String _dictationErrorMessage(String code) => switch (code) {
        'error_no_match' || 'error_speech_timeout' => 'No se escuchó nada. Habla cerca del micrófono e inténtalo de nuevo.',
        'error_network' || 'error_network_timeout' => 'El dictado necesita internet.',
        'error_language_not_supported' || 'error_language_unavailable' =>
          'Tu teléfono no tiene el idioma del dictado instalado.',
        _ => 'El dictado falló ($code). Inténtalo de nuevo.',
      };

  Future<void> _refresh() async {
    final session = CoreScope.of(context);
    try {
      final app = await session.withToken(session.client.appStatus);
      final list = app.hasAccess ? await session.withToken(session.client.requests) : const <CerebroRequest>[];
      if (!mounted) return;
      setState(() {
        _app = app;
        _requests = list;
        _phase = _Phase.ready;
      });
    } on CerebroException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _phase = _Phase.ready;
        });
      }
    }
  }

  Future<void> _signOut() async {
    final navigator = Navigator.of(context);
    await CoreScope.of(context).signOut();
    navigator.popUntil((r) => r.isFirst);
  }

  Future<void> _send() async {
    final session = CoreScope.of(context);
    if (_listening) await _dictation.stop();
    if (!mounted) return;
    final text = _textField.text.trim();
    if (text.length < _minLength) {
      setState(() => _error = 'Escribe al menos $_minLength caracteres.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await session.withToken((t) => session.client.send(t, text));
      _textField.clear();
      setState(() => _requests = [created, ..._requests]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Solicitud enviada. Se revisa antes de implementarse.')),
        );
      }
    } on CerebroException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    setState(() => _error = null);
    try {
      final session = CoreScope.of(context);
      final url = await session.withToken(session.client.downloadLink);
      final open = widget.openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication);
      if (!await open(url) && mounted) setState(() => _error = 'No se pudo abrir el navegador.');
    } on CerebroException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sugerencias'),
        actions: [
          IconButton(
            key: const Key('core-sign-out'),
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
          ),
        ],
      ),
      body: switch (_phase) {
        _Phase.loading => ListView(children: const [CoreProgressCard(text: 'Conectando con el cerebro…')]),
        _Phase.ready => RefreshIndicator(onRefresh: _refresh, child: _ready()),
      },
    );
  }

  Widget _ready() {
    final theme = Theme.of(context);
    final latest = _app.latest;
    final open = _requests.any((r) => r.isOpen);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (_error != null) CoreErrorBanner(message: _error!, onClose: () => setState(() => _error = null)),
        if (!_app.hasAccess)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Tu cuenta todavía no tiene acceso a esta app.'),
          )
        else ...[
          Card(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: ListTile(
              leading: const Icon(Icons.system_update),
              title: Text(latest == null ? 'Todavía no hay versiones nuevas' : 'Versión más reciente: v${latest.versionCode}'),
              subtitle: latest == null ? null : Text(coreFormatDateTime(latest.createdAt)),
              trailing: latest == null
                  ? null
                  : FilledButton(key: const Key('download-apk'), onPressed: _download, child: const Text('Descargar')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'Hola, ${CoreScope.of(context).userName}. ¿Qué mejorarías de la app?',
              style: theme.textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              key: const Key('request-text'),
              controller: _textField,
              enabled: !_busy && !open,
              minLines: 2,
              maxLines: 5,
              maxLength: _maxLength,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: open
                    ? 'Ya tienes una solicitud en curso. Espera a que termine.'
                    : 'Ej. Mostrar la fecha de la última lectura de códigos',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const Key('dictate-request'),
                  tooltip: _listening ? 'Detener dictado' : 'Dictar por voz',
                  icon: Icon(_listening ? Icons.stop : Icons.mic),
                  color: _listening ? theme.colorScheme.error : null,
                  onPressed: _busy || open ? null : _toggleDictation,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('send-request'),
                onPressed: _busy || open ? null : _send,
                icon: const Icon(Icons.send),
                label: const Text('Enviar'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_requests.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Aún no has enviado solicitudes.'),
            )
          else
            for (final r in _requests) _requestTile(r),
        ],
      ],
    );
  }

  Widget _requestTile(CerebroRequest r) {
    final theme = Theme.of(context);
    final color = switch (r.status) {
      'built' => Colors.green,
      'failed' || 'rejected' || 'discarded' => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(coreFormatDateTime(r.createdAt), style: theme.textTheme.bodySmall)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(99)),
                  child: Text(r.statusLabel, style: theme.textTheme.labelSmall?.copyWith(color: color)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(r.text),
            if (r.build != null) ...[
              const SizedBox(height: 4),
              Text('Incluida en la versión v${r.build!.versionCode}', style: theme.textTheme.bodySmall),
            ],
            if (r.reason != null && r.reason!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(r.reason!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
