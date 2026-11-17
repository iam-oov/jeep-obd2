import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../solutions/cerebro_client.dart';
import 'widgets.dart';

/// "Buzón": send improvement requests for this app to coordinating-brain,
/// follow their status, and download the latest APK built from them.
class MailboxScreen extends StatefulWidget {
  const MailboxScreen({super.key, this.client, this.codeStore, this.openUrl});

  /// For tests.
  final CerebroClient? client;
  final CerebroCodeStore? codeStore;
  final Future<bool> Function(Uri url)? openUrl;

  @override
  State<MailboxScreen> createState() => _MailboxScreenState();
}

enum _Phase { loading, needCode, ready }

class _MailboxScreenState extends State<MailboxScreen> {
  late final CerebroClient _client = widget.client ?? CerebroClient();
  late final CerebroCodeStore _codes = widget.codeStore ?? CerebroCodeStore();
  final _codeField = TextEditingController();
  final _textField = TextEditingController();

  _Phase _phase = _Phase.loading;
  CerebroSession? _session;
  List<CerebroRequest> _requests = const [];
  String? _error;
  bool _busy = false;

  static const _minLength = 16;
  static const _maxLength = 280;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _codeField.dispose();
    _textField.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final code = await _codes.load();
    if (code == null) {
      if (mounted) setState(() => _phase = _Phase.needCode);
      return;
    }
    await _login(code, saveCode: false);
  }

  Future<void> _login(String code, {bool saveCode = true}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await _client.login(code);
      if (saveCode) await _codes.save(code);
      _session = session;
      _requests = session.hasAccess ? await _client.requests(session.token) : const [];
      if (mounted) setState(() => _phase = _Phase.ready);
    } on CerebroException catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.needCode;
          _error = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeCode() async {
    await _codes.clear();
    _codeField.clear();
    setState(() {
      _session = null;
      _requests = const [];
      _error = null;
      _phase = _Phase.needCode;
    });
  }

  /// Runs [action]; a 401 means the session expired, so log in again once.
  Future<T?> _withSession<T>(Future<T> Function(String token) action) async {
    final s = _session;
    if (s == null) return null;
    try {
      return await action(s.token);
    } on CerebroException catch (e) {
      if (!e.sessionExpired) rethrow;
      final code = await _codes.load();
      if (code == null) rethrow;
      _session = await _client.login(code);
      return await action(_session!.token);
    }
  }

  Future<void> _refresh() async {
    try {
      final code = await _codes.load();
      if (code != null) _session = await _client.login(code);
      final list = await _withSession(_client.requests);
      if (mounted) setState(() => _requests = list ?? _requests);
    } on CerebroException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _send() async {
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
      final created = await _withSession((t) => _client.send(t, text));
      if (created != null) {
        _textField.clear();
        setState(() => _requests = [created, ..._requests]);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Solicitud enviada. Se revisa antes de implementarse.')),
          );
        }
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
      final url = await _withSession(_client.downloadLink);
      if (url == null) return;
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
        title: const Text('Buzón'),
        actions: [
          if (_phase == _Phase.ready)
            IconButton(tooltip: 'Cambiar código', icon: const Icon(Icons.logout), onPressed: _changeCode),
        ],
      ),
      body: switch (_phase) {
        _Phase.loading => ListView(children: const [ProgressCard(text: 'Conectando con el cerebro…')]),
        _Phase.needCode => _codeForm(),
        _Phase.ready => RefreshIndicator(onRefresh: _refresh, child: _ready()),
      },
    );
  }

  Widget _codeForm() {
    void submit() {
      final code = _codeField.text.trim();
      if (RegExp(r'^\d{4}$').hasMatch(code)) _login(code);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Escribe tu código de 4 dígitos. Con él puedes pedir mejoras para esta app y '
          'descargar la versión más reciente.',
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('cerebro-code'),
          controller: _codeField,
          keyboardType: TextInputType.number,
          maxLength: 4,
          obscureText: true,
          autofocus: true,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: 'Código',
            errorText: _error,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => submit(),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: _busy ? null : submit, child: Text(_busy ? 'Entrando…' : 'Entrar')),
      ],
    );
  }

  Widget _ready() {
    final theme = Theme.of(context);
    final s = _session!;
    final latest = s.latest;
    final open = _requests.any((r) => r.isOpen);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (_error != null) ErrorBanner(message: _error!, onClose: () => setState(() => _error = null)),
        if (!s.hasAccess)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Tu código no tiene acceso a esta app. Pide que te la asignen.'),
          )
        else ...[
          Card(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: ListTile(
              leading: const Icon(Icons.system_update),
              title: Text(latest == null ? 'Todavía no hay versiones nuevas' : 'Versión más reciente: v${latest.versionCode}'),
              subtitle: latest == null ? null : Text(_fmt(latest.createdAt)),
              trailing: latest == null
                  ? null
                  : FilledButton(key: const Key('download-apk'), onPressed: _download, child: const Text('Descargar')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('Hola, ${s.userName}. ¿Qué mejorarías de la app?', style: theme.textTheme.titleSmall),
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
                Expanded(child: Text(_fmt(r.createdAt), style: theme.textTheme.bodySmall)),
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

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }
}
