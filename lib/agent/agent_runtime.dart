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

    // A6b. The window is opened on the action that *ran*, so it comes after
    // `execute` and not before it: the compensation a press dispatches has to
    // aim at the screen the action produced, and the toast has to describe a
    // completion that happened rather than one about to. It is offered for
    // riskLevel >= 1, and the window itself decides whether the action is
    // something that can be compensated at all.
    final executed = await execute.run(plan);
    await undoWindow.open(
      5,
      action: UndoableAction(
        plan: plan,
        riskLevel: risk.level,
        executor: execute,
        outcome: executed,
        compensation: compensationFor(plan.content),
      ),
      allowed: risk.level >= 1,
    );
    final reflection = await reflectionCritic.analyze(
      plan,
      executed,
      sanitized,
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

/// The A6b stage, and what it is handed: the action that ran, and everything an
/// undo of it needs.
///
/// [action] is required rather than optional because a window with nothing to
/// reverse is what made the D15 control inert — the window used to carry an id
/// and a `cancelled` flag, so a press had no plan to read and no executor to
/// reach.
abstract class UndoWindowOpener {
  Future<UndoState> open(
    int seconds, {
    required UndoableAction action,
    bool allowed = true,
  });
}

abstract class Executor {
  Future<dynamic> run(Plan plan);
}

// The A12 confidence ladder, named rather than inlined.
//
// The threshold that matters is the `0.5` in [AgentRuntimePipeline.run]: below it
// the run goes to [RecoveryEngine], at or above it the run is reported as the
// action it claims to be. Every negative score sits under that line on purpose.
//
// The order inside the negative half is a statement about how much the run
// actually learned, not about how bad the failure was. [kConfidenceNoObservation]
// is the only rung where nothing at all came back, and
// [kConfidencePlatformErrorCode] is the only rung that carries a reason, which is
// why it is the closest of the three to the threshold: it is the score an
// operator reads for a real dispatch failure, and it is what the Safety Center
// row will say, in points out of a hundred.

/// Nothing was observed. The critic was handed something that is not an
/// [ExecutionReport], so the pipeline has no evidence about the screen in either
/// direction. Deliberately the lowest score: this is the one case where the app
/// cannot even say that the action failed.
const double kConfidenceNoObservation = 0.10;

/// The action is known not to have happened.
///
/// The report says `executed == false`. Whether the gate refused the run outright
/// or the platform simply never confirmed the gesture, the observed fact is the
/// same one: the screen did not do what the plan asked, and no reason came back
/// with it.
const double kConfidenceNotExecuted = 0.20;

/// The action is known not to have happened, and the platform said why.
///
/// A code off `lib/platform/native_bridge.dart` — `NATIVE_DISPATCH_FAILED`,
/// `NATIVE_BRIDGE_UNAVAILABLE`, `MALFORMED_GESTURE_TARGET` and the rest — turns
/// the refusal into a diagnosable one, so this is the negative score a reader can
/// act on.
const double kConfidencePlatformErrorCode = 0.30;

/// The action happened, but the dump the critic was handed was not the whole
/// screen.
///
/// [Sanitizer] stripped at least one node off it, which means something on that
/// screen was zero-alpha, off-viewport, empty, invisible or bidi-overridden. The
/// gesture is confirmed and the observation is not, so this stays above the
/// threshold: a run like this is reported with a flag rather than sent to
/// recovery, because nothing went wrong with the action.
const double kConfidenceScreenSanitized = 0.60;

/// The action happened, the gate granted it, the platform named no code and the
/// dump was clean. A confident run, with nothing about it in doubt.
const double kConfidenceConfirmed = 0.92;

/// The code a failed report carries, or null when it carries none.
///
/// A report that is not an [ExecutionSignal] has no code to read, and a blank one
/// says nothing, so neither is reported as a failure. Only a code the platform
/// actually wrote counts.
String? _reportedFailureCode(Object? outcome) {
  if (outcome is! ExecutionSignal) return null;
  final String code = outcome.platformCode?.trim() ?? '';
  return code.isEmpty ? null : code;
}

/// A12 — what the critic decided about one run, read off the run's own evidence.
///
/// The score comes from the [ExecutionReport] the executor answered with, never
/// from a rendering of it. It used to be
/// `executed.toString().contains('failed')`, and the shipped executor's answer is
/// a `NativeGestureOutcome`, whose default `toString` is
/// `Instance of 'NativeGestureOutcome'` — so `confidence < 0.5` could not be true
/// on any real run, and the A4 recovery audit trail was reachable only by driving
/// [RecoveryEngine] by hand in a test.
///
/// There is deliberately **no** plan-vs-observed comparison here, and [p] is
/// taken only because the pipeline hands every stage the plan it ran. Nothing in
/// this pipeline re-reads the screen after the gesture, so there is no second
/// observation to compare the first against. The platform receipt cannot stand
/// in for one either: it echoes the coordinates the executor itself resolved and
/// sent, so reading it back here would be the executor comparing its own output
/// to itself. A comparison worth making needs a fresh screen read, which this
/// build does not take; the comment that used to claim one was a claim about code
/// that was not in this file.
class ReflectionCritic {
  Future<Reflection> analyze(
    Plan p,
    dynamic executed,
    SanitizedResult screen,
  ) async => Reflection(confidence: computeConfidence(p, executed, screen));

  double computeConfidence(Plan p, dynamic executed, SanitizedResult screen) {
    if (executed is! ExecutionReport) return kConfidenceNoObservation;
    // Read through the same fail-closed rule the undo window is built on: an
    // answer that is not a report is not a success, and `executionConfirmed` is
    // where that rule already lives.
    if (!executionConfirmed(executed)) {
      return _reportedFailureCode(executed) == null
          ? kConfidenceNotExecuted
          : kConfidencePlatformErrorCode;
    }
    // A confirmed gesture the gate never cleared would be the C2 invariant
    // broken, not a successful run. `NativeBridge` cannot produce one — it fails
    // closed before dispatching — so this read is here because the field is, and
    // because a future implementer of [ExecutionReport] could.
    if (executed is ExecutionSignal && executed.gateGranted == false) {
      return kConfidenceNotExecuted;
    }
    if (screen.stripped.isNotEmpty) return kConfidenceScreenSanitized;
    return kConfidenceConfirmed;
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

/// What an undo attempt actually did.
///
/// Sealed because the D15 control is only honest if the two answers cannot be
/// confused: the UI prints "Undone." for [UndoPerformed] and has no way to
/// reach that string for a refusal, which is the whole difference between a
/// live control and a control that claims a success nobody had.
sealed class UndoResult {
  const UndoResult();
}

/// The compensating run dispatched a gesture and the platform confirmed it.
final class UndoPerformed extends UndoResult {
  const UndoPerformed(this.actionId);

  /// The action that was compensated, as the window named it.
  final String actionId;

  @override
  String toString() => 'UndoPerformed($actionId)';
}

/// Nothing was compensated, and this is the reason that is shown.
final class UndoRefused extends UndoResult {
  const UndoRefused(this.reason);

  /// Wire-stable: either a code from this file, the executor's own block code,
  /// or the PolicyEngine's message.
  final String reason;

  @override
  String toString() => 'UndoRefused($reason)';
}

/// The window a press named is not open: it already elapsed, it was already
/// used, or the graph was never offering one.
const String kUndoNoLiveWindow = 'NO_LIVE_UNDO_WINDOW';

/// The action has no inverse this build can dispatch, so there is nothing an
/// undo could do. The control is not offered for such an action.
const String kUndoNotCompensatable = 'NOT_COMPENSATABLE';

/// The policy allowed the compensation and the human did not answer it. The
/// gate's own bound produced this, and silence is a refusal.
const String kUndoNotApproved = 'UNDO_NOT_APPROVED';

/// The compensating run could not be performed at all: the screen could not be
/// read, or the pipeline failed before it dispatched anything.
const String kUndoCouldNotRun = 'UNDO_COULD_NOT_RUN';

/// The run finished without the platform confirming that anything happened.
const String kUndoUnconfirmed = 'UNDO_UNCONFIRMED';

/// An [Executor] answer that can say whether the action really reached the
/// screen.
///
/// The A6 [Executor] is an interface, and only the app's real implementation
/// can answer this: `NativeGestureExecutor` returns the platform's own
/// `executed` receipt. Nothing else in the app may claim an action happened.
abstract class ExecutionReport {
  /// Whether a gesture really reached the accessibility service.
  bool get executed;
}

/// The part of an execution answer the A12 critic reads beyond "did it run".
///
/// [ExecutionReport] answers one question, and the undo window is entitled to
/// exactly that one. The critic needs two more, and both are things the platform
/// already reported rather than something it would have to infer: whether the
/// gate cleared the run, and the code a failed run failed with.
///
/// Declared here beside [ExecutionReport] because the only implementer lives in
/// `lib/platform/`, and that half must not import the pipeline.
///
/// A report that does not implement this carries no verdict and no code, and that
/// is not read as a denial. Only an explicit `false` from [gateGranted] is a
/// refusal, and only a non-blank [platformCode] is a failure: a type that opts
/// out of the interface has not claimed anything went wrong, so it is not scored
/// as though it had.
abstract class ExecutionSignal extends ExecutionReport {
  /// Whether the gate cleared this run, or null when the report carries no
  /// verdict to read.
  bool? get gateGranted;

  /// The platform's own code for a run that did not happen, verbatim, or null
  /// when it reported none.
  String? get platformCode;
}

/// Whether [outcome] is the executor confirming that the action happened.
///
/// An answer that is not a report is not treated as success. The undo window is
/// built on this, and a window over an action nobody confirmed would announce a
/// completion that did not happen and offer a control with nothing behind it.
bool executionConfirmed(Object? outcome) =>
    outcome is ExecutionReport ? outcome.executed : false;

/// The inverse action an undo dispatches, as data and nothing else.
///
/// It names a verb and the text of the control to aim at; it does not name a
/// screen, a node or a gesture. The compensating run re-plans it against the
/// live dump through the same planner a manual run uses, so a control that is
/// not on the screen is a real refusal from the executor rather than a guess
/// this class has already committed to.
class Compensation {
  const Compensation({
    required this.action,
    required this.input,
    this.targetNodeIndex,
  });

  /// The verb the compensating run is scored and gated under.
  final String action;

  /// The text the executor looks for in the live dump, exactly as a manual
  /// request's own input is looked for.
  final String input;

  /// A node index, when the inverse aims at a known position rather than at
  /// text. Null for every inverse in [kActionCompensations].
  final int? targetNodeIndex;

  @override
  String toString() => 'Compensation($action on "$input")';
}

/// The inverses this build can dispatch, keyed by the verb they undo.
///
/// This is a capability list, not a heuristic, and it is deliberately short. An
/// entry means the app can name the reverse gesture and send it through the same
/// gated executor the original action used, so an undo is a second gated run
/// rather than a shortcut. An action with no entry has no undo: it is
/// irreversible by construction, the D15 control is not drawn for it, and
/// nothing about it is faked — the app cannot un-tap a button, un-send a
/// message or un-delete a note, so those verbs are absent rather than mapped to
/// something that would merely look like a reversal.
const Map<String, Compensation> kActionCompensations = <String, Compensation>{
  'navigate': Compensation(action: 'navigate_back', input: 'back'),
};

/// The inverse available for [content], or null when it has none.
///
/// A proposal that is not a map, or that names no verb, has no inverse: this
/// decides whether a control is offered, so a guess here would be a control that
/// cannot do what it says.
Compensation? compensationFor(dynamic content) {
  if (content is! Map) return null;
  final String verb = content['action']?.toString().trim().toLowerCase() ?? '';
  if (verb.isEmpty) return null;
  return kActionCompensations[verb];
}

/// One action that ran, and everything an undo of it needs.
///
/// This is the record the A6b window holds. Before it existed the window
/// carried an id and a flag, so the D15 button had no plan to describe, no
/// executor to reach and no inverse to run, which is why it could only ever be
/// drawn disabled.
class UndoableAction {
  UndoableAction({
    required this.plan,
    required this.riskLevel,
    required this.executor,
    required this.outcome,
    required this.compensation,
  }) : description = _describe(plan);

  /// The plan that ran, verbatim: the proposal the gate scored and the executor
  /// dispatched.
  final Plan plan;

  /// The A6 numeric risk level this action was classified at.
  final int riskLevel;

  /// The executor that ran it, kept so the record says who did the work rather
  /// than only that something did.
  final Executor executor;

  /// What the executor answered. Read through [executionConfirmed], never
  /// assumed.
  final Object? outcome;

  /// The inverse for this action's verb, or null when the app cannot name one.
  final Compensation? compensation;

  /// What the user is told happened, built from the real proposal.
  ///
  /// Never the window's own handle: "action undo-1" is a wire id, not a
  /// description of anything a user did.
  final String description;

  /// Whether the platform confirmed the action reached the screen.
  bool get completed => executionConfirmed(outcome);

  /// Whether an undo of this action can be dispatched at all.
  ///
  /// This is what the window publishes as `reversible`, and it is a property of
  /// the action rather than of how its window happened to end.
  bool get isCompensatable => compensation != null;

  /// The proposal, in the words the user chose, with the verb that acted on it.
  static String _describe(Plan plan) {
    final Object? content = plan.content;
    if (content is! Map) return 'an action';
    final String verb = content['action']?.toString().trim() ?? '';
    final String target = content['input']?.toString().trim() ?? '';
    if (verb.isEmpty) return 'an action';
    return target.isEmpty ? verb : '$verb "$target"';
  }

  @override
  String toString() =>
      'UndoableAction($description, risk $riskLevel, '
      'compensatable: $isCompensatable)';
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
// caller passes, announces it while the countdown is still running, and ends it
// when that duration has elapsed or the user cancels. It is handed the
// [UndoableAction] the run produced, and the composition root wires both the
// implementation and the press handler into the app.

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
