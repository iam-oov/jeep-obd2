import 'package:google_sign_in/google_sign_in.dart';

const googleServerClientId = '270967585578-m2huerpvv6m5kn2fcse8g0aosi59h0fc.apps.googleusercontent.com';

class SignInCanceled implements Exception {}

class SignInFailed implements Exception {
  SignInFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class IdentityProvider {
  Future<String?> silentIdToken();

  Future<String> interactiveIdToken();

  Future<void> signOut();
}

class GoogleIdentityProvider implements IdentityProvider {
  GoogleIdentityProvider({GoogleSignIn? signIn}) : _signIn = signIn ?? GoogleSignIn.instance;

  final GoogleSignIn _signIn;
  Future<void>? _ready;

  Future<void> _init() => _ready ??= _signIn.initialize(serverClientId: googleServerClientId);

  @override
  Future<String?> silentIdToken() async {
    try {
      await _init();
      final account = await (_signIn.attemptLightweightAuthentication() ?? Future.value());
      return account?.authentication.idToken;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> interactiveIdToken() async {
    await _init();
    try {
      final token = (await _signIn.authenticate()).authentication.idToken;
      if (token == null) throw SignInFailed('Google no entregó un token. Intenta de nuevo.');
      return token;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled || e.code == GoogleSignInExceptionCode.interrupted) {
        throw SignInCanceled();
      }
      throw SignInFailed('No se pudo entrar con Google (${e.code.name}).');
    }
  }

  @override
  Future<void> signOut() async {
    await _init();
    await _signIn.signOut();
  }
}
