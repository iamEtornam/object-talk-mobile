import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The scanned object cut out of the frozen frame.
class Cutout {
  const Cutout({required this.png, required this.rect, required this.masked});

  final Uint8List png;

  /// Where it sat in the frame, normalised 0..1, so it can lift from that spot.
  final Rect rect;

  /// True when the background is transparent (a real cutout), false when it is
  /// a plain rectangular crop of the photo.
  final bool masked;
}

const _channel = MethodChannel('object_talk/subject');

/// Cut the object at [box] (normalised, from Gemini) out of [frame] (PNG).
/// Uses on-device subject segmentation (Vision / ML Kit) and falls back to a
/// plain crop when no subject is found.
Future<Cutout> cutOut(Uint8List frame, Rect? box) async {
  Uint8List? masked;
  try {
    masked = await _channel.invokeMethod<Uint8List>('lift', {
      'image': frame,
      if (box != null) 'box': [box.top, box.left, box.bottom, box.right],
    });
  } on PlatformException catch (e) {
    debugPrint('Subject lift failed: ${e.message}');
  } on MissingPluginException {
    debugPrint('Subject lift is not available on this platform');
  }

  final source = await _decode(masked ?? frame);
  try {
    final region = _expand(box ?? const Rect.fromLTRB(0.2, 0.25, 0.8, 0.65), 0.06);
    var px = Rect.fromLTRB(
      region.left * source.width,
      region.top * source.height,
      region.right * source.width,
      region.bottom * source.height,
    );
    if (masked != null) {
      px = await _opaqueBounds(source, px) ?? px;
    }
    final png = await _crop(source, px);
    return Cutout(
      png: png,
      rect: Rect.fromLTRB(px.left / source.width, px.top / source.height, px.right / source.width, px.bottom / source.height),
      masked: masked != null,
    );
  } finally {
    source.dispose();
  }
}

Rect _expand(Rect r, double by) => Rect.fromLTRB(
      math.max(0, r.left - r.width * by),
      math.max(0, r.top - r.height * by),
      math.min(1, r.right + r.width * by),
      math.min(1, r.bottom + r.height * by),
    );

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

/// Tight bounds of the visible (alpha > 0) pixels of [image] inside [within],
/// or null when nothing inside is visible.
Future<Rect?> _opaqueBounds(ui.Image image, Rect within) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  if (data == null) return null;
  return opaqueBounds(data.buffer.asUint8List(), image.width, image.height, within);
}

/// Pure helper behind [_opaqueBounds] (RGBA bytes), exposed for tests.
@visibleForTesting
Rect? opaqueBounds(Uint8List rgba, int width, int height, Rect within) {
  final x0 = within.left.floor().clamp(0, width), x1 = within.right.ceil().clamp(0, width);
  final y0 = within.top.floor().clamp(0, height), y1 = within.bottom.ceil().clamp(0, height);
  var minX = x1, minY = y1, maxX = -1, maxY = -1;
  for (var y = y0; y < y1; y++) {
    final row = y * width;
    for (var x = x0; x < x1; x++) {
      if (rgba[(row + x) * 4 + 3] > 16) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return null;
  return Rect.fromLTRB(minX.toDouble(), minY.toDouble(), maxX + 1.0, maxY + 1.0);
}

Future<Uint8List> _crop(ui.Image image, Rect px) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(image, px, Rect.fromLTWH(0, 0, px.width, px.height), ui.Paint());
  final cropped = await recorder.endRecording().toImage(px.width.round(), px.height.round());
  final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
  cropped.dispose();
  if (png == null) throw StateError('Could not encode the cutout');
  return png.buffer.asUint8List();
}
