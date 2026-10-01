import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:object_talk/ai/gemini.dart';
import 'package:object_talk/ai/persona.dart';
import 'package:object_talk/conversation/conversation.dart';
import 'package:object_talk/vision/cutout.dart';
import 'package:object_talk/voice/voice.dart';

const _caseJson = '''
{
  "name": "Google Pixel Buds Pro charging case",
  "category": "technology",
  "description": "A pebble-shaped charging case for wireless earbuds.",
  "age_estimate": "made in 2022",
  "origin": "Vietnam",
  "interesting_facts": ["It charges over Qi.", "", "Its hinge is rated for thousands of opens."],
  "observations": ["a scuff on my lid", "lying on a beige couch arm"],
  "character_name": "Dot",
  "personality": "Fussy, loyal, convinced the owner will lose her in the couch.",
  "speech_habits": "Quick, clipped sentences and sighs.",
  "voice_name": "leda",
  "voice_direction": "early twenties, crisp London, quick, a little exasperated",
  "greeting": "[sighs] The couch again? I'm Dot, by the way. Keep me out of the cushions.",
  "box_2d": [400, 300, 600, 700],
  "confidence": "high"
}''';

class _FakeSpeaker implements Speaker {
  final lines = <String>[];
  var stops = 0;
  @override
  void enqueue(String line) => lines.add(line);
  @override
  Future<void> stop() async => stops++;
}

void main() {
  group('parsePersona', () {
    test('casts a character from the identification JSON', () {
      final p = parsePersona(_caseJson);
      expect(p.identifiedAs, 'Google Pixel Buds Pro charging case');
      expect(p.characterName, 'Dot');
      expect(p.category, ObjectCategory.other); // technology collapses to other
      expect(p.voiceName, 'Leda'); // matched case-insensitively
      expect(p.voiceDirection, contains('London'));
      expect(p.facts, hasLength(2)); // blank fact dropped
      expect(p.observations, contains('a scuff on my lid'));
      expect(p.box, const Rect.fromLTRB(0.3, 0.4, 0.7, 0.6));
    });

    test('tolerates markdown fences and prose around the JSON', () {
      expect(parsePersona('Sure!\n```json\n$_caseJson\n```').characterName, 'Dot');
    });

    test('falls back sensibly when optional fields are missing or invalid', () {
      final p = parsePersona('{"name": "Granite pebble", "category": "mineral", "voice_name": "Robot", "box_2d": [1, 2]}');
      expect(p.characterName, 'Granite pebble');
      expect(p.category, ObjectCategory.mineral);
      expect(p.voiceName, 'Sulafat');
      expect(p.box, isNull);
      expect(p.greeting, contains('granite pebble'));
    });

    test('ignores a degenerate box', () {
      expect(parsePersona('{"name": "x", "box_2d": [500, 500, 505, 900]}').box, isNull);
    });

    test('reports no object detected', () {
      expect(
        () => parsePersona('{"error": "no_object_detected", "reason": "blank wall"}'),
        throwsA(isA<NotIdentifiedException>().having((e) => e.reason, 'reason', 'blank wall')),
      );
    });

    test('rejects malformed output', () {
      expect(() => parsePersona('not json at all'), throwsA(isA<PersonaFormatException>()));
      expect(() => parsePersona('[1, 2]'), throwsA(isA<PersonaFormatException>()));
      expect(() => parsePersona('{"category": "food"}'), throwsA(isA<PersonaFormatException>()));
    });
  });

  test('identification prompt offers every Gemini voice and asks for a box', () {
    for (final voice in geminiVoices.keys) {
      expect(identificationPrompt, contains(voice));
    }
    expect(identificationPrompt, contains('box_2d'));
  });

  test('system prompt is human and stays on its own topic', () {
    final prompt = parsePersona(_caseJson).systemPrompt;
    expect(prompt, contains('You are Dot'));
    expect(prompt, contains('Fussy, loyal'));
    expect(prompt, contains('a scuff on my lid'));
    expect(prompt, contains('YOUR ONE TOPIC IS YOURSELF'));
    expect(prompt, contains('do NOT answer it'));
    expect(prompt, contains('a shoe says it is a shoe, not a car'));
    expect(prompt, contains('Never break character'));
  });

  test('displayText hides markdown and vocal cues', () {
    expect(displayText('**I** am _very_ `old`.'), 'I am very old.');
    expect(displayText('[sighs] The couch again? [laughs] Fine.'), 'The couch again? Fine.');
    expect(displayText('See [my maker](https://x.y) now'), 'See my maker now');
    expect(displayText('<chuckle> Fine. <short pause> Go on.'), 'Fine. Go on.');
  });

  test('speechText keeps only cues TTS performs, as its tags', () {
    expect(speechText('[laughs] **Mate**, no.'), '<laugh> Mate, no.');
    expect(speechText('[scoffs] A car? <sigh> Please.'), '<pff> A car? <sigh> Please.');
    expect(speechText('[dramatic music] Hi [winks] there'), 'Hi there');
    expect(speechText('Just words.'), 'Just words.');
  });

  group('SentenceSplitter', () {
    test('emits sentences as the stream completes them', () {
      final s = SentenceSplitter();
      expect(s.take('I was stitched in Vietnam'), isEmpty);
      expect(s.take('I was stitched in Vietnam. Then I flew'), ['I was stitched in Vietnam.']);
      expect(s.take('I was stitched in Vietnam. Then I flew far!'), isEmpty); // no boundary yet
      expect(s.take('I was stitched in Vietnam. Then I flew far! Ok', isFinal: true), ['Then I flew far!', 'Ok']);
    });

    test('does not cut on short abbreviations or decimals', () {
      expect(SentenceSplitter().take('Mr. Lee wore me 3.5 years. Yes'), ['Mr. Lee wore me 3.5 years.']);
    });
  });

  group('Conversation', () {
    late _FakeSpeaker speaker;
    late Persona persona;
    setUp(() {
      speaker = _FakeSpeaker();
      persona = parsePersona(_caseJson);
    });

    test('shows the greeting without cues and speaks it in one piece', () {
      final c = Conversation(persona, speaker, reply: (_) => const Stream.empty());
      expect(c.messages.single.text, "The couch again? I'm Dot, by the way. Keep me out of the cushions.");
      c.speakGreeting();
      expect(speaker.lines, [persona.greeting]);
    });

    test('speaks the first sentence early and the rest in one call', () async {
      final controller = StreamController<String>();
      final c = Conversation(persona, speaker, reply: (_) => controller.stream);
      c.send('  Tell me about cars  ');
      expect(c.messages[1].text, 'Tell me about cars');
      expect(speaker.stops, 1); // talking over the object cuts it off
      c.send('ignored while streaming');
      expect(c.messages, hasLength(3));

      controller.add('I am a **case**, not a car. ');
      await pumpEventQueue();
      expect(c.messages.last.text, 'I am a case, not a car. ');
      expect(speaker.lines, ['I am a **case**, not a car.']);

      controller.add('Engines? No idea. [laughs] Ask me about my hinge.');
      await controller.close();
      await pumpEventQueue();
      expect(c.isStreaming, isFalse);
      expect(c.messages.last.failed, isFalse);
      expect(c.messages.last.text, 'I am a case, not a car. Engines? No idea. Ask me about my hinge.');
      expect(speaker.lines, ['I am a **case**, not a car.', 'Engines? No idea. [laughs] Ask me about my hinge.']);
    });

    test('keeps partial text and flags a dropped stream without speaking the rest', () async {
      final controller = StreamController<String>();
      final c = Conversation(persona, speaker, reply: (_) => controller.stream);
      c.send('Hello');
      controller.add('I was made');
      controller.addError(Exception('network'));
      await pumpEventQueue();
      expect(c.messages.last.text, 'I was made');
      expect(c.messages.last.failed, isTrue);
      expect(c.isStreaming, isFalse);
      expect(speaker.lines, isEmpty);
    });

    test('ignores blank input', () {
      final c = Conversation(persona, speaker, reply: (_) => const Stream.empty());
      c.send('   ');
      expect(c.messages, hasLength(1));
    });
  });

  test('loudness envelope tracks speech and normalises to the peak', () {
    const rate = 24000;
    final samples = Int16List(rate); // 1 s: 0.5 s silence, then a tone
    for (var i = rate ~/ 2; i < rate; i++) {
      samples[i] = (math.sin(i * 0.1) * 12000).round();
    }
    final env = loudnessEnvelope(samples.buffer.asUint8List(), rate);
    expect(env.length, (1000 / envelopeStepMs).ceil());
    expect(env.first, 0);
    expect(env.last, closeTo(1, 0.05));
    expect(env.reduce(math.max), 1);
  });

  test('opaqueBounds finds the visible pixels inside a region', () {
    const w = 10, h = 8;
    final rgba = Uint8List(w * h * 4);
    void opaque(int x, int y) => rgba[(y * w + x) * 4 + 3] = 255;
    opaque(3, 2);
    opaque(6, 5);
    opaque(9, 7); // outside the search region below
    expect(opaqueBounds(rgba, w, h, const Rect.fromLTRB(0, 0, 8, 6)), const Rect.fromLTRB(3, 2, 7, 6));
    expect(opaqueBounds(Uint8List(w * h * 4), w, h, const Rect.fromLTRB(0, 0, 10, 8)), isNull);
  });

  group('speechFromAudio', () {
    test('passes raw PCM through and reads the rate from the mime type', () {
      final pcm = Uint8List.fromList([1, 2, 3, 4]);
      final speech = speechFromAudio(pcm, 'audio/L16;codec=pcm;rate=16000');
      expect(speech.pcm, pcm);
      expect(speech.sampleRate, 16000);
    });

    test('strips a WAV container and keeps its sample rate', () {
      final pcm = List<int>.generate(100, (i) => i);
      final b = BytesBuilder();
      void ascii(String t) => b.add(t.codeUnits);
      void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
      void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
      ascii('RIFF');
      u32(36 + 6 + pcm.length);
      ascii('WAVE');
      ascii('fmt ');
      u32(16);
      u16(1);
      u16(1);
      u32(22050);
      u32(44100);
      u16(2);
      u16(16);
      ascii('LIST'); // an extra chunk before "data" must be skipped
      u32(6);
      b.add([0, 0, 0, 0, 0, 0]);
      ascii('data');
      u32(pcm.length);
      b.add(pcm);
      final speech = speechFromAudio(b.toBytes(), 'audio/wav');
      expect(speech.sampleRate, 22050);
      expect(speech.pcm, pcm);
    });
  });
}
