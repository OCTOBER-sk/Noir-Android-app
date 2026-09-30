// lib/core/agent_wiring.dart — the concrete collaborators of
// [AgentRuntimePipeline].
//
// `lib/agent/agent_runtime.dart` declares the A6 pipeline as a set of abstract
// roles — Planner, Gate, UndoWindowOpener, Executor, RecoveryEngine — and
// nothing in lib/ implemented them, so the pipeline could not be constructed by
// the app at all. This file supplies the five implementations, each built out of
// a system that already exists and each refusing to do the one thing it must
// never do:
//
//   * [ScreenPlanner] reads the real accessibility dump. It never invents a
//     screen, and a dump that could not be read is an error, not an empty plan.
//   * [ConsentGate] is the only source of an approval, it can be satisfied only
//     by a human answering a prompt it published, and it expires. An approval
//     is single-use and bound to one action string.
//   * [CountdownUndoWindow] runs the real 5-second cancellable window from A6b
//     and reports whether it survived to zero.
//   * [NativeGestureExecutor] is the only path that touches the screen, and it
//     refuses to dispatch without a live, unconsumed approval. The platform's
//     own Kotlin gate still runs behind it — this does not replace it.
//   * [SanitizingRecoveryEngine] recovers on *sanitized* screen content only,
//     and never re-executes on its own: a degraded run ends in "needs review"
//     so the next attempt goes through the gate from the top.
//
// Nothing here fabricates. Every value the pipeline consumes comes from the
// accessibility service, the policy engine, the risk classifier, the user, or
// the clock.
library;

import 'dart:async';

import '../agent/agent_runtime.dart';
import '../agent/recovery_engine.dart' as recovery;
import '../agent/task_controller.dart' show TaskController;
import '../core/ui_state_contract.dart';
import '../platform/native_bridge.dart';
import '../safety/policy_engine.dart' show GateResult;
import '../safety/risk_classifier.dart'
    show RiskClassifier, RiskLevel, RiskTier;

export '../agent/task_controller.dart' show TaskController;

/// A request the user made to act on the current screen.
///
/// This is the pipeline's `context`: an action verb the [RiskClassifier]
/// understands, the user's own words as the input, and optionally which node of
/// the real dump to aim at. It carries no screen data — the planner reads that
/// from the accessibility service, so the request cannot smuggle in a screen
/// that is not there.
class AutomationRequest {
  const AutomationRequest({
    required this.action,
    required this.input,
    this.targetNodeIndex,
  }) : assert(action != '', 'an action verb is required');

  /// Verb the risk classifier scores, e.g. `tap`, `navigate`, `delete`.
  final String action;

  /// The user's own text for the action.
  final String input;

  /// Index into the real node dump, or null to let the executor resolve the
  /// first node whose text contains [input].
  final int? targetNodeIndex;

  /// The proposal the policy engine and the platform both score.
  Map<String, dynamic> toProposal() => <String, dynamic>{
    'action': action,
    'input': input,
    if (targetNodeIndex != null) 'targetNodeIndex': targetNodeIndex,
  };

  @override
  String toString() =>
      'AutomationRequest($action on "${input.length} chars"'
      '${targetNodeIndex == null ? '' : ', node $targetNodeIndex'})';
}

/// Reads the real screen and turns a user's request into a [Plan].
///
/// The dump is fetched at plan time rather than being passed in, so a plan can
/// never describe a screen that is not the one the service is holding now.
class ScreenPlanner implements Planner {
  ScreenPlanner({required NativeBridge bridge}) : _bridge = bridge;

  final NativeBridge _bridge;

  @override
  Future<Plan> plan(dynamic context) async {
    if (context is! AutomationRequest) {
      throw ArgumentError.value(
        context,
        'context',
        'ScreenPlanner plans AutomationRequest, got ${context.runtimeType}',
      );
    }
    final NativeNodeDump dump = await _bridge.getNodes();
    if (!dump.available) {
      // Unavailable is not empty. Planning against a screen nobody could read
      // is the one thing that must not happen, so this is an error the caller
      // reports rather than a plan with no nodes.
      throw ScreenUnavailableException(dump.code ?? kCodeNodeDumpUnavailable);
    }
    return Plan(
      content: context.toProposal(),
      screenNodes: List<dynamic>.of(dump.nodes),
    );
  }
}

/// Raised when a plan could not be built because the screen could not be read.
class ScreenUnavailableException implements Exception {
  const ScreenUnavailableException(this.code);

  /// Wire-stable reason the dump was unavailable.
  final String code;

  @override
  String toString() => 'ScreenUnavailableException($code)';
}

/// One confirmation the app is asking a human to answer.
class PendingConfirmation {
  PendingConfirmation({
    required this.requestId,
    required this.action,
    required this.riskLevel,
    required this.message,
    required this.needsBiometric,
  });

  final String requestId;
  final String action;
  final int riskLevel;
  final String message;

  /// Whether the policy engine wants a biometric this build cannot perform.
  final bool needsBiometric;

  bool _answered = false;
  bool? _answer;
  void Function(bool approved)? _onAnswer;

  /// Answers this confirmation. Ignored after the first answer, so a late tap
  /// cannot approve a superseded request, and after the gate has given up
  /// waiting, so silence can never be read as consent.
  bool answer(bool approved) {
    if (_answered) return false;
    _answered = true;
    _answer = approved;
    _onAnswer?.call(approved);
    return true;
  }

  /// Whether the gate is still waiting for this answer.
  bool get isAnswered => _answer != null;

  /// Whether this request could be approved at all on this build.
  ///
  /// False for anything the policy engine wants a biometric for: there is no
  /// biometric binding here, so the answer is a refusal whatever the user taps.
  bool get canBeApproved => !needsBiometric || kConsentCanSatisfyBiometric;

  /// Always false. Stated as a named constant so the reason the Allow control
  /// is inert is visible at the call site instead of implied by an absent
  /// platform channel.
  static const bool kConsentCanSatisfyBiometric = false;

  /// What the human said, or null while they have not said anything.
  bool? get answerValue => _answer;
}

/// The gate between "classified" and "executed".
///
/// Three properties matter and all three are enforced here:
///
///   * It is user-initiated. A confirmation exists only because somebody called
///     [check], and [check] is only reached from a run the user asked for.
///   * It is bounded. [timeout] expires the request and the answer is
///     `false`. Silence is never consent.
///   * It is consent-based. The only way to answer `true` is
///     [PendingConfirmation.answer], and only the UI holds one.
///
/// A `true` answer does not become ambient permission: it is recorded as a
/// single-use approval for that one action string, which
/// [NativeGestureExecutor] consumes by calling [consumeApproval].
///
/// One thing this gate will not do, and it is the same rule
/// `lib/core/mcp_composition.dart` already follows: when the policy engine asks
/// for a biometric, a human tapping "Allow" is not enough. This build has no
/// biometric binding, so a biometric-demanding action is refused outright. The
/// request is still published, so the UI can show the user exactly what was
/// asked and why it cannot be approved here.
class ConsentGate implements Gate {
  ConsentGate({
    this.timeout = const Duration(seconds: 45),
    String Function(int sequence)? requestId,
  }) : _requestId = requestId ?? _defaultRequestId;

  /// How long a human has to answer before the request is refused.
  final Duration timeout;

  final String Function(int sequence) _requestId;
  final StreamController<PendingConfirmation> _requests =
      StreamController<PendingConfirmation>.broadcast();

  /// Action string -> the confirmation request that approved it.
  final Map<String, String> _approvals = <String, String>{};

  int _sequence = 0;

  /// One expiry timer per outstanding request.
  ///
  /// This was a single `Timer? _expiry` field, which deadlocked the whole graph
  /// the moment two requests overlapped: each new `check` cancelled the previous
  /// request's only timer, so that request's `Completer` was never completed and
  /// its `await answer.future` hung forever. That hang propagated up through
  /// `runDueJobs` (whose default `maxConcurrentRuns` is 2, so two due jobs do
  /// overlap), leaving the automation scheduler's `_inFlight` stuck true and
  /// skipping every later tick for the life of the process. The timers are keyed
  /// by request id and only ever cancel themselves.
  final Map<String, Timer> _expiries = <String, Timer>{};

  /// Confirmations waiting for a human. The UI listens here.
  Stream<PendingConfirmation> get requests => _requests.stream;

  /// Actions with a live, unconsumed approval.
  Set<String> get approvedActions => _approvals.keys.toSet();

  @override
  Future<bool> check(GateResult policy, RiskLevel risk) async {
    final String? action = _actionOf(policy.message);
    _sequence++;
    final PendingConfirmation request = PendingConfirmation(
      requestId: _requestId(_sequence),
      action: action ?? 'unknown',
      riskLevel: risk.level,
      message: policy.message,
      needsBiometric: policy.needsBiometric,
    );
    final Completer<bool> answer = Completer<bool>();
    request._onAnswer = (bool approved) {
      if (!answer.isCompleted) answer.complete(approved);
    };
    _requests.add(request);
    // Per-request, so an overlapping request can never cancel this one's only
    // path to settling.
    _expiries[request.requestId] = Timer(timeout, () {
      // Expiry is a refusal. The request stays visible to the UI so it can be
      // rendered as "not answered"; it simply stops being answerable.
      if (!answer.isCompleted) answer.complete(false);
    });
    try {
      final bool approved = await answer.future;
      if (approved && policy.needsBiometric) {
        // A tap is not a biometric. Refuse, and leave no approval behind.
        return false;
      }
      if (approved && action != null) {
        _approvals[action] = request.requestId;
      }
      return approved;
    } finally {
      // Only this request's timer, only once.
      _expiries.remove(request.requestId)?.cancel();
    }
  }

  /// Takes the approval for [action], if there is one, and invalidates it.
  ///
  /// Single use on purpose: an approval covers one dispatch, so a plan that
  /// tries to run twice cannot ride on one tap.
  bool consumeApproval(String action) => _approvals.remove(action) != null;

  /// Withdraws every outstanding approval, e.g. when the UI lock goes on.
  void revokeAll() => _approvals.clear();

  /// Closes the confirmation stream.
  ///
  /// Deliberately does not await [StreamController.close]: a broadcast
  /// controller that never had a subscriber never completes its done future, so
  /// awaiting it would make teardown hang on a gate nobody ever asked.
  Future<void> dispose() async {
    // Every outstanding request's timer, so none of them is left holding the
    // process open after teardown.
    for (final Timer timer in _expiries.values) {
      timer.cancel();
    }
    _expiries.clear();
    _approvals.clear();
    if (!_requests.isClosed) unawaited(_requests.close());
  }

  /// The action out of the message PolicyEngine built, which is always
  /// `Confirmation required: <action>` for an allowed verdict.
  static String? _actionOf(String message) =>
      RegExp(r':\s*(\S+)\s*$').firstMatch(message)?.group(1);

  static String _defaultRequestId(int sequence) => 'confirm-$sequence';
}

/// How an undo window ended.
enum UndoOutcome {
  /// The countdown ran to zero and the action stands.
  elapsed,

  /// The user cancelled inside the window.
  cancelled,

  /// The caller was not allowed to open a window at all.
  notAllowed,

  /// The action the window would have covered never reached the screen, so
  /// there is nothing to reverse and nothing to announce. Its own ending, and
  /// deliberately not [notAllowed]: the caller was allowed, the platform simply
  /// never confirmed a gesture.
  notExecuted,
}

/// The window that is counting down right now, with the action it can still
/// compensate.
///
/// Null from [CountdownUndoWindow.live] means there is no window, which is why
/// a press is refused rather than answered: the action has either already been
/// compensated, already elapsed, or never had one.
class LiveUndoWindow {
  const LiveUndoWindow({
    required this.actionId,
    required this.action,
    required this.window,
  });

  /// The handle the announcement carries and a press hands back.
  final String actionId;

  /// The action that ran, with its plan, its executor and its inverse.
  final UndoableAction action;

  /// The countdown itself, for a caller that wants the deadline rather than
  /// the action.
  final UndoWindow window;

  @override
  String toString() => 'LiveUndoWindow($actionId, $action)';
}

/// The A6b undo window: five seconds, cancellable, and reported as an event.
///
/// Two properties matter, and both used to be wrong.
///
///   * It is announced when it *opens*, not when it ends. Publishing from the
///     ending meant the toast appeared after the countdown it belonged to was
///     over, so its control could not be pressed in time — which is the whole
///     reason the D15 button was drawn disabled and captioned "undo is not wired
///     to an action executor yet".
///   * What it announces as `reversible` is whether the action can be
///     compensated, read off the [UndoableAction] it was handed. It used to be
///     `outcome == UndoOutcome.cancelled`, which made an action reversible only
///     after the user had already reversed it and irreversible whenever nobody
///     pressed anything.
///
/// [AgentRuntimePipeline] takes the result as a bare `UndoState` because that is
/// the type the pipeline interface declares, so the observable outcome travels
/// on [outcomes] and as an [ActionCompletedWithUndoWindow] instead of being
/// discarded.
class CountdownUndoWindow implements UndoWindowOpener {
  CountdownUndoWindow({
    UndoWindow Function({required String actionId, required int seconds})?
    windows,
    this.publish,
  }) : _windows = windows ?? UndoWindow.new;

  final UndoWindow Function({required String actionId, required int seconds})
  _windows;

  /// Where the window is announced. The composition root forwards this to the
  /// UI event stream.
  final void Function(ActionCompletedWithUndoWindow event)? publish;

  final StreamController<UndoOutcome> _outcomes =
      StreamController<UndoOutcome>.broadcast();

  /// Ends the window that is counting down right now, if any.
  void Function(UndoOutcome outcome)? _finishCurrent;

  /// The action the live window is offering, while one is open. The composition
  /// root reads it to answer a press; nothing else may.
  LiveUndoWindow? _live;

  int _sequence = 0;

  /// How each window that has been opened ended.
  Stream<UndoOutcome> get outcomes => _outcomes.stream;

  /// The window counting down right now, or null. This is the whole of what an
  /// undo press is allowed to act on.
  LiveUndoWindow? get live => _live;

  @override
  Future<UndoState> open(
    int seconds, {
    required UndoableAction action,
    bool allowed = true,
  }) async {
    if (!allowed) {
      _outcomes.add(UndoOutcome.notAllowed);
      return UndoState();
    }
    if (!action.completed) {
      // The platform never confirmed a gesture, so there is no completion to
      // announce and nothing an undo could reverse. Reported as its own ending
      // rather than swallowed, so a caller watching [outcomes] can tell this
      // apart from a window nobody was allowed to open.
      _outcomes.add(UndoOutcome.notExecuted);
      return UndoState();
    }
    _sequence++;
    final String actionId = 'undo-$_sequence';
    // The window is opened for exactly the duration the caller asked for, so
    // `open(30, ...)` really does give the user 30 seconds.
    final UndoWindow window = _windows(actionId: actionId, seconds: seconds);
    final Completer<UndoState> done = Completer<UndoState>();
    Timer? ticker;
    Timer? expiry;
    void finish(UndoOutcome outcome) {
      // The one re-entrancy guard. It has to be the only guard: an earlier
      // version also returned early when `_finishCurrent` was null, which sat
      // between the guard and the publish, so the announcement and the outcome
      // could be dropped even though the window had ended.
      if (done.isCompleted) return;
      ticker?.cancel();
      expiry?.cancel();
      _outcomes.add(outcome);
      done.complete(UndoState());
    }

    _finishCurrent = finish;
    // Published before the first await, so the toast is on screen while the
    // countdown is still running. The live record is in place before it is
    // published too, so a press that arrives with the announcement already has
    // an action to press it on.
    _live = LiveUndoWindow(actionId: actionId, action: action, window: window);
    publish?.call(
      ActionCompletedWithUndoWindow(
        action.description,
        action.isCompensatable,
        Duration(seconds: seconds),
        actionId,
      ),
    );
    // Two endings, and only two. Cancellation is the user's decision, reported
    // as `cancelled`; running out of time is the clock's, reported as
    // `elapsed`. The ticker watches only for the user's decision, so a window
    // that simply times out is never mislabelled as a cancellation.
    ticker = Timer.periodic(const Duration(milliseconds: 250), (Timer timer) {
      if (window.cancelled) {
        finish(UndoOutcome.cancelled);
      } else if (!window.isActive()) {
        finish(UndoOutcome.elapsed);
      }
    });
    expiry = Timer(
      Duration(seconds: seconds),
      () => finish(UndoOutcome.elapsed),
    );
    try {
      return await done.future;
    } finally {
      _finishCurrent = null;
      _live = null;
    }
  }

  /// Cancels the window currently counting down, if any.
  void cancel() => _finishCurrent?.call(UndoOutcome.cancelled);

  /// Closes the outcome stream without awaiting its done future, for the same
  /// reason [ConsentGate.dispose] does not.
  Future<void> dispose() async {
    cancel();
    if (!_outcomes.isClosed) unawaited(_outcomes.close());
  }
}

/// The only path from the pipeline to the screen.
///
/// Three things it will not do:
///
///   * dispatch without a live approval from [gate] (consumed on use),
///   * dispatch to a target it resolved from its own imagination — the bounds
///     come from the node in the real dump,
///   * report success the platform did not confirm. `NativeBridge` already
///     fails closed on a missing or `executed != true` reply, and that outcome
///     is passed through untouched so the reflection critic can see it.
class NativeGestureExecutor implements Executor {
  NativeGestureExecutor({
    required NativeBridge bridge,
    required ConsentGate gate,
    this.publish,
  }) : _bridge = bridge,
       _gate = gate;

  final NativeBridge _bridge;
  final ConsentGate _gate;

  /// Where tool lifecycle is announced on the UI event stream.
  ///
  /// `ToolCallStarted` / `ToolCallCompleted` are the only place in the app that
  /// knows a tool genuinely began and genuinely finished, so this is their
  /// emitter. The composition root forwards this to [NoirTaskRun.emit]. Left
  /// null in tests that only care about the dispatch outcome.
  final void Function(NoirUiEvent event)? publish;

  @override
  Future<dynamic> run(Plan plan) async {
    final Object? content = plan.content;
    if (content is! Map) {
      return NativeGestureOutcome.blocked(
        const NativeGateVerdict.blocked(kCodeMalformedGateRequest),
      );
    }
    final Map<String, dynamic> proposal = Map<String, dynamic>.from(content);
    final String action = proposal['action']?.toString() ?? 'unknown';

    if (!_gate.consumeApproval(action)) {
      return NativeGestureOutcome.blocked(
        const NativeGateVerdict.blocked(kCodeConfirmationRequired),
      );
    }

    final List<Map<String, dynamic>> nodes = <Map<String, dynamic>>[
      for (final dynamic node in plan.screenNodes)
        if (node is Map<String, dynamic>) node,
    ];
    final GestureBounds? bounds = _resolveBounds(proposal, nodes);
    if (bounds == null) {
      return NativeGestureOutcome.blocked(
        const NativeGateVerdict.blocked(kCodeMalformedGestureTarget),
      );
    }

    // Announced only now: past the approval, and only once the gesture target
    // actually resolved. An event emitted earlier would claim a tool run that
    // the executor then refused to make.
    final RiskLevel risk = await _classifyForDisplay(proposal);
    publish?.call(ToolCallStarted(action, risk.level));

    final dynamic outcome = await _bridge.dispatchGesture(
      proposal: proposal,
      bounds: bounds,
      // True because [ConsentGate] holds no approval for this action any more:
      // it was just consumed above. The platform still re-runs the Dart
      // PolicyEngine through `policyGate` before it touches anything.
      confirmed: true,
    );
    // `executed` is the only field the bridge documents as meaning a gesture
    // really reached the accessibility service, so it is the only thing allowed
    // to decide success here.
    final bool executed = outcome is NativeGestureOutcome && outcome.executed;
    publish?.call(ToolCallCompleted(action, executed));
    return outcome;
  }

  /// The risk level the UI shows, from the same classifier the bridge uses.
  ///
  /// Falls back to the highest tier, matching the bridge's own fail-closed
  /// rule: a classification failure must never look like a low-risk action.
  Future<RiskLevel> _classifyForDisplay(Map<String, dynamic> proposal) async {
    try {
      return await _bridge.riskClassifier.classify(proposal);
    } catch (_) {
      return RiskLevel(level: 3);
    }
  }

  /// The screen rectangle of the node the plan named, or of the first node
  /// whose text the action's input points at.
  static GestureBounds? _resolveBounds(
    Map<String, dynamic> proposal,
    List<Map<String, dynamic>> nodes,
  ) {
    if (nodes.isEmpty) return null;
    final Object? index = proposal['targetNodeIndex'];
    if (index is int && index >= 0 && index < nodes.length) {
      return GestureBounds.fromNode(nodes[index]);
    }
    final String needle =
        proposal['input']?.toString().trim().toLowerCase() ?? '';
    if (needle.isEmpty) return null;
    for (final Map<String, dynamic> node in nodes) {
      final Object? text = node['text'];
      if (text is String && text.toLowerCase().contains(needle)) {
        return GestureBounds.fromNode(node);
      }
    }
    return null;
  }
}

/// The A4 recovery path, on sanitized content only.
///
/// A low-confidence reflection is not retried here. Retrying would either skip
/// the gate — which C2 forbids and this class will not do — or re-enter it
/// invisibly. Instead the run ends as `RECOVERY_NEEDS_REVIEW`: the audit entry
/// is produced by the real `executeReflectionRecovery` and handed to [onAudit],
/// and the user starts a fresh run, which goes through classification, the gate
/// and confirmation again from the top.
///
/// What the executor said went wrong travels out with that result, on
/// [RuntimeResult.failureReason], so a caller that has to report the failure can
/// report the specific one. It is deliberately not folded into the block code:
/// the code means "this run needs review" and the Safety Center's row says
/// exactly that today, and it is still going to say it.
class SanitizingRecoveryEngine extends RecoveryEngine {
  SanitizingRecoveryEngine({required TaskController tasks, this.onAudit})
    : _tasks = tasks;

  final TaskController _tasks;

  /// Where the A4 audit entry is announced, when something is listening.
  ///
  /// The composition root injects its own safety log, which is the same
  /// `Stream<SafetyEventState>` every other decision reaches the Safety Center
  /// through — so a run that ends `RECOVERY_NEEDS_REVIEW` shows up there with
  /// its task id, its confidence and the path that was chosen, instead of being
  /// a record only this object holds.
  ///
  /// Null is honest and silent: the entry is still built and still kept in
  /// [auditTrail], it simply has nowhere to go. A local fallback sink is never
  /// installed, because a log nobody can read is a claim, not a record.
  final void Function(recovery.RecoveryAudit audit)? onAudit;

  /// Audit entries this engine has produced, oldest first, in the wire shape
  /// `lib/agent/recovery_engine.dart` has always produced. One entry per recovery
  /// run, from the same [recovery.RecoveryAudit] that [onAudit] is handed.
  final List<Map<String, dynamic>> auditTrail = <Map<String, dynamic>>[];

  @override
  Future<RuntimeResult> executeReflectionRecovery(
    Reflection reflection,
    dynamic executed,
  ) async {
    final recovery.HierarchicalRecovery plan = recovery.HierarchicalRecovery(
      _tasks.taskId,
      (reflection.confidence * 100).round(),
    );
    // The one record for this run. It is neither rebuilt nor invented downstream:
    // the map below and the event the Safety Center shows are two views of it.
    final recovery.RecoveryAudit audit = recovery.executeReflectionRecovery(
      plan,
      // Sanitized text only. The raw dump is never handed to the recovery path,
      // so a hidden node cannot steer a retry.
      sanitizedScreen: const <String>[],
    );
    auditTrail.add(audit.toMap());
    onAudit?.call(audit);
    _tasks.transitionTo(TaskState.recovering);
    _tasks.transitionTo(TaskState.failed);
    return RuntimeResult.blocked(
      GateResult.blocked('RECOVERY_NEEDS_REVIEW'),
      // Why the run did not complete, when the executor's own answer names a
      // reason — read off that answer through the interface, the same way the
      // A12 critic scored it, and never off a rendering of it.
      //
      // It is carried beside the block code, not written into it. The Safety
      // Center's row is built from the audit entry above and its
      // `RECOVERY_NEEDS_REVIEW` meaning is unchanged; what this adds is a second
      // reading of the same run for the callers that have to say what actually
      // went wrong — the D15 undo toast being the one that exists today.
      //
      // `null` is a real answer and not a gap: a recovery run can be entered for
      // something other than an executor failure, and in that case the code above
      // is the whole truth.
      failureReason: reportedBlockReason(executed),
    );
  }
}

/// The A5 task state machine, wired to the A6 pipeline and to the UI contract.
///
/// [AgentRuntimePipeline] is a set of `await`s with no state of its own, so the
/// state a user sees would otherwise have to be invented at the call site. This
/// holder is the single place a pipeline stage becomes a [TaskState], which is
/// what makes `LiveTaskView` able to show a real timeline.
class NoirTaskRun {
  NoirTaskRun({String? taskId, TaskController? controller})
    : controller =
          controller ?? TaskController(taskId: taskId ?? _nextTaskId());

  final TaskController controller;

  final StreamController<NoirUiEvent> _events =
      StreamController<NoirUiEvent>.broadcast();

  static int _taskSequence = 0;

  static String _nextTaskId() {
    _taskSequence++;
    return 'task-$_taskSequence';
  }

  /// Every event this run has produced, in order. The Command Centre and the
  /// Live Task view both read this; nothing else publishes.
  Stream<NoirUiEvent> get events => _events.stream;

  /// The events emitted so far, mirrored into the A5 task controller's history.
  List<NoirUiEvent> get history => controller.eventHistory;

  /// The current A5 state.
  TaskState get state => controller.currentState;

  /// Publishes [event] and records it in the task history.
  void emit(NoirUiEvent event) {
    controller.emitEvent(event);
    if (!_events.isClosed) _events.add(event);
  }

  /// Moves the task to [next] and publishes the matching contract event.
  void transitionTo(TaskState next) {
    if (controller.currentState == next) return;
    controller.transitionTo(next);
    if (!_events.isClosed) _events.add(TaskStateChanged(next));
  }

  /// Announces that a gated action is waiting on a human.
  void announceConfirmation({
    required String action,
    required int riskTier,
    required String toolName,
    required bool screenContentWasSanitized,
  }) => emit(
    ConfirmationRequired(
      'Confirm $action',
      riskTier,
      toolName,
      screenContentWasSanitized,
    ),
  );

  /// Closes the event stream without awaiting its done future: a broadcast
  /// controller with no subscriber never completes `close()`'s future, and
  /// teardown must not hang because nothing was listening.
  Future<void> close() async {
    if (!_events.isClosed) unawaited(_events.close());
  }
}

/// Risk tier -> the A6 numeric level, so a UI can render one number.
int riskTierLevel(RiskTier tier) => RiskClassifier.tierMap[tier] ?? 0;
