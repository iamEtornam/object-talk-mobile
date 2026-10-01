import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_thinking_orbs/flutter_thinking_orbs.dart';

import '../ui/theme.dart';
import '../vision/cutout.dart';
import '../voice/voice.dart';
import 'conversation.dart';

/// Chat sheet under the hovering object: a header with who it is, the thread
/// as bubbles, and a composer. Tap or drag the handle to give the thread more
/// room.
class ConversationPanel extends StatefulWidget {
  const ConversationPanel({
    super.key,
    required this.conversation,
    required this.speaking,
    required this.topFraction,
    this.avatar,
  });

  final Conversation conversation;
  final ValueNotifier<bool> speaking;

  /// The compact panel never rises above this fraction of the screen height,
  /// so the object above it stays in view.
  final double topFraction;

  /// The object's own cutout, shown beside its messages.
  final Cutout? avatar;

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
    // While a reply is still arriving the draft stays in the field.
    if (value.trim().isEmpty || _c.isStreaming) return;
    HapticFeedback.selectionClick();
    _c.send(value);
    if (text == null) _input.clear();
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
                padding: EdgeInsets.fromLTRB(0, 0, 0, 10 + (keyboard > 0 ? 0 : mq.padding.bottom)),
                child: ListenableBuilder(
                  listenable: _c,
                  builder: (context, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Handle(expanded: _expanded, onTap: () => setState(() => _expanded = !_expanded)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: _Header(conversation: _c, speaking: widget.speaking, accent: accent, avatar: widget.avatar),
                      ),
                      const SizedBox(height: 10),
                      Flexible(
                        child: _Thread(messages: _c.messages, accent: accent, avatar: widget.avatar),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: _Composer(
                          controller: _input,
                          speech: _speech,
                          hint: 'Message ${_c.persona.characterName}',
                          canSend: !_c.isStreaming,
                          onSend: _send,
                          onMic: _toggleMic,
                        ),
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
          height: 22,
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

/// The object's face for the thread: its own cutout, bare (no disc behind a
/// masked cutout), or the photo crop in a circle when there is no mask.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.cutout, required this.size, required this.accent});
  final Cutout? cutout;
  final double size;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final c = cutout;
    final Widget face;
    if (c == null) {
      face = Icon(Icons.blur_on_rounded, size: size * 0.8, color: accent);
    } else if (c.masked) {
      face = Image.memory(c.png, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium);
    } else {
      face = ClipOval(child: Image.memory(c.png, fit: BoxFit.cover, gaplessPlayback: true));
    }
    return ExcludeSemantics(child: SizedBox.square(dimension: size, child: Center(child: face)));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.conversation, required this.speaking, required this.accent, required this.avatar});
  final Conversation conversation;
  final ValueNotifier<bool> speaking;
  final Color accent;
  final Cutout? avatar;

  @override
  Widget build(BuildContext context) {
    final p = conversation.persona;
    return Row(
      children: [
        _Avatar(cutout: avatar, size: 40, accent: accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      p.characterName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: voiceFont, fontSize: 24, height: 1.15, color: Palette.bone),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _SpeakingBars(speaking: speaking, color: accent),
                ],
              ),
              Text(
                conversation.isStreaming ? 'thinking…' : p.identifiedAs,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 1.3, color: accent),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The whole thread, newest at the bottom. Consecutive messages from one side
/// group together; the last of a group gets the tail corner (and, for the
/// object, its avatar).
class _Thread extends StatelessWidget {
  const _Thread({required this.messages, required this.accent, required this.avatar});
  final List<Message> messages;
  final Color accent;
  final Cutout? avatar;

  @override
  Widget build(BuildContext context) {
    // Reversed so the newest message stays pinned to the bottom as it streams.
    return ListView.builder(
      reverse: true,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final index = messages.length - 1 - i;
        final m = messages[index];
        final next = index + 1 < messages.length ? messages[index + 1] : null;
        final previous = index > 0 ? messages[index - 1] : null;
        final lastOfGroup = next == null || next.fromUser != m.fromUser;
        final firstOfGroup = previous == null || previous.fromUser != m.fromUser;
        return Padding(
          padding: EdgeInsets.only(top: firstOfGroup ? 10 : 3),
          child: m.fromUser
              ? _UserBubble(text: m.text, tail: lastOfGroup, accent: accent)
              : _ObjectBubble(message: m, tail: lastOfGroup, accent: accent, avatar: avatar),
        );
      },
    );
  }
}

const _bubbleRadius = Radius.circular(20);
const _tailRadius = Radius.circular(6);
const _avatarSize = 28.0;

double _bubbleMaxWidth(BuildContext context) => MediaQuery.sizeOf(context).width * 0.76;

class _ObjectBubble extends StatelessWidget {
  const _ObjectBubble({required this.message, required this.tail, required this.accent, required this.avatar});
  final Message message;
  final bool tail;
  final Color accent;
  final Cutout? avatar;

  @override
  Widget build(BuildContext context) {
    final waiting = message.streaming && message.text.trim().isEmpty;
    final lost = message.failed && message.text.trim().isEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Every object bubble keeps the avatar's slot so the column stays aligned.
        tail ? _Avatar(cutout: avatar, size: _avatarSize, accent: accent) : const SizedBox(width: _avatarSize),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: _bubbleMaxWidth(context)),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Palette.inkRaised,
                    borderRadius: BorderRadius.only(
                      topLeft: _bubbleRadius,
                      topRight: _bubbleRadius,
                      bottomRight: _bubbleRadius,
                      bottomLeft: tail ? _tailRadius : _bubbleRadius,
                    ),
                  ),
                  child: Padding(
                    padding: waiting
                        ? const EdgeInsets.symmetric(horizontal: 14, vertical: 9)
                        : const EdgeInsets.fromLTRB(14, 9, 14, 10),
                    child: waiting
                        ? const ThinkingOrb(state: OrbState.composing, size: 24, theme: OrbTheme.dark, semanticLabel: 'Thinking')
                        : Text(
                            lost ? 'I lost my words. Ask me again?' : message.text,
                            style: TextStyle(
                              fontFamily: voiceFont,
                              fontSize: 18,
                              height: 1.34,
                              color: lost ? Palette.muted : Palette.bone,
                            ),
                          ),
                  ),
                ),
              ),
              if (message.failed && !lost)
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 4, 0, 0),
                  child: Text('The connection dropped mid-sentence.', style: TextStyle(fontSize: 12, color: Palette.warn)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.tail, required this.accent});
  final String text;
  final bool tail;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _bubbleMaxWidth(context)),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // A quiet tint of the object's colour, not the colour itself.
            color: Color.alphaBlend(accent.withValues(alpha: 0.24), Palette.inkRaised),
            borderRadius: BorderRadius.only(
              topLeft: _bubbleRadius,
              topRight: _bubbleRadius,
              bottomLeft: _bubbleRadius,
              bottomRight: tail ? _tailRadius : _bubbleRadius,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
            child: Text(text, style: const TextStyle(fontSize: 16, height: 1.38, color: Palette.bone)),
          ),
        ),
      ),
    );
  }
}

/// Message field with one round action beside it: the mic while the field is
/// empty, send once there is text, stop while listening.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.speech,
    required this.hint,
    required this.canSend,
    required this.onSend,
    required this.onMic,
  });

  final TextEditingController controller;
  final SpeechInput speech;
  final String hint;
  final bool canSend;
  final void Function([String?]) onSend;
  final VoidCallback onMic;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: speech.listening,
      builder: (context, listening, _) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final hasText = value.text.trim().isNotEmpty;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 46),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(color: Palette.inkRaised, borderRadius: BorderRadius.circular(23)),
                  child: listening
                      // Live transcript in place of the field while the mic is open.
                      ? ValueListenableBuilder<String>(
                          valueListenable: speech.transcript,
                          builder: (context, heard, _) => Padding(
                            padding: const EdgeInsets.fromLTRB(12, 11, 16, 11),
                            child: Row(
                              children: [
                                const ThinkingOrb(state: OrbState.listening, size: 22, theme: OrbTheme.dark),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    heard.isEmpty ? 'Listening…' : heard,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 16, height: 1.3, color: heard.isEmpty ? Palette.muted : Palette.bone),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : TextField(
                          controller: controller,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          textCapitalization: TextCapitalization.sentences,
                          onSubmitted: (_) => onSend(),
                          style: const TextStyle(fontSize: 16, height: 1.3, color: Palette.bone),
                          cursorColor: Palette.bone,
                          decoration: InputDecoration(
                            hintText: hint,
                            hintStyle: const TextStyle(color: Palette.muted),
                            isDense: true,
                            contentPadding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
                            border: InputBorder.none,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 8),
              if (listening)
                _RoundAction(icon: Icons.stop_rounded, label: 'Stop listening', filled: true, onTap: onMic)
              else if (hasText)
                _RoundAction(icon: Icons.arrow_upward_rounded, label: 'Send', filled: true, onTap: canSend ? onSend : null)
              else
                _RoundAction(icon: Icons.mic_rounded, label: 'Talk', filled: false, onTap: canSend ? onMic : null),
            ],
          );
        },
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({required this.icon, required this.label, required this.filled, required this.onTap});
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fill = filled ? (enabled ? Palette.bone : Palette.inkLine) : Palette.inkRaised;
    final ink = filled ? (enabled ? Palette.ink : Palette.muted) : (enabled ? Palette.bone : Palette.muted);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: fill,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(dimension: 46, child: Icon(icon, color: ink, size: 22)),
        ),
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
