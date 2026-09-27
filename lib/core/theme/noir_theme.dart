import 'package:flutter/material.dart';

// lib/core/theme/noir_theme.dart — V2.3 UI spec (monochrome, zero accent colors)
// Design tokens extend Section 2 palette; exactly 7 hex values (no new colors added).
class NoirColors {
  static const Color pureBlack = Color(0xFF000000);
  static const Color nearBlack = Color(0xFF121212);
  static const Color surfaceDark = Color(0xFF1E1E1E);
  static const Color surfaceDark2 = Color(0xFF2A2A2A);
  static const Color textMuted = Color(0xFFB0B0B0);
  static const Color textSecondary = Color(0xFFE5E5E5);
  static const Color pureWhite = Color(0xFFFFFFFF);
  // Documented deviation from SOURCE_OF_TRUTH_ADDENDUM_V2.3_UI.md ("Zero accent
  // colors"): FRONTEND_PLAN.md records this single rainbow-shifting accent as an
  // explicit user request, applied ONLY to three tiny spots (stream loader tip,
  // undo countdown fill, needs_review dot). Nothing else in the app uses colour.
  static const List<Color> rainbowAccent = [
    Color(0xFFFF0000),
    Color(0xFFFF7F00),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF0000FF),
    Color(0xFF4B0082),
    Color(0xFF9400D3),
  ];
}
