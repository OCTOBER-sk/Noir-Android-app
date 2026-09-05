import '../safety/policy_engine.dart';
import 'tool_call.dart';
import 'tool_registry.dart';

/// Gateway that enforces policy before dispatching a [ToolCall] (V2.1 §8 B4).
class ToolGateway {
  /// Registry used to resolve tool names.
  final ToolRegistry registry;

  /// Policy engine that gates execution.
  final PolicyEngine policy;

  /// Creates a [ToolGateway] bound to [registry] and [policy].
  ToolGateway({required this.registry, required this.policy});

  /// Executes [call] after policy evaluation.
  ///
  /// 1. Calls `policy.evaluate` with `biometricAvailable: true`.
  /// 2. If `decision.allowed` is false, throws [StateError] with
  ///    `decision.reason`.
  /// 3. If `decision.requiresConfirmation` is true, throws [StateError]
  ///    indicating user confirmation is required.
  /// 4. If `decision.requiresBiometric` is true, throws [StateError]
  ///    indicating biometric is required.
  /// 5. Otherwise returns a stub success string.
  Future<String> execute(ToolCall call) async {
    final decision = policy.evaluate(
      risk: call.riskLevel,
      executionClass: call.executionClass,
      requiredPermissions: call.requiredPermissions,
      biometricAvailable: true,
    );
    if (!decision.allowed) {
      throw StateError(decision.reason ?? 'policy denied');
    }
    if (decision.requiresConfirmation) {
      throw StateError(
        'user confirmation required; not yet implemented in thin slice',
      );
    }
    if (decision.requiresBiometric) {
      throw StateError(
        'biometric required; not yet implemented in thin slice',
      );
    }
    return 'tool:${call.name} executed (stub, no real side effect in thin slice)';
  }
}
