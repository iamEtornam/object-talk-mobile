# Object Talk (Flutter)

Flutter port of the Swift `object-talk-app`. Sign in with Google and point the
camera at an object. When you scan it, the camera shuts off, the frame
freezes, and the object lifts out of the photo. It hovers, talks in its own
Gemini voice, and answers questions about itself, but only about itself
("I'm a shoe, not a car").

| Piece | Swift app | Here |
| --- | --- | --- |
| Auth | Firebase + GoogleSignIn | `firebase_auth` + `google_sign_in` 7 (`lib/auth/`) |
| Identify + persona | `FirebaseAIEngines` / `PersonaBuilder` | `firebase_ai`, `gemini-3.8-flash` (`lib/ai/`) |
| Subject cutout | Vision `SubjectCutout` | Vision on iOS (`ios/Runner/AppDelegate.swift`), ML Kit on Android (`MainActivity.kt`), `lib/vision/` |
| Hovering character | RealityKit card | `lib/camera/object_stage.dart`: lift-out, hover, tilt parallax, voice-driven motion |
| Voice out | Gemini TTS via backend | Gemini TTS via Firebase AI Logic, `gemini-3.1-flash-tts-preview` (`lib/voice/`) |
| Voice in | `SFSpeechRecognizer` | `speech_to_text` |

The persona builder casts a specific character from what the photo shows (wear,
setting, condition): a personality, speech habits, one of Gemini's 30 voices and
a director's note for how it should sound. The chat keeps the photo in context.

## Run

Needs a physical device. The AR camera doesn't run in the simulator.

```bash
flutter pub get
flutter run
```

## One-time Firebase setup

- **iOS** reuses the Swift app's Firebase iOS app (`dev.etornam.ObjectTalk`).
  Debug builds use the App Check debug provider. Register the token printed in the
  Xcode console under Firebase Console → App Check → Manage debug tokens.
- **Android**: add the debug SHA-1 for Google Sign-In (`cd android && ./gradlew signingReport`).
- Firebase AI Logic must be enabled. TTS tries the Agent Platform backend first and
  falls back to the Gemini Developer API.

## Tests

```bash
flutter analyze && flutter test
```

Gambarino (the objects' voice on screen) is from Fontshare under the Fontshare
Free License (`assets/fonts/FFL.txt`).
