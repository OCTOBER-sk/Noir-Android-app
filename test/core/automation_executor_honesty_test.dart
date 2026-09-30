// test/core/automation_executor_honesty_test.dart — the executor's own contract,
// driven at its injectable `run` seam.
//
// test/integration/scheduled_automation_test.dart proves the same rule through
// the real graph, but every unconfirmed run the pipeline produces scores under
// 0.5 on the A12 ladder and is therefore routed to recovery before the executor
// ever sees it. That makes the executor's unconfirmed branch unreachable through
// the pipeline today — so it is proved here directly, at the seam the class was
// built to accept, rather than being left as a claim no test can fail.

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/automations/automation_models.dart';
import 'package:noir_android_app/core/automation_wiring.dart';
import 'package:noir_android_app/safety/policy_engine.dart';

/// A real `ExecutionReport` that reports the gesture did not happen, and says
/// why in the platform's own vocabulary.
class _RefusedReport implements ExecutionSignal {
  const _RefusedReport();

  @override
  bool get executed => false;

  @override
  String? get platformCode => 'NATIVE_DISPATCH_FAILED';

  @override
  String? get blockReason => 'the node moved before the tap';

  @override
  bool? get gateGranted => true;
}

/// A real `ExecutionReport` reporting the gesture did happen.
class _ConfirmedReport implements ExecutionReport {
  const _ConfirmedReport();

  @override
  bool get executed => true;
}

void main() {
  final DateTime now = DateTime.now().toUtc();
  final UserIntent intent = UserIntent(userId: 'u-1', requestedAt: now);
  final Automation job = Automation(
    id: 'morning',
    name: 'Morning digest',
    action: 'read_screen|Send message',
    schedule: AutomationSchedule.interval(every: const Duration(hours: 1)),
    enabled: true,
    createdBy: intent,
    createdAt: now,
    updatedAt: now,
    maxAttempts: 3,
    revision: 1,
  );

  AutomationExecutionContext context() => AutomationExecutionContext(
    automation: job,
    intent: intent,
    runId: 'run-1',
    attempt: 1,
    scheduledFor: now,
    token: CancellationToken(),
  );

  /// The reason the executor refused with, or null if it did not refuse.
  Future<String?> reasonFor(RuntimeResult result) async {
    final ConsentGatedAutomationExecutor executor =
        ConsentGatedAutomationExecutor(run: (dynamic _) async => result);
    try {
      await executor.execute(context());
      return null;
    } on ScheduledAutomationRefused catch (refused) {
      return refused.reason;
    }
  }

  group('the executor refuses a run that did not happen', () {
    test('an unconfirmed report is refused, not reported as done', () async {
      // Not blocked — the run was never stopped — and not performed. Those are
      // different failures, and a scheduled job must not record the second as a
      // success.
      final String? reason = await reasonFor(
        RuntimeResult.success(
          const _RefusedReport(),
          Reflection(confidence: 0.92),
        ),
      );

      expect(
        reason,
        isNotNull,
        reason: 'an unconfirmed answer is not a completion',
      );
      expect(
        reason,
        isNot(contains('Instance of')),
        reason: 'the refusal must name something, not render an object',
      );
    });

    test(
      'a blocked run names the executor\'s own reason, not the block code',
      () async {
        final String? reason = await reasonFor(
          RuntimeResult.blocked(
            GateResult.blocked('RECOVERY_NEEDS_REVIEW'),
            failureReason: 'NATIVE_DISPATCH_FAILED',
          ),
        );

        expect(
          reason,
          'NATIVE_DISPATCH_FAILED',
          reason: 'the specific code beats the blanket one, as it does for D15',
        );
      },
    );

    test(
      'a blocked run with no reason falls back to the gate\'s message',
      () async {
        final String? reason = await reasonFor(
          RuntimeResult.blocked(GateResult.blocked('POLICY_DENIED')),
        );

        expect(
          reason,
          'POLICY_DENIED',
          reason: 'GateResult has no toString; its message is the truth',
        );
      },
    );

    test('a confirmed run is not refused', () async {
      // The fail-closed check must not swallow the success path: a job that
      // really did its work has to stay a success.
      final String? reason = await reasonFor(
        RuntimeResult.success(
          const _ConfirmedReport(),
          Reflection(confidence: 0.92),
        ),
      );

      expect(reason, isNull);
    });
  });
}
