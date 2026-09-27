// lib/safety/screen_content_sanitizer.dart
// A6a — deterministic, NO LLM call.
// The Reason values are the V2.2 E4 identifiers and are logged verbatim in the
// Safety Center (D9), so the lowerCamelCase constant rule does not apply.
// ignore_for_file: constant_identifier_names
enum Reason {
  REASON_ZERO_ALPHA,
  REASON_OFF_SCREEN,
  REASON_ZERO_WIDTH,
  REASON_BIDI_OVERRIDE,

  /// The node reports itself not visible. Previously this case fell through to
  /// REASON_ZERO_ALPHA, which logged a reason the service never stated.
  REASON_NOT_VISIBLE,
}

class SanitizedItem {
  final String text;
  final Reason reason;
  final int nodeIndex;
  final int zOrder;
  final double alpha;
  final bool offViewport;
  SanitizedItem(
    this.text,
    this.reason,
    this.nodeIndex, {
    this.zOrder = 0,
    this.alpha = 1.0,
    this.offViewport = false,
  });
}

class SanitizedResult {
  final List<String> cleanTextNodes;
  final List<SanitizedItem> stripped;
  SanitizedResult(this.cleanTextNodes, this.stripped);
}

class Sanitizer {
  // A6a \u2014 deterministic pass; operates on full node metadata (text, bounds, alpha, zOrder, visibility)
  // from AgentAccessibilityService (C1). Never relies on LLM to notice concealed content.
  static SanitizedResult sanitize(List<dynamic> nodes) {
    final stripped = <SanitizedItem>[];
    final clean = <String>[];
    for (int i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      // Extract full metadata per C1 requirements
      final alpha = (n['alpha'] ?? 1.0) as double;
      final bounds = n['bounds'] as Map<String, dynamic>?;
      final text = n['text'] as String? ?? '';
      final zOrder = (n['zOrder'] ?? 0) as int;
      final visible = (n['visible'] ?? true) as bool;

      final hasBidi =
          text.contains('\u200e') ||
          text.contains('\u200f') ||
          text.contains('\u202a');
      final offViewport = (bounds != null)
          ? ((bounds['left'] ?? 0) < 0 ||
                (bounds['top'] ?? 0) < 0 ||
                (bounds['bottom'] ?? 0) < 0 ||
                (bounds['right'] ?? 0) < 0)
          : false;

      // A6a: strip/flag nodes with zero alpha, zero bounds, off-viewport, bidi override, empty text, invisible
      if (alpha < 0.01 ||
          offViewport ||
          text.trim().isEmpty ||
          hasBidi ||
          !visible) {
        final Reason r = alpha < 0.01
            ? Reason.REASON_ZERO_ALPHA
            : offViewport
            ? Reason.REASON_OFF_SCREEN
            : !visible
            ? Reason.REASON_NOT_VISIBLE
            : text.trim().isEmpty
            ? Reason.REASON_ZERO_WIDTH
            : hasBidi
            ? Reason.REASON_BIDI_OVERRIDE
            : Reason.REASON_ZERO_ALPHA;
        stripped.add(
          SanitizedItem(
            text,
            r,
            i,
            zOrder: zOrder,
            alpha: alpha,
            offViewport: offViewport,
          ),
        );
      } else {
        clean.add(text);
      }
    }
    return SanitizedResult(clean, stripped);
  }
}
