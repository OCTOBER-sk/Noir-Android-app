// lib/safety/policy_engine.dart
// A6 — Policy Engine gate (release-blocking security path).
// Risk tier names are the V2.2 A6 identifiers and are printed verbatim in the
// Safety Center (D9) log, so the lowerCamelCase constant rule does not apply.
// ignore_for_file: constant_identifier_names
enum RiskTier { SAFE, STANDARD, SENSITIVE, HIGH_RISK }

class PolicyEngine {
  final List<String> blacklist = [];
  bool uiLock = false;
  bool requireBiometric = false;

  GateResult gate(dynamic proposal, {int riskLevel = 0}) {
    if (uiLock) {
      requireBiometric = false;
      return GateResult.blocked('UI_LOCK');
    }

    if (riskLevel < 0) {
      requireBiometric = false;
      return GateResult.blocked('INVALID_RISK_LEVEL');
    }

    if (proposal is! Map) {
      requireBiometric = false;
      return GateResult.blocked('MALFORMED_PROPOSAL');
    }

    String? action;
    try {
      action = proposal['action'] as String?;
    } catch (_) {
      requireBiometric = false;
      return GateResult.blocked('MALFORMED_PROPOSAL');
    }

    final normalizedAction = action?.trim();
    if (normalizedAction == null || normalizedAction.isEmpty) {
      requireBiometric = false;
      return GateResult.blocked('MALFORMED_PROPOSAL');
    }

    if (blacklist.contains(normalizedAction)) {
      requireBiometric = false;
      return GateResult.blocked('BLACKLIST');
    }

    final needsBiometric = riskLevel >= 2;
    requireBiometric = needsBiometric;
    return GateResult.confirm(
      'Confirmation required: $normalizedAction',
      needsBiometric,
    );
  }
}

class GateResult {
  final bool allowed;
  final String message;
  final bool needsBiometric;
  final bool needsConfirmation;
  GateResult.confirm(this.message, this.needsBiometric)
    : allowed = true,
      needsConfirmation = true;
  GateResult.blocked(this.message)
    : allowed = false,
      needsBiometric = false,
      needsConfirmation = false;
}

// A8 biometric gate: biometric requirement set when riskLevel >= 2 (biometric flag present in PolicyEngine).
