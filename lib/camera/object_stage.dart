import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../ui/theme.dart';
import '../vision/cutout.dart';

/// The frozen frame with the scanned object lifted out of it: the photo blurs
/// and dims while the cutout rises from its exact spot into a hover, then bobs,
/// tilts with the phone for depth, and squashes and stretches with its voice.
class ObjectStage extends StatefulWidget {
  const ObjectStage({
    super.key,
    required this.frame,
    required this.cutout,
    required this.level,
    required this.hoverBand,
  });

  final Uint8List frame;
  final Cutout cutout;

  /// Current voice loudness 0..1, sampled every frame.
  final double Function() level;

  /// Vertical band (fractions of the screen height) the object hovers in,
  /// i.e. the space above the conversation panel.
  final (double top, double bottom) hoverBand;

  @override
  State<ObjectStage> createState() => _ObjectStageState();
}

class _ObjectStageState extends State<ObjectStage> with SingleTickerProviderStateMixin {
  static const _revealDuration = Duration(milliseconds: 1100);

  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  double _voice = 0;
  Offset _tilt = Offset.zero, _tiltTarget = Offset.zero;
  StreamSubscription<AccelerometerEvent>? _accel;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() {
        _elapsed = elapsed;
        // Ease toward the targets so motion never jitters.
        _voice += (widget.level() - _voice) * 0.35;
        _tilt = Offset.lerp(_tilt, _tiltTarget, 0.08)!;
      });
    })
      ..start();
    _accel = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
      (e) => _tiltTarget = Offset((e.x / 9.8).clamp(-0.6, 0.6), (e.z / 9.8).clamp(-0.6, 0.6)),
      onError: (Object e) => debugPrint('Accelerometer unavailable: $e'),
    );
  }

  @override
  void dispose() {
    _accel?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final size = MediaQuery.sizeOf(context);
    final t = still ? 1.0 : (_elapsed.inMicroseconds / _revealDuration.inMicroseconds).clamp(0.0, 1.0);
    final secs = _elapsed.inMicroseconds / 1e6;
    final tilt = still ? Offset.zero : _tilt;

    // Where the object sat in the photo vs where it hovers.
    final c = widget.cutout.rect;
    final from = Rect.fromLTRB(c.left * size.width, c.top * size.height, c.right * size.width, c.bottom * size.height);
    final (bandTop, bandBottom) = widget.hoverBand;
    final bandH = (bandBottom - bandTop) * size.height;
    final aspect = from.width / math.max(1, from.height);
    final targetH = math.min(bandH * 0.74, size.width * 0.74 / aspect);
    final target = Rect.fromCenter(
      center: Offset(size.width / 2, (bandTop * size.height) + bandH * 0.46),
      width: targetH * aspect,
      height: targetH,
    );

    final lift = Curves.easeOutCubic.transform(t);
    final settle = Curves.easeOutBack.transform(t);
    final rect = Rect.lerp(from, target, lift)!;
    final scale = 0.94 + 0.06 * settle; // overshoots a hair, then settles

    // Hover: slow bob and sway that fade in as the lift finishes.
    final hover = still ? 0.0 : Curves.easeIn.transform(t);
    final bob = math.sin(secs * 2 * math.pi / 3.2) * 9 * hover;
    final sway = math.sin(secs * 2 * math.pi / 5.1) * 0.02 * hover;

    // Talking: stretch up and narrow slightly on loud syllables, from the base.
    final v = still ? 0.0 : _voice;

    return Stack(
      fit: StackFit.expand,
      children: [
        // The photo recedes: blurred, dimmed, and drifting against the tilt.
        Transform.translate(
          offset: Offset(-tilt.dx * 18, tilt.dy * 14) * hover,
          child: Transform.scale(
            scale: 1.08,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 18 * lift, sigmaY: 18 * lift),
              child: Image.memory(widget.frame, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        ),
        ColoredBox(color: Palette.ink.withValues(alpha: 0.5 * lift)),
        // Contact shadow on the "floor" below the hover: tight, cast straight
        // down, shrinking as the object rises.
        Positioned(
          left: target.center.dx - target.width * 0.36,
          top: target.bottom + 18,
          width: target.width * 0.72,
          height: 16,
          child: Opacity(
            opacity: (0.55 - bob * 0.012).clamp(0.0, 1.0) * hover,
            child: Transform.scale(scaleX: 1 - bob * 0.006, child: const CustomPaint(painter: _ShadowPainter())),
          ),
        ),
        Positioned.fromRect(
          rect: rect.translate(tilt.dx * 10 * hover, bob - tilt.dy * 8 * hover),
          child: Transform(
            alignment: Alignment.bottomCenter,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY(tilt.dx * 0.22 * hover)
              ..rotateX(-tilt.dy * 0.14 * hover)
              ..rotateZ(sway)
              ..scaleByDouble((1 - 0.03 * v) * scale, (1 + 0.07 * v) * scale, 1, 1),
            child: widget.cutout.masked
                ? Image.memory(widget.cutout.png, fit: BoxFit.fill, gaplessPlayback: true)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.memory(widget.cutout.png, fit: BoxFit.fill, gaplessPlayback: true),
                  ),
          ),
        ),
      ],
    );
  }
}

class _ShadowPainter extends CustomPainter {
  const _ShadowPainter();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawOval(
        Offset.zero & size,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.6)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );

  @override
  bool shouldRepaint(_ShadowPainter old) => false;
}
