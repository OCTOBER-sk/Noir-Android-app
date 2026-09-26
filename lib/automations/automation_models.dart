// lib/automations/automation_models.dart
// A scheduled automation: the record, its schedule, the seams it dispatches
// through, and the repository they are stored in.
//
// Two rules shape this file.
//
// First, there is no sample data anywhere in it. A new repository is empty and
// a new job only exists because a caller created one.
//
// Second, this layer never acts on the device. It holds the schedule, asks an
// injected [AutomationPolicyGate] for a verdict, and only then calls an
// injected [AutomationExecutor] that is already policy-gated by whatever
// composed it. There is no Android, accessibility or notification code path in
// this package, by design: the safety decision belongs to the gate, not here.
//
// Every automation carries a [UserIntent], so a job can only exist because a
// user asked for it. Nothing in this file can synthesise one.

import 'dart:async';

import '../providers/cancellation.dart';

export '../providers/cancellation.dart' show CancellationToken;

/// Machine-readable failure raised by the automation layer.
///
/// Callers branch on [code] rather than parsing a message. [id] carries the job
/// the failure is about, when there is one.
class AutomationError implements Exception {
  const AutomationError(this.code, {this.detail, this.id});

  /// No job was created under an id that is already taken.
  static const String duplicateId = 'DUPLICATE_ID';

  /// The job is not in the repository.
  static const String unknownId = 'UNKNOWN_ID';

  /// A blank job id.
  static const String emptyId = 'EMPTY_ID';

  /// A blank human-readable name.
  static const String emptyName = 'EMPTY_NAME';

  /// A blank instruction for the executor.
  static const String emptyAction = 'EMPTY_ACTION';

  /// An instruction the executor cannot read as a request.
  ///
  /// Not a blank one: the action is there, and it is still not something that
  /// can be run. Whoever composes an executor decides what a valid action looks
  /// like and reports this rather than guessing at the intent.
  static const String invalidAction = 'INVALID_ACTION';

  /// The schedule cannot describe a real future run.
  static const String invalidSchedule = 'INVALID_SCHEDULE';

  /// An interval schedule that is not strictly positive.
  static const String invalidInterval = 'INVALID_INTERVAL';

  /// A retry bound below one attempt.
  static const String invalidMaxAttempts = 'INVALID_MAX_ATTEMPTS';

  /// The intent carries no user id.
  static const String emptyUserId = 'EMPTY_USER_ID';

  /// The intent claims to come from a moment that has not happened yet.
  static const String requestedInFuture = 'REQUESTED_IN_FUTURE';

  /// A concurrency bound below one.
  static const String invalidConcurrency = 'INVALID_CONCURRENCY';

  /// An execution-log retention bound below one.
  static const String invalidLogRetention = 'INVALID_LOG_RETENTION';

  final String code;
  final String? detail;
  final String? id;

  @override
  String toString() {
    final StringBuffer out = StringBuffer('AutomationError($code');
    if (id != null) {
      out.write(', id: $id');
    }
    if (detail != null) {
      out.write(', $detail');
    }
    out.write(')');
    return out.toString();
  }
}

/// Proof that a user asked for a job.
///
/// A [UserIntent] is required by `AutomationService.create`, carried on every
/// [Automation], and handed to the executor, so a job with no user behind it
/// cannot be represented.
class UserIntent {
  const UserIntent({required this.userId, required this.requestedAt});

  /// Who asked. Never empty.
  final String userId;

  /// When they asked. Never after the clock reading the job was created with.
  final DateTime requestedAt;

  @override
  String toString() =>
      'UserIntent($userId at ${requestedAt.toUtc().toIso8601String()})';
}

/// How a job decides when it runs.
enum AutomationScheduleKind {
  /// Runs once at a fixed instant, then the job disables itself.
  once,

  /// Runs every [AutomationSchedule.every].
  interval,
}

/// A validated schedule.
///
/// Both constructors reject anything impossible, so a schedule that exists can
/// always answer "when next?": [nextRunAfter] returns null only for a one-shot
/// whose instant has passed.
class AutomationSchedule {
  const AutomationSchedule._({required this.kind, this.every, this.onceAt});

  /// Repeats every [every]. The duration must be strictly positive.
  factory AutomationSchedule.interval({required Duration every}) {
    if (every <= Duration.zero) {
      throw AutomationError(
        AutomationError.invalidInterval,
        detail: 'every must be positive, got ${every.inMicroseconds}us',
      );
    }
    return AutomationSchedule._(
      kind: AutomationScheduleKind.interval,
      every: every,
    );
  }

  /// Runs once at [at] and then disables itself.
  factory AutomationSchedule.once(DateTime at) => AutomationSchedule._(
    kind: AutomationScheduleKind.once,
    onceAt: at.toUtc(),
  );

  final AutomationScheduleKind kind;

  /// Gap between runs, for [AutomationScheduleKind.interval].
  final Duration? every;

  /// The instant of the single run, for [AutomationScheduleKind.once].
  final DateTime? onceAt;

  /// Whether this schedule fires more than once.
  bool get isRecurring => kind == AutomationScheduleKind.interval;

  /// The first run strictly after [from], or null when there will not be one.
  ///
  /// Deterministic by construction: given the same [from] this always returns
  /// the same instant, which is what makes the service's next-run maths
  /// testable against an injected clock.
  DateTime? nextRunAfter(DateTime from) {
    final DateTime reference = from.toUtc();
    switch (kind) {
      case AutomationScheduleKind.interval:
        return reference.add(every!);
      case AutomationScheduleKind.once:
        final DateTime at = onceAt!;
        return at.isAfter(reference) ? at : null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationSchedule &&
      other.kind == kind &&
      other.every == every &&
      other.onceAt == onceAt;

  @override
  int get hashCode => Object.hash(kind, every, onceAt);

  @override
  String toString() => switch (kind) {
    AutomationScheduleKind.interval => 'AutomationSchedule(every: $every)',
    AutomationScheduleKind.once =>
      'AutomationSchedule(once at ${onceAt!.toUtc().toIso8601String()})',
  };
}

/// An immutable scheduled job.
///
/// [revision] counts *configuration* changes only: an edit, an enable, a
/// disable. Running the job does not move it, so a revision identifies the set
/// of settings a run was authorised under.
class Automation {
  const Automation({
    required this.id,
    required this.name,
    required this.action,
    required this.schedule,
    required this.enabled,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.maxAttempts,
    required this.revision,
    this.nextRunAt,
    this.lastRunAt,
    this.claimedAt,
    this.runCount = 0,
    this.consecutiveFailures = 0,
    this.lastError,
  });

  final String id;

  /// Human-readable label. Never blank.
  final String name;

  /// What the executor is asked to do. Never blank, and never an action
  /// statement: this layer does not interpret it.
  final String action;

  final AutomationSchedule schedule;
  final bool enabled;

  /// Total attempts allowed for one due occurrence, including the first.
  /// At least 1; higher values are the caller's explicit retry bound.
  final int maxAttempts;

  final UserIntent createdBy;
  final DateTime createdAt;

  /// Last *configuration* change. A run does not move it.
  final DateTime updatedAt;

  /// Starts at 1 and moves forward on every configuration change.
  final int revision;

  /// When this job is next due. Null means "no further runs", which is how a
  /// finished one-shot and an interval job that cannot fire again look.
  final DateTime? nextRunAt;

  final DateTime? lastRunAt;

  /// Set while a dispatch holds this job, so two scheduler passes can never run
  /// one occurrence twice. Cleared when the run finishes, however it finishes.
  final DateTime? claimedAt;

  final int runCount;
  final int consecutiveFailures;

  /// Why the last run failed, truncated. Never a secret: the caller is
  /// responsible for not putting one in here.
  final String? lastError;

  /// Whether this job should run at [at].
  ///
  /// A disabled job, a job with no next run, a job already claimed by an
  /// in-flight run, and a job whose next run is still in the future are all
  /// not due. The boundary is inclusive: at exactly [nextRunAt] the job is due.
  bool isDueAt(DateTime at) {
    if (!enabled || claimedAt != null) {
      return false;
    }
    final DateTime? next = nextRunAt;
    if (next == null) {
      return false;
    }
    return !next.toUtc().isAfter(at.toUtc());
  }

  Automation copyWith({
    String? name,
    String? action,
    AutomationSchedule? schedule,
    bool? enabled,
    int? maxAttempts,
    DateTime? nextRunAt,
    bool clearNextRunAt = false,
    DateTime? lastRunAt,
    DateTime? claimedAt,
    bool clearClaim = false,
    int? runCount,
    int? consecutiveFailures,
    String? lastError,
    bool clearLastError = false,
    DateTime? updatedAt,
    int? revision,
  }) {
    return Automation(
      id: id,
      name: name ?? this.name,
      action: action ?? this.action,
      schedule: schedule ?? this.schedule,
      enabled: enabled ?? this.enabled,
      maxAttempts: maxAttempts ?? this.maxAttempts,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      revision: revision ?? this.revision,
      nextRunAt: clearNextRunAt ? null : (nextRunAt ?? this.nextRunAt),
      lastRunAt: lastRunAt ?? this.lastRunAt,
      claimedAt: clearClaim ? null : (claimedAt ?? this.claimedAt),
      runCount: runCount ?? this.runCount,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  @override
  String toString() =>
      'Automation($id, "$name", $schedule, enabled: $enabled, rev: $revision, '
      'next: ${nextRunAt?.toUtc().toIso8601String()}, runs: $runCount)';
}

/// Why a revision was recorded.
enum AutomationChange {
  /// The job was created by a user request.
  created,

  /// A name, instruction, schedule or retry bound changed.
  edited,

  /// The job was switched on.
  enabled,

  /// The job was switched off.
  disabled,
}

/// One immutable entry in a job's history.
///
/// A revision keeps a full snapshot rather than a diff, so history stays
/// readable after the live record has moved on several times.
class AutomationRevision {
  const AutomationRevision({
    required this.automationId,
    required this.revision,
    required this.change,
    required this.recordedAt,
    required this.snapshot,
  });

  final String automationId;
  final int revision;
  final AutomationChange change;
  final DateTime recordedAt;

  /// The job exactly as it was at this revision.
  final Automation snapshot;

  @override
  String toString() =>
      'AutomationRevision($automationId rev: $revision, ${change.name})';
}

/// How a run ended. Every dispatch ends in exactly one of these.
enum AutomationOutcome {
  /// The executor returned normally.
  succeeded,

  /// Every allowed attempt threw.
  failed,

  /// The run was cancelled through its token while running or before it began.
  cancelled,

  /// The policy gate refused, so the executor was never called.
  denied,
}

/// The result of one dispatch, and one line of the execution log.
class AutomationRun {
  const AutomationRun({
    required this.runId,
    required this.automationId,
    required this.automationName,
    required this.automationRevision,
    required this.outcome,
    required this.scheduledFor,
    required this.startedAt,
    required this.finishedAt,
    required this.attempts,
    this.error,
  });

  /// Assigned in selection order: `run-0001`, `run-0002`, ...
  final String runId;
  final String automationId;
  final String automationName;

  /// The configuration revision the run was authorised under.
  final int automationRevision;

  final AutomationOutcome outcome;

  /// The due time this run was answering.
  final DateTime scheduledFor;
  final DateTime startedAt;
  final DateTime finishedAt;

  /// How many times the executor was called. 0 when the gate denied the run.
  final int attempts;

  /// Why the run did not succeed, truncated. Null on success.
  final String? error;

  @override
  String toString() =>
      'AutomationRun($runId, $automationId, ${outcome.name}, '
      'attempts: $attempts)';
}

/// The verdict on whether a job may run now.
///
/// A decision is only ever produced by an [AutomationPolicyGate]. There is no
/// way to construct an approval anywhere else in this package.
class PolicyGateDecision {
  const PolicyGateDecision({required this.approved, required this.reason});

  /// The run may proceed to the executor.
  const PolicyGateDecision.approved([String reason = 'APPROVED'])
    : this(approved: true, reason: reason);

  /// The run must not proceed.
  const PolicyGateDecision.denied([String reason = 'DENIED'])
    : this(approved: false, reason: reason);

  final bool approved;

  /// Why, in words safe to show the user and to put in the log.
  final String reason;

  @override
  String toString() =>
      'PolicyGateDecision(${approved ? 'approved' : 'denied'}: $reason)';
}

/// The safety seam. Injected, never constructed from policy rules in here.
abstract interface class AutomationPolicyGate {
  /// Decides whether [automation] may run right now.
  ///
  /// Implementations are expected to re-check what the user actually
  /// authorised — biometrics, session state, the Safety Center lock — and to
  /// deny by default. An implementation must not approve a job it has not
  /// inspected.
  Future<PolicyGateDecision> evaluate(Automation automation);
}

/// The safe default: refuses every job.
///
/// Use it to wire the subsystem so nothing can run until a real gate is
/// composed in, and as the documented answer to "what happens with no policy
/// configured".
class DenyAllPolicyGate implements AutomationPolicyGate {
  const DenyAllPolicyGate({this.reason = 'DEFAULT_DENY'});

  final String reason;

  @override
  Future<PolicyGateDecision> evaluate(Automation automation) async =>
      PolicyGateDecision.denied(reason);
}

/// Everything an executor is given for one attempt.
///
/// The [token] is the same object the service listens to for cancellation, so
/// an executor that polls it or registers a listener stops promptly.
class AutomationExecutionContext {
  const AutomationExecutionContext({
    required this.automation,
    required this.intent,
    required this.runId,
    required this.attempt,
    required this.scheduledFor,
    required this.token,
  });

  final Automation automation;
  final UserIntent intent;
  final String runId;

  /// 1-based, never above [Automation.maxAttempts].
  final int attempt;

  /// The due time this run is answering.
  final DateTime scheduledFor;

  final CancellationToken token;
}

/// The action seam: a single already policy-gated step of work.
///
/// The service never interprets [Automation.action] and never touches Android,
/// the device, the network or any other subsystem. Whatever composes this is
/// responsible for the action being policy-gated; the service still asks the
/// gate first, so a misconfigured executor cannot run a denied job.
abstract interface class AutomationExecutor {
  /// Performs the work. Throwing means the attempt failed.
  ///
  /// A cancelling executor should stop when [AutomationExecutionContext.token]
  /// is cancelled. One that ignores it is still reported as cancelled, because
  /// the user asked for that.
  Future<void> execute(AutomationExecutionContext context);
}

/// The longest failure text one run keeps.
const int maxAutomationErrorLength = 500;

/// Truncates a failure for the run record and the job's [Automation.lastError].
String describeAutomationError(Object error) {
  final String text = error.toString();
  if (text.length <= maxAutomationErrorLength) {
    return text;
  }
  return text.substring(0, maxAutomationErrorLength);
}

/// Persistence seam for jobs and their history.
///
/// Deliberately narrow: the service depends on this interface only, so a
/// durable implementation can be added later without touching dispatch,
/// scheduling or the policy gate. Read-modify-write goes through [update], which
/// must apply [mutate] atomically — that is what makes a single occurrence safe
/// to claim when two scheduler passes overlap.
abstract interface class AutomationRepository {
  /// Every stored job, ordered by id.
  Future<List<Automation>> list();

  /// The job stored under [id], or null.
  Future<Automation?> find(String id);

  /// Stores a new job.
  ///
  /// Throws [AutomationError] with [AutomationError.duplicateId] when [id] is
  /// already taken; an insert must never overwrite an existing job.
  Future<Automation> insert(Automation automation);

  /// Reads the job, applies [mutate] and stores the result as one step.
  ///
  /// Throws [AutomationError] with [AutomationError.unknownId] when there is no
  /// such job.
  Future<Automation> update(
    String id,
    Automation Function(Automation current) mutate,
  );

  /// Removes a job. Returns false when there was nothing to remove.
  Future<bool> delete(String id);

  /// Appends one immutable revision. History is append-only.
  Future<void> appendRevision(AutomationRevision revision);

  /// Every revision of [id], oldest first, as an unmodifiable list.
  Future<List<AutomationRevision>> revisions(String id);
}

/// In-memory [AutomationRepository].
///
/// A real implementation, not a stub: reads are snapshots, [update] serialises
/// per id so a read-modify-write cannot interleave, and history is append-only
/// and unmodifiable. It starts empty.
///
/// Durability is deliberately out of scope for this layer: wiring these records
/// into the data layer's durable collections is a separate change, and this
/// file does not reach into `lib/data`.
class InMemoryAutomationRepository implements AutomationRepository {
  InMemoryAutomationRepository();

  final Map<String, Automation> _rows = <String, Automation>{};
  final Map<String, List<AutomationRevision>> _history =
      <String, List<AutomationRevision>>{};

  /// Per-id tail of the write queue, so [update] applies in call order.
  final Map<String, Future<void>> _queues = <String, Future<void>>{};

  @override
  Future<List<Automation>> list() async {
    final List<String> ids = _rows.keys.toList()..sort();
    return List<Automation>.unmodifiable(ids.map((String id) => _rows[id]!));
  }

  @override
  Future<Automation?> find(String id) async => _rows[id];

  @override
  Future<Automation> insert(Automation automation) async {
    if (_rows.containsKey(automation.id)) {
      throw AutomationError(AutomationError.duplicateId, id: automation.id);
    }
    _rows[automation.id] = automation;
    return automation;
  }

  @override
  Future<Automation> update(
    String id,
    Automation Function(Automation current) mutate,
  ) {
    final Completer<Automation> result = Completer<Automation>();
    final Future<void> previous = _queues[id] ?? Future<void>.value();
    _queues[id] = previous.then((_) => _apply(id, mutate, result));
    return result.future;
  }

  Future<void> _apply(
    String id,
    Automation Function(Automation current) mutate,
    Completer<Automation> result,
  ) async {
    try {
      final Automation? current = _rows[id];
      if (current == null) {
        throw AutomationError(AutomationError.unknownId, id: id);
      }
      final Automation updated = mutate(current);
      _rows[id] = updated;
      result.complete(updated);
    } catch (error, stackTrace) {
      result.completeError(error, stackTrace);
    }
  }

  @override
  Future<bool> delete(String id) async => _rows.remove(id) != null;

  @override
  Future<void> appendRevision(AutomationRevision revision) async {
    final List<AutomationRevision> rows = _history.putIfAbsent(
      revision.automationId,
      () => <AutomationRevision>[],
    );
    rows.add(revision);
  }

  @override
  Future<List<AutomationRevision>> revisions(String id) async {
    final List<AutomationRevision> rows =
        _history[id] ?? const <AutomationRevision>[];
    return List<AutomationRevision>.unmodifiable(rows);
  }
}
