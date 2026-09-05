/// Decision returned by [PolicyEngine.evaluate].
class PolicyDecision {
  /// Whether execution is allowed at all.
  final bool allowed;

  /// Whether user confirmation is required before execution.
  final bool requiresConfirmation;

  /// Whether biometric verification is required before execution.
  final bool requiresBiometric;

  /// Human-readable reason when [allowed] is false.
  final String? reason;

  /// Creates a new [PolicyDecision].
  const PolicyDecision({
    required this.allowed,
    required this.requiresConfirmation,
    required this.requiresBiometric,
    this.reason,
  });
}

/// Enforces safety gates after risk classification (V2.1 §7 A6).
class PolicyEngine {
  /// Evaluates the policy for a proposed tool call.
  ///
  /// Rules (V2.1 §A6 thin):
  /// - risk 0: always allowed, no gates.
  /// - risk 1: requires confirmation iff [executionClass] is `uiBound`.
  /// - risk 2: always requires confirmation.
  /// - risk 3: always requires confirmation + biometric. If biometric is
  ///   required but [biometricAvailable] is false, [PolicyDecision.allowed]
  ///   is false with reason `"biometric unavailable"`.
  PolicyDecision evaluate({
    required int risk,
    required String executionClass,
    required List<String> requiredPermissions,
    required bool biometricAvailable,
  }) {
    if (risk == 0) {
      return const PolicyDecision(
        allowed: true,
        requiresConfirmation: false,
        requiresBiometric: false,
      );
    }
    if (risk == 1) {
      final needsConfirm = executionClass == 'uiBound';
      return PolicyDecision(
        allowed: true,
        requiresConfirmation: needsConfirm,
        requiresBiometric: false,
      );
    }
    if (risk == 2) {
      return const PolicyDecision(
        allowed: true,
        requiresConfirmation: true,
        requiresBiometric: false,
      );
    }
    if (risk == 3) {
      if (!biometricAvailable) {
        return const PolicyDecision(
          allowed: false,
          requiresConfirmation: true,
          requiresBiometric: true,
          reason: 'biometric unavailable',
        );
      }
      return const PolicyDecision(
        allowed: true,
        requiresConfirmation: true,
        requiresBiometric: true,
      );
    }
    // Fallback for out-of-range risk values: treat as risk 2.
    return const PolicyDecision(
      allowed: true,
      requiresConfirmation: true,
      requiresBiometric: false,
    );
  }
}
