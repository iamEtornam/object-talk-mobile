import 'package:flutter/material.dart';

import '../ai/persona.dart';

/// Warm charcoal + bone palette. The camera feed is the real background;
/// these are the surfaces that sit on it.
abstract final class Palette {
  static const ink = Color(0xFF14110F);
  static const inkRaised = Color(0xFF221D19);
  static const inkLine = Color(0xFF2E2823);
  static const bone = Color(0xFFF2EDE6);
  static const muted = Color(0xFFA79F95);
  static const warn = Color(0xFFE2B56B);

  static Color accent(ObjectCategory c) => Color(categoryColors[c]!);
}

/// The objects speak in Gambarino; people (and chrome) use the system face.
const voiceFont = 'Gambarino';

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: Palette.ink,
    colorScheme: const ColorScheme.dark(
      surface: Palette.ink,
      primary: Palette.bone,
      onPrimary: Palette.ink,
      secondary: Palette.muted,
      error: Palette.warn,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: Palette.bone, displayColor: Palette.bone),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Palette.inkRaised,
      contentTextStyle: TextStyle(color: Palette.bone, fontSize: 15),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
