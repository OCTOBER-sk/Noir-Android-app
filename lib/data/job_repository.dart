// lib/data/job_repository.dart — scheduled jobs and their run bookkeeping.
//
// The schedule is data, not code, so a job survives an app restart with the same
// next run time. Every run updates the record atomically, which is what keeps
// [ScheduledJob.runCount] honest even when a scheduler fires twice.

import 'codecs.dart';
import 'collection_repository.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'pagination.dart';
import 'records.dart';

/// How a job decides when it runs next.
enum JobScheduleKind {
  /// Runs once at a fixed instant, then disables itself.
  once,

  /// Runs every [JobSchedule.intervalMinutes].
  interval,

  /// Runs daily at a wall-clock time.
  daily,
}

/// A validated schedule. Instances cannot hold an impossible combination, so a
/// stored job can always answer "when next?".
class JobSchedule {
  /// Validates the fields the [kind] needs and rejects the rest.
  ///
  /// Everything goes through here, including [JobSchedule.fromJson], so a
  /// schedule that exists is always a schedule that can answer "when next?".
  factory JobSchedule({
    required JobScheduleKind kind,
    int? hour,
    int? minute,
    int? intervalMinutes,
    DateTime? onceAt,
  }) {
    switch (kind) {
      case JobScheduleKind.daily:
        if (hour == null) {
          throw const InvalidScheduleError('a daily schedule needs an hour');
        }
        if (minute == null) {
          throw const InvalidScheduleError('a daily schedule needs a minute');
        }
        if (hour < 0 || hour > 23) {
          throw InvalidScheduleError('"hour" must be 0..23, got $hour');
        }
        if (minute < 0 || minute > 59) {
          throw InvalidScheduleError('"minute" must be 0..59, got $minute');
        }
        return JobSchedule._daily(hour: hour, minute: minute);
      case JobScheduleKind.interval:
        if (intervalMinutes == null) {
          throw const InvalidScheduleError(
            'an interval schedule needs intervalMinutes',
          );
        }
        if (intervalMinutes < 1) {
          throw InvalidScheduleError(
            '"intervalMinutes" must be at least 1, got $intervalMinutes',
          );
        }
        return JobSchedule._interval(intervalMinutes: intervalMinutes);
      case JobScheduleKind.once:
        if (onceAt == null) {
          throw const InvalidScheduleError(
            'a "once" schedule needs the instant it runs at (onceAt)',
          );
        }
        return JobSchedule._once(onceAt.toUtc());
    }
  }

  /// A daily schedule at [hour]:[minute] UTC.
  factory JobSchedule.daily({required int hour, required int minute}) =>
      JobSchedule(kind: JobScheduleKind.daily, hour: hour, minute: minute);

  /// A schedule that repeats every [intervalMinutes].
  factory JobSchedule.interval({required int intervalMinutes}) => JobSchedule(
    kind: JobScheduleKind.interval,
    intervalMinutes: intervalMinutes,
  );

  /// A schedule that runs once at [at] and then disables itself.
  factory JobSchedule.once(DateTime at) =>
      JobSchedule(kind: JobScheduleKind.once, onceAt: at);

  const JobSchedule._daily({required this.hour, required this.minute})
    : kind = JobScheduleKind.daily,
      intervalMinutes = null,
      onceAt = null;

  const JobSchedule._interval({required this.intervalMinutes})
    : kind = JobScheduleKind.interval,
      hour = null,
      minute = null,
      onceAt = null;

  const JobSchedule._once(this.onceAt)
    : kind = JobScheduleKind.once,
      intervalMinutes = null,
      hour = null,
      minute = null;

  final JobScheduleKind kind;

  /// Minutes between runs, for [JobScheduleKind.interval].
  final int? intervalMinutes;

  /// Hour of day in UTC, for [JobScheduleKind.daily].
  final int? hour;
  final int? minute;

  /// The instant of a one-shot run, for [JobScheduleKind.once].
  final DateTime? onceAt;

  /// Whether this schedule runs more than once.
  bool get isRecurring => kind != JobScheduleKind.once;

  /// The next run strictly after [from], or null when there will not be one.
  DateTime? nextRunAfter(DateTime from) {
    final reference = from.toUtc();
    switch (kind) {
      case JobScheduleKind.once:
        final at = onceAt!;
        return at.isAfter(reference) ? at : null;
      case JobScheduleKind.interval:
        return reference.add(Duration(minutes: intervalMinutes!));
      case JobScheduleKind.daily:
        var candidate = DateTime.utc(
          reference.year,
          reference.month,
          reference.day,
          hour!,
          minute!,
        );
        if (!candidate.isAfter(reference)) {
          candidate = candidate.add(const Duration(days: 1));
        }
        return candidate;
    }
  }

  Map<String, Object?> toJson() {
    switch (kind) {
      case JobScheduleKind.once:
        return <String, Object?>{
          'kind': 'once',
          'onceAt': onceAt!.toUtc().toIso8601String(),
        };
      case JobScheduleKind.interval:
        return <String, Object?>{
          'kind': 'interval',
          'intervalMinutes': intervalMinutes,
        };
      case JobScheduleKind.daily:
        return <String, Object?>{
          'kind': 'daily',
          'hour': hour,
          'minute': minute,
        };
    }
  }

  /// Rebuilds a schedule from storage, rejecting anything impossible.
  factory JobSchedule.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    if (kindName is! String) {
      throw InvalidScheduleError(
        'a stored schedule needs a "kind" string, got ${kindName.runtimeType}',
      );
    }
    final kind = JobScheduleKind.values
        .where((candidate) => candidate.name == kindName)
        .toList();
    if (kind.isEmpty) {
      throw InvalidScheduleError('unknown schedule kind "$kindName"');
    }
    final hour = json['hour'];
    if (hour != null && hour is! int) {
      throw InvalidScheduleError(
        '"hour" must be an int, got ${hour.runtimeType}',
      );
    }
    final minute = json['minute'];
    if (minute != null && minute is! int) {
      throw InvalidScheduleError(
        '"minute" must be an int, got ${minute.runtimeType}',
      );
    }
    final intervalMinutes = json['intervalMinutes'];
    if (intervalMinutes != null && intervalMinutes is! int) {
      throw InvalidScheduleError(
        '"intervalMinutes" must be an int, got ${intervalMinutes.runtimeType}',
      );
    }
    DateTime? onceAt;
    final rawOnceAt = json['onceAt'];
    if (rawOnceAt != null) {
      if (rawOnceAt is! String) {
        throw InvalidScheduleError(
          '"onceAt" must be an ISO-8601 timestamp, got ${rawOnceAt.runtimeType}',
        );
      }
      onceAt = DateTime.tryParse(rawOnceAt);
      if (onceAt == null) {
        throw InvalidScheduleError('"onceAt" is not a timestamp: "$rawOnceAt"');
      }
    }
    return JobSchedule(
      kind: kind.single,
      hour: hour as int?,
      minute: minute as int?,
      intervalMinutes: intervalMinutes as int?,
      onceAt: onceAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is JobSchedule &&
      other.kind == kind &&
      other.intervalMinutes == intervalMinutes &&
      other.hour == hour &&
      other.minute == minute &&
      other.onceAt == onceAt;

  @override
  int get hashCode => Object.hash(kind, intervalMinutes, hour, minute, onceAt);

  @override
  String toString() {
    switch (kind) {
      case JobScheduleKind.once:
        return 'JobSchedule(once at ${onceAt!.toIso8601String()})';
      case JobScheduleKind.interval:
        return 'JobSchedule(interval ${intervalMinutes}m)';
      case JobScheduleKind.daily:
        final paddedHour = hour!.toString().padLeft(2, '0');
        final paddedMinute = minute!.toString().padLeft(2, '0');
        return 'JobSchedule(daily $paddedHour:$paddedMinute'
            'Z)';
    }
  }
}

/// The longest error text a job keeps from a failed run.
const int maxJobErrorLength = 500;

/// A persisted scheduled job.
class ScheduledJob extends DataRecord {
  ScheduledJob({
    required super.id,
    required this.name,
    required this.prompt,
    required this.schedule,
    required this.enabled,
    required this.startAt,
    required this.runCount,
    required super.createdAt,
    required super.updatedAt,
    this.nextRunAt,
    this.lastRunAt,
    this.lastError,
  }) {
    if (name.trim().isEmpty) {
      throw const InvalidDataError('a job needs a name');
    }
    if (prompt.trim().isEmpty) {
      throw const InvalidDataError('a job needs a prompt to run');
    }
    if (runCount < 0) {
      throw InvalidDataError('runCount must not be negative, got $runCount');
    }
  }

  final String name;
  final String prompt;
  final JobSchedule schedule;
  final bool enabled;
  final DateTime startAt;

  /// When this job is next due. Null for a finished one-shot job.
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;
  final int runCount;

  /// The last failure text, truncated to [maxJobErrorLength]. Never a secret:
  /// callers are responsible for not putting one in an error message.
  final String? lastError;

  /// Whether this job is due at [at].
  bool isDueAt(DateTime at) {
    if (!enabled) {
      return false;
    }
    final next = nextRunAt;
    if (next == null) {
      return false;
    }
    return !next.toUtc().isAfter(at.toUtc());
  }

  ScheduledJob copyWith({
    String? name,
    String? prompt,
    JobSchedule? schedule,
    bool? enabled,
    DateTime? nextRunAt,
    bool clearNextRunAt = false,
    DateTime? lastRunAt,
    int? runCount,
    String? lastError,
    bool clearLastError = false,
    DateTime? updatedAt,
  }) {
    return ScheduledJob(
      id: id,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      schedule: schedule ?? this.schedule,
      enabled: enabled ?? this.enabled,
      startAt: startAt,
      nextRunAt: clearNextRunAt ? null : (nextRunAt ?? this.nextRunAt),
      lastRunAt: lastRunAt ?? this.lastRunAt,
      runCount: runCount ?? this.runCount,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'prompt': prompt,
    'schedule': schedule.toJson(),
    'enabled': enabled,
    'startAt': startAt.toUtc().toIso8601String(),
    'nextRunAt': nextRunAt?.toUtc().toIso8601String(),
    'lastRunAt': lastRunAt?.toUtc().toIso8601String(),
    'runCount': runCount,
    'lastError': lastError,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  @override
  String toString() =>
      'ScheduledJob($id, "$name", $schedule, enabled: $enabled, '
      'next: ${nextRunAt?.toIso8601String()}, runs: $runCount)';
}

class ScheduledJobCodec extends RecordCodec<ScheduledJob> {
  const ScheduledJobCodec();

  @override
  Map<String, Object?> encode(ScheduledJob record) => record.toJson();

  @override
  ScheduledJob decode(String id, Map<String, Object?> json) {
    const collection = NoirCollections.jobs;
    final name = requireString(json, 'name', collection, id);
    final prompt = requireString(json, 'prompt', collection, id);
    final rawSchedule = json['schedule'];
    if (rawSchedule is! Map) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'schedule',
        detail: 'expected an object, got ${rawSchedule.runtimeType}',
      );
    }
    final JobSchedule schedule;
    try {
      schedule = JobSchedule.fromJson(Map<String, Object?>.from(rawSchedule));
    } on InvalidScheduleError catch (error) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'schedule',
        detail: error.message,
        cause: error,
      );
    }
    final enabled = optionalBool(json, 'enabled', collection, id);
    final startAt = requireTimestamp(json, 'startAt', collection, id);
    final runCount = requireInt(json, 'runCount', collection, id);
    final lastError = optionalString(json, 'lastError');
    final lastRunAt = json['lastRunAt'] == null
        ? null
        : requireTimestamp(json, 'lastRunAt', collection, id);
    final createdAt = requireTimestamp(json, 'createdAt', collection, id);
    final updatedAt = requireTimestamp(json, 'updatedAt', collection, id);
    if (!json.containsKey('nextRunAt')) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'nextRunAt',
        detail: 'the key must be present; null means "no further runs"',
      );
    }
    final nextRunAt = json['nextRunAt'] == null
        ? null
        : requireTimestamp(json, 'nextRunAt', collection, id);
    try {
      return ScheduledJob(
        id: id,
        name: name,
        prompt: prompt,
        schedule: schedule,
        enabled: enabled,
        startAt: startAt,
        nextRunAt: nextRunAt,
        lastRunAt: lastRunAt,
        runCount: runCount,
        lastError: lastError,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
    } on InvalidScheduleError catch (error) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'schedule',
        detail: error.message,
        cause: error,
      );
    } on InvalidDataError catch (error) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: error.message.contains('name') ? 'name' : 'prompt',
        detail: error.message,
        cause: error,
      );
    }
  }
}

class JobRepository extends CollectionRepository<ScheduledJob> {
  JobRepository({
    required super.store,
    super.codec = const ScheduledJobCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.jobs);

  /// A job that starts from the repository clock.
  ScheduledJob newJob({
    required String id,
    required String name,
    required String prompt,
    required JobSchedule schedule,
    DateTime? startAt,
    bool enabled = true,
  }) {
    final stamp = now;
    return ScheduledJob(
      id: id,
      name: name,
      prompt: prompt,
      schedule: schedule,
      enabled: enabled,
      startAt: startAt ?? stamp,
      nextRunAt: schedule.nextRunAfter(startAt ?? stamp),
      runCount: 0,
      createdAt: stamp,
      updatedAt: stamp,
    );
  }

  /// A page of jobs that are due at [at], oldest due time first.
  Future<Page<ScheduledJob>> dueAt(
    DateTime at, {
    PageRequest? page,
    int? limit,
    int? offset,
  }) async {
    final request = PageRequest.validated(
      offset: offset ?? page?.offset ?? 0,
      limit: limit ?? page?.limit ?? defaultPageLimit,
      maxLimit: maxPageLimit,
    );
    final due = <ScheduledJob>[];
    for (final job in await readAll()) {
      if (job.isDueAt(at)) {
        due.add(job);
      }
    }
    due.sort(compareByDueTime);
    return pageOf<ScheduledJob>(due, request, total: due.length);
  }

  /// Earliest due time first, then id, so paging is stable.
  static int compareByDueTime(ScheduledJob a, ScheduledJob b) {
    final left = a.nextRunAt ?? DateTime.utc(9999);
    final right = b.nextRunAt ?? DateTime.utc(9999);
    final byDue = left.compareTo(right);
    return byDue != 0 ? byDue : a.id.compareTo(b.id);
  }

  /// Enables or disables a job. A disabled job is never due.
  Future<ScheduledJob> setEnabled(String id, {required bool enabled}) => update(
    id,
    (current) => current.copyWith(enabled: enabled, updatedAt: now),
  );

  /// Records that a run finished, and works out the next run.
  ///
  /// A one-shot job disables itself and has no next run. A recurring job is
  /// rescheduled from [at], so a job that ran late does not immediately fire
  /// again. [error] is truncated rather than stored whole.
  Future<ScheduledJob> markCompleted(
    String id, {
    required DateTime at,
    String? error,
  }) {
    final runAt = at.toUtc();
    return update(id, (current) {
      final next = current.schedule.nextRunAfter(runAt);
      return current.copyWith(
        runCount: current.runCount + 1,
        lastRunAt: runAt,
        lastError: error == null
            ? null
            : (error.length > maxJobErrorLength
                  ? error.substring(0, maxJobErrorLength)
                  : error),
        clearLastError: error == null,
        clearNextRunAt: next == null,
        nextRunAt: next,
        enabled: next == null ? false : current.enabled,
        updatedAt: now,
      );
    });
  }
}
