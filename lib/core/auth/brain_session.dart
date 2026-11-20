import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../mailbox/cerebro_client.dart';
import 'identity_provider.dart';

enum SessionStatus { loading, signedOut, signedIn }

class BrainSession extends ChangeNotifier {
  BrainSession({required this.client, required this.identity, FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final CerebroClient client;
  final IdentityProvider identity;
  final FlutterSecureStorage _storage;

  static const _tokenKey = 'cerebro_token';
  static const _userKey = 'cerebro_user';
  static const _legacyCodeKey = 'cerebro_code';

  SessionStatus _status = SessionStatus.loading;
  String? _token;
  String _userName = '';
  String? _error;

  SessionStatus get status => _status;
  String get userName => _userName;
  String? get error => _error;

  Future<void> restore() async {
    await _safe(() => _storage.delete(key: _legacyCodeKey));
    final saved = await _safe<String?>(() => _storage.read(key: _tokenKey));
    if (saved != null && saved.isNotEmpty) {
      _token = saved;
      _userName = await _safe<String?>(() => _storage.read(key: _userKey)) ?? '';
      _set(SessionStatus.signedIn);
      return;
    }
    final idToken = await identity.silentIdToken();
    if (idToken == null) return _set(SessionStatus.signedOut);
    await _loginOrSignOut(idToken);
  }

  Future<void> signIn() async {
    _error = null;
    _set(SessionStatus.loading);
    try {
      await _loginOrSignOut(await identity.interactiveIdToken());
    } on SignInCanceled {
      _set(SessionStatus.signedOut);
    } on SignInFailed catch (e) {
      _error = e.message;
      _set(SessionStatus.signedOut);
    }
  }

  Future<void> signOut() async {
    _token = null;
    _userName = '';
    await _safe(() => _storage.delete(key: _tokenKey));
    await _safe(() => _storage.delete(key: _userKey));
    await _safe(identity.signOut);
    _set(SessionStatus.signedOut);
  }

  Future<T> withToken<T>(Future<T> Function(String token) action) async {
    final token = _token;
    if (token == null) throw CerebroException('Vuelve a entrar con tu cuenta de Google.', sessionExpired: true);
    try {
      return await action(token);
    } on CerebroException catch (e) {
      if (!e.sessionExpired) rethrow;
      final idToken = await identity.silentIdToken();
      if (idToken == null) {
        await signOut();
        rethrow;
      }
      await _login(idToken);
      return action(_token!);
    }
  }

  Future<void> _loginOrSignOut(String idToken) async {
    try {
      await _login(idToken);
      _set(SessionStatus.signedIn);
    } on CerebroException catch (e) {
      _error = e.message;
      _set(SessionStatus.signedOut);
    }
  }

  Future<void> _login(String idToken) async {
    final session = await client.loginWithGoogle(idToken);
    _token = session.token;
    _userName = session.userName;
    await _safe(() => _storage.write(key: _tokenKey, value: session.token));
    await _safe(() => _storage.write(key: _userKey, value: session.userName));
  }

  void _set(SessionStatus s) {
    _status = s;
    notifyListeners();
  }

  static Future<T?> _safe<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }
}
