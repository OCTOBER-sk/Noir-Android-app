// Scheduled jobs: a schedule that validates, a due query that respects time, and
// run bookkeeping that survives a restart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/noir_schema.dart';

void main() {
  late Directory root;
  late KeyValueStore store;
  late JobRepository jobs;

  final created = DateTime.utc(2026, 5, 1, 8);
  final now = DateTime.utc(2026, 5, 1, 9);

  ScheduledJob job({
    required String id,
    String name = 'Nightly check',
    String prompt = 'run the check',
    JobSchedule? schedule,
    bool enabled = true,
    DateTime? startAt,
    DateTime? nextRunAt,
    int runCount = 0,
    DateTime? lastRunAt,
    String? lastError,
  }) {
    final stamp = created;
    return ScheduledJob(
      id: id,
      name: name,
      prompt: prompt,
      schedule:
          schedule ??
          JobSchedule(kind: JobScheduleKind.daily, hour: 3, minute: 15),
      enabled: enabled,
      startAt: startAt ?? created,
      nextRunAt: nextRunAt ?? DateTime.utc(2026, 5, 2, 3, 15),
      runCount: runCount,
      lastRunAt: lastRunAt,
      lastError: lastError,
      createdAt: stamp,
      updatedAt: stamp,
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_jobs_');
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(),
      clock: () => DateTime.utc(2026, 5, 1, 10),
    );
    jobs = JobRepository(
      store: store,
      clock: () => DateTime.utc(2026, 5, 1, 10),
    );
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('schedules', () {
    test('a daily schedule fires at the next matching wall-clock time', () {
      final schedule = JobSchedule(
        kind: JobScheduleKind.daily,
        hour: 3,
        minute: 15,
      );

      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 5, 1, 2)),
        DateTime.utc(2026, 5, 1, 3, 15),
      );
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 5, 1, 3, 15)),
        DateTime.utc(2026, 5, 2, 3, 15),
      );
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 5, 1, 23, 59)),
        DateTime.utc(2026, 5, 2, 3, 15),
      );
    });

    test('an interval schedule adds its interval to the reference time', () {
      final schedule = JobSchedule(
        kind: JobScheduleKind.interval,
        intervalMinutes: 90,
      );

      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 5, 1, 10)),
        DateTime.utc(2026, 5, 1, 11, 30),
      );
      expect(
        schedule.nextRunAfter(DateTime.utc(2026, 5, 1, 23, 30)),
        DateTime.utc(2026, 5, 2, 1),
      );
    });

    test('a one-shot schedule never repeats', () {
      final at = DateTime.utc(2026, 5, 3, 12);
      final schedule = JobSchedule.once(at);

      expect(schedule.nextRunAfter(DateTime.utc(2026, 5, 1)), at);
      expect(schedule.nextRunAfter(at), isNull);
      expect(schedule.isRecurring, isFalse);
      expect(
        schedule.toString(),
        'JobSchedule(once at 2026-05-03T12:00:00.000Z)',
      );
    });

    test('a recurring schedule reports itself as recurring', () {
      expect(
        JobSchedule(
          kind: JobScheduleKind.daily,
          hour: 0,
          minute: 0,
        ).isRecurring,
        isTrue,
      );
      expect(
        JobSchedule(
          kind: JobScheduleKind.interval,
          intervalMinutes: 5,
        ).toString(),
        'JobSchedule(interval 5m)',
      );
      expect(
        JobSchedule(kind: JobScheduleKind.daily, hour: 6, minute: 5).toString(),
        'JobSchedule(daily 06:05Z)',
      );
    });

    test('an invalid schedule is rejected with a reason', () {
      expect(
        () => JobSchedule(kind: JobScheduleKind.daily, hour: 24, minute: 0),
        throwsA(
          isA<InvalidScheduleError>().having(
            (e) => e.message,
            'message',
            contains('hour'),
          ),
        ),
      );
      expect(
        () => JobSchedule(kind: JobScheduleKind.daily, hour: 3, minute: 60),
        throwsA(isA<InvalidScheduleError>()),
      );
      expect(
        () => JobSchedule(kind: JobScheduleKind.interval, intervalMinutes: 0),
        throwsA(
          isA<InvalidScheduleError>().having(
            (e) => e.message,
            'message',
            contains('interval'),
          ),
        ),
      );
      expect(
        () => JobSchedule(kind: JobScheduleKind.once),
        throwsA(
          isA<InvalidScheduleError>().having(
            (e) => e.message,
            'message',
            contains('once'),
          ),
        ),
      );
      expect(
        () => JobSchedule(kind: JobScheduleKind.interval, intervalMinutes: -5),
        throwsA(isA<InvalidScheduleError>()),
      );
    });

    test('a schedule survives a JSON round trip', () {
      final original = JobSchedule(
        kind: JobScheduleKind.daily,
        hour: 3,
        minute: 15,
      );

      final decoded = JobSchedule.fromJson(original.toJson());

      expect(decoded.kind, JobScheduleKind.daily);
      expect(decoded.hour, 3);
      expect(decoded.minute, 15);
      expect(decoded, original);
    });

    test('a malformed stored schedule is named as a field', () {
      expect(
        () => JobSchedule.fromJson(<String, Object?>{'kind': 'hourly'}),
        throwsA(
          isA<InvalidScheduleError>().having(
            (e) => e.message,
            'message',
            contains('kind'),
          ),
        ),
      );
      expect(
        () => JobSchedule.fromJson(<String, Object?>{'kind': 'daily'}),
        throwsA(
          isA<InvalidScheduleError>().having(
            (e) => e.message,
            'message',
            contains('hour'),
          ),
        ),
      );
    });
  });

  group('CRUD', () {
    test('a fresh repository is empty', () async {
      expect(await jobs.readAll(), isEmpty);
      expect(await jobs.count(), isZero);
      expect((await jobs.dueAt(now)).items, isEmpty);
    });

    test('a job round-trips with its schedule and bookkeeping', () async {
      await jobs.upsert(job(id: 'j1', runCount: 3, lastRunAt: created));

      final loaded = (await jobs.find('j1'))!;

      expect(loaded.name, 'Nightly check');
      expect(loaded.prompt, 'run the check');
      expect(loaded.schedule.kind, JobScheduleKind.daily);
      expect(loaded.runCount, 3);
      expect(loaded.lastRunAt, created);
      expect(loaded.enabled, isTrue);
      expect(loaded.nextRunAt, DateTime.utc(2026, 5, 2, 3, 15));
    });

    test('a job with a blank name or prompt is rejected', () async {
      expect(() => job(id: 'j1', name: ' '), throwsA(isA<InvalidDataError>()));
      expect(() => job(id: 'j2', prompt: ''), throwsA(isA<InvalidDataError>()));
      expect(
        () => job(id: 'j3', runCount: -1),
        throwsA(isA<InvalidDataError>()),
      );
      expect(await jobs.count(), isZero);
    });

    test('a job survives a restart with its run count intact', () async {
      await jobs.upsert(job(id: 'j1'));
      await jobs.markCompleted('j1', at: DateTime.utc(2026, 5, 1, 3, 15));

      final reopened = JobRepository(
        store: JsonFileKeyValueStore(root: root, catalog: buildNoirCatalog()),
      );

      final loaded = (await reopened.find('j1'))!;
      expect(loaded.runCount, 1);
      expect(loaded.lastRunAt, DateTime.utc(2026, 5, 1, 3, 15));
      expect(loaded.nextRunAt, DateTime.utc(2026, 5, 2, 3, 15));
    });

    test('a job can be disabled and re-enabled', () async {
      await jobs.upsert(job(id: 'j1'));

      expect((await jobs.setEnabled('j1', enabled: false)).enabled, isFalse);
      expect((await jobs.dueAt(now)).items, isEmpty);
      expect((await jobs.setEnabled('j1', enabled: true)).enabled, isTrue);
      expect((await jobs.find('j1'))!.enabled, isTrue);
    });

    test('disabling a job that does not exist is an explicit error', () async {
      await expectLater(
        jobs.setEnabled('nope', enabled: false),
        throwsA(isA<RecordNotFoundError>()),
      );
    });

    test('deleting removes the job', () async {
      await jobs.upsert(job(id: 'j1'));
      await jobs.upsert(job(id: 'j2'));

      await jobs.delete('j1');

      expect(await jobs.exists('j1'), isFalse);
      expect(await jobs.count(), 1);
    });
  });

  group('due jobs', () {
    test('only enabled jobs whose next run has arrived are due', () async {
      await jobs.upsert(
        job(id: 'due', nextRunAt: DateTime.utc(2026, 5, 1, 8, 59)),
      );
      await jobs.upsert(
        job(id: 'later', nextRunAt: DateTime.utc(2026, 5, 1, 9, 1)),
      );
      await jobs.upsert(
        job(id: 'off', nextRunAt: DateTime.utc(2026, 5, 1, 8), enabled: false),
      );

      final due = await jobs.dueAt(now);

      expect(due.items.map((j) => j.id), <String>['due']);
      expect(due.total, 1);
    });

    test('a job due exactly now is due', () async {
      await jobs.upsert(job(id: 'edge', nextRunAt: now));

      expect((await jobs.dueAt(now)).items.map((j) => j.id), <String>['edge']);
    });

    test('due jobs come back oldest first and respect the limit', () async {
      await jobs.upsert(
        job(id: 'third', nextRunAt: DateTime.utc(2026, 5, 1, 8, 3)),
      );
      await jobs.upsert(
        job(id: 'first', nextRunAt: DateTime.utc(2026, 5, 1, 8, 1)),
      );
      await jobs.upsert(
        job(id: 'second', nextRunAt: DateTime.utc(2026, 5, 1, 8, 2)),
      );

      final due = await jobs.dueAt(now, limit: 2);

      expect(due.items.map((j) => j.id), <String>['first', 'second']);
      expect(due.total, 3);
      expect(due.hasMore, isTrue);
    });

    test('due jobs are paged without repeating one', () async {
      for (var i = 0; i < 5; i++) {
        await jobs.upsert(
          job(id: 'j$i', nextRunAt: DateTime.utc(2026, 5, 1, 8, i)),
        );
      }

      final seen = <String>[];
      var request = PageRequest(limit: 2);
      while (true) {
        final page = await jobs.dueAt(now, page: request);
        seen.addAll(page.items.map((j) => j.id));
        final next = page.nextPage;
        if (next == null) {
          break;
        }
        request = next;
      }

      expect(seen, <String>['j0', 'j1', 'j2', 'j3', 'j4']);
    });
  });

  group('completing a run', () {
    test(
      'a successful run bumps the counter and schedules the next one',
      () async {
        await jobs.upsert(job(id: 'j1', runCount: 2));

        final done = await jobs.markCompleted(
          'j1',
          at: DateTime.utc(2026, 5, 1, 3, 15),
        );

        expect(done.runCount, 3);
        expect(done.lastRunAt, DateTime.utc(2026, 5, 1, 3, 15));
        expect(done.nextRunAt, DateTime.utc(2026, 5, 2, 3, 15));
        expect(done.lastError, isNull);
      },
    );

    test('a failed run records the error and still reschedules', () async {
      await jobs.upsert(job(id: 'j1'));

      final failed = await jobs.markCompleted(
        'j1',
        at: DateTime.utc(2026, 5, 1, 3, 15),
        error: 'provider timeout',
      );

      expect(failed.lastError, 'provider timeout');
      expect(failed.runCount, 1);
      expect(failed.nextRunAt, DateTime.utc(2026, 5, 2, 3, 15));
    });

    test('an interval job reschedules relative to the run time', () async {
      await jobs.upsert(
        job(
          id: 'j1',
          schedule: JobSchedule(
            kind: JobScheduleKind.interval,
            intervalMinutes: 30,
          ),
        ),
      );

      final done = await jobs.markCompleted(
        'j1',
        at: DateTime.utc(2026, 5, 1, 10),
      );

      expect(done.nextRunAt, DateTime.utc(2026, 5, 1, 10, 30));
    });

    test('a one-shot job is disabled after its single run', () async {
      await jobs.upsert(
        job(id: 'j1', schedule: JobSchedule.once(DateTime.utc(2026, 5, 1, 12))),
      );

      final done = await jobs.markCompleted(
        'j1',
        at: DateTime.utc(2026, 5, 1, 12),
      );

      expect(done.enabled, isFalse);
      expect(done.nextRunAt, isNull);
      expect(done.runCount, 1);
      expect((await jobs.dueAt(now)).items, isEmpty);
    });

    test(
      'a very long error message is truncated rather than stored raw',
      () async {
        await jobs.upsert(job(id: 'j1'));

        final failed = await jobs.markCompleted(
          'j1',
          at: now,
          error: 'x' * 5000,
        );

        expect(failed.lastError!.length, lessThanOrEqualTo(500));
      },
    );

    test('completing a job that does not exist is an explicit error', () async {
      await expectLater(
        jobs.markCompleted('nope', at: now),
        throwsA(isA<RecordNotFoundError>()),
      );
    });

    test('concurrent completions all count', () async {
      await jobs.upsert(
        job(
          id: 'j1',
          schedule: JobSchedule(
            kind: JobScheduleKind.interval,
            intervalMinutes: 10,
          ),
        ),
      );

      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < 10; i++)
          jobs.markCompleted('j1', at: now.add(Duration(minutes: i))),
      ]);

      final loaded = (await jobs.find('j1'))!;
      expect(loaded.runCount, 10);
    });
  });

  group('malformed records', () {
    test(
      'a job whose stored schedule is broken is reported as malformed',
      () async {
        await store.write(NoirCollections.jobs, 'j1', <String, Object?>{
          'name': 'Broken',
          'prompt': 'p',
          'schedule': <String, Object?>{'kind': 'hourly'},
          'enabled': true,
          'startAt': '2026-05-01T00:00:00.000Z',
          'nextRunAt': '2026-05-02T00:00:00.000Z',
          'runCount': 0,
          'createdAt': '2026-05-01T00:00:00.000Z',
          'updatedAt': '2026-05-01T00:00:00.000Z',
        });

        await expectLater(
          jobs.find('j1'),
          throwsA(
            isA<MalformedRecordError>()
                .having((e) => e.field, 'field', 'schedule')
                .having(
                  (e) => e.collection,
                  'collection',
                  NoirCollections.jobs,
                ),
          ),
        );
      },
    );

    test('a job with no nextRunAt is malformed', () async {
      await store.write(NoirCollections.jobs, 'j1', <String, Object?>{
        'name': 'Broken',
        'prompt': 'p',
        'schedule': <String, Object?>{'kind': 'daily', 'hour': 3, 'minute': 0},
        'enabled': true,
        'startAt': '2026-05-01T00:00:00.000Z',
        'runCount': 0,
        'createdAt': '2026-05-01T00:00:00.000Z',
        'updatedAt': '2026-05-01T00:00:00.000Z',
      });

      await expectLater(
        jobs.find('j1'),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'nextRunAt',
          ),
        ),
      );
    });

    test('a record with a secret-looking field is not a job', () async {
      await store.write(NoirCollections.jobs, 'j1', <String, Object?>{
        'name': 'x',
        'prompt': 'p',
        'schedule': <String, Object?>{'kind': 'daily', 'hour': 3, 'minute': 0},
        'enabled': true,
        'startAt': '2026-05-01T00:00:00.000Z',
        'nextRunAt': '2026-05-02T00:00:00.000Z',
        'runCount': 0,
        'createdAt': '2026-05-01T00:00:00.000Z',
        'updatedAt': '2026-05-01T00:00:00.000Z',
        'apiKey': 'sk-should-never-be-here',
      });

      // Unknown fields are ignored, but the record still has to decode.
      expect((await jobs.find('j1'))!.name, 'x');
      final raw = await (store as RawStoreAccess).rawEnvelope(
        NoirCollections.jobs,
        'j1',
      );
      expect(
        raw,
        contains('sk-should-never-be-here'),
        reason: 'the data layer did not invent this field; it round-tripped',
      );
    });
  });
}
