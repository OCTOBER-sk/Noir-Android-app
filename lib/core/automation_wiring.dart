// lib/core/automation_wiring.dart — the concrete collaborators of
// `lib/automations`.
//
// `lib/automations` ships a real scheduler, a real dispatch loop and a real
// persistence seam, and it deliberately implements none of the three things that
// decide whether an automation may act: it has no policy rules, no platform
// access and no idea what a user consented to. It takes a
// [AutomationPolicyGate] and an [AutomationExecutor] and trusts them. This file
// is the other half of that trust, and it is the composition root's
// responsibility to get right, so it states what each piece is:
//
//   * [PolicyEngineAutomationGate] asks the *one* [PolicyEngine] in the process —
//     the same instance the platform calls back into through
//     `NativeBridge.evaluateGate` and the same one the A6 pipeline scores with —
//     about the same proposal a manual run would produce. There is no second set
//     of rules, and a scheduled job therefore gets no privilege a manual one
//     would not get.
//   * [ConsentGatedAutomationExecutor] does not act. It calls the composition
//     root's own `runAutomation`, which classifies, asks the policy engine,
//     publishes a confirmation, waits for a human and only then lets
//     [NativeGestureExecutor] reach the platform. A job is therefore gated per
//     run, exactly like the button the user presses.
//
// What is deliberately absent: no default executor, no allow-list of "trusted"
// actions, no way to approve a job without a human in the loop, and no
// interpretation of a job that is not a real [AutomationRequest].
library;

import '../agent/agent_runtime.dart'
    show
        ExecutionSignal,
        RuntimeResult,
        executionConfirmed,
        reportedBlockReason;
import '../automations/automation_models.dart';
import '../safety/policy_engine.dart';
import '../safety/risk_classifier.dart';
import 'agent_wiring.dart';

/// The separator between the verb and the target in a stored job's `action`.
///
/// A scheduled job has to name two things a manual run gets from two UI
/// controls: the action verb the risk classifier scores, and the text the
/// executor aims at on the real screen dump. One stored field carries both, and
/// the split is explicit so a job whose action cannot be read as a request is
/// refused rather than guessed at.
const String kScheduledActionSeparator = '|';

/// A stored job's `action`, split into the two things a run needs.
class ScheduledAction {
  const ScheduledAction({required this.verb, required this.target});

  /// Reads [action] as `verb|target`.
  ///
  /// Throws [AutomationError] with [AutomationError.invalidAction] when either
  /// half is missing. There is no default verb: an action Noir cannot read is
  /// an action Noir refuses to run, and the refusal is recorded on the job.
  factory ScheduledAction.parse(String action) {
    final int split = action.indexOf(kScheduledActionSeparator);
    if (split < 0) {
      throw AutomationError(
        AutomationError.invalidAction,
        detail:
            'a scheduled action is "<verb>$kScheduledActionSeparator<target>", '
            'got "$action"',
      );
    }
    final String verb = action.substring(0, split).trim();
    final String target = action.substring(split + 1).trim();
    if (verb.isEmpty || target.isEmpty) {
      throw AutomationError(
        AutomationError.invalidAction,
        detail: 'a scheduled action needs a verb and a target, got "$action"',
      );
    }
    return ScheduledAction(verb: verb, target: target);
  }

  /// The action verb, e.g. `tap`, `navigate`, `delete`.
  final String verb;

  /// The text the executor looks for in the real screen dump.
  final String target;

  /// The pipeline request this job is, exactly as a manual one would be.
  AutomationRequest toRequest() =>
      AutomationRequest(action: verb, input: target);

  @override
  bool operator ==(Object other) =>
      other is ScheduledAction && other.verb == verb && other.target == target;

  @override
  int get hashCode => Object.hash(verb, target);

  @override
  String toString() => 'ScheduledAction($verb on "$target")';
}

/// Noir's single [PolicyEngine], asked about a scheduled job.
///
/// The gate scores the *same proposal* a manual run would carry, so the
/// blacklist, the UI lock and the biometric rule apply to a job on exactly the
/// terms they apply to a tap. A biometric-demanding job is refused outright,
/// which is the rule `ConsentGate` and `McpComposition` already follow: this
/// build has no biometric binding, so a human tapping "Allow" is not one.
///
/// It denies by default. An approval is only ever produced from a real verdict
/// about a real [Automation] this gate has inspected — the user who asked for
/// the job, the revision it is running under and the verb it is about to run are
/// all part of the proposal, so a job with no user behind it cannot be approved
/// even by a permissive policy.
///
/// It does not re-check the claim. The service hands it the record it has just
/// claimed, so a claim is present on every run this gate is asked about; whether
/// *this* pass owns the occurrence is the service's question, answered inside the
/// repository's atomic update, not something a second opinion here can improve.
class PolicyEngineAutomationGate implements AutomationPolicyGate {
  PolicyEngineAutomationGate({
    required PolicyEngine policy,
    required RiskClassifier riskClassifier,
  }) : _policy = policy,
       _risk = riskClassifier;

  final PolicyEngine _policy;
  final RiskClassifier _risk;

  @override
  Future<PolicyGateDecision> evaluate(Automation automation) async {
    final ScheduledAction action;
    try {
      action = ScheduledAction.parse(automation.action);
    } on AutomationError catch (error) {
      return PolicyGateDecision.denied(
        'the job\'s action is not a request Noir can run: ${error.detail}',
      );
    }
    // A job is only ever authorised by the user who asked for it. An intent
    // with no user is a record that cannot be represented honestly, and a job
    // that cannot name its user is not one anything may act on.
    final String user = automation.createdBy.userId.trim();
    if (user.isEmpty) {
      return const PolicyGateDecision.denied(
        'the job names no user, so nothing may act on its behalf',
      );
    }
    final AutomationRequest request = action.toRequest();
    final RiskLevel risk = await _risk.classify(request.toProposal());
    final GateResult verdict = _policy.gate(<String, dynamic>{
      ...request.toProposal(),
      // Who asked for this, and under which configuration. Extra fields are
      // ignored by the engine's rules and read by whoever audits the verdict.
      'automationId': automation.id,
      'automationName': automation.name,
      'automationRevision': automation.revision,
      'requestedBy': user,
      'scheduled': true,
    }, riskLevel: risk.level);
    if (!verdict.allowed) {
      return PolicyGateDecision.denied('PolicyEngine ${verdict.message}');
    }
    if (verdict.needsBiometric) {
      return PolicyGateDecision.denied(
        '${action.verb} is a risk level ${risk.level} action and the policy '
        'engine wants a biometric. This build has no biometric binding, so a '
        'scheduled job is not run at that level.',
      );
    }
    return PolicyGateDecision.approved(
      'PolicyEngine ${verdict.message} (risk level ${risk.level})',
    );
  }
}

/// The executor a scheduled job runs through.
///
/// It holds no gesture code, no bridge and no shortcut. Every attempt becomes a
/// call to the graph's own `runAutomation`, which is the one entry point to the
/// A6 pipeline: classification, the policy engine, a
/// confirmation published to the UI, the five-second undo window, and only then
/// the platform. There is no argument, no `AutomationExecutor` implementation
/// anywhere in `lib/` that does not pass through it.
///
/// A blocked or absent result is raised as [ScheduledAutomationRefused] rather
/// than swallowed, so the job's run is recorded as failed with the real reason
/// instead of a "succeeded" line for work that never happened.
class ConsentGatedAutomationExecutor implements AutomationExecutor {
  ConsentGatedAutomationExecutor({required this.run});

  /// Runs one already-gated request on the graph. The composition root passes
  /// its own `runAutomation`, late-bound, because a scheduled job can only be
  /// dispatched once the graph exists.
  final Future<RuntimeResult?> Function(AutomationRequest request) run;

  @override
  Future<void> execute(AutomationExecutionContext context) async {
    if (context.token.isCancelled) {
      throw const ScheduledAutomationRefused(
        'the run was cancelled before it reached the gate',
      );
    }
    final ScheduledAction action;
    try {
      action = ScheduledAction.parse(context.automation.action);
    } on AutomationError catch (error) {
      throw ScheduledAutomationRefused(
        'the job\'s action is not a request Noir can run: ${error.detail}',
      );
    }
    final RuntimeResult? result = await run(action.toRequest());
    if (result == null) {
      throw const ScheduledAutomationRefused(
        'the pipeline produced no result: no screen to act on, or it failed',
      );
    }
    if (result.blocked) {
      throw ScheduledAutomationRefused(
        describeAutomationError(_blockReason(result)),
      );
    }
    // Not blocked is not the same as done. A run that was never stopped still
    // has to have been *performed*, and the only thing that says so is the
    // executor's own confirmation — read through `executionConfirmed`, the same
    // reader the undo window and the A12 critic use, so a scheduled job cannot
    // be recorded as succeeded on an answer that reports no work.
    if (!executionConfirmed(result.result)) {
      throw ScheduledAutomationRefused(
        describeAutomationError(_unconfirmedReason(result.result)),
      );
    }
  }
}

/// What a run the executor did not confirm is recorded as having failed with.
///
/// Read through [ExecutionSignal] and never off a rendering: the shipped
/// answer is a `NativeGestureOutcome`, whose default `toString` is
/// `Instance of 'NativeGestureOutcome'`, so the same mistake this file had for
/// [GateResult] would have been repeated here with a different class name.
/// Precedence is the platform's own code first — it is the one a reader can
/// act on — then the reason a stage named, and only then a stated absence.
String _unconfirmedReason(Object? outcome) {
  if (outcome is ExecutionSignal) {
    final String code = outcome.platformCode?.trim() ?? '';
    if (code.isNotEmpty) return code;
    final String reason = reportedBlockReason(outcome)?.trim() ?? '';
    if (reason.isNotEmpty) return reason;
  }
  return 'the platform answered without confirming the action';
}

/// What a blocked scheduled run is recorded as having failed with.
///
/// Three readings of the same run, in order of specificity, and never a
/// rendering: the reason the executor itself named ([RuntimeResult.failureReason],
/// which only exists when a real answer named one), then the gate's own message,
/// then nothing. Read structurally because `GateResult` has no `toString`, so
/// handing it to `describeAutomationError` directly wrote the literal
/// `Instance of 'GateResult'` into a job's `lastError` — a user-facing record
/// that named no reason at all.
String _blockReason(RuntimeResult result) {
  final String? reason = result.failureReason;
  if (reason != null) return reason;
  final Object? outcome = result.result;
  if (outcome is GateResult) return outcome.message;
  return 'BLOCKED';
}

/// A scheduled run that did not complete its work, with the reason it did not.
///
/// Carries the pipeline's own block reason, so what a job's `lastError` says
/// afterwards is what actually stopped it.
class ScheduledAutomationRefused implements Exception {
  const ScheduledAutomationRefused(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
