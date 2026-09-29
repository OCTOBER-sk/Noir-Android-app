import 'dart:io';

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

    test('the accent is confined to the three spots the plan authorizes', () {
      // The accent is a deviation from "zero accent colors", so its blast radius
      // is exactly what the deviation said it was: the stream loader tip, the
      // undo countdown fill and the needs_review dot. Nothing else may use it.
      //
      // This is asserted by reading the sources rather than by inspecting widget
      // trees, because a static LinearGradient over the token is exactly the
      // shape that a rendered-widget assertion would miss -- an extra 4px
      // decorative bar is invisible in a screenshot and would never fail a
      // behavioural test, but it widens an authorized exception every time one
      // is added "just for a bit of colour".
      const Map<String, int> authorized = <String, int>{
        // 1 = the _cyclingAccent helper, which paints the loader tip and the
        // undo countdown. A 2 here would be the helper plus a stray duplicate.
        'lib/ui/command_centre_screen.dart': 1,
        // 1 = the static needs_review dot
        'lib/ui/skill_manager_screen.dart': 1,
      };

      final Directory lib = Directory('lib');
      final Map<String, int> found = <String, int>{};
      for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.contains('/theme/')) continue; // the definition itself
        final int hits = RegExp(
          'NoirColors\\.rainbowAccent',
        ).allMatches(entity.readAsStringSync()).length;
        if (hits > 0) found[entity.path] = hits;
      }

      expect(
        found,
        equals(authorized),
        reason:
            'NoirColors.rainbowAccent must appear only on the three spots '
            'FRONTEND_PLAN.md authorizes. A new call site is either a fourth '
            'spot or a duplicate -- either way the deviation has grown.',
      );
    });

    test('the accent is painted animated, never as a static gradient', () {
      // "Accent is tiny + moving" (FRONTEND_PLAN.md). A static LinearGradient over
      // the token is the same colour with none of the behaviour, which is how a
      // spot starts drifting away from the deviation it was granted under.
      //
      // The one legitimate static use is the needs_review dot: it is a 8px dot
      // beside a label, there is nothing for motion to communicate, and
      // animating it would make a scannable marker distract. The two bars that
      // do carry meaning -- the loader tip and the undo countdown -- must go
      // through the shared _cyclingAccent helper.
      final String cc = File(
        'lib/ui/command_centre_screen.dart',
      ).readAsStringSync();
      expect(
        RegExp('gradient: _cyclingAccent\\(').allMatches(cc).length,
        2,
        reason:
            'The loader tip and the undo countdown must both animate the '
            'accent through _cyclingAccent.',
      );
      expect(
        RegExp('colors: NoirColors\\.rainbowAccent').allMatches(cc).length,
        0,
        reason:
            'command_centre_screen.dart must paint the accent through '
            '_cyclingAccent, not through a raw static gradient.',
      );
    });
  });
}
