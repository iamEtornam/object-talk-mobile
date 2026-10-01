import 'dart:io';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth/sign_in_screen.dart';
import 'camera/camera_screen.dart';
import 'firebase_options.dart';
import 'ui/theme.dart';
import 'voice/voice.dart';

/// Android's Google Sign-In needs the project's *web* OAuth client id. It is
/// read from google-services.json once `flutterfire configure` has added
/// Android; this define overrides it when needed.
const _serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Same App Check setup as the Swift app: debug provider for dev and profile builds
  // (register the printed token in the console), attestation in release.
  await FirebaseAppCheck.instance.activate(
    providerApple: !kReleaseMode ? const AppleDebugProvider() : const AppleAppAttestWithDeviceCheckFallbackProvider(),
    providerAndroid: !kReleaseMode ? const AndroidDebugProvider() : const AndroidPlayIntegrityProvider(),
  );
  await GoogleSignIn.instance.initialize(
    clientId: Platform.isIOS ? DefaultFirebaseOptions.ios.iosClientId : null,
    serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
  );
  await Voice.configureAudioSession();
  runApp(const ObjectTalkApp());
}

class ObjectTalkApp extends StatelessWidget {
  const ObjectTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Object Talk',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const ColoredBox(color: Palette.ink);
          }
          return snapshot.data == null ? const SignInScreen() : const CameraScreen();
        },
      ),
    );
  }
}
