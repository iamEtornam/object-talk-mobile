import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../ai/gemini.dart';
import '../ai/persona.dart';

/// Splits streamed text into speakable sentences as they complete.
class SentenceSplitter {
  static const _terminators = {'.', '!', '?', '…'};

  /// Below this a terminator is ignored, so "Mr." or "3.5" don't cut a sentence.
  static const minSentenceLength = 12;

  int _offset = 0;

  void reset() => _offset = 0;

  /// Returns the sentences completed in [text] since the last call. With
  /// [isFinal], any trailing fragment is flushed too.
  List<String> take(String text, {bool isFinal = false}) {
    final out = <String>[];
    if (_offset > text.length) _offset = 0;
    var start = _offset;
    for (var i = _offset; i < text.length; i++) {
      if (!_terminators.contains(text[i])) continue;
      // Mid-stream, the chunk may end inside "3.5"; only whitespace proves a boundary.
      final boundary = i + 1 < text.length ? text[i + 1].trim().isEmpty : isFinal;
      if (boundary && i - start + 1 >= minSentenceLength) {
        out.add(text.substring(start, i + 1).trim());
        start = i + 1;
      }
    }
    _offset = start;
    if (isFinal && start < text.length) {
      out.add(text.substring(start).trim());
      _offset = text.length;
    }
    return out.where((s) => s.isNotEmpty).toList();
  }
}

/// A synthesized line ready to play, with its loudness envelope.
class _Clip {
  _Clip(Speech speech)
      : wav = encodeWav(speech.pcm, speech.sampleRate),
        envelope = loudnessEnvelope(speech.pcm, speech.sampleRate);
  final Uint8List wav;
  final List<double> envelope;
}

/// Envelope resolution: one loudness value per this many milliseconds.
const envelopeStepMs = 30;

/// RMS loudness of 16-bit mono PCM per [envelopeStepMs] window, normalised so
/// the loudest window is 1. Drives the object's talking motion.
List<double> loudnessEnvelope(Uint8List pcm, int sampleRate) {
  final samples = pcm.buffer.asByteData(pcm.offsetInBytes, pcm.lengthInBytes);
  final count = pcm.lengthInBytes ~/ 2;
  final window = math.max(1, sampleRate * envelopeStepMs ~/ 1000);
  final out = <double>[];
  for (var start = 0; start < count; start += window) {
    final end = math.min(count, start + window);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      final s = samples.getInt16(i * 2, Endian.little) / 32768;
      sum += s * s;
    }
    out.add(math.sqrt(sum / (end - start)));
  }
  final peak = out.fold(0.0, math.max);
  return peak == 0 ? out : out.map((v) => v / peak).toList();
}

/// Wrap raw PCM in a WAV header so the platform player can decode it.
Uint8List encodeWav(Uint8List pcm, int sampleRate) {
  final header = ByteData(44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header
    ..setUint32(16, 16, Endian.little) // PCM chunk size
    ..setUint16(20, 1, Endian.little) // linear PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little) // byte rate
    ..setUint16(32, 2, Endian.little) // block align
    ..setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .toBytes();
}

/// The bits of [Voice] a conversation needs; tests swap in a fake.
abstract interface class Speaker {
  void enqueue(String line);
  Future<void> stop();
}

/// The object's voice: Gemini TTS, played in order. Each line starts
/// synthesizing the moment it is queued, so the next one is usually ready
/// before the current one finishes.
class Voice implements Speaker {
  final _player = AudioPlayer();
  final _queue = <Future<_Clip?>>[];
  List<double> _envelope = const [];
  bool _draining = false;
  int _generation = 0;
  int _clipCounter = 0;
  Persona? _persona;

  final speaking = ValueNotifier(false);

  /// Shares a play-and-record session with speech recognition and routes to
  /// the loudspeaker, not the earpiece.
  static Future<void> configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.allowBluetoothA2dp,
      avAudioSessionMode: AVAudioSessionMode.spokenAudio,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.media,
      ),
    ));
  }

  /// Who is speaking; set once per conversation.
  set persona(Persona persona) => _persona = persona;

  /// Current loudness 0..1 of what is playing, for animation.
  double get level {
    if (!speaking.value || _envelope.isEmpty) return 0;
    final i = _player.position.inMilliseconds ~/ envelopeStepMs;
    return i < _envelope.length ? _envelope[i] : 0;
  }

  @override
  void enqueue(String line) {
    final persona = _persona;
    final text = speechText(line);
    if (persona == null || text.isEmpty) return;
    _queue.add(synthesize(text, persona).then<_Clip?>(
      (speech) => compute((Speech s) => _Clip(s), speech),
      onError: (Object e) {
        // Voice sits on top of the transcript; a failed line is skipped.
        debugPrint('TTS failed: $e');
        return null;
      },
    ));
    if (!_draining) _drain(_generation);
  }

  Future<void> _drain(int generation) async {
    _draining = true;
    try {
      while (_queue.isNotEmpty && generation == _generation) {
        final clip = await _queue.removeAt(0);
        if (clip == null || generation != _generation) continue;
        // A short-lived file: the most reliable source on both platforms.
        final file = File('${Directory.systemTemp.path}/object_talk_${generation}_${_clipCounter++}.wav');
        await file.writeAsBytes(clip.wav, flush: true);
        try {
          _envelope = clip.envelope;
          await _player.setFilePath(file.path);
          speaking.value = true;
          await _player.play(); // completes when the clip ends or is stopped
        } finally {
          unawaited(file.delete().then((_) {}, onError: (_) {}));
        }
      }
    } catch (e) {
      debugPrint('Playback failed: $e');
    } finally {
      if (generation == _generation) {
        _draining = false;
        speaking.value = false;
      }
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _queue.clear();
    _draining = false;
    speaking.value = false;
    await _player.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}

/// Tap-to-talk speech recognition. Finishes on its own after a pause.
class SpeechInput {
  final _stt = SpeechToText();
  bool _ready = false;
  double _peakLevel = double.negativeInfinity;

  final listening = ValueNotifier(false);
  final transcript = ValueNotifier('');

  /// Set when a listen ends without usable speech, for the UI to explain.
  final problem = ValueNotifier<String?>(null);

  /// Starts listening; [onFinal] gets the recognised text once speech ends.
  /// Returns false if permission was denied or recognition is unavailable.
  Future<bool> start(void Function(String text) onFinal) async {
    _ready = _ready ||
        await _stt.initialize(
          onStatus: (s) => listening.value = s == SpeechToText.listeningStatus,
          onError: (e) {
            // The level tells silence-from-the-mic apart from unclear speech.
            debugPrint('Speech error: ${e.errorMsg} (peak level $_peakLevel)');
            listening.value = false;
            transcript.value = '';
            problem.value = e.errorMsg == 'error_no_match' || e.errorMsg == 'error_speech_timeout'
                ? 'I didn’t catch that. Tap the mic and speak a little closer.'
                : 'Voice input stopped. Try again, or type your question.';
          },
        );
    if (!_ready) return false;

    // Hand the audio session over cleanly: the voice player may still hold it
    // in playback mode, which leaves the recognizer with a silent mic.
    try {
      await (await AudioSession.instance).setActive(false);
    } catch (e) {
      debugPrint('Could not release audio session before listening: $e');
    }

    transcript.value = '';
    problem.value = null;
    _peakLevel = double.negativeInfinity;
    await _stt.listen(
      onResult: (r) {
        transcript.value = r.recognizedWords;
        if (r.finalResult) {
          listening.value = false;
          final text = r.recognizedWords.trim();
          transcript.value = '';
          if (text.isNotEmpty) onFinal(text);
        }
      },
      onSoundLevelChange: (level) => _peakLevel = math.max(_peakLevel, level),
      listenOptions: SpeechListenOptions(
        // Free-form questions, not yes/no (the plugin default is confirmation).
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 45),
      ),
    );
    listening.value = true;
    return true;
  }

  Future<void> stop() async {
    await _stt.stop();
    listening.value = false;
  }
}
