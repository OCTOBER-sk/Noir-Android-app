// lib/safety/risk_classifier.dart — A6 (RiskClassifier — REAL implementation)
// Classifies proposed ToolCall into tier 0-3 based on content, screen input, and action type.

// Risk tier names are the V2.2 A6 identifiers, so the lowerCamelCase constant
// rule does not apply to this file.
// ignore_for_file: constant_identifier_names
enum RiskTier { SAFE, STANDARD, SENSITIVE, HIGH_RISK }

class RiskClassifier {
  // 0 = auto (no confirmation/card), 1 = Standard (confirmation card, undo), 2 = Sensitive (+biometric), 3 = High risk (+biometric + stricter gate)
  static const Map<RiskTier, int> tierMap = {
    RiskTier.SAFE: 0,
    RiskTier.STANDARD: 1,
    RiskTier.SENSITIVE: 2,
    RiskTier.HIGH_RISK: 3,
  };

  Future<RiskLevel> classify(dynamic proposal) async {
    final int level = _computeLevel(proposal);
    return RiskLevel(level: level);
  }

  int _computeLevel(dynamic proposal) {
    // Real classification logic per A6 / V2.2 R1
    final String action = (proposal is Map
        ? proposal['action']?.toString() ?? ''
        : proposal.toString());
    final String input = (proposal is Map
        ? proposal['input']?.toString() ?? ''
        : '');

    // HIGH RISK: sends messages to external apps with unverified recipients or deletes data
    if (action.contains('delete') ||
        action.contains('send') && input.contains('@')) {
      return 3;
    }
    // SENSITIVE: actions that modify state in external apps (tap send, navigate to URL) but with verified context
    if (action.contains('tap') &&
        (input.contains('whatsapp') ||
            input.contains('email') ||
            input.contains('message'))) {
      return 2;
    }
    // STANDARD: navigation, searches, reading screen content (needs confirmation + undo when >=1)
    if (action.contains('navigate') ||
        action.contains('search') ||
        action.contains('read_screen')) {
      return 1;
    }
    // SAFE: internal memory writes, draft creation without external dispatch
    if (action.contains('save_fact') ||
        action.contains('draft') ||
        action.contains('memory')) {
      return 0;
    }
    // Default to STANDARD if unknown action — never assume safe without classification
    return 1;
  }
}

class RiskLevel {
  final int level; // 0-3 mapped to RiskTier
  RiskLevel({required this.level});
  RiskTier get tier {
    if (level <= 0) return RiskTier.SAFE;
    if (level == 1) return RiskTier.STANDARD;
    if (level == 2) return RiskTier.SENSITIVE;
    return RiskTier.HIGH_RISK;
  }
}
