// The app icon and launch images are renders of the app's own orb, so they
// can never drift from it. Regenerate after changing the orb or the mark:
//   flutter test test/brand_art_test.dart --update-goldens
//   dart run flutter_launcher_icons && dart run flutter_native_splash:create
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:object_talk/ui/orb.dart';
import 'package:object_talk/ui/splash.dart';
import 'package:object_talk/ui/theme.dart';

Future<void> _loadVoiceFont() async {
  final bytes = File('assets/fonts/Gambarino-Regular.ttf').readAsBytesSync();
  await (FontLoader(voiceFont)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

/// Lays [art] out in a [logical]-point square (or [height] tall), paints it at
/// 4x (goldens capture at 1x, so the vector art is scaled up, not the pixels)
/// and compares it with assets/brand/[name].
Future<void> _render(WidgetTester tester, String name, Widget art, {double logical = 256, double? height}) async {
  final size = Size(logical, height ?? logical);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size * 4;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(RepaintBoundary(
    key: key,
    child: FittedBox(child: SizedBox.fromSize(size: size, child: art)),
  ));
  await expectLater(find.byKey(key), matchesGoldenFile('../assets/brand/$name'));
}

Widget _orb(double size, {Offset look = Offset.zero}) =>
    CustomPaint(size: Size.square(size), painter: OrbPainter(color: splashOrbColor, look: look));

void main() {
  setUpAll(_loadVoiceFont);

  testWidgets('app icon: the orb, glancing up, on warm ink lit from the top left', (tester) async {
    await _render(
      tester,
      'icon.png',
      DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2B241F), Palette.ink],
          ),
        ),
        // Nudged up so the orb and its contact shadow sit centred together.
        child: Align(alignment: const Alignment(0, -0.06), child: _orb(170, look: const Offset(0.35, -0.3))),
      ),
    );
  });

  testWidgets('Android adaptive icon foreground: the orb inside the safe zone', (tester) async {
    await _render(
      tester,
      'icon_foreground.png',
      Align(alignment: const Alignment(0, -0.05), child: _orb(124, look: const Offset(0.35, -0.3))),
    );
  });

  testWidgets('launch image: the splash mark exactly as Splash draws it', (tester) async {
    // 4x of the mark's 176 x 245 points; the native splash shows it at 1x points.
    await _render(tester, 'splash.png', const Center(child: SplashMark()), logical: 200, height: 250);
  });

  testWidgets('Android 12 launch icon: the orb alone, inside the masked circle', (tester) async {
    await _render(tester, 'splash_android12.png', Center(child: _orb(150)), logical: 288);
  });

  testWidgets('Splash shows the mark first, then hands over to the app', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Splash(child: Text('app'))));
    expect(find.byType(SplashMark), findsOneWidget);
    expect(find.text('app'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('app'), findsOneWidget);
    expect(find.byType(SplashMark), findsNothing);
  });

  testWidgets('Splash goes straight to the app when reduce-motion is on', (tester) async {
    await tester.pumpWidget(const MediaQuery(
      data: MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: Splash(child: Text('app'))),
    ));
    expect(find.text('app'), findsOneWidget);
  });
}
