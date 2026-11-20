import 'dart:convert';

import 'package:http/http.dart' as http;

/// Server of coordinating-brain, which receives improvement requests for this
/// app and publishes the APK built from them.
const cerebroBaseUrl = 'https://cerebro.valdoh.com';

/// This app's id on the brain.
const cerebroAppSlug = 'jeep-obd2';

class CerebroException implements Exception {
  CerebroException(this.message, {this.sessionExpired = false});

  /// Plain-language message for the user (Spanish).
  final String message;

  final bool sessionExpired;

  @override
  String toString() => message;
}

class CerebroBuild {
  const CerebroBuild({required this.versionCode, required this.commit, required this.createdAt});

  final int versionCode;
  final String commit;
  final DateTime createdAt;

  static CerebroBuild? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    return CerebroBuild(
      versionCode: (j['versionCode'] as num).toInt(),
      commit: j['commit'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch((j['createdAt'] as num).toInt()),
    );
  }
}

class CerebroRequest {
  const CerebroRequest({
    required this.id,
    required this.text,
    required this.status,
    required this.statusLabel,
    required this.createdAt,
    this.reason,
    this.build,
  });

  final int id;
  final String text;

  /// pending, approved, rejected, running, built, failed or discarded.
  final String status;
  final String statusLabel;
  final String? reason;
  final DateTime createdAt;

  /// The APK this request produced, when it is built.
  final CerebroBuild? build;

  bool get isOpen => status == 'pending' || status == 'approved' || status == 'running';

  static CerebroRequest fromJson(Map<String, dynamic> j) => CerebroRequest(
        id: (j['id'] as num).toInt(),
        text: j['text'] as String,
        status: j['status'] as String,
        statusLabel: j['statusLabel'] as String? ?? j['status'] as String,
        reason: j['reason'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch((j['createdAt'] as num).toInt()),
        build: CerebroBuild.fromJson(j['build']),
      );
}

class CerebroSession {
  const CerebroSession({required this.token, required this.userName});

  final String token;
  final String userName;
}

class CerebroAppStatus {
  const CerebroAppStatus({required this.hasAccess, this.latest});

  final bool hasAccess;
  final CerebroBuild? latest;
}

/// Minimal client for the coordinating-brain API.
class CerebroClient {
  CerebroClient({http.Client? httpClient, this.baseUrl = cerebroBaseUrl, this.appSlug = cerebroAppSlug})
      : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String appSlug;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Future<CerebroSession> loginWithGoogle(String idToken) async {
    final data = await _send('POST', '/api/login/google', body: {'idToken': idToken, 'app': appSlug});
    return CerebroSession(
      token: data['token'] as String,
      userName: (data['user'] as Map?)?['name'] as String? ?? '',
    );
  }

  Future<CerebroAppStatus> appStatus(String token) async {
    final data = await _send('GET', '/api/apps', token: token);
    final apps = (data['apps'] as List? ?? const []).cast<Map<String, dynamic>>();
    final mine = apps.where((a) => a['slug'] == appSlug).firstOrNull;
    return CerebroAppStatus(hasAccess: mine != null, latest: CerebroBuild.fromJson(mine?['latest']));
  }

  Future<List<CerebroRequest>> requests(String token) async {
    final data = await _send('GET', '/api/apps/$appSlug/requests', token: token);
    return [
      for (final r in (data['requests'] as List? ?? const []).cast<Map<String, dynamic>>()) CerebroRequest.fromJson(r),
    ];
  }

  Future<CerebroRequest> send(String token, String text) async {
    final data = await _send('POST', '/api/apps/$appSlug/requests', token: token, body: {'text': text});
    return CerebroRequest.fromJson(data['request'] as Map<String, dynamic>);
  }

  /// One-time URL (valid 10 minutes) that downloads the latest APK in the browser.
  Future<Uri> downloadLink(String token) async {
    final data = await _send('POST', '/api/apps/$appSlug/download-link', token: token);
    return Uri.parse(data['url'] as String);
  }

  Future<Map<String, dynamic>> _send(String method, String path, {String? token, Map<String, Object?>? body}) async {
    final req = http.Request(method, _uri(path));
    req.headers['accept'] = 'application/json';
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req)).timeout(const Duration(seconds: 20));
    } catch (_) {
      throw CerebroException('No se pudo contactar al cerebro. Revisa tu conexión a internet.');
    }
    Map<String, dynamic> data = const {};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300) return data;
    final message = data['error'] as String?;
    if (res.statusCode == 401 && token != null) {
      throw CerebroException(message ?? 'Sesión vencida.', sessionExpired: true);
    }
    throw CerebroException(message ?? 'El cerebro respondió con un error (${res.statusCode}).');
  }
}
