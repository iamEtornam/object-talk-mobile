import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ai/persona.dart';
import 'orb.dart';
import 'theme.dart';

/// The orb's launch colour: the first stop of the sign-in screen's drift, so
/// the hand-off from launch to sign-in keeps its colour.
final splashOrbColor = Color(categoryColors[ObjectCategory.mineral]!);

/// Orb over the wordmark. The native launch screen is a render of this widget
/// (see test/brand_art_test.dart), so [Splash] can pick up on the same frame.
class SplashMark extends StatelessWidget {
  const SplashMark({super.key, this.blink = 0, this.look = Offset.zero});

  final double blink;
  final Offset look;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size.square(176),
          painter: OrbPainter(color: splashOrbColor, blink: blink, look: look),
        ),
        const SizedBox(height: 28),
        const Text(
          'Object Talk',
          textDirection: TextDirection.ltr,
          style: TextStyle(fontFamily: voiceFont, fontSize: 34, height: 1.2, color: Palette.bone),
        ),
      ],
    );
  }
}

/// Continues the native launch screen: the orb wakes up (a blink, a curious
/// glance) and the app fades in. Skipped when reduce-motion is on.
class Splash extends StatefulWidget {
  const Splash({super.key, required this.child});
  final Widget child;

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> with SingleTickerProviderStateMixin {
  late final _wake = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _wake.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _done = true;
  }

  @override
  void dispose() {
    _wake.dispose();
    super.dispose();
  }

  /// One quick blink around 20% in.
  static double _blinkAt(double t) {
    final d = (t - 0.2).abs() / 0.07;
    return d < 1 ? math.cos(d * math.pi / 2) : 0;
  }

  /// A glance up and to the right, and back.
  static Offset _lookAt(double t) {
    if (t < 0.38 || t > 0.95) return Offset.zero;
    final s = math.sin((t - 0.38) / 0.57 * math.pi);
    return Offset(0.8, -0.6) * Curves.easeInOut.transform(s.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      child: _done
          ? KeyedSubtree(key: const ValueKey('app'), child: widget.child)
          : ColoredBox(
              key: const ValueKey('splash'),
              color: Palette.ink,
              child: Center(
                child: AnimatedBuilder(
                  animation: _wake,
                  builder: (context, _) => SplashMark(blink: _blinkAt(_wake.value), look: _lookAt(_wake.value)),
                ),
              ),
            ),
    );
  }
}
