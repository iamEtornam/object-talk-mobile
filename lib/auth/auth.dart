import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Google → Firebase sign-in (port of the Swift `AuthService` Google path).
abstract final class Auth {
  /// Returns false when the user dismissed the Google sheet.
  static Future<bool> signInWithGoogle() async {
    final GoogleSignInAccount account;
    try {
      account = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) throw StateError('Google Sign-In did not return an ID token.');
    await FirebaseAuth.instance.signInWithCredential(GoogleAuthProvider.credential(idToken: idToken));
    return true;
  }

  static Future<void> signOut() async {
    await GoogleSignIn.instance.signOut();
    await FirebaseAuth.instance.signOut();
  }

  /// Human copy for a failed sign-in.
  static String describe(Object error) => switch (error) {
        GoogleSignInException(code: GoogleSignInExceptionCode.clientConfigurationError) =>
          'Google Sign-In isn’t configured for this build.',
        FirebaseAuthException(code: 'network-request-failed') => 'No connection. Check your network and try again.',
        FirebaseAuthException(:final message?) => message,
        _ => 'Couldn’t sign you in. Please try again.',
      };
}
