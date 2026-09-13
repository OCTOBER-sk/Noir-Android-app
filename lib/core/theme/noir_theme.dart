import 'package:flutter/material.dart';

// lib/core/theme/noir_theme.dart — V2.3 UI spec (monochrome, zero accent colors)
// Design tokens extend Section 2 palette; exactly 7 hex values (no new colors added).
class NoirColors {
  static const String pureBlack    = '#000000';
  static const String nearBlack    = '#121212';
  static const String surfaceDark  = '#1A1A1A';
  static const String surfaceDark2 = '#2A2A2A';
  static const String textMuted    = '#B0B0B0';
  static const String textSecondary= '#E5E5E5';
  static const String pureWhite    = '#FFFFFF';
  // Subtle rainbow-shifting accent — animated gradient applied ONLY to tiny spots
  // (stream loader tip, undo countdown fill, needs_review dot). Zero elsewhere.
  static const List<Color> rainbowAccent = [
    Color(0xFFFF0000), Color(0xFFFF7F00), Color(0xFFFFFF00),
    Color(0xFF00FF00), Color(0xFF0000FF), Color(0xFF4B0082),
    Color(0xFF9400D3),
  ];
}
