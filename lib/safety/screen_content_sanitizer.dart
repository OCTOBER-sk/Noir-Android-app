// lib/safety/screen_content_sanitizer.dart
// A6a — deterministic, NO LLM call.
enum Reason { REASON_ZERO_ALPHA, REASON_OFF_SCREEN, REASON_ZERO_WIDTH, REASON_BIDI_OVERRIDE }

class SanitizedItem {
  final String text; final Reason reason; final int nodeIndex;
  SanitizedItem(this.text, this.reason, this.nodeIndex);
}

class SanitizedResult {
  final List<String> cleanTextNodes; final List<SanitizedItem> stripped;
  SanitizedResult(this.cleanTextNodes, this.stripped);
}

class Sanitizer {
  static SanitizedResult sanitize(List<dynamic> nodes) {
    final stripped = <SanitizedItem>[];
    final clean = <String>[];
    for (int i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final alpha = (n['alpha'] ?? 1.0) as double;
      final bounds = n['bounds'] as Map<String, dynamic>?;
      final text = n['text'] as String? ?? '';
      final hasBidi = text.contains('\u200e') || text.contains('\u200f') || text.contains('\u202a');
      final offViewport = (bounds != null) ? ((bounds['left'] ?? 0) < 0 || (bounds['top'] ?? 0) < 0) : false;
      if (alpha < 0.01 || offViewport || text.trim().isEmpty || hasBidi) {
        Reason r = alpha < 0.01 ? Reason.REASON_ZERO_ALPHA
            : offViewport ? Reason.REASON_OFF_SCREEN
            : text.trim().isEmpty ? Reason.REASON_ZERO_WIDTH
            : Reason.REASON_BIDI_OVERRIDE;
        stripped.add(SanitizedItem(text, r, i));
      } else {
        clean.add(text);
      }
    }
    return SanitizedResult(clean, stripped);
  }
}
