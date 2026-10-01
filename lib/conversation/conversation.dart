import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/persona.dart';
import '../voice/voice.dart';

class Message {
  Message({required this.fromUser, required this.text, this.streaming = false});
  final bool fromUser;

  /// Display text (no markdown, no vocal cues).
  String text;
  bool streaming;
  bool failed = false;
}

/// One conversation with a scanned object: transcript, streamed replies, and
/// speech that starts on the first finished sentence.
class Conversation extends ChangeNotifier {
  Conversation(this.persona, this.speaker, {required Stream<String> Function(String message) reply})
      : _reply = reply, // ignore: prefer_initializing_formals (public name reads better)
        messages = [Message(fromUser: false, text: displayText(persona.greeting))];

  final Persona persona;
  final Speaker speaker;
  final Stream<String> Function(String message) _reply;
  final List<Message> messages;
  final _splitter = SentenceSplitter();
  StreamSubscription<String>? _stream;
  bool _disposed = false;

  bool get isStreaming => _stream != null;

  /// The greeting goes to TTS in one piece so it is performed as one breath.
  void speakGreeting() => speaker.enqueue(persona.greeting);

  /// Send [text] and stream the in-character reply. Ignored while a reply is
  /// still arriving or when [text] is blank.
  void send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || isStreaming) return;

    // The person talking over the object cuts it off.
    speaker.stop();
    messages.add(Message(fromUser: true, text: trimmed));
    final reply = Message(fromUser: false, text: '', streaming: true);
    messages.add(reply);
    _splitter.reset();
    var raw = '';
    var spokeFirst = false;
    final rest = <String>[];

    void finish({required bool failed}) {
      reply
        ..streaming = false
        ..failed = failed;
      _stream = null;
      if (!failed) {
        rest.addAll(_splitter.take(raw, isFinal: true));
        // The opening sentence starts the voice early; the rest is one call so
        // it keeps a natural flow instead of a stitched, per-sentence rhythm.
        if (!spokeFirst && rest.isNotEmpty) speaker.enqueue(rest.removeAt(0));
        if (rest.isNotEmpty) speaker.enqueue(rest.join(' '));
      }
      _notify();
    }

    _stream = _reply(trimmed).listen(
      (chunk) {
        raw += chunk;
        reply.text = displayText(raw);
        final done = _splitter.take(raw);
        if (!spokeFirst && done.isNotEmpty) {
          speaker.enqueue(done.removeAt(0));
          spokeFirst = true;
        }
        rest.addAll(done);
        _notify();
      },
      onError: (Object e) {
        debugPrint('Chat stream failed: $e');
        finish(failed: true);
      },
      onDone: () => finish(failed: false),
      cancelOnError: true,
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stream?.cancel();
    speaker.stop();
    super.dispose();
  }
}
