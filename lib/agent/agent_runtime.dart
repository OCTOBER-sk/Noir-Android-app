import 'dart:async';
import '../safety/risk_classifier.dart';
import '../safety/screen_content_sanitizer.dart';
import '../safety/policy_engine.dart';
import '../agent/recovery_engine.dart';

class AgentRuntimePipeline {
  final Planner planner;
  final RiskClassifier riskClassifier;
  final ScreenContentSanitizer sanitizer;
  final PolicyEngine policyEngine;
  final Gate gate;
  final UndoWindow undoWindow;
  final Executor execute;
  final ReflectionCritic reflectionCritic;
  final RecoveryEngine recovery;

  AgentRuntimePipeline({
    required this.planner,
    required this.riskClassifier,
    required this.sanitizer,
    required this.policyEngine,
    required this.gate,
    required this.undoWindow,
    required this.execute,
    required this.reflectionCritic,
    required this.recovery,
  });

  Future<RuntimeResult> run(dynamic context) async {
    // 1. Planner
    final plan = await planner.plan(context);
    // 2. RiskClassifier
    final risk = await riskClassifier.classify(plan);
    // 3. Sanitizer
    final clean = await sanitizer.sanitize(plan.content);
    // 4. PolicyEngine
    final policy = await policyEngine.evaluate(clean, risk);
    // 5. Gate
    final allowed = await gate.check(policy, risk);
    if (!allowed) return RuntimeResult.blocked(risk, policy);
    // 6. UndoWindow (5s)
    final undo = await undoWindow.open(5, allowed: risk.level >= 1);
    // 7. Execute
    final executed = await execute.run(plan);
    // 8. Reflection / Critic (A12)
    final reflection = await reflectionCritic.analyze(plan, executed, clean);
    if (reflection.confidence < 0.5) {
      // 9. Recovery (A4) — hierarchical
      return await recovery.executeReflectionRecovery(reflection, executed);
    }
    return RuntimeResult.success(executed, reflection);
  }
}

class Planner { Future<Plan> plan(dynamic c) async => Plan(); }
class RiskClassifier { Future<RiskLevel> classify(dynamic p) async => RiskLevel(level: 0); }
class ScreenContentSanitizer { Future<String> sanitize(String s) async => s; }
class PolicyEngine { Future<Policy> evaluate(String c, RiskLevel r) async => Policy(); }
class Gate { Future<bool> check(Policy p, RiskLevel r) async => true; }
class UndoWindow { Future<UndoState> open(int seconds, {bool allowed = true}) async => UndoState(); }
class Executor { Future<dynamic> run(Plan p) async => p; }
class ReflectionCritic { Future<Reflection> analyze(Plan p, dynamic e, String s) async => Reflection(confidence: 0.9); }
class RecoveryEngine { Future<RuntimeResult> executeReflectionRecovery(Reflection r, dynamic e) async => RuntimeResult.blocked(r, Policy()); }

class RuntimeResult {
  final bool blocked; final dynamic result; final Reflection? reflection;
  RuntimeResult.success(this.result, this.reflection) : blocked = false;
  RuntimeResult.blocked(dynamic r, Policy p) : blocked = true, result = r, reflection = null;
}
class Plan { String content = ''; }
class RiskLevel { int level; RiskLevel({required this.level}); }
class Policy {}
class UndoState {}
class Reflection { double confidence; Reflection({required this.confidence}); }
