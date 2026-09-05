import 'task_controller.dart';

/// Hierarchical recovery ladder (V2.1 §7 A4).
///
/// Thin slice implements steps 1-4; steps 5-7 are stubbed to [askUser].
enum RecoveryStep {
  /// Retry the failed tool once (ladder steps 1-2).
  retryOnce,

  /// Re-plan the task with updated context (ladder step 3).
  rePlan,

  /// Escalate to the user for guidance (ladder step 4).
  askUser,

  /// Restart the task from the beginning (ladder step 5 — stubbed).
  restart,

  /// Mark the task as permanently failed (ladder step 6 — stubbed).
  failPermanently,

  /// Defer work to a background job (ladder step 7a — stubbed).
  deferBackground,

  /// Abort and clean up resources (ladder step 7b — stubbed).
  abortAndCleanup,
}

/// Hierarchical recovery engine driving the 7-step ladder (V2.1 §7 A4).
///
/// Thin slice implements the first 4 steps; steps 5-7 are stubbed and
/// currently return [RecoveryStep.askUser] with reason "not yet implemented".
class RecoveryEngine {
  /// Injected task controller that owns the lifecycle state.
  final TaskController controller;

  /// Maximum retry attempts before escalating to re-plan.
  final int maxRetries;

  /// Per-tool attempt counters keyed by `toolName`.
  final Map<String, int> _attempts = {};

  RecoveryEngine._(this.controller, this.maxRetries);

  /// Creates a [RecoveryEngine] bound to [controller].
  ///
  /// [maxRetries] defaults to 2 per spec.
  factory RecoveryEngine(TaskController controller, {int maxRetries = 2}) {
    return RecoveryEngine._(controller, maxRetries);
  }

  /// Handles an [error] for the tool identified by [toolName].
  ///
  /// Tracks attempt count per tool and returns the next [RecoveryStep]
  /// per the 7-step ladder:
  /// * attempts 1..[maxRetries] → [RecoveryStep.retryOnce]
  /// * attempt [maxRetries]+1 → [RecoveryStep.rePlan]
  /// * any further attempt → [RecoveryStep.askUser]
  ///
  /// Steps 5-7 are stubbed and currently also return [RecoveryStep.askUser]
  /// with reason "not yet implemented".
  Future<RecoveryStep> handleError(
    Object error, {
    String? toolName,
    Map<String, dynamic>? args,
  }) async {
    final key = toolName ?? '__default__';
    final current = _attempts[key] ?? 0;
    final next = current + 1;
    _attempts[key] = next;
    if (next <= maxRetries) {
      return RecoveryStep.retryOnce;
    }
    if (next == maxRetries + 1) {
      return RecoveryStep.rePlan;
    }
    // Steps 4-7 thin slice: askUser. Steps 5-7 stubbed with same return
    // and reason "not yet implemented" (caller may log the reason).
    return RecoveryStep.askUser;
  }

  /// Clears the attempt counter for [toolName].
  void reset(String toolName) {
    _attempts.remove(toolName);
  }
}
