
import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter/foundation.dart';

import 'persona.dart';

/// Firebase AI Logic for every AI call: identification, in-character chat and
/// Gemini text-to-speech. Auth is Firebase Auth + App Check, so no API key
/// ships in the app and there is no custom backend.
const _model = 'gemini-3.8-flash';

/// TTS models in order of preference: 3.8 for quality, Lite for speed, and the
/// 3.1 preview that Firebase AI Logic documents as a last resort.
const _ttsModels = ['gemini-3.8-flash-tts', 'gemini-3.8-flash-lite-tts', 'gemini-3.1-flash-tts-preview'];

FirebaseAI get _ai => FirebaseAI.agentPlatform();

/// Gemini 3 models take a thinking *level*; the 2.x-style `thinkingBudget: 0`
/// doesn't switch thinking off for them. `minimal` is rejected by
/// gemini-3.8-flash ("Thinking level is unsupported"), so use the lowest it takes.
final _fast = ThinkingConfig.withThinkingLevel(ThinkingLevel.low);

/// A reply that goes quiet this long is treated as dropped, not left spinning.
const _replyStall = Duration(seconds: 25);

/// Identify the object in [image] and cast its character.
/// Throws [NotIdentifiedException] or [PersonaFormatException].
Future<Persona> identifyObject(Uint8List image, {required String mimeType}) async {
  final model = _ai.generativeModel(
    model: _model,
    generationConfig: GenerationConfig(
      // Warm enough for an original character, cool enough for valid JSON.
      temperature: 0.9,
      maxOutputTokens: 1200,
      responseMimeType: 'application/json',
      thinkingConfig: _fast,
    ),
  );
  final clock = Stopwatch()..start();
  final response = await model.generateContent([
    Content.multi([TextPart(identificationPrompt), InlineDataPart(mimeType, image)]),
  ]);
  debugPrint('timing identify: ${clock.elapsedMilliseconds} ms');
  final text = response.text;
  if (text == null || text.isEmpty) {
    throw const PersonaFormatException('empty identification response');
  }
  return parsePersona(text);
}

/// One persona conversation. The [ChatSession] holds the history, opening with
/// the photo so the object can talk about what it actually looks like.
class PersonaChat {
  PersonaChat(Persona persona, {required Uint8List photo, required String mimeType})
      : _session = _ai
            .generativeModel(
              model: _model,
              generationConfig: GenerationConfig(
                temperature: 0.95,
                maxOutputTokens: 400,
                thinkingConfig: _fast,
              ),
              systemInstruction: Content.system(persona.systemPrompt),
            )
            .startChat(history: [
          // History must open with a user turn and alternate.
          Content.multi([
            InlineDataPart(mimeType, photo),
            TextPart('This is you. You have just come alive and noticed me looking at you.'),
          ]),
          Content.model([TextPart(persona.greeting)]),
        ]);

  final ChatSession _session;

  /// Streams reply text chunks for [message].
  Stream<String> reply(String message) {
    final clock = Stopwatch()..start();
    var chunks = 0;
    return _session
        .sendMessageStream(Content.text(message))
        .timeout(_replyStall)
        .map((r) => r.text ?? '')
        .where((t) => t.isNotEmpty)
        .map((t) {
      if (chunks++ == 0) debugPrint('timing chat first chunk: ${clock.elapsedMilliseconds} ms');
      return t;
    });
  }
}

/// Mono 16-bit PCM from Gemini TTS.
class Speech {
  const Speech(this.pcm, this.sampleRate);
  final Uint8List pcm;
  final int sampleRate;
}

/// Normalise TTS output to raw PCM. Older TTS models return headerless PCM
/// (`audio/L16;rate=24000`); 3.8 returns a WAV file by default.
@visibleForTesting
Speech speechFromAudio(Uint8List bytes, String mimeType) {
  final header = String.fromCharCodes(bytes.take(4));
  if (header == 'RIFF' && bytes.length > 44) {
    final view = ByteData.sublistView(bytes);
    final rate = view.getUint32(24, Endian.little);
    // Walk the chunks to "data"; headers are not always exactly 44 bytes.
    var at = 12;
    while (at + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(at, at + 4));
      final size = view.getUint32(at + 4, Endian.little);
      if (id == 'data') {
        return Speech(Uint8List.sublistView(bytes, at + 8, (at + 8 + size).clamp(0, bytes.length)), rate);
      }
      at += 8 + size + (size.isOdd ? 1 : 0);
    }
  }
  final rate = int.tryParse(RegExp(r'rate=(\d+)').firstMatch(mimeType)?.group(1) ?? '') ?? 24000;
  return Speech(bytes, rate);
}

// The first (backend, model) pair that produced audio, reused for the session.
(FirebaseAI, String)? _tts;

/// Speak [text] as [persona] with Gemini TTS. The persona's director's note
/// steers accent, pace and tone; [laughs]-style cues in [text] are performed.
Future<Speech> synthesize(String text, Persona persona) async {
  final prompt = 'Read the transcript aloud as ${persona.characterName}, a talking '
      '${persona.identifiedAs}, in a natural, conversational way, like a real person '
      'talking to a friend, not an announcer.\n'
      'Voice: ${persona.voiceDirection}.\n'
      'Transcript:\n$text';

  Future<Speech> run(FirebaseAI ai, String modelName) async {
    final model = ai.generativeModel(
      model: modelName,
      generationConfig: GenerationConfig(
        responseModalities: [ResponseModalities.audio],
        speechConfig: SpeechConfig(voiceName: persona.voiceName),
      ),
    );
    final clock = Stopwatch()..start();
    final response = await model.generateContent([Content.text(prompt)]);
    debugPrint('timing tts ($modelName): ${clock.elapsedMilliseconds} ms for ${text.length} chars');
    final audio = response.inlineDataParts.where((p) => p.mimeType.startsWith('audio/')).firstOrNull;
    if (audio == null) throw const PersonaFormatException('TTS returned no audio');
    return speechFromAudio(audio.bytes, audio.mimeType);
  }

  if (_tts case (final ai, final modelName)) return run(ai, modelName);

  Object? lastError;
  for (final modelName in _ttsModels) {
    for (final ai in [_ai, FirebaseAI.googleAI()]) {
      try {
        final speech = await run(ai, modelName);
        _tts = (ai, modelName);
        debugPrint('TTS using $modelName');
        return speech;
      } on FirebaseAIException catch (e) {
        // Model not served on this backend (or not enabled): try the next one.
        debugPrint('TTS $modelName unavailable: ${e.message}');
        lastError = e;
      }
    }
  }
  throw lastError ?? const PersonaFormatException('No TTS model available');
}
