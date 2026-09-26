import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/core/agent_wiring.dart';
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
  Future<UndoState> open(int seconds, {bool allowed = true}) async =>
      UndoState();
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

      final Future<UndoState> opened = undo.open(1);
      final UndoOutcome outcome = await first;

      expect(outcome, UndoOutcome.elapsed);
      await opened;
      await undo.dispose();
    });

    test('a window the user cancels reports cancelled', () async {
      final CountdownUndoWindow undo = CountdownUndoWindow();
      final Future<UndoOutcome> first = undo.outcomes.first;

      final Future<UndoState> opened = undo.open(30);
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

      final Future<UndoState> opened = undo.open(12);
      expect(seen, 12);
      undo.cancel();
      await opened;
      await undo.dispose();
    });

    test('a disallowed caller gets notAllowed and no window', () async {
      final CountdownUndoWindow undo = CountdownUndoWindow();
      final Future<UndoOutcome> first = undo.outcomes.first;

      await undo.open(5, allowed: false);

      expect(await first, UndoOutcome.notAllowed);
      await undo.dispose();
    });
  });
}
