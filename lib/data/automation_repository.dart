// lib/data/automation_repository.dart — the durable home of the scheduled
// automations in `lib/automations`.
//
// `lib/automations/automation_models.dart` ships a real `AutomationRepository`
// and a real `InMemoryAutomationRepository`, and both stop at the process
// boundary: a job created by a user exists until the process exits, so a
// scheduler that came back after a restart had nothing to schedule and a
// scheduled job silently never ran again. This file is the durable half, built
// out of the same `KeyValueStore`/`CollectionRepository` machinery every other
// repository uses, so a job written here is still there after a reopen — the
// property the subsystem's own header says is a separate change, and this is
// that change.
//
// What it adds on top of the interface, and why each part is here rather than
// left to the caller:
//
//   * `insert` is atomic and refuses to overwrite. It goes through the store's
//     own critical section (`mutateRecord`) rather than a read followed by a
//     write, so two schedulers creating the same id cannot both succeed.
//   * `update` applies the mutation inside that same critical section, so a
//     read-modify-write on one id cannot interleave with another. This is what
//     lets `AutomationService` claim one occurrence exactly once, even with two
//     overlapping passes.
//   * History is append-only and outlives the job: `delete` removes the record
//     and keeps the revisions, because an audit trail that disappears with the
//     row it audits is not an audit trail.
//   * Decoding is strict. A field that is missing or the wrong type is a
//     `MalformedRecordError` naming that field, never a default that would let a
//     half-written job come back looking scheduled.
//
// What it deliberately does not do: interpret a job, decide whether it may run,
// or dispatch anything. `AutomationService` owns all three, and the safety
// decision belongs to the policy gate the composition root injects.
library;

import '../automations/automation_models.dart';
import 'codecs.dart';
import 'collection_repository.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'key_value_store.dart';
import 'pagination.dart';
import 'records.dart';

export '../automations/automation_models.dart'
    show
        Automation,
        AutomationChange,
        AutomationRepository,
        AutomationRevision,
        AutomationSchedule,
        AutomationScheduleKind,
        UserIntent;

/// The durable row behind one [Automation].
///
/// The data layer keeps its own record type, as it does for conversations and
/// memories: `Automation` belongs to `lib/automations` and this file is the
// adapter between that value and the storage envelope. [createdAt] and
/// [updatedAt] are the job's own timestamps, so a run — which moves the run
/// count, the last run and the due time — does not pretend to be a
/// configuration change.
class AutomationRecord extends DataRecord {
  AutomationRecord(Automation job)
    : job = job,
      super(id: job.id, createdAt: job.createdAt, updatedAt: job.updatedAt);

  /// The job exactly as it is stored.
  final Automation job;

  /// The same row with a different job, used by the atomic update path.
  AutomationRecord copyWith(Automation job) => AutomationRecord(job);

  @override
  String toString() => 'AutomationRecord($job)';
}

/// The durable append-only revision log of one automation.
///
/// One record per automation id holding every revision in append order, because
/// a revision is immutable: rewriting a row per revision would make "the newest
/// revision" the only thing stored and turn the trail into a log with one entry.
class AutomationHistoryRecord extends DataRecord {
  AutomationHistoryRecord({
    required super.id,
    required super.createdAt,
    required super.updatedAt,
    required List<AutomationRevision> revisions,
  }) : revisions = List<AutomationRevision>.unmodifiable(revisions);

  /// Oldest first. Never edited, only extended.
  final List<AutomationRevision> revisions;

  /// The same log with one more revision on the end.
  AutomationHistoryRecord append(AutomationRevision revision) {
    return AutomationHistoryRecord(
      id: id,
      // The log's own span: the first revision is when the record appeared and
      // the last one is when it was last extended.
      createdAt: createdAt,
      updatedAt: revision.recordedAt,
      revisions: <AutomationRevision>[...revisions, revision],
    );
  }

  @override
  String toString() =>
      'AutomationHistoryRecord($id, ${revisions.length} revision(s))';
}

/// Strict JSON codec for [Automation].
///
/// Nothing here invents a value. A missing or wrongly typed field is an error
/// that names the field, and a schedule that cannot be rebuilt is reported
/// rather than replaced with a default — a job that came back claiming to be
/// due at some invented instant would be worse than one that failed to load.
class AutomationRecordCodec extends RecordCodec<AutomationRecord> {
  const AutomationRecordCodec();

  @override
  Map<String, Object?> encode(AutomationRecord record) =>
      encodeAutomation(record.job);

  @override
  AutomationRecord decode(String id, Map<String, Object?> json) =>
      AutomationRecord(decodeAutomation(id, json));
}

/// The storage payload for one [Automation], without the record wrapper.
///
/// Exposed because [AutomationHistoryCodec] has to write a full snapshot of the
/// job into every revision, and two copies of the field list would be two
/// chances to let them drift apart.
Map<String, Object?> encodeAutomation(Automation job) => <String, Object?>{
  'name': job.name,
  'action': job.action,
  'schedule': _encodeSchedule(job.schedule),
  'enabled': job.enabled,
  'maxAttempts': job.maxAttempts,
  'createdBy': <String, Object?>{
    'userId': job.createdBy.userId,
    'requestedAt': job.createdBy.requestedAt.toUtc().toIso8601String(),
  },
  'createdAt': job.createdAt.toUtc().toIso8601String(),
  'updatedAt': job.updatedAt.toUtc().toIso8601String(),
  'revision': job.revision,
  'nextRunAt': job.nextRunAt?.toUtc().toIso8601String(),
  'lastRunAt': job.lastRunAt?.toUtc().toIso8601String(),
  'claimedAt': job.claimedAt?.toUtc().toIso8601String(),
  'runCount': job.runCount,
  'consecutiveFailures': job.consecutiveFailures,
  'lastError': job.lastError,
};

Map<String, Object?> _encodeSchedule(AutomationSchedule schedule) {
  return switch (schedule.kind) {
    AutomationScheduleKind.interval => <String, Object?>{
      'kind': 'interval',
      // Microseconds, because anything coarser would round an interval and a
      // job that drifts is a job whose schedule is not the one the user set.
      'everyMicroseconds': schedule.every!.inMicroseconds,
    },
    AutomationScheduleKind.once => <String, Object?>{
      'kind': 'once',
      'onceAt': schedule.onceAt!.toUtc().toIso8601String(),
    },
  };
}

/// Rebuilds an [Automation] from its stored payload. The id comes from the
/// storage key, exactly as it does for every other collection.
Automation decodeAutomation(String id, Map<String, Object?> json) {
  const String collection = NoirCollections.automations;
  final String name = requireString(json, 'name', collection, id);
  final String action = requireString(json, 'action', collection, id);
  final bool enabled = requireBool(json, 'enabled', collection, id);
  final int maxAttempts = requireInt(json, 'maxAttempts', collection, id);
  final int revision = requireInt(json, 'revision', collection, id);
  final int runCount = requireInt(json, 'runCount', collection, id);
  final int consecutiveFailures = requireInt(
    json,
    'consecutiveFailures',
    collection,
    id,
  );
  final DateTime createdAt = requireTimestamp(
    json,
    'createdAt',
    collection,
    id,
  );
  final DateTime updatedAt = requireTimestamp(
    json,
    'updatedAt',
    collection,
    id,
  );
  final UserIntent intent = _decodeIntent(id, json);
  final AutomationSchedule schedule = _decodeSchedule(id, json);
  if (maxAttempts < 1) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: 'maxAttempts',
      detail: 'expected at least 1, got $maxAttempts',
    );
  }
  if (revision < 1) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: 'revision',
      detail: 'a stored job starts at revision 1, got $revision',
    );
  }
  return Automation(
    id: id,
    name: name,
    action: action,
    schedule: schedule,
    enabled: enabled,
    maxAttempts: maxAttempts,
    createdBy: intent,
    createdAt: createdAt,
    updatedAt: updatedAt,
    revision: revision,
    nextRunAt: _optionalTimestamp(json, 'nextRunAt', collection, id),
    lastRunAt: _optionalTimestamp(json, 'lastRunAt', collection, id),
    claimedAt: _optionalTimestamp(json, 'claimedAt', collection, id),
    runCount: runCount,
    consecutiveFailures: consecutiveFailures,
    lastError: optionalString(json, 'lastError'),
  );
}

UserIntent _decodeIntent(String id, Map<String, Object?> json) {
  const String collection = NoirCollections.automations;
  final Object? raw = json['createdBy'];
  if (raw is! Map) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: 'createdBy',
      detail:
          'a job must name the user who asked for it; expected an object, '
          'got ${raw.runtimeType}',
    );
  }
  final Map<String, Object?> intent = Map<String, Object?>.from(raw);
  final String userId = requireString(intent, 'userId', collection, id);
  if (userId.trim().isEmpty) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: 'createdBy.userId',
      detail: 'a job with no user behind it cannot be represented',
    );
  }
  return UserIntent(
    userId: userId,
    requestedAt: requireTimestamp(intent, 'requestedAt', collection, id),
  );
}

AutomationSchedule _decodeSchedule(String id, Map<String, Object?> json) {
  const String collection = NoirCollections.automations;
  final Object? raw = json['schedule'];
  if (raw is! Map) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: 'schedule',
      detail: 'expected an object, got ${raw.runtimeType}',
    );
  }
  final Map<String, Object?> schedule = Map<String, Object?>.from(raw);
  final Object? kind = schedule['kind'];
  if (kind is! String) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: 'schedule.kind',
      detail: 'expected a string, got ${kind.runtimeType}',
    );
  }
  try {
    switch (kind) {
      case 'interval':
        final int every = requireInt(
          schedule,
          'everyMicroseconds',
          collection,
          id,
        );
        return AutomationSchedule.interval(
          every: Duration(microseconds: every),
        );
      case 'once':
        return AutomationSchedule.once(
          requireTimestamp(schedule, 'onceAt', collection, id),
        );
      default:
        throw MalformedRecordError(
          collection: collection,
          id: id,
          field: 'schedule.kind',
          detail: 'unknown schedule kind "$kind"',
        );
    }
  } on AutomationError catch (error) {
    // A schedule that cannot be rebuilt is a malformed record, not a job the
    // codec is allowed to repair with an interval of its own choosing.
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: 'schedule',
      detail: error.detail ?? error.code,
      cause: error,
    );
  }
}

DateTime? _optionalTimestamp(
  Map<String, Object?> json,
  String key,
  String collection,
  String id,
) {
  final Object? value = json[key];
  if (value == null) return null;
  return requireTimestamp(json, key, collection, id);
}

/// Strict JSON codec for an [AutomationRevision] and the log that holds them.
class AutomationHistoryCodec extends RecordCodec<AutomationHistoryRecord> {
  const AutomationHistoryCodec();

  @override
  Map<String, Object?> encode(AutomationHistoryRecord record) =>
      <String, Object?>{
        'createdAt': record.createdAt.toUtc().toIso8601String(),
        'updatedAt': record.updatedAt.toUtc().toIso8601String(),
        'revisions': <Map<String, Object?>>[
          for (final AutomationRevision revision in record.revisions)
            <String, Object?>{
              'automationId': revision.automationId,
              'revision': revision.revision,
              'change': revision.change.name,
              'recordedAt': revision.recordedAt.toUtc().toIso8601String(),
              // A full snapshot, not a diff: history has to stay readable after
              // the live record has moved on several times.
              'snapshot': encodeAutomation(revision.snapshot),
            },
        ],
      };

  @override
  AutomationHistoryRecord decode(String id, Map<String, Object?> json) {
    const String collection = NoirCollections.automationHistory;
    final Object? raw = json['revisions'];
    if (raw is! List) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'revisions',
        detail: 'expected a list, got ${raw.runtimeType}',
      );
    }
    final List<AutomationRevision> revisions = <AutomationRevision>[];
    for (var index = 0; index < raw.length; index++) {
      final Object? entry = raw[index];
      if (entry is! Map) {
        throw MalformedRecordError(
          collection: collection,
          id: id,
          field: 'revisions[$index]',
          detail: 'expected an object, got ${entry.runtimeType}',
        );
      }
      revisions.add(
        _decodeRevision(id, index, Map<String, Object?>.from(entry)),
      );
    }
    return AutomationHistoryRecord(
      id: id,
      createdAt: requireTimestamp(json, 'createdAt', collection, id),
      updatedAt: requireTimestamp(json, 'updatedAt', collection, id),
      revisions: revisions,
    );
  }

  AutomationRevision _decodeRevision(
    String id,
    int index,
    Map<String, Object?> json,
  ) {
    const String collection = NoirCollections.automationHistory;
    String field(String key) => 'revisions[$index].$key';
    final String automationId = requireString(
      json,
      'automationId',
      collection,
      id,
    );
    // A revision filed under one id must belong to that id. A mismatch means the
    // log was written by something other than this repository, and reading it
    // as if it were the job's own history would attribute a run to the wrong job.
    if (automationId != id) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: field('automationId'),
        detail: 'expected "$id", got "$automationId"',
      );
    }
    final Object? changeName = json['change'];
    if (changeName is! String) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: field('change'),
        detail: 'expected a string, got ${changeName.runtimeType}',
      );
    }
    final List<AutomationChange> changes = AutomationChange.values
        .where((AutomationChange change) => change.name == changeName)
        .toList();
    if (changes.isEmpty) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: field('change'),
        detail: 'unknown change "$changeName"',
      );
    }
    final Object? rawSnapshot = json['snapshot'];
    if (rawSnapshot is! Map) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: field('snapshot'),
        detail: 'expected an object, got ${rawSnapshot.runtimeType}',
      );
    }
    final int revision = requireInt(json, 'revision', collection, id);
    final Automation snapshot = decodeAutomation(
      id,
      Map<String, Object?>.from(rawSnapshot),
    );
    if (snapshot.revision != revision) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: field('revision'),
        detail:
            'the entry says $revision but its snapshot is revision '
            '${snapshot.revision}',
      );
    }
    return AutomationRevision(
      automationId: automationId,
      revision: revision,
      change: changes.single,
      recordedAt: requireTimestamp(json, 'recordedAt', collection, id),
      snapshot: snapshot,
    );
  }
}

/// The CRUD over the durable [Automation] rows.
///
/// The same shape as every other collection repository, so a job is paged,
/// counted and updated the way a conversation is. What it does *not* do is
/// interpret the job or decide what is due: that is
/// [DurableAutomationRepository] and `AutomationService`, which owns the claim
/// that makes a single occurrence safe to run.
class AutomationJobRepository extends CollectionRepository<AutomationRecord> {
  AutomationJobRepository({
    required super.store,
    super.codec = const AutomationRecordCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.automations);
}

/// The CRUD over the append-only revision logs.
class AutomationHistoryRepository
    extends CollectionRepository<AutomationHistoryRecord> {
  AutomationHistoryRepository({
    required super.store,
    super.codec = const AutomationHistoryCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.automationHistory);
}

/// A durable [AutomationRepository].
///
/// Built over two [CollectionRepository]s on one [KeyValueStore]: one row per
/// job, one append-only log per job. Everything that has to be atomic goes
/// through [KeyValueStore.mutateRecord], which the store serialises, so a
/// concurrent `insert` cannot overwrite and a concurrent `update` cannot lose a
/// write. Nothing is cached in memory: a read is a read, so two repositories
/// over the same directory — which is exactly what a restart produces — agree.
class DurableAutomationRepository implements AutomationRepository {
  DurableAutomationRepository({
    required KeyValueStore store,
    DateTime Function()? clock,
    int maxPageLimit = defaultMaxPageLimit,
  }) : _store = store,
       _jobs = AutomationJobRepository(
         store: store,
         clock: clock,
         maxPageLimit: maxPageLimit,
       ),
       _history = AutomationHistoryRepository(
         store: store,
         clock: clock,
         maxPageLimit: maxPageLimit,
       );

  final KeyValueStore _store;
  final AutomationJobRepository _jobs;
  final AutomationHistoryRepository _history;

  /// The store these rows live in. Exposed so a caller can report the backend
  /// and its durability rather than guessing.
  KeyValueStore get store => _store;

  /// The collection the jobs themselves are filed under.
  String get collection => _jobs.collection;

  /// The collection their revision logs are filed under.
  String get historyCollection => _history.collection;

  /// Whether the rows behind this repository survive a process restart.
  bool get isDurable => _store.isDurable;

  @override
  Future<List<Automation>> list() => _readAll();

  /// Every stored job, oldest id first.
  ///
  /// A job that cannot be decoded is left out and reported to [onUnreadable] if
  /// one was given: the store's recovery path keeps the reason and the bytes,
  /// and a job that cannot be read is simply not offered as runnable.
  Future<List<Automation>> _readAll({
    void Function(String id, Object error)? onUnreadable,
  }) async {
    final List<AutomationRecord> rows = await _jobs.readAll(
      onUnreadable: onUnreadable ?? _reportNothing,
    );
    return List<Automation>.unmodifiable(
      rows.map((AutomationRecord row) => row.job),
    );
  }

  static void _reportNothing(String id, Object error) {}

  @override
  Future<Automation?> find(String id) async => (await _jobs.find(id))?.job;

  @override
  Future<Automation> insert(Automation automation) async {
    final StoredRecord? stored = await _store.mutateRecord(
      _jobs.collection,
      automation.id,
      (Map<String, Object?>? current) {
        if (current != null) {
          throw AutomationError(AutomationError.duplicateId, id: automation.id);
        }
        return _jobs.codec.encode(AutomationRecord(automation));
      },
    );
    if (stored == null) {
      // The callback never returns null, so this cannot happen; it is here so a
      // store that failed the write cannot be reported as a successful insert.
      throw const InvalidDataError(
        'the store did not publish the automation it was handed',
      );
    }
    return automation;
  }

  @override
  Future<Automation> update(
    String id,
    Automation Function(Automation current) mutate,
  ) async {
    try {
      final AutomationRecord updated = await _jobs.update(
        id,
        (AutomationRecord current) => current.copyWith(mutate(current.job)),
      );
      return updated.job;
    } on RecordNotFoundError catch (error) {
      // The service distinguishes "no such job" from every other failure, so the
      // data layer's own vocabulary is translated rather than leaked.
      throw AutomationError(
        AutomationError.unknownId,
        id: id,
        detail: '$error',
      );
    }
  }

  @override
  Future<bool> delete(String id) async {
    if (!await _store.exists(_jobs.collection, id)) return false;
    await _jobs.delete(id);
    // The revision log stays: history is append-only audit history, not live
    // state, and a trail that vanished with the row it audits would prove
    // nothing.
    return true;
  }

  @override
  Future<void> appendRevision(AutomationRevision revision) async {
    // One critical section for the whole append: read the log, add the entry,
    // publish it. Two concurrent appends are serialised by the store, so no
    // entry can overwrite another and the log stays in append order. The log is
    // filed under the automation's own id, so a trail can never be lost to a
    // naming scheme and a job's history follows the id a caller already knows.
    Map<String, Object?>? append(Map<String, Object?>? current) {
      final AutomationHistoryRecord log = current == null
          ? AutomationHistoryRecord(
              id: revision.automationId,
              createdAt: revision.recordedAt,
              updatedAt: revision.recordedAt,
              revisions: const <AutomationRevision>[],
            )
          : _history.codec.decode(revision.automationId, current);
      return _history.codec.encode(log.append(revision));
    }

    await _store.mutateRecord(
      _history.collection,
      revision.automationId,
      append,
    );
  }

  @override
  Future<List<AutomationRevision>> revisions(String id) async {
    final AutomationHistoryRecord? log = await _history.find(id);
    if (log == null) return const <AutomationRevision>[];
    return List<AutomationRevision>.unmodifiable(log.revisions);
  }

  /// Every stored job as plain maps, safe to write to a file, attach to a bug
  /// report or show in a UI.
  ///
  /// There is nothing to redact here: a row holds an id, a label, the
  /// instruction the user gave, a schedule, the user who asked for it and run
  /// bookkeeping — no credential, no screen content. [onUnreadable] is passed
  /// straight through so a record that cannot be decoded is reported rather than
  /// quietly missing from the export.
  Future<List<Map<String, Object?>>> exportJobs({
    void Function(String id, Object error)? onUnreadable,
  }) async {
    return <Map<String, Object?>>[
      for (final Automation job in await _readAll(onUnreadable: onUnreadable))
        <String, Object?>{
          'id': job.id,
          'name': job.name,
          'action': job.action,
          'enabled': job.enabled,
          'maxAttempts': job.maxAttempts,
          'revision': job.revision,
          'runCount': job.runCount,
          'consecutiveFailures': job.consecutiveFailures,
          'requestedBy': job.createdBy.userId,
          'schedule': job.schedule.kind.name,
          'createdAt': job.createdAt.toUtc().toIso8601String(),
          'updatedAt': job.updatedAt.toUtc().toIso8601String(),
          'nextRunAt': job.nextRunAt?.toUtc().toIso8601String(),
          'lastRunAt': job.lastRunAt?.toUtc().toIso8601String(),
          'claimedAt': job.claimedAt?.toUtc().toIso8601String(),
          'lastError': job.lastError,
        },
    ];
  }

  /// The revision index of every job that has one, oldest first per job.
  ///
  /// A projection rather than a copy: each entry repeats the snapshot the
  /// revision carries, and the live job is already exported in full by
  /// [exportJobs]. What is added here is the *order* of the changes — which
  /// change, at which revision, recorded when — and that is the part of the
  /// trail an export would otherwise drop.
  Future<List<Map<String, Object?>>> exportHistory({
    void Function(String id, Object error)? onUnreadable,
  }) async {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[
      for (final AutomationHistoryRecord log in await _history.readAll(
        onUnreadable: onUnreadable,
      ))
        <String, Object?>{
          'automationId': log.id,
          'revisionCount': log.revisions.length,
          'revisions': <Map<String, Object?>>[
            for (final AutomationRevision revision in log.revisions)
              <String, Object?>{
                'revision': revision.revision,
                'change': revision.change.name,
                'recordedAt': revision.recordedAt.toUtc().toIso8601String(),
                'snapshotRevision': revision.snapshot.revision,
              },
          ],
        },
    ];
    return List<Map<String, Object?>>.unmodifiable(out);
  }
}
