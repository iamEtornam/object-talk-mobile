import 'package:flutter/material.dart';

/// The 2D twin of the AR character: a lit sphere with two eyes. [look] is a
/// -1..1 offset the pupils drift toward; [blink] is 0 (open) to 1 (shut).
class OrbPainter extends CustomPainter {
  OrbPainter({required this.color, this.look = Offset.zero, this.blink = 0, this.pulse = 0});

  final Color color;
  final Offset look;
  final double blink;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2 * (0.9 + 0.06 * pulse);
    final c = size.center(Offset.zero);

    // Contact shadow on the "ground", cast down and slightly right of a
    // top-left key light. Small and directional, never a halo.
    canvas.drawOval(
      Rect.fromCenter(center: c + Offset(r * 0.12, r * 1.06), width: r * 1.3, height: r * 0.16),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // Body, shaded from a key light at the top-left.
    final hsl = HSLColor.fromColor(color);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.5),
          radius: 1.05,
          colors: [
            hsl.withLightness((hsl.lightness + 0.14).clamp(0, 1)).toColor(),
            color,
            hsl.withLightness((hsl.lightness - 0.28).clamp(0, 1)).toColor(),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // Eyes sit where the 3D model puts them, drifting with [look].
    final eyeR = r * 0.17;
    final drift = Offset(look.dx.clamp(-1, 1) * r * 0.1, look.dy.clamp(-1, 1) * r * 0.08);
    for (final side in [-1.0, 1.0]) {
      final e = c + Offset(side * r * 0.36, -r * 0.2) + drift;
      final open = (1 - blink).clamp(0.08, 1.0);
      canvas.drawOval(
        Rect.fromCenter(center: e, width: eyeR * 2, height: eyeR * 2 * open),
        Paint()..color = const Color(0xFF120F0D),
      );
      if (open > 0.5) {
        canvas.drawCircle(e + Offset(eyeR * 0.3, -eyeR * 0.34), eyeR * 0.3, Paint()..color = Colors.white);
      }
    }
  }

  @override
  bool shouldRepaint(OrbPainter old) =>
      old.color != color || old.look != look || old.blink != blink || old.pulse != pulse;
}

/// The official Google "G", drawn from Google's sign-in branding paths
/// (48×48 viewBox) so it stays crisp at any size.
class GoogleG extends StatelessWidget {
  const GoogleG({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GooglePainter());
}

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48);
    void fill(int argb, Path p) => canvas.drawPath(p, Paint()..color = Color(argb));

    fill(
      0xFFEA4335,
      Path()
        ..moveTo(24, 9.5)
        ..relativeCubicTo(3.54, 0, 6.71, 1.22, 9.21, 3.6)
        ..relativeLineTo(6.85, -6.85)
        ..cubicTo(35.9, 2.38, 30.47, 0, 24, 0)
        ..cubicTo(14.62, 0, 6.51, 5.38, 2.56, 13.22)
        ..relativeLineTo(7.98, 6.19)
        ..cubicTo(12.43, 13.72, 17.74, 9.5, 24, 9.5)
        ..close(),
    );
    fill(
      0xFF4285F4,
      Path()
        ..moveTo(46.98, 24.55)
        ..relativeCubicTo(0, -1.57, -0.15, -3.09, -0.38, -4.55)
        ..lineTo(24, 20)
        ..relativeLineTo(0, 9.02)
        ..relativeLineTo(12.94, 0)
        ..relativeCubicTo(-0.58, 2.96, -2.26, 5.48, -4.78, 7.18)
        ..relativeLineTo(7.73, 6)
        ..relativeCubicTo(4.51, -4.18, 7.09, -10.36, 7.09, -17.65)
        ..close(),
    );
    fill(
      0xFFFBBC05,
      Path()
        ..moveTo(10.53, 28.59)
        ..relativeCubicTo(-0.48, -1.45, -0.76, -2.99, -0.76, -4.59)
        ..relativeCubicTo(0, -1.6, 0.27, -3.14, 0.76, -4.59)
        ..relativeLineTo(-7.98, -6.19)
        ..cubicTo(0.92, 16.46, 0, 20.12, 0, 24)
        ..relativeCubicTo(0, 3.88, 0.92, 7.54, 2.56, 10.78)
        ..relativeLineTo(7.97, -6.19)
        ..close(),
    );
    fill(
      0xFF34A853,
      Path()
        ..moveTo(24, 48)
        ..relativeCubicTo(6.48, 0, 11.93, -2.13, 15.89, -5.81)
        ..relativeLineTo(-7.73, -6)
        ..relativeCubicTo(-2.15, 1.45, -4.92, 2.3, -8.16, 2.3)
        ..relativeCubicTo(-6.26, 0, -11.57, -4.22, -13.47, -9.91)
        ..relativeLineTo(-7.98, 6.19)
        ..cubicTo(6.51, 42.62, 14.62, 48, 24, 48)
        ..close(),
    );
  }

  @override
  bool shouldRepaint(_GooglePainter old) => false;
}
