import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/theme/noir_theme.dart';

// Pins the design tokens to the values written in
// SOURCE_OF_TRUTH_ADDENDUM_V2.3_UI.md, section 1:
// "Monochrome only (7 tokens: pureBlack #000, nearBlack #121, surfaceDark #1E1E,
//  surfaceDark2 #2A2A, textMuted #B0B, textSecondary #E5E5, pureWhite #FFF)."
// A token drifting by a few hex digits is invisible in review and obvious on a
// device, so it is worth a test rather than a comment.
void main() {
  group('NoirColors (V2.3 palette)', () {
    test('the seven base tokens hold their spec hex values', () {
      expect(NoirColors.pureBlack, const Color(0xFF000000));
      expect(NoirColors.nearBlack, const Color(0xFF121212));
      expect(NoirColors.surfaceDark, const Color(0xFF1E1E1E));
      expect(NoirColors.surfaceDark2, const Color(0xFF2A2A2A));
      expect(NoirColors.textMuted, const Color(0xFFB0B0B0));
      expect(NoirColors.textSecondary, const Color(0xFFE5E5E5));
      expect(NoirColors.pureWhite, const Color(0xFFFFFFFF));
    });

    test('the accent list is the documented user-requested deviation', () {
      // FRONTEND_PLAN.md asks for one rainbow accent on three spots, overriding
      // the spec's "zero accent colors". It is a list, not a token, and it is
      // only ever consumed as an animated gradient — see FRONTEND_PLAN.md.
      expect(NoirColors.rainbowAccent, hasLength(7));
      expect(
        NoirColors.rainbowAccent,
        containsAll(<Color>[
          Color(0xFFFF0000),
          Color(0xFFFF7F00),
          Color(0xFFFFFF00),
          Color(0xFF00FF00),
          Color(0xFF0000FF),
          Color(0xFF4B0082),
          Color(0xFF9400D3),
        ]),
      );
    });
  });
}
