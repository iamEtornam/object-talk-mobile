// On-device smoke test of the live AI path: Firebase + App Check + Gemini chat
// and Gemini TTS, without the camera. Run on a physical device:
//   flutter test integration_test/ai_smoke_test.dart -d <device-id>
import 'dart:io';
import 'dart:ui' as ui;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:object_talk/ai/gemini.dart';
import 'package:object_talk/ai/persona.dart';
import 'package:object_talk/firebase_options.dart';
import 'package:object_talk/voice/voice.dart';

const _shoe = '''
{
  "name": "Nike Air Max 90 running shoe",
  "category": "textile",
  "description": "A cushioned running shoe with a visible air unit in the heel.",
  "age_estimate": "made in 2019",
  "origin": "Vietnam",
  "interesting_facts": ["The visible air unit debuted in 1987.", "Its outsole is rubber with a waffle pattern."],
  "observations": ["a crease across my toe box", "grey mud on my left heel"],
  "character_name": "Max",
  "personality": "Proud, a little vain about his looks, secretly tired of the daily commute.",
  "speech_habits": "Short punchy sentences, sporty slang, a dry laugh.",
  "voice_name": "Puck",
  "voice_direction": "late twenties, upbeat London, quick, a little cocky",
  "greeting": "Oi, mind the crease. I'm Max. Ask me anything about the miles I've done."
}''';

Future<Uint8List> _photo() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 64, 64), ui.Paint()..color = const ui.Color(0xFF8A8478));
  final image = await recorder.endRecording().toImage(64, 64);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

Future<(String text, int firstChunkMs, int totalMs)> _ask(PersonaChat chat, String question) async {
  final clock = Stopwatch()..start();
  var first = -1;
  final buffer = StringBuffer();
  await for (final chunk in chat.reply(question).timeout(const Duration(seconds: 40))) {
    if (first < 0) first = clock.elapsedMilliseconds;
    buffer.write(chunk);
  }
  return (buffer.toString(), first, clock.elapsedMilliseconds);
}

/// Results also go to a file in the app's tmp dir, so they can be pulled off a
/// device where profile builds don't surface Flutter's log output:
///   xcrun devicectl device copy from --domain-type appDataContainer \
///     --domain-identifier dev.etornam.ObjectTalk --source tmp/smoke_result.txt ...
final _report = File('${Directory.systemTemp.path}/smoke_result.txt');

void _log(String line) {
  debugPrint(line);
  _report.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// Run [body], recording PASS/FAIL for it in the report.
Future<void> _recorded(String name, Future<void> Function() body) async {
  try {
    await body();
    _log('PASS $name');
  } catch (e) {
    _log('FAIL $name: $e');
    rethrow;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (_report.existsSync()) _report.deleteSync();

  late Persona persona;
  late PersonaChat chat;

  setUpAll(() async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await FirebaseAppCheck.instance.activate(
      providerApple: !kReleaseMode ? const AppleDebugProvider() : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      providerAndroid: !kReleaseMode ? const AndroidDebugProvider() : const AndroidPlayIntegrityProvider(),
    );
    persona = parsePersona(_shoe);
    chat = PersonaChat(persona, photo: await _photo(), mimeType: 'image/png');
  });

  testWidgets('chat replies quickly, in character, and refuses an off-topic question', (tester) =>
      _recorded('chat', () async {
    final (offTopic, firstMs, totalMs) = await _ask(chat, 'What do you know about cars? Explain how an engine works.');
    _log('SMOKE off-topic reply (${firstMs}ms to first chunk, ${totalMs}ms total): $offTopic');
    expect(offTopic.trim(), isNotEmpty);
    expect(firstMs, lessThan(15000), reason: 'first chunk should not stall');
    // It should identify as itself (in whatever words) and decline: "I'm an Air Max, not a motor".
    final lower = offTopic.toLowerCase();
    expect(['shoe', 'air max', 'sneaker', 'trainer', 'max'].any(lower.contains), isTrue,
        reason: 'should say what it is');
    expect(lower, anyOf(contains('not a'), contains("don't know"), contains('no idea')),
        reason: 'should decline the car question');

    final (onTopic, firstMs2, _) = await _ask(chat, 'What are you made of?');
    _log('SMOKE on-topic reply (${firstMs2}ms to first chunk): $onTopic');
    expect(onTopic.trim(), isNotEmpty);
  }));

  testWidgets('Gemini TTS returns playable speech', (tester) =>
      _recorded('tts', () async {
    final clock = Stopwatch()..start();
    final speech = await synthesize('Oi, mind the crease. I am Max.', persona);
    final seconds = speech.pcm.lengthInBytes / 2 / speech.sampleRate;
    _log('SMOKE tts: ${speech.pcm.lengthInBytes} bytes @ ${speech.sampleRate} Hz '
        '(${seconds.toStringAsFixed(2)} s audio) in ${clock.elapsedMilliseconds}ms');
    expect(speech.sampleRate, inInclusiveRange(8000, 48000));
    expect(seconds, greaterThan(0.5));
    // The envelope that drives the talking motion must be non-trivial.
    final envelope = loudnessEnvelope(speech.pcm, speech.sampleRate);
    expect(envelope.where((v) => v > 0.2), isNotEmpty);
  }));
}
