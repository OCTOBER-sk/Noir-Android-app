import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/core/agent_wiring.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/safety/policy_engine.dart';
import 'package:noir_android_app/safety/risk_classifier.dart';
import 'package:noir_android_app/safety/screen_content_sanitizer.dart';

/// Fixes the three honesty gaps found on `main`:
///
///  1. `ReflectionEvent` was dead code claiming "A12 FULL" while nothing
///     constructed, consumed or asserted on it.
///  2. `UndoWindow.countdownSeconds` was a hardcoded 5 that never decremented,
///     so `isActive()` could never become false because of elapsed time.
///  3. A comment claimed a `SkillStorage` / `SkillReplay` subsystem exists.
///     It does not: `grep -r "class SkillStorage" lib` returns nothing.
class _Planner extends Planner {
  @override
  Future<Plan> plan(dynamic context) async =>
      const Plan(content: <String, dynamic>{'action': 'save_fact'});
}

class _ZeroRisk extends RiskClassifier {
  @override
  Future<RiskLevel> classify(dynamic content) async => RiskLevel(level: 0);
}

class _Gate extends Gate {
  @override
  Future<bool> check(GateResult policy, RiskLevel risk) async => true;
}

class _Opener extends UndoWindowOpener {
  @override
  Future<UndoState> open(
    int seconds, {
    required UndoableAction action,
    bool allowed = true,
  }) async => UndoState();
}

class _Executor extends Executor {
  _Executor(this.outcome);
  final dynamic outcome;

  @override
  Future<dynamic> run(Plan plan) async => outcome;
}

class _Recovery extends RecoveryEngine {
  @override
  Future<RuntimeResult> executeReflectionRecovery(
    Reflection reflection,
    dynamic executed,
  ) async => RuntimeResult.success('recovered', reflection);
}

AgentRuntimePipeline _pipeline({
  required dynamic executed,
  required PolicyEngine policyEngine,
}) {
  return AgentRuntimePipeline(
    planner: _Planner(),
    riskClassifier: _ZeroRisk(),
    policyEngine: policyEngine,
    gate: _Gate(),
    undoWindow: _Opener(),
    execute: _Executor(executed),
    reflectionCritic: ReflectionCriticImpl(),
    recovery: _Recovery(),
    sanitizer: (List<dynamic> nodes) async =>
        SanitizedResult(const <String>[], const []),
  );
}

/// What the platform answers when a gesture really reached the service. Not a
/// stand-in for success: [executionConfirmed] reads this type, so a window is
/// only opened for an executor that reported exactly this.
final NativeGestureOutcome _executed = const NativeGestureOutcome(
  executed: true,
  verdict: NativeGateVerdict(allowed: true, message: 'ok'),
);

/// The action record the window is opened with, built by hand from the pieces a
/// real run produces: the plan, the executor, the platform's answer, and the
/// compensation for the verb.
UndoableAction _navigation({bool executed = true}) {
  final Plan plan = const Plan(
    content: <String, dynamic>{'action': 'navigate', 'input': 'maps'},
  );
  return UndoableAction(
    plan: plan,
    riskLevel: 1,
    executor: _Executor(_executed),
    outcome: executed
        ? _executed
        : const NativeGestureOutcome(
            executed: false,
            verdict: NativeGateVerdict.blocked(kCodeNativeDispatchFailed),
          ),
    compensation: compensationFor(plan.content),
  );
}

/// Plans a navigation, which is a verb `RiskClassifier` scores STANDARD and for
/// which this build can name an inverse.
class _NavigationPlanner extends Planner {
  @override
  Future<Plan> plan(dynamic context) async => const Plan(
    content: <String, dynamic>{'action': 'navigate', 'input': 'maps'},
  );
}

/// Plans a tap: also STANDARD, and with no inverse.
class _TapPlanner extends Planner {
  @override
  Future<Plan> plan(dynamic context) async => const Plan(
    content: <String, dynamic>{'action': 'tap', 'input': 'maps'},
  );
}

/// An opener that records what it was asked for, so the pipeline's own half of
/// the contract can be asserted without a real countdown running.
class _RecordingOpener extends UndoWindowOpener {
  _RecordingOpener(this.order);

  /// Shared with the executor, so the order of the two stages is recorded
  /// rather than inferred from either one's return value.
  final List<String> order;
  int seconds = -1;
  bool? allowed;
  UndoableAction? action;

  @override
  Future<UndoState> open(
    int seconds, {
    required UndoableAction action,
    bool allowed = true,
  }) async {
    order.add('window');
    this.seconds = seconds;
    this.action = action;
    this.allowed = allowed;
    return UndoState();
  }
}

/// An executor that records the plan it was handed and when it ran, so the
/// order of the two stages is asserted rather than assumed.
class _OrderingExecutor extends Executor {
  _OrderingExecutor(this.order, this.outcome);

  final List<String> order;
  final dynamic outcome;
  Plan? plan;

  @override
  Future<dynamic> run(Plan plan) async {
    order.add('execute');
    this.plan = plan;
    return outcome;
  }
}

AgentRuntimePipeline _navigationPipeline({
  required _RecordingOpener opener,
  required Executor executor,
  Planner? planner,
}) {
  // The opener is a required collaborator here so the caller owns the order
  // record both stages write into.
  return AgentRuntimePipeline(
    planner: planner ?? _NavigationPlanner(),
    // The real classifier, so the risk level the window is offered at is the
    // one the platform would have scored.
    riskClassifier: RiskClassifier(),
    policyEngine: PolicyEngine(),
    gate: _Gate(),
    undoWindow: opener,
    execute: executor,
    reflectionCritic: ReflectionCriticImpl(),
    recovery: _Recovery(),
    sanitizer: (List<dynamic> nodes) async =>
        SanitizedResult(const <String>[], const []),
  );
}

void main() {
  group('ReflectionEvent is real', () {
    test('a confident run carries a ReflectionEvent on its result', () async {
      final RuntimeResult result = await _pipeline(
        executed: 'sent',
        policyEngine: PolicyEngine(),
      ).run(null);

      expect(result.blocked, isFalse);
      expect(result.reflectionEvent, isNotNull);
      expect(result.reflectionEvent!.confidenceScore, 0.92);
      expect(result.reflectionEvent!.degradedToNeedsReview, isFalse);
      expect(result.reflectionEvent!.isConfident(), isTrue);
      expect(result.reflectionEvent!.needsReview(), isFalse);
    });

    test(
      'a degraded run is marked as such and keeps the event after recovery',
      () async {
        final RuntimeResult result = await _pipeline(
          executed: 'action failed',
          policyEngine: PolicyEngine(),
        ).run(null);

        expect(result.reflection, isNotNull);
        expect(result.reflectionEvent, isNotNull);
        expect(result.reflectionEvent!.confidenceScore, lessThan(0.5));
        expect(result.reflectionEvent!.degradedToNeedsReview, isTrue);
        expect(result.reflectionEvent!.isConfident(), isFalse);
        expect(result.reflectionEvent!.needsReview(), isTrue);
      },
    );

    test(
      'a blocked run has no reflection event, because it never reflected',
      () async {
        final PolicyEngine locked = PolicyEngine()..uiLock = true;
        final RuntimeResult result = await _pipeline(
          executed: 'sent',
          policyEngine: locked,
        ).run(null);

        expect(result.blocked, isTrue);
        expect(result.reflectionEvent, isNull);
      },
    );
  });

  group('UndoWindow counts down for real', () {
    test('isActive() is true before the deadline and false after it', () {
      final DateTime start = DateTime.utc(2026, 1, 1, 12);
      DateTime now = start;
      DateTime clock() => now;

      final UndoWindow window = UndoWindow(
        actionId: 'a1',
        seconds: 5,
        openedAt: start,
        clock: clock,
      );

      expect(window.isActive(), isTrue);
      expect(window.countdownSeconds, 5);
      expect(window.remainingSeconds, 5);

      now = start.add(const Duration(seconds: 3));
      expect(window.remainingSeconds, 2);
      expect(window.isActive(), isTrue);

      now = start.add(const Duration(seconds: 6));
      expect(window.remainingSeconds, 0);
      expect(window.isActive(), isFalse);
    });

    test('cancel() ends the window before the deadline', () {
      final UndoWindow window = UndoWindow(actionId: 'a1', seconds: 5);
      expect(window.isActive(), isTrue);
      window.cancel();
      expect(window.isActive(), isFalse);
    });

    test('a window opened with 0 seconds is already over', () {
      expect(UndoWindow(actionId: 'a1', seconds: 0).isActive(), isFalse);
    });
  });

  group('CountdownUndoWindow ends for the right reason', () {
    test('a window nobody cancels reports elapsed, not cancelled', () async {
      final CountdownUndoWindow undo = CountdownUndoWindow();
      final Future<UndoOutcome> first = undo.outcomes.first;

      final Future<UndoState> opened = undo.open(
        1,
        action: _navigation(),
      );
      final UndoOutcome outcome = await first;

      expect(outcome, UndoOutcome.elapsed);
      await opened;
      await undo.dispose();
    });

    test('a window the user cancels reports cancelled', () async {
      final CountdownUndoWindow undo = CountdownUndoWindow();
      final Future<UndoOutcome> first = undo.outcomes.first;

      final Future<UndoState> opened = undo.open(
        30,
        action: _navigation(),
      );
      undo.cancel();

      expect(await first, UndoOutcome.cancelled);
      await opened;
      await undo.dispose();
    });

    test('the window is opened for the duration the caller passed', () async {
      int seen = -1;
      final CountdownUndoWindow undo = CountdownUndoWindow(
        windows: ({required String actionId, required int seconds}) {
          seen = seconds;
          return UndoWindow(actionId: actionId, seconds: seconds);
        },
      );

      final Future<UndoState> opened = undo.open(
        12,
        action: _navigation(),
      );
      expect(seen, 12);
      undo.cancel();
      await opened;
      await undo.dispose();
    });

    test('a disallowed caller gets notAllowed and no window', () async {
      final CountdownUndoWindow undo = CountdownUndoWindow();
      final Future<UndoOutcome> first = undo.outcomes.first;

      await undo.open(5, action: _navigation(), allowed: false);

      expect(await first, UndoOutcome.notAllowed);
      await undo.dispose();
    });

    test('a gesture the platform never confirmed gets notExecuted', () async {
      final CountdownUndoWindow undo = CountdownUndoWindow();
      final Future<UndoOutcome> first = undo.outcomes.first;

      await undo.open(5, action: _navigation(executed: false));

      expect(await first, UndoOutcome.notExecuted);
      await undo.dispose();
    });
  });

  // The window used to open *before* the action, so the toast it published
  // announced a completion that had not happened yet, and there was no action
  // for an Undo press to reach. The ordering below is the fix, and the action
  // the window carries is what makes the press mean something.
  group('the pipeline opens the window on the action that ran', () {
    test('the action runs first, and the window opens on it', () async {
      final List<String> order = <String>[];
      final _RecordingOpener opener = _RecordingOpener(order);
      final _OrderingExecutor executor = _OrderingExecutor(order, _executed);

      await _navigationPipeline(opener: opener, executor: executor).run(null);

      expect(
        order,
        <String>['execute', 'window'],
        reason:
            'a window over an action that has not run is a countdown on '
            'nothing, and the compensation would aim at a screen the action '
            'has not changed yet',
      );
      expect(opener.seconds, 5);
      expect(opener.allowed, isTrue);
    });

    test('the window carries the plan, the outcome and the inverse', () async {
      final List<String> order = <String>[];
      final _RecordingOpener opener = _RecordingOpener(order);
      final _OrderingExecutor executor = _OrderingExecutor(order, _executed);

      await _navigationPipeline(opener: opener, executor: executor).run(null);

      final UndoableAction? action = opener.action;
      expect(action, isNotNull);
      expect(identical(action!.plan, executor.plan), isTrue);
      expect(action.outcome, isNotNull);
      expect(action.completed, isTrue);
      expect(action.riskLevel, 1);
      expect(action.compensation, isNotNull);
      expect(action.isCompensatable, isTrue);
    });

    test('an action with no inverse opens a window that is not reversible', () async {
      final List<String> order = <String>[];
      final _RecordingOpener opener = _RecordingOpener(order);
      final _OrderingExecutor executor = _OrderingExecutor(order, _executed);

      await _navigationPipeline(
        opener: opener,
        executor: executor,
        planner: _TapPlanner(),
      ).run(null);

      expect(opener.allowed, isTrue);
      expect(opener.action!.isCompensatable, isFalse);
      expect(opener.action!.compensation, isNull);
    });

    test('an action the executor could not confirm is carried as such', () async {
      final List<String> order = <String>[];
      final _RecordingOpener opener = _RecordingOpener(order);
      final _OrderingExecutor executor = _OrderingExecutor(
        order,
        NativeGestureOutcome(
          executed: false,
          verdict: const NativeGateVerdict.blocked(kCodeNativeDispatchFailed),
        ),
      );

      await _navigationPipeline(opener: opener, executor: executor).run(null);

      expect(opener.action!.completed, isFalse);
    });

    test('a SAFE action is not offered a window at all', () async {
      final List<String> order = <String>[];
      final _RecordingOpener opener = _RecordingOpener(order);

      // `_Planner` plans `save_fact`, which `RiskClassifier` scores 0, and
      // A6b offers the window for riskLevel >= 1 only.
      await _navigationPipeline(
        opener: opener,
        executor: _OrderingExecutor(order, _executed),
        planner: _Planner(),
      ).run(null);

      expect(opener.allowed, isFalse);
      expect(opener.action!.riskLevel, 0);
    });
  });
}
