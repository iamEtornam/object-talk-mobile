import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_thinking_orbs/flutter_thinking_orbs.dart';

import '../ui/theme.dart';
import '../voice/voice.dart';
import 'conversation.dart';

/// Bottom sheet under the hovering object. Compact by default (who it is, the
/// latest exchange, the input); tap the handle for the whole transcript.
class ConversationPanel extends StatefulWidget {
  const ConversationPanel({
    super.key,
    required this.conversation,
    required this.speaking,
    required this.topFraction,
  });

  final Conversation conversation;
  final ValueNotifier<bool> speaking;

  /// The compact panel never rises above this fraction of the screen height,
  /// so the object above it stays in view.
  final double topFraction;

  @override
  State<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends State<ConversationPanel> {
  final _input = TextEditingController();
  final _speech = SpeechInput();
  bool _expanded = false;

  Conversation get _c => widget.conversation;

  @override
  void initState() {
    super.initState();
    _speech.problem.addListener(_showSpeechProblem);
  }

  void _showSpeechProblem() {
    final problem = _speech.problem.value;
    if (problem == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(problem)));
  }

  @override
  void dispose() {
    _speech.problem.removeListener(_showSpeechProblem);
    _speech.stop();
    _input.dispose();
    super.dispose();
  }

  void _send([String? text]) {
    final value = text ?? _input.text;
    if (value.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    _c.send(value);
    _input.clear();
  }

  Future<void> _toggleMic() async {
    HapticFeedback.selectionClick();
    if (_speech.listening.value) {
      await _speech.stop();
      return;
    }
    // Don't record the object's own voice.
    await _c.speaker.stop();
    final ok = await _speech.start(_send);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Allow microphone and speech recognition in Settings to talk out loud.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final accent = Palette.accent(_c.persona.category);
    final keyboard = mq.viewInsets.bottom;
    final available = mq.size.height - keyboard - mq.padding.top - 8;
    final maxHeight = _expanded ? available * 0.82 : math.min(available, mq.size.height * (1 - widget.topFraction));

    return Align(
      alignment: Alignment.bottomCenter,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboard),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: Palette.ink,
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12 + (keyboard > 0 ? 0 : mq.padding.bottom)),
                child: ListenableBuilder(
                  listenable: _c,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Handle(expanded: _expanded, onTap: () => setState(() => _expanded = !_expanded)),
                      _Header(conversation: _c, speaking: widget.speaking, accent: accent),
                      const SizedBox(height: 12),
                      Flexible(
                        child: _expanded
                            ? _Transcript(messages: _c.messages)
                            : _Latest(messages: _c.messages),
                      ),
                      const SizedBox(height: 12),
                      _InputRow(
                        controller: _input,
                        speech: _speech,
                        accent: accent,
                        hint: 'Ask ${_c.persona.characterName} something…',
                        enabled: !_c.isStreaming,
                        onSend: _send,
                        onMic: _toggleMic,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle({required this.expanded, required this.onTap});
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: expanded ? 'Show less' : 'Show whole conversation',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if ((v < -200 && !expanded) || (v > 200 && expanded)) onTap();
        },
        child: SizedBox(
          height: 26,
          child: Center(
            child: Container(
              width: 38,
              height: 5,
              decoration: BoxDecoration(color: Palette.inkLine, borderRadius: BorderRadius.circular(3)),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.conversation, required this.speaking, required this.accent});
  final Conversation conversation;
  final ValueNotifier<bool> speaking;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final p = conversation.persona;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                p.characterName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: voiceFont, fontSize: 30, height: 1.15, color: Palette.bone),
              ),
            ),
            const SizedBox(width: 12),
            _SpeakingBars(speaking: speaking, color: accent),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          p.identifiedAs,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, height: 1.3, color: accent),
        ),
      ],
    );
  }
}

/// Compact view: the newest line from the object, with the question that
/// prompted it above, scrollable if long.
class _Latest extends StatelessWidget {
  const _Latest({required this.messages});
  final List<Message> messages;

  @override
  Widget build(BuildContext context) {
    final last = messages.last;
    final question = messages.length >= 2 && messages[messages.length - 2].fromUser ? messages[messages.length - 2] : null;
    return SingleChildScrollView(
      reverse: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (question != null) ...[_UserLine(text: question.text), const SizedBox(height: 12)],
          if (last.fromUser) _UserLine(text: last.text) else _ObjectLine(message: last),
        ],
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.messages});
  final List<Message> messages;

  @override
  Widget build(BuildContext context) {
    // Reversed so the newest line stays pinned to the bottom as it streams.
    return ListView.builder(
      reverse: true,
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final m = messages[messages.length - 1 - i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: m.fromUser ? _UserLine(text: m.text) : _ObjectLine(message: m),
        );
      },
    );
  }
}

class _ObjectLine extends StatelessWidget {
  const _ObjectLine({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final waiting = message.streaming && message.text.trim().isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (waiting)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: ThinkingOrb(state: OrbState.composing, size: 28, theme: OrbTheme.dark, semanticLabel: 'Thinking'),
          )
        else
          Text(
            message.text,
            style: const TextStyle(fontFamily: voiceFont, fontSize: 21, height: 1.36, color: Palette.bone),
          ),
        if (message.failed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              message.text.isEmpty ? 'I lost my words. Ask me again?' : 'The connection dropped mid-sentence.',
              style: const TextStyle(fontSize: 13, color: Palette.warn),
            ),
          ),
      ],
    );
  }
}

class _UserLine extends StatelessWidget {
  const _UserLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.72),
        child: DecoratedBox(
          decoration: BoxDecoration(color: Palette.inkRaised, borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(text, style: const TextStyle(fontSize: 15, height: 1.4, color: Palette.bone)),
          ),
        ),
      ),
    );
  }
}

class _InputRow extends StatelessWidget {
  const _InputRow({
    required this.controller,
    required this.speech,
    required this.accent,
    required this.hint,
    required this.enabled,
    required this.onSend,
    required this.onMic,
  });

  final TextEditingController controller;
  final SpeechInput speech;
  final Color accent;
  final String hint;
  final bool enabled;
  final void Function([String?]) onSend;
  final VoidCallback onMic;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: speech.listening,
      builder: (context, listening, _) => Row(
        children: [
          Semantics(
            button: true,
            label: listening ? 'Stop listening' : 'Talk',
            child: Material(
              color: listening ? accent : Palette.inkRaised,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: enabled ? onMic : null,
                child: SizedBox.square(
                  dimension: 50,
                  child: Icon(
                    listening ? Icons.stop_rounded : Icons.mic_rounded,
                    color: listening ? Palette.ink : Palette.bone,
                    size: 23,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: listening
                // Live transcript in place of the field while the mic is open.
                ? ValueListenableBuilder<String>(
                    valueListenable: speech.transcript,
                    builder: (context, heard, _) => Container(
                      constraints: const BoxConstraints(minHeight: 50),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(color: Palette.inkRaised, borderRadius: BorderRadius.circular(16)),
                      child: Row(
                        children: [
                          const ThinkingOrb(state: OrbState.listening, size: 22, theme: OrbTheme.dark),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              heard.isEmpty ? 'Listening…' : heard,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 16, color: heard.isEmpty ? Palette.muted : Palette.bone),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : TextField(
                    controller: controller,
                    enabled: enabled,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => onSend(),
                    style: const TextStyle(fontSize: 16, color: Palette.bone),
                    cursorColor: accent,
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: const TextStyle(color: Palette.muted),
                      filled: true,
                      fillColor: Palette.inkRaised,
                      isDense: true,
                      contentPadding: const EdgeInsets.fromLTRB(16, 15, 6, 15),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      suffixIcon: IconButton(
                        tooltip: 'Send',
                        onPressed: enabled ? onSend : null,
                        icon: Icon(Icons.arrow_upward_rounded, color: enabled ? Palette.bone : Palette.muted),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Three rounded bars that move while the object is speaking and rest as
/// dots when it is quiet.
class _SpeakingBars extends StatefulWidget {
  const _SpeakingBars({required this.speaking, required this.color});
  final ValueNotifier<bool> speaking;
  final Color color;

  @override
  State<_SpeakingBars> createState() => _SpeakingBarsState();
}

class _SpeakingBarsState extends State<_SpeakingBars> with SingleTickerProviderStateMixin {
  late final _t = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    widget.speaking.addListener(_sync);
    _sync();
  }

  void _sync() => widget.speaking.value ? _t.repeat() : _t.animateTo(0, duration: const Duration(milliseconds: 200));

  @override
  void dispose() {
    widget.speaking.removeListener(_sync);
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.speaking.value ? 'Speaking' : null,
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) => CustomPaint(
          size: const Size(22, 18),
          painter: _BarsPainter(phase: _t.value, active: widget.speaking.value, color: widget.color),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.phase, required this.active, required this.color});
  final double phase;
  final bool active;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 4.0;
    final paint = Paint()..color = color;
    for (var i = 0; i < 3; i++) {
      final wave = active ? 0.5 + 0.5 * math.sin((phase + i * 0.22) * 2 * math.pi) : 0.0;
      // Never shorter than its width, so the caps stay perfectly round.
      final h = w + (size.height - w) * wave;
      final x = i * (size.width - w) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, w, h), const Radius.circular(w / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.phase != phase || old.active != active || old.color != color;
}
