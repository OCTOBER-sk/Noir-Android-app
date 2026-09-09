// lib/safety/policy_engine.dart
// A6 — Policy Engine gate (release-blocking security path).
enum RiskTier { SAFE, STANDARD, SENSITIVE, HIGH_RISK }

class PolicyEngine {
  final List<String> blacklist = [];
  bool uiLock = false; bool requireBiometric = false;

  GateResult gate(dynamic proposal, {int riskLevel = 0}) {
    if (uiLock) return GateResult.blocked('UI_LOCK');
    if (riskLevel >= 2) requireBiometric = true;
    if (blacklist.contains(proposal['action'])) return GateResult.blocked('BLACKLIST');
    return GateResult.confirm(proposal, requireBiometric);
  }
}

class GateResult {
  final bool allowed; final String message; final bool needsBiometric; final bool needsConfirmation;
  GateResult.confirm(this.message, this.needsBiometric) : allowed = true, needsConfirmation = true;
  GateResult.blocked(this.message) : allowed = false, needsBiometric = false, needsConfirmation = false;
}

// A8 biometric gate: biometric requirement set when riskLevel >= 2 (biometric flag present in PolicyEngine).
