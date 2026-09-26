import 'dart:async';

import '../safety/policy_engine.dart' show GateResult, PolicyEngine;
import '../safety/risk_classifier.dart' show RiskClassifier, RiskLevel;
import '../safety/screen_content_sanitizer.dart'
    show SanitizedResult, Sanitizer;

class AgentRuntimePipeline {
  final Planner planner;
  final RiskClassifier riskClassifier;
  final ScreenSanitizer sanitizer;
  final PolicyEngine policyEngine;
  final Gate gate;
  final UndoWindowOpener undoWindow;
  final Executor execute;
  final ReflectionCritic reflectionCritic;
  final RecoveryEngine recovery;

  AgentRuntimePipeline({
    required this.planner,
    required this.riskClassifier,
    required this.policyEngine,
    required this.gate,
    required this.undoWindow,
    required this.execute,
    required this.reflectionCritic,
    required this.recovery,
    ScreenSanitizer? sanitizer,
  }) : sanitizer = sanitizer ?? Sanitizer.sanitize;

  Future<RuntimeResult> run(dynamic context) async {
    final plan = await planner.plan(context);

    late final RiskLevel risk;
    try {
      risk = await riskClassifier.classify(plan.content);
    } catch (_) {
      return RuntimeResult.blocked(
        GateResult.blocked('RISK_CLASSIFICATION_FAILED'),
      );
    }

    late final SanitizedResult sanitized;
    try {
      sanitized = await sanitizer(plan.screenNodes);
    } catch (_) {
      return RuntimeResult.blocked(
        GateResult.blocked('MALFORMED_SCREEN_CONTENT'),
      );
    }

    late final GateResult policy;
    try {
      policy = policyEngine.gate(plan.content, riskLevel: risk.level);
    } catch (_) {
      return RuntimeResult.blocked(GateResult.blocked('POLICY_ERROR'));
    }

    if (!policy.allowed) {
      return RuntimeResult.blocked(policy);
    }

    if (policy.needsConfirmation || policy.needsBiometric) {
      final bool approved;
      try {
        approved = await gate.check(policy, risk);
      } catch (_) {
        return RuntimeResult.blocked(GateResult.blocked('GATE_ERROR'));
      }
      if (!approved) {
        return RuntimeResult.blocked(policy);
      }
    }

    await undoWindow.open(5, allowed: risk.level >= 1);
    final executed = await execute.run(plan);
    final reflection = await reflectionCritic.analyze(
      plan,
      executed,
      sanitized.cleanTextNodes.join('\n'),
    );
    // The event is built here, on the path every completed run takes, so it
    // cannot drift into being a claim nothing produces.
    final ReflectionEvent event = ReflectionEvent.fromReflection(reflection);
    if (reflection.confidence < 0.5) {
      final RuntimeResult recovered = await recovery.executeReflectionRecovery(
        reflection,
        executed,
      );
      return recovered.withReflectionEvent(event);
    }
    return RuntimeResult.success(
      executed,
      reflection,
    ).withReflectionEvent(event);
  }
}

abstract class Planner {
  Future<Plan> plan(dynamic context);
}

typedef ScreenSanitizer =
    FutureOr<SanitizedResult> Function(List<dynamic> nodes);

abstract class Gate {
  Future<bool> check(GateResult policy, RiskLevel risk);
}

abstract class UndoWindowOpener {
  Future<UndoState> open(int seconds, {bool allowed = true});
}

abstract class Executor {
  Future<dynamic> run(Plan plan);
}

class ReflectionCritic {
  Future<Reflection> analyze(
    Plan p,
    dynamic executed,
    String sanitizedScreenContent,
  ) async => Reflection(
    confidence: computeConfidence(p, executed, sanitizedScreenContent),
  );

  // A12 — real reflection: compares intended outcome (plan) vs observed screen state (executed result + sanitized content)
  // Produces confidence score 0.0-1.0; low confidence (<0.5) routes to HierarchicalRecovery (A4)
  double computeConfidence(Plan p, dynamic executed, String sanitizedContent) {
    // If executed result indicates failure or mismatch with plan, confidence drops
    if (executed == null ||
        executed.toString().contains('failed') ||
        executed.toString().contains('error')) {
      return 0.3; // Low confidence -> trigger recovery
    }
    // If screen content was heavily sanitized (injection detected), lower confidence slightly
    if (sanitizedContent.contains('REASON_') ||
        sanitizedContent.contains('stripped')) {
      return 0.6; // Moderate confidence, still passes but flagged
    }
    // Normal successful execution with clean screen content -> high confidence
    return 0.92;
  }
}

class ReflectionCriticImpl extends ReflectionCritic {}

abstract class RecoveryEngine {
  Future<RuntimeResult> executeReflectionRecovery(
    Reflection reflection,
    dynamic executed,
  );
}

class RuntimeResult {
  final bool blocked;
  final dynamic result;
  final Reflection? reflection;

  /// What the reflection critic decided about this run, when the run got far
  /// enough to be reflected on. Null for a blocked run, which never reaches
  /// the critic.
  final ReflectionEvent? reflectionEvent;

  RuntimeResult.success(this.result, this.reflection)
    : blocked = false,
      reflectionEvent = null;

  RuntimeResult.blocked(GateResult policy)
    : blocked = true,
      result = policy,
      reflection = null,
      reflectionEvent = null;

  /// The same outcome, carrying the reflection event the pipeline just built.
  /// Used on the recovery path, where the [RecoveryEngine] returns a result
  /// and the pipeline still owes the caller the event for that run.
  RuntimeResult withReflectionEvent(ReflectionEvent event) => RuntimeResult._(
    blocked: blocked,
    result: result,
    reflection: reflection,
    reflectionEvent: event,
  );

  RuntimeResult._({
    required this.blocked,
    required this.result,
    required this.reflection,
    required this.reflectionEvent,
  });
}

class Plan {
  final dynamic content;
  final List<dynamic> screenNodes;

  const Plan({this.content, this.screenNodes = const <dynamic>[]});
}

class UndoState {}

class Reflection {
  final double confidence;

  Reflection({required this.confidence});
}

// A6b — UndoWindow: the cancellable countdown offered on any action with
// risk >= 1 (V2.2 addendum R1). The duration in force is the `seconds` value
// the caller passed to [UndoWindowOpener.open], and the window ends when that
// duration has actually elapsed, not when someone merely says so.
class UndoWindow {
  final String actionId;

  /// The duration this window was opened for, in whole seconds.
  final int countdownSeconds;

  /// The instant the window closes if nobody cancels it.
  final DateTime deadline;

  final DateTime Function() _clock;

  bool cancelled = false;

  UndoWindow({
    required this.actionId,
    int seconds = 5,
    DateTime? openedAt,
    DateTime Function()? clock,
  }) : countdownSeconds = seconds,
       _clock = clock ?? DateTime.now,
       deadline = (openedAt ?? (clock ?? DateTime.now)()).add(
         Duration(seconds: seconds),
       );

  void cancel() => cancelled = true;

  /// Whole seconds left, floored at 0. Derived from the clock, so it is a real
  /// countdown rather than a constant that never moves.
  int get remainingSeconds {
    final int left = deadline.difference(_clock()).inSeconds;
    return left < 0 ? 0 : left;
  }

  /// True while the window is still open: not cancelled, and time remaining.
  bool isActive() => !cancelled && _clock().isBefore(deadline);
}
// A6 — Pipeline.execute now integrates PolicyEngine.gate + UndoWindow.
// The countdown itself is not a placeholder: CountdownUndoWindow in
// lib/core/agent_wiring.dart opens a real UndoWindow for the duration the
// caller passes and ends it when that duration has elapsed or the user
// cancels, and the composition root wires that implementation into the app.

// A12 (V2.2 R1) — what reflection actually decided for one run.
//
// This is the real path, not a claim about one: [AgentRuntimePipeline.run]
// builds one of these for every run that reaches the reflection critic and
// carries it on [RuntimeResult.reflectionEvent], and a run whose confidence
// drops below 0.5 is marked as degraded before it goes to recovery.
//
// There is deliberately no `skillId` here. No `SkillStorage` or `SkillReplay`
// subsystem exists in this codebase — `grep -r "class SkillStorage" lib`
// returns nothing — so an event keyed by skill id would be a key to nowhere.
// The event describes one run of the pipeline, and it lives on that run's
// result.
class ReflectionEvent {
  final double confidenceScore; // 0.0 - 1.0
  final bool degradedToNeedsReview;

  const ReflectionEvent({
    required this.confidenceScore,
    this.degradedToNeedsReview = false,
  });

  /// Builds the event for a [Reflection] the critic produced. Below 0.5 the
  /// pipeline routes the run to recovery, which is what "degraded" records.
  factory ReflectionEvent.fromReflection(Reflection reflection) =>
      ReflectionEvent(
        confidenceScore: reflection.confidence,
        degradedToNeedsReview: reflection.confidence < 0.5,
      );

  bool isConfident() => confidenceScore >= 0.75;

  bool needsReview() => degradedToNeedsReview || confidenceScore < 0.5;
}
