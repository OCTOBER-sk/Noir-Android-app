// lib/automations/automation_service.dart
// The scheduled automation subsystem: CRUD, deterministic next-run maths,
// bounded dispatch, cooperative cancellation and the execution log.
//
// What this service deliberately does not do:
//
//  * It never reads the system clock. Time arrives through an injected [Clock],
//    so "is this due" and "when is it next due" have exact answers under test.
//  * It never touches Android, the device, the network or any other subsystem.
//    Dispatch is: ask the injected gate, then call the injected executor.
//  * It never creates a job of its own accord. Every job needs a [UserIntent],
//    so only a user request can start one.
//  * It never retries past the bound the caller put on the job, and it never
//    invents a schedule that is not either an interval or an explicit instant.

import '../core/clock.dart';
import 'automation_models.dart';

export 'automation_models.dart';

/// A wait between retry attempts. The default is immediate, which is what keeps
/// dispatch deterministic; a caller that wants a backoff injects its own.
typedef AutomationSleeper = Future<void> Function(Duration delay);

Future<void> _noDelay(Duration _) => Future<void>.value();

class AutomationService {
  /// Creates a service over an injected [repository], [gate] and [executor].
  ///
  /// All three are required on purpose. There is no default executor, so a
  /// caller that forgets to wire one gets a compile error rather than a service
  /// that quietly does nothing, and a caller that forgets the gate gets
  /// [DenyAllPolicyGate] rather than an unguarded dispatcher.
  AutomationService({
    required this.repository,
    required this.gate,
    required this.executor,
    Clock? clock,
    this.maxConcurrentRuns = 2,
    this.maxLogEntries = 100,
    this.retryDelay = Duration.zero,
    AutomationSleeper sleeper = _noDelay,
  }) : clock = clock ?? const SystemClock(),
       _sleeper = sleeper {
    if (maxConcurrentRuns < 1) {
      throw const AutomationError(
        AutomationError.invalidConcurrency,
        detail: 'maxConcurrentRuns must be at least 1',
      );
    }
    if (maxLogEntries < 1) {
      throw const AutomationError(
        AutomationError.invalidLogRetention,
        detail: 'maxLogEntries must be at least 1',
      );
    }
    if (retryDelay < Duration.zero) {
      throw const AutomationError(
        AutomationError.invalidInterval,
        detail: 'retryDelay must not be negative',
      );
    }
  }

  final AutomationRepository repository;
  final AutomationPolicyGate gate;
  final AutomationExecutor executor;
  final Clock clock;

  /// How many jobs may be in flight during one [runDueJobs] call. Jobs beyond
  /// this stay pending, in selection order.
  final int maxConcurrentRuns;

  /// How many run records the execution log keeps. The oldest are dropped.
  final int maxLogEntries;

  /// How long to wait before a retry attempt. Zero by default.
  final Duration retryDelay;

  final AutomationSleeper _sleeper;

  /// Run records in completion order; the log is served from the end.
  final List<AutomationRun> _log = <AutomationRun>[];

  /// Ids currently executing, with the token the executor can be stopped by.
  final Map<String, CancellationToken> _running = <String, CancellationToken>{};

  /// Ids selected by the in-flight [runDueJobs] but not started yet.
  final Set<String> _pending = <String>{};

  /// Ids cancelled while still pending, consumed by the worker that reaches
  /// them so the run is recorded as cancelled without being executed.
  final Set<String> _cancelWhilePending = <String>{};

  int _runSequence = 0;

  /// Ids executing right now.
  Set<String> get runningIds => Set<String>.unmodifiable(_running.keys);

  /// Ids picked up by an in-flight dispatch that have not started yet.
  Set<String> get pendingIds => Set<String>.unmodifiable(_pending);

  /// The execution log, newest first, optionally filtered to one job.
  ///
  /// The result is an unmodifiable snapshot ordered by when each run finished,
  /// so a caller can bind it to a list without owning the service's state.
  List<AutomationRun> log({String? automationId, int? limit}) {
    final Iterable<AutomationRun> rows = automationId == null
        ? _log.reversed
        : _log.reversed.where(
            (AutomationRun run) => run.automationId == automationId,
          );
    final List<AutomationRun> out = rows.toList();
    if (limit != null && limit >= 0 && out.length > limit) {
      return List<AutomationRun>.unmodifiable(out.sublist(0, limit));
    }
    return List<AutomationRun>.unmodifiable(out);
  }

  /// The job stored under [id], or null.
  Future<Automation?> find(String id) => repository.find(id);

  /// Every job, ordered by id.
  Future<List<Automation>> list() => repository.list();

  /// The immutable history of [id], oldest first.
  Future<List<AutomationRevision>> history(String id) =>
      repository.revisions(id);

  // --- CRUD ---------------------------------------------------------------

  /// Creates a user-requested job.
  ///
  /// [firstRunAt] is when the schedule starts counting; the first run is the
  /// next instant after it, so passing a past value makes the job due
  /// immediately. For a one-shot it is the instant itself, and disagreeing with
  /// the schedule is rejected.
  ///
  /// Throws [AutomationError] with [AutomationError.duplicateId] rather than
  /// overwriting an existing job, and never returns a job without a valid
  /// schedule.
  Future<Automation> create({
    required String id,
    required String name,
    required String action,
    required AutomationSchedule schedule,
    required UserIntent intent,
    int maxAttempts = 1,
    bool enabled = true,
    DateTime? firstRunAt,
  }) async {
    final String jobId = _requireText(id, AutomationError.emptyId, 'id');
    final String jobName = _requireText(
      name,
      AutomationError.emptyName,
      'name',
    );
    final String jobAction = _requireText(
      action,
      AutomationError.emptyAction,
      'action',
    );
    _requireUserIntent(intent);
    _requireMaxAttempts(maxAttempts);

    final DateTime now = clock.now();
    if (intent.requestedAt.toUtc().isAfter(now)) {
      throw AutomationError(
        AutomationError.requestedInFuture,
        id: jobId,
        detail:
            'a user cannot have asked for this at '
            '${intent.requestedAt.toUtc().toIso8601String()}',
      );
    }
    final DateTime start = (firstRunAt ?? now).toUtc();
    final DateTime? next = _firstRun(schedule, start, now);
    if (next == null) {
      throw AutomationError(
        AutomationError.invalidSchedule,
        id: jobId,
        detail: '$schedule cannot fire after ${now.toIso8601String()}',
      );
    }
    // A one-shot fires at its own instant and nowhere else, so a caller that
    // names a different start instant is contradicting itself.
    if (schedule.kind == AutomationScheduleKind.once &&
        firstRunAt != null &&
        start != schedule.onceAt) {
      throw AutomationError(
        AutomationError.invalidSchedule,
        id: jobId,
        detail: '$schedule does not fire at ${start.toIso8601String()}',
      );
    }

    final Automation created = Automation(
      id: jobId,
      name: jobName,
      action: jobAction,
      schedule: schedule,
      enabled: enabled,
      maxAttempts: maxAttempts,
      createdBy: intent,
      createdAt: now,
      updatedAt: now,
      revision: 1,
      nextRunAt: next,
    );
    final Automation stored = await repository.insert(created);
    await _record(stored, AutomationChange.created);
    return stored;
  }

  /// Changes a job's configuration and opens a new revision.
  ///
  /// Omitted arguments keep their current value. Changing [schedule] or
  /// re-arming a job with [firstRunAt] recomputes [Automation.nextRunAt] from
  /// the injected clock; everything else leaves it alone.
  Future<Automation> update(
    String id, {
    String? name,
    String? action,
    AutomationSchedule? schedule,
    int? maxAttempts,
    DateTime? firstRunAt,
  }) {
    return _change(id, AutomationChange.edited, (Automation current) {
      final DateTime now = clock.now();
      final AutomationSchedule nextSchedule = schedule ?? current.schedule;
      // Re-arming is deliberate: a new schedule or a new start instant means
      // the next run has to be worked out again. Without one the job keeps
      // the due time it already had.
      final bool rearm = schedule != null || firstRunAt != null;
      final DateTime? next = rearm
          ? _firstRun(nextSchedule, (firstRunAt ?? now).toUtc(), now)
          : null;
      if (rearm && next == null) {
        throw AutomationError(
          AutomationError.invalidSchedule,
          id: id,
          detail: '$nextSchedule cannot fire after ${now.toIso8601String()}',
        );
      }
      // copyWith treats a null argument as "leave this alone", so the fields
      // the caller did not mention are untouched.
      return current.copyWith(
        name: name == null
            ? null
            : _requireText(name, AutomationError.emptyName, 'name'),
        action: action == null
            ? null
            : _requireText(action, AutomationError.emptyAction, 'action'),
        schedule: schedule,
        maxAttempts: maxAttempts == null
            ? null
            : _requireMaxAttempts(maxAttempts),
        nextRunAt: next,
        updatedAt: now,
        revision: current.revision + 1,
      );
    });
  }

  /// Switches a job off. A disabled job is never due, whatever its next run.
  Future<Automation> disable(String id) => _change(
    id,
    AutomationChange.disabled,
    (Automation current) => current.copyWith(
      enabled: false,
      updatedAt: clock.now(),
      revision: current.revision + 1,
    ),
  );

  /// Switches a job on and re-arms it.
  ///
  /// The next run is recomputed from the injected clock, so a job that was off
  /// for a week does not fire a week of backlog. A one-shot whose instant passed
  /// while it was off comes back with no next run: it cannot be re-armed.
  Future<Automation> enable(String id) =>
      _change(id, AutomationChange.enabled, (Automation current) {
        final DateTime now = clock.now();
        final DateTime? next = current.schedule.nextRunAfter(now);
        return current.copyWith(
          enabled: true,
          nextRunAt: next,
          clearNextRunAt: next == null,
          updatedAt: now,
          revision: current.revision + 1,
        );
      });

  /// Removes a job. Returns false when there was nothing to remove.
  ///
  /// A job that is running right now is cancelled first, so a delete never
  /// leaves an executor running against a job the user just removed. History
  /// survives the delete: it is append-only audit history, not live state.
  Future<bool> delete(String id) async {
    if (_running.containsKey(id) || _pending.contains(id)) {
      cancel(id, 'job deleted');
    }
    return repository.delete(id);
  }

  // --- dispatch -----------------------------------------------------------

  /// Runs every job that is due, with at most [maxConcurrentRuns] in flight.
  ///
  /// Jobs are selected in due order — earliest due time first, then id — and
  /// each is claimed before it starts, so a second call while this one is
  /// running cannot execute the same occurrence twice. The result is returned
  /// in selection order rather than completion order, and the execution log is
  /// ordered by completion.
  ///
  /// A run ends as succeeded, failed, cancelled or denied. A failure is retried
  /// up to [Automation.maxAttempts] times and no further. A denial never reaches
  /// the executor and reschedules instead, so a locked job cannot spin.
  ///
  /// [limit] caps how many jobs are considered in this pass.
  ///
  /// A job that another pass claimed, or that was deleted between selection and
  /// claim, is skipped without a run record: nothing ran, so there is nothing
  /// to report.
  Future<List<AutomationRun>> runDueJobs({int? limit}) async {
    final DateTime now = clock.now();
    final List<Automation> due = await selectDueJobs(at: now, limit: limit);
    if (due.isEmpty) {
      return const <AutomationRun>[];
    }
    for (final Automation job in due) {
      _pending.add(job.id);
    }
    final List<AutomationRun?> results = List<AutomationRun?>.filled(
      due.length,
      null,
    );
    int next = 0;
    Future<void> worker() async {
      while (true) {
        final int index = next;
        if (index >= due.length) {
          return;
        }
        next += 1;
        final Automation job = due[index];
        _pending.remove(job.id);
        final DateTime occurrence = job.nextRunAt!;
        if (_cancelWhilePending.remove(job.id)) {
          results[index] = _recordCancelledBeforeStart(job, occurrence);
          continue;
        }
        results[index] = await _dispatch(job, occurrence);
        // Left null when the job could not be claimed, which is not a run.
      }
    }

    final int workers = maxConcurrentRuns < due.length
        ? maxConcurrentRuns
        : due.length;
    try {
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < workers; i++) worker(),
      ]);
    } finally {
      // Only this pass's ids: an overlapping pass owns its own.
      for (final Automation job in due) {
        _pending.remove(job.id);
        _cancelWhilePending.remove(job.id);
      }
    }
    return List<AutomationRun>.unmodifiable(results.whereType<AutomationRun>());
  }

  /// The jobs [runDueJobs] would consider at [at], in selection order.
  Future<List<Automation>> selectDueJobs({DateTime? at, int? limit}) async {
    final DateTime reference = (at ?? clock.now()).toUtc();
    final List<Automation> due =
        (await repository.list())
            .where((Automation job) => job.isDueAt(reference))
            .toList()
          ..sort(_byDueTime);
    if (limit == null || limit < 0 || due.length <= limit) {
      return List<Automation>.unmodifiable(due);
    }
    return List<Automation>.unmodifiable(due.sublist(0, limit));
  }

  /// Cancels the job with [id], whether it is running or still pending.
  ///
  /// A running job has its [CancellationToken] cancelled, which is the only way
  /// anything in flight is stopped: the executor chooses to honour it, and the
  /// run is recorded as cancelled either way. A pending job never starts.
  ///
  /// Returns false when the job is not in flight, so a caller cannot mistake
  /// this for "the job was disabled".
  bool cancel(String id, [String reason = 'cancelled by user']) {
    final CancellationToken? token = _running[id];
    if (token != null) {
      token.cancel(reason);
      return true;
    }
    if (_pending.contains(id)) {
      _cancelWhilePending.add(id);
      return true;
    }
    return false;
  }

  /// Cancels everything in flight. Returns false when nothing was.
  bool cancelAll([String reason = 'cancelled by user']) {
    final List<String> ids = <String>[
      ..._running.keys,
      ..._pending.where((String id) => !_running.containsKey(id)),
    ];
    if (ids.isEmpty) {
      return false;
    }
    for (final String id in ids) {
      cancel(id, reason);
    }
    return true;
  }

  // --- internals ----------------------------------------------------------

  /// Earliest due time first, then id, so selection is stable.
  static int _byDueTime(Automation a, Automation b) {
    final int byDue = a.nextRunAt!.compareTo(b.nextRunAt!);
    return byDue != 0 ? byDue : a.id.compareTo(b.id);
  }

  DateTime? _firstRun(
    AutomationSchedule schedule,
    DateTime start,
    DateTime now,
  ) {
    if (schedule.kind == AutomationScheduleKind.once) {
      final DateTime? at = schedule.onceAt;
      if (at == null || !at.isAfter(now)) {
        return null;
      }
      return at;
    }
    return schedule.nextRunAfter(start);
  }

  static String _requireText(String value, String code, String field) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw AutomationError(code, detail: '$field must not be blank');
    }
    return trimmed;
  }

  static int _requireMaxAttempts(int maxAttempts) {
    if (maxAttempts < 1) {
      throw AutomationError(
        AutomationError.invalidMaxAttempts,
        detail: 'maxAttempts must be at least 1, got $maxAttempts',
      );
    }
    return maxAttempts;
  }

  static void _requireUserIntent(UserIntent intent) {
    if (intent.userId.trim().isEmpty) {
      throw const AutomationError(
        AutomationError.emptyUserId,
        detail: 'a job must name the user who asked for it',
      );
    }
  }

  Future<Automation> _change(
    String id,
    AutomationChange change,
    Automation Function(Automation current) mutate,
  ) async {
    final Automation updated = await repository.update(id, (
      Automation current,
    ) {
      _requireUserIntent(current.createdBy);
      return mutate(current);
    });
    await _record(updated, change);
    return updated;
  }

  Future<void> _record(Automation automation, AutomationChange change) async {
    await repository.appendRevision(
      AutomationRevision(
        automationId: automation.id,
        revision: automation.revision,
        change: change,
        recordedAt: clock.now(),
        snapshot: automation,
      ),
    );
  }

  /// Claims the job, asks the gate, then runs it with its bounded retries.
  ///
  /// [dueAt] is the occurrence being answered, i.e. the job's own
  /// [Automation.nextRunAt]. Rescheduling works from that instant rather than
  /// from the pass instant, so a job that started a little late keeps its phase
  /// instead of drifting by the delay on every run.
  Future<AutomationRun?> _dispatch(Automation job, DateTime dueAt) async {
    final Automation? claimed = await _claim(job.id, dueAt);
    if (claimed == null) {
      return null;
    }
    _pending.remove(job.id);

    final PolicyGateDecision decision = await gate.evaluate(claimed);
    if (!decision.approved) {
      await _rescheduleDenied(
        claimed.id,
        next: claimed.schedule.nextRunAfter(dueAt),
        reason: 'POLICY_DENIED: ${decision.reason}',
      );
      return _finish(
        claimed,
        dueAt,
        AutomationOutcome.denied,
        attempts: 0,
        error: decision.reason,
      );
    }

    final CancellationToken token = CancellationToken();
    _running[claimed.id] = token;
    final String runId = _nextRunId();
    final DateTime startedAt = clock.now();
    // `attempts` is both the loop bound and the number of calls actually made,
    // so the two can never disagree and the bound cannot be overshot.
    int attempts = 0;
    String? error;
    bool cancelled = false;
    bool succeeded = false;

    try {
      while (attempts < claimed.maxAttempts) {
        if (token.isCancelled) {
          cancelled = true;
          break;
        }
        attempts += 1;
        try {
          await executor.execute(
            AutomationExecutionContext(
              automation: claimed,
              intent: claimed.createdBy,
              runId: runId,
              attempt: attempts,
              scheduledFor: dueAt,
              token: token,
            ),
          );
          // Honoured or not, a token cancelled while the run was in flight wins:
          // the user asked for it to stop, so it did not complete as intended.
          cancelled = token.isCancelled;
          succeeded = !cancelled;
          break;
        } catch (failure) {
          if (token.isCancelled) {
            cancelled = true;
            break;
          }
          error = describeAutomationError(failure);
        }
        // Only ever between attempts, so the bound is a hard ceiling.
        if (attempts < claimed.maxAttempts) {
          await _sleeper(retryDelay);
        }
      }
    } finally {
      _running.remove(claimed.id);
    }

    if (cancelled) {
      // Leave the due time alone so the job can be tried again.
      await _unclaim(claimed.id);
      return _finish(
        claimed,
        dueAt,
        AutomationOutcome.cancelled,
        attempts: attempts,
        startedAt: startedAt,
        runId: runId,
        error: error ?? (token.reason?.toString() ?? 'cancelled'),
      );
    }
    if (succeeded) {
      await _complete(
        claimed.id,
        next: claimed.schedule.nextRunAfter(dueAt),
        runAt: clock.now(),
        succeeded: true,
      );
      return _finish(
        claimed,
        dueAt,
        AutomationOutcome.succeeded,
        attempts: attempts,
        startedAt: startedAt,
        runId: runId,
      );
    }
    await _complete(
      claimed.id,
      next: claimed.schedule.nextRunAfter(dueAt),
      runAt: clock.now(),
      succeeded: false,
      error: error ?? 'exhausted ${claimed.maxAttempts} attempts',
    );
    return _finish(
      claimed,
      dueAt,
      AutomationOutcome.failed,
      attempts: attempts,
      startedAt: startedAt,
      runId: runId,
      error: error ?? 'exhausted ${claimed.maxAttempts} attempts',
    );
  }

  /// Takes exclusive ownership of one occurrence before anything runs.
  ///
  /// The claim is a single atomic read-modify-write, so two overlapping
  /// scheduler passes cannot both take the same job.
  ///
  /// Returns null when the job is gone or is no longer due — deleted by the user
  /// or already claimed by another pass — and the caller skips it.
  Future<Automation?> _claim(String id, DateTime at) async {
    // Set inside the mutate callback, which the repository runs inside its write
    // queue and which only completes before update() returns. Reading it back
    // afterwards is therefore safe, and it is the only thing that says whether
    // *this* call is the one that took the job: a job another pass already
    // claimed still comes back carrying a claimedAt, so testing the record would
    // hand the same occurrence to both passes.
    var tookIt = false;
    try {
      final Automation claimed = await repository.update(id, (
        Automation current,
      ) {
        if (!current.isDueAt(at)) {
          return current;
        }
        tookIt = true;
        return current.copyWith(claimedAt: at);
      });
      return tookIt ? claimed : null;
    } on AutomationError {
      return null;
    }
  }

  /// Stores the outcome of a run and frees the claim.
  ///
  /// A finished run moves to the next occurrence, and a one-shot comes back with
  /// no next run and switched off, because it has nothing left to do.
  Future<void> _complete(
    String id, {
    required DateTime? next,
    required DateTime runAt,
    required bool succeeded,
    String? error,
  }) async {
    try {
      await repository.update(
        id,
        (Automation current) => current.copyWith(
          runCount: succeeded ? current.runCount + 1 : current.runCount,
          lastRunAt: runAt,
          consecutiveFailures: succeeded ? 0 : current.consecutiveFailures + 1,
          lastError: error,
          clearLastError: error == null,
          nextRunAt: next,
          clearNextRunAt: next == null,
          enabled: next == null ? false : current.enabled,
          clearClaim: true,
        ),
      );
    } on AutomationError {
      // The job was deleted mid-run; there is nothing left to update.
    }
  }

  /// Re-arms a job the gate refused.
  ///
  /// A denial is not a run: the run count, the last-run instant and the failure
  /// streak are all left alone, because nothing was executed. What changes is
  /// the due time — re-armed rather than left behind, so a locked job cannot
  /// spin — and [Automation.lastError], which is what the user needs to see.
  Future<void> _rescheduleDenied(
    String id, {
    required DateTime? next,
    required String reason,
  }) async {
    try {
      await repository.update(
        id,
        (Automation current) => current.copyWith(
          nextRunAt: next,
          clearNextRunAt: next == null,
          enabled: next == null ? false : current.enabled,
          lastError: reason,
          clearClaim: true,
        ),
      );
    } on AutomationError {
      // The job was deleted while the gate was deciding.
    }
  }

  /// Frees the claim without touching the due time.
  ///
  /// Used for a cancelled run: the occurrence was never answered, so the job
  /// stays due and a later pass may try it again.
  Future<void> _unclaim(String id) async {
    try {
      await repository.update(
        id,
        (Automation current) => current.copyWith(clearClaim: true),
      );
    } on AutomationError {
      // The job was deleted while it was running.
    }
  }

  AutomationRun _recordCancelledBeforeStart(Automation job, DateTime dueAt) =>
      _finish(
        job,
        dueAt,
        AutomationOutcome.cancelled,
        attempts: 0,
        error: 'cancelled before it started',
      );

  AutomationRun _finish(
    Automation job,
    DateTime dueAt,
    AutomationOutcome outcome, {
    required int attempts,
    DateTime? startedAt,
    String? runId,
    String? error,
  }) {
    final DateTime finishedAt = clock.now();
    final AutomationRun run = AutomationRun(
      runId: runId ?? _nextRunId(),
      automationId: job.id,
      automationName: job.name,
      automationRevision: job.revision,
      outcome: outcome,
      scheduledFor: dueAt,
      startedAt: startedAt ?? finishedAt,
      finishedAt: finishedAt,
      attempts: attempts,
      error: outcome == AutomationOutcome.succeeded ? null : error,
    );
    _log.add(run);
    while (_log.length > maxLogEntries) {
      _log.removeAt(0);
    }
    return run;
  }

  String _nextRunId() {
    _runSequence += 1;
    return 'run-${_runSequence.toString().padLeft(4, '0')}';
  }
}
