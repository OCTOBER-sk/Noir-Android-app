import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/safety/policy_engine.dart';
import 'package:noir_android_app/safety/risk_classifier.dart';
import 'package:noir_android_app/safety/screen_content_sanitizer.dart';

class _Planner extends Planner {
  @override
  Future<Plan> plan(dynamic context) async {
    return const Plan(
      content: <String, dynamic>{'action': 'save_fact'},
      screenNodes: <dynamic>[
        <String, dynamic>{
          'text': 'safe heading',
          'alpha': 1.0,
          'visible': true,
          'zOrder': 1,
          'bounds': <String, dynamic>{
            'left': 0,
            'top': 0,
            'right': 100,
            'bottom': 20,
          },
        },
      ],
    );
  }
}

class _Gate extends Gate {
  int calls = 0;
  GateResult? lastPolicy;

  @override
  Future<bool> check(GateResult policy, RiskLevel risk) async {
    calls += 1;
    lastPolicy = policy;
    return true;
  }
}

class _UndoWindowOpener extends UndoWindowOpener {
  @override
  Future<UndoState> open(
    int seconds, {
    required UndoableAction action,
    bool allowed = true,
  }) async {
    return UndoState();
  }
}

/// Answers the way the shipped executor answers: a `NativeGestureOutcome`, the
/// only type the A12 reflection critic can read. A bare string here would score
/// as "no observation" and send the run to recovery, which is the honest answer
/// for an answer nothing can interpret — and not what a run whose gesture was
/// confirmed should look like.
class _Executor extends Executor {
  int calls = 0;

  @override
  Future<dynamic> run(Plan plan) async {
    calls += 1;
    return const NativeGestureOutcome(
      executed: true,
      verdict: NativeGateVerdict(allowed: true, message: 'ok'),
    );
  }
}

class _Recovery extends RecoveryEngine {
  @override
  Future<RuntimeResult> executeReflectionRecovery(
    Reflection reflection,
    dynamic executed,
  ) async {
    return RuntimeResult.blocked(GateResult.blocked('RECOVERY_REQUIRED'));
  }
}

AgentRuntimePipeline _pipeline({
  required PolicyEngine policyEngine,
  required Gate gate,
  required Executor executor,
}) {
  return AgentRuntimePipeline(
    planner: _Planner(),
    riskClassifier: RiskClassifier(),
    sanitizer: Sanitizer.sanitize,
    policyEngine: policyEngine,
    gate: gate,
    undoWindow: _UndoWindowOpener(),
    execute: executor,
    reflectionCritic: ReflectionCritic(),
    recovery: _Recovery(),
  );
}

void main() {
  test(
    'runtime uses the canonical policy gate before approval and execution',
    () async {
      final gate = _Gate();
      final executor = _Executor();
      final pipeline = _pipeline(
        policyEngine: PolicyEngine(),
        gate: gate,
        executor: executor,
      );

      final result = await pipeline.run(<String, dynamic>{});

      expect(result.blocked, isFalse);
      expect(gate.calls, 1);
      expect(gate.lastPolicy?.message, contains('save_fact'));
      expect(executor.calls, 1);
    },
  );

  test('runtime never executes a policy-blocked proposal', () async {
    final gate = _Gate();
    final executor = _Executor();
    final pipeline = _pipeline(
      policyEngine: PolicyEngine()..blacklist.add('save_fact'),
      gate: gate,
      executor: executor,
    );

    final result = await pipeline.run(<String, dynamic>{});

    expect(result.blocked, isTrue);
    expect((result.result as GateResult).message, 'BLACKLIST');
    expect(gate.calls, 0);
    expect(executor.calls, 0);
  });
}
