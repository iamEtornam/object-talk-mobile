import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ai/persona.dart';
import '../ui/orb.dart';
import '../ui/theme.dart';
import 'auth.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> with SingleTickerProviderStateMixin {
  // One slow loop drives the colour drift through every category and the blinks.
  late final _loop = AnimationController(vsync: this, duration: const Duration(seconds: 18))..repeat();
  Offset _look = Offset.zero;
  bool _busy = false;

  static final _colors = categoryColors.values.map(Color.new).toList();

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  Color _colorAt(double t) {
    final x = t * _colors.length;
    final i = x.floor() % _colors.length;
    // Smoothstep so the orb lingers on each colour before moving on.
    final f = x - x.floor();
    return Color.lerp(_colors[i], _colors[(i + 1) % _colors.length], f * f * (3 - 2 * f))!;
  }

  double _blinkAt(double t) {
    // Two quick blinks per loop, ~180 ms each.
    for (final at in const [0.31, 0.78]) {
      final d = (t - at).abs() * 18;
      if (d < 0.09) return math.cos(d / 0.09 * math.pi / 2);
    }
    return 0;
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    try {
      await Auth.signInWithGoogle();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Auth.describe(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      body: Listener(
        // The orb watches your finger anywhere on screen.
        onPointerMove: (e) => setState(() {
          _look = Offset((e.position.dx / size.width - 0.5) * 2, (e.position.dy / size.height - 0.4) * 2);
        }),
        onPointerUp: (_) => setState(() => _look = Offset.zero),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _loop,
                      builder: (context, _) => TweenAnimationBuilder<Offset>(
                        tween: Tween(end: _look),
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        builder: (context, look, _) => CustomPaint(
                          size: Size.square(math.min(size.width * 0.66, 300)),
                          painter: OrbPainter(
                            color: _colorAt(_loop.value),
                            look: look,
                            blink: _blinkAt(_loop.value),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Text(
                  'Everything has\nsomething to say.',
                  style: TextStyle(fontFamily: voiceFont, fontSize: 40, height: 1.1, color: Palette.bone),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Point your camera at any object. It wakes up, introduces itself, '
                  'and answers whatever you ask it about itself.',
                  style: TextStyle(fontSize: 16, height: 1.45, color: Palette.muted),
                ),
                const SizedBox(height: 36),
                _GoogleButton(busy: _busy, onPressed: _busy ? null : _signIn),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.busy, required this.onPressed});
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Continue with Google',
      child: Material(
        color: Palette.bone,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          splashColor: Palette.ink.withValues(alpha: 0.08),
          highlightColor: Palette.ink.withValues(alpha: 0.06),
          child: SizedBox(
            height: 58,
            width: double.infinity,
            child: Center(
              child: busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4, color: Palette.ink),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        GoogleG(size: 20),
                        SizedBox(width: 12),
                        Text(
                          'Continue with Google',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Palette.ink),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
