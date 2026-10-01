import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_thinking_orbs/flutter_thinking_orbs.dart';

import '../ai/gemini.dart';
import '../ai/persona.dart';
import '../auth/auth.dart';
import '../conversation/conversation.dart';
import '../conversation/conversation_panel.dart';
import '../ui/theme.dart';
import '../vision/cutout.dart';
import '../voice/voice.dart';
import 'object_stage.dart';

enum _Phase { live, identifying, talking }

/// The space above the conversation panel the object hovers in.
const _hoverBand = (0.08, 0.56);

/// After sign-in: the live camera until you scan; then the camera shuts off,
/// the frame freezes and the object lifts out of it to talk.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  ARSessionManager? _session;
  final _voice = Voice();
  _Phase _phase = _Phase.live;
  String? _error;

  /// The frozen frame (screen resolution, capped) once a scan starts.
  Uint8List? _frame;
  Cutout? _cutout;
  Conversation? _conversation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _conversation?.dispose();
    _voice.dispose();
    _session?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _voice.stop();
  }

  void _onARViewCreated(
    ARSessionManager session,
    ARObjectManager objects,
    ARAnchorManager anchors,
    ARLocationManager location,
  ) {
    // The AR view is only the live viewfinder now: no planes, no taps.
    session.onInitialize(showAnimatedGuide: false, showPlanes: false, showFeaturePoints: false, handleTaps: false);
    objects.onInitialize();
    session.onError = (e) => debugPrint('AR error: $e');
    _session = session;
  }

  Future<void> _scan() async {
    final session = _session;
    if (session == null || _phase != _Phase.live) return;
    HapticFeedback.mediumImpact();

    final Uint8List full, small, chatPhoto;
    try {
      (full, small, chatPhoto) = await _captureFrame(session);
    } catch (e) {
      debugPrint('Capture failed: $e');
      setState(() => _error = 'Couldn’t grab the frame. Try again.');
      return;
    }

    // Freeze on the captured frame and shut the camera off: everything from
    // here works on the still, so there is no reason to keep ARKit running.
    _session = null;
    await session.dispose();
    setState(() {
      _frame = full;
      _phase = _Phase.identifying;
      _error = null;
    });

    try {
      final persona = await identifyObject(small, mimeType: 'image/png');
      _voice.persona = persona;
      final conversation = Conversation(
        persona,
        _voice,
        reply: PersonaChat(persona, photo: chatPhoto, mimeType: 'image/png').reply,
      );
      // Start synthesizing the greeting while the cutout is being made.
      conversation.speakGreeting();
      final cutout = await cutOut(full, persona.box);
      if (!mounted) {
        conversation.dispose();
        return;
      }
      HapticFeedback.lightImpact();
      setState(() {
        _cutout = cutout;
        _conversation = conversation;
        _phase = _Phase.talking;
      });
    } catch (e) {
      debugPrint('Scan failed: $e');
      await _voice.stop();
      if (mounted) {
        setState(() {
          _frame = null;
          _phase = _Phase.live;
          _error = _describe(e);
        });
      }
    }
  }

  /// The AR frame at up to 1800 px (cutout), 1024 px (identification) and
  /// 512 px (kept in the chat history, so it is re-sent every turn).
  static Future<(Uint8List, Uint8List, Uint8List)> _captureFrame(ARSessionManager session) async {
    final shot = await session.snapshot();
    if (shot is! MemoryImage) throw StateError('Snapshot was not in memory');
    return (
      await _resized(shot.bytes, 1800),
      await _resized(shot.bytes, 1024),
      await _resized(shot.bytes, 512),
    );
  }

  static Future<Uint8List> _resized(Uint8List bytes, int longSide) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = math.min(1.0, longSide / math.max(descriptor.width, descriptor.height));
    final codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round(),
      targetHeight: (descriptor.height * scale).round(),
    );
    final image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (png == null) throw StateError('Could not encode the frame');
    return png.buffer.asUint8List();
  }

  static String _describe(Object e) => switch (e) {
        NotIdentifiedException() => 'Couldn’t quite make that out. Fill the frame with one object and try again.',
        PersonaFormatException() => 'That one went quiet on me. Try scanning it again.',
        FirebaseAIException(:final message) when message.contains('PERMISSION_DENIED') =>
          'The AI service refused the request. Check Firebase AI Logic and App Check for this app.',
        FirebaseAIException() => 'The AI service is having trouble right now. Try again in a moment.',
        _ => 'Something went wrong. Check your connection and try again.',
      };

  Future<void> _newScan() async {
    HapticFeedback.selectionClick();
    await _voice.stop();
    final old = _conversation;
    if (!mounted) return;
    setState(() {
      _conversation = null;
      _cutout = null;
      _frame = null;
      _phase = _Phase.live;
    });
    // The panel still listens until this frame rebuilds without it.
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  Future<void> _signOut() async {
    await _newScan();
    await Auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame, cutout = _cutout, conversation = _conversation;
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_phase == _Phase.live)
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig: PlaneDetectionConfig.none,
              permissionPromptDescription: 'Object Talk needs the camera to see the objects you want to talk to.',
              permissionPromptButtonText: 'Allow camera',
            )
          else if (frame != null && cutout != null)
            ObjectStage(frame: frame, cutout: cutout, level: () => _voice.level, hoverBand: _hoverBand)
          else if (frame != null)
            Image.memory(frame, fit: BoxFit.cover, gaplessPlayback: true),
          if (_phase != _Phase.talking) ...[
            IgnorePointer(child: _Reticle(identifying: _phase == _Phase.identifying)),
            Positioned(
              left: 24,
              right: 24,
              bottom: 0,
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Caption(
                      text: _error ??
                          (_phase == _Phase.identifying
                              ? 'Looking closely…'
                              : 'Point at one thing. Tap to wake it up.'),
                      warn: _error != null,
                    ),
                    const SizedBox(height: 22),
                    _Shutter(busy: _phase == _Phase.identifying, onPressed: _scan),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
          ],
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_phase == _Phase.talking) _ChromeButton(label: 'Scan again', onTap: _newScan),
                  const Spacer(),
                  _AccountButton(onSignOut: _signOut),
                ],
              ),
            ),
          ),
          if (conversation != null)
            ConversationPanel(conversation: conversation, speaking: _voice.speaking, topFraction: _hoverBand.$2),
        ],
      ),
    );
  }
}

/// Rounded corner brackets framing the scan area. They breathe slowly while
/// waiting and close in, holding a searching orb, while identifying.
class _Reticle extends StatefulWidget {
  const _Reticle({required this.identifying});
  final bool identifying;

  @override
  State<_Reticle> createState() => _ReticleState();
}

class _ReticleState extends State<_Reticle> with SingleTickerProviderStateMixin {
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = math.min(MediaQuery.sizeOf(context).width * 0.68, 300.0);
    final still = MediaQuery.disableAnimationsOf(context);
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.identifying ? 0.84 : 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
        builder: (context, closing, _) => AnimatedBuilder(
          animation: _breath,
          builder: (context, _) {
            final breathe =
                widget.identifying || still ? 1.0 : 1 - 0.025 * Curves.easeInOut.transform(_breath.value);
            final s = side * closing * breathe;
            return CustomPaint(
              size: Size.square(s),
              painter: _BracketPainter(),
              child: SizedBox.square(
                dimension: s,
                child: widget.identifying
                    ? const Center(
                        child: ThinkingOrb(
                          state: OrbState.searching,
                          size: 72,
                          theme: OrbTheme.dark,
                          semanticLabel: 'Identifying object',
                        ),
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Palette.bone.withValues(alpha: 0.92)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final arm = size.width * 0.16;
    const r = 14.0;
    final w = size.width, h = size.height;
    for (final (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (w, 0.0, -1.0, 1.0), (0.0, h, 1.0, -1.0), (w, h, -1.0, -1.0)]) {
      canvas.drawPath(
        Path()
          ..moveTo(x, y + dy * arm)
          ..lineTo(x, y + dy * r)
          ..quadraticBezierTo(x, y, x + dx * r, y)
          ..lineTo(x + dx * arm, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BracketPainter old) => false;
}

class _Caption extends StatelessWidget {
  const _Caption({required this.text, required this.warn});
  final String text;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: DecoratedBox(
        key: ValueKey(text),
        decoration: BoxDecoration(color: Palette.ink.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, height: 1.35, color: warn ? Palette.warn : Palette.bone),
          ),
        ),
      ),
    );
  }
}

/// Camera-style shutter. While busy the ring turns into a travelling arc.
class _Shutter extends StatefulWidget {
  const _Shutter({required this.busy, required this.onPressed});
  final bool busy;
  final VoidCallback onPressed;

  @override
  State<_Shutter> createState() => _ShutterState();
}

class _ShutterState extends State<_Shutter> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  bool _pressed = false;

  @override
  void didUpdateWidget(_Shutter old) {
    super.didUpdateWidget(old);
    widget.busy ? _spin.repeat() : _spin.stop();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.busy ? 'Identifying object' : 'Scan object',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.busy ? null : widget.onPressed,
        child: AnimatedBuilder(
          animation: _spin,
          builder: (context, _) => CustomPaint(
            size: const Size.square(78),
            painter: _ShutterPainter(busy: widget.busy, turn: _spin.value, pressed: _pressed),
          ),
        ),
      ),
    );
  }
}

class _ShutterPainter extends CustomPainter {
  _ShutterPainter({required this.busy, required this.turn, required this.pressed});
  final bool busy;
  final double turn;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(center: c, radius: size.width / 2 - 2);
    if (busy) {
      canvas.drawCircle(c, size.width / 2 - 2, ring..color = Palette.bone.withValues(alpha: 0.25));
      canvas.drawArc(rect, turn * 2 * math.pi, math.pi * 0.6, false, ring..color = Palette.bone);
    } else {
      canvas.drawCircle(c, size.width / 2 - 2, ring..color = Palette.bone);
    }
    // The inner disc dips when pressed and shrinks to a dot while busy.
    final inner = busy ? 10.0 : (pressed ? size.width / 2 - 12 : size.width / 2 - 9);
    canvas.drawCircle(c, inner, Paint()..color = Palette.bone);
  }

  @override
  bool shouldRepaint(_ShutterPainter old) => old.busy != busy || old.turn != turn || old.pressed != pressed;
}

/// Small solid control over the photo.
class _ChromeButton extends StatelessWidget {
  const _ChromeButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Palette.ink.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          height: 42,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.center_focus_strong_rounded, size: 18, color: Palette.bone),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Palette.bone)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Profile photo (or a plain mark) opening a small account sheet.
class _AccountButton extends StatelessWidget {
  const _AccountButton({required this.onSignOut});
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final photo = user?.photoURL;
    return Semantics(
      button: true,
      label: 'Account',
      child: GestureDetector(
        onTap: () => _showSheet(context, user),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Palette.ink.withValues(alpha: 0.82),
            image: photo == null ? null : DecorationImage(image: NetworkImage(photo), fit: BoxFit.cover),
          ),
          child: photo == null ? const Icon(Icons.person_rounded, color: Palette.bone, size: 22) : null,
        ),
      ),
    );
  }

  void _showSheet(BuildContext context, User? user) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Palette.ink,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user?.displayName ?? 'Signed in',
                  style: const TextStyle(fontFamily: voiceFont, fontSize: 28, color: Palette.bone)),
              if (user?.email != null) ...[
                const SizedBox(height: 4),
                Text(user!.email!, style: const TextStyle(fontSize: 15, color: Palette.muted)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: Palette.inkRaised,
                    foregroundColor: Palette.bone,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    onSignOut();
                  },
                  child: const Text('Sign out', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
