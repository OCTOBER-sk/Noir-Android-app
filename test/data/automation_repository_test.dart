// The durable half of the scheduled automation subsystem: a codec that refuses
// to invent a field, an insert that will not overwrite, an update that is
// atomic per id, an append-only history that outlives the job, and records that
// are still there after the data layer is closed and reopened over the same
// directory.
//
// Real files throughout. A durability claim proved against an in-memory store
// would be a claim about nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/automations/automations.dart';
import 'package:noir_android_app/core/clock.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/noir_schema.dart';

final DateTime _created = DateTime.utc(2026, 5, 1, 8);
final DateTime _due = DateTime.utc(2026, 5, 1, 9);

UserIntent _intent([String userId = 'u-1']) =>
    UserIntent(userId: userId, requestedAt: _created);

Automation job({
  required String id,
  String name = 'Morning digest',
  String action = 'read_screen|Inbox',
  AutomationSchedule? schedule,
  bool enabled = true,
  int maxAttempts = 1,
  UserIntent? createdBy,
  DateTime? createdAt,
  DateTime? updatedAt,
  int revision = 1,
  DateTime? nextRunAt,
  // The same idiom the model uses in copyWith, so a test can ask for a job with
  // no next run instead of having null mean "use the default".
  bool clearNextRunAt = false,
  DateTime? lastRunAt,
  DateTime? claimedAt,
  int runCount = 0,
  int consecutiveFailures = 0,
  String? lastError,
}) => Automation(
  id: id,
  name: name,
  action: action,
  schedule:
      schedule ?? AutomationSchedule.interval(every: const Duration(hours: 12)),
  enabled: enabled,
  maxAttempts: maxAttempts,
  createdBy: createdBy ?? _intent(),
  createdAt: createdAt ?? _created,
  updatedAt: updatedAt ?? _created,
  revision: revision,
  nextRunAt: clearNextRunAt ? null : (nextRunAt ?? _due),
  lastRunAt: lastRunAt,
  claimedAt: claimedAt,
  runCount: runCount,
  consecutiveFailures: consecutiveFailures,
  lastError: lastError,
);

AutomationRevision revisionOf(
  Automation job, {
  AutomationChange change = AutomationChange.created,
  int revision = 1,
  DateTime? recordedAt,
}) => AutomationRevision(
  automationId: job.id,
  revision: revision,
  change: change,
  recordedAt: recordedAt ?? _created,
  snapshot: job,
);

/// Every field, compared by value: `Automation` has no `==`, and a round trip
/// that dropped one field would otherwise pass.
void expectSameJob(Automation actual, Automation expected, {String? reason}) {
  expect(actual.id, expected.id, reason: reason);
  expect(actual.name, expected.name, reason: reason);
  expect(actual.action, expected.action, reason: reason);
  expect(actual.schedule, expected.schedule, reason: reason);
  expect(actual.enabled, expected.enabled, reason: reason);
  expect(actual.maxAttempts, expected.maxAttempts, reason: reason);
  expect(actual.createdBy.userId, expected.createdBy.userId, reason: reason);
  expect(
    actual.createdBy.requestedAt,
    expected.createdBy.requestedAt,
    reason: reason,
  );
  expect(actual.createdAt, expected.createdAt, reason: reason);
  expect(actual.updatedAt, expected.updatedAt, reason: reason);
  expect(actual.revision, expected.revision, reason: reason);
  expect(actual.nextRunAt, expected.nextRunAt, reason: reason);
  expect(actual.lastRunAt, expected.lastRunAt, reason: reason);
  expect(actual.claimedAt, expected.claimedAt, reason: reason);
  expect(actual.runCount, expected.runCount, reason: reason);
  expect(
    actual.consecutiveFailures,
    expected.consecutiveFailures,
    reason: reason,
  );
  expect(actual.lastError, expected.lastError, reason: reason);
}

void main() {
  late Directory root;
  late KeyValueStore store;
  late DurableAutomationRepository automations;

  /// A second repository over the same directory: what a restart produces.
  DurableAutomationRepository reopen() => DurableAutomationRepository(
    store: JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(),
      clock: () => _created,
    ),
    clock: () => _created,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_automations_');
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(),
      clock: () => _created,
    );
    automations = DurableAutomationRepository(
      store: store,
      clock: () => _created,
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('empty by default', () {
    test('a fresh repository holds no jobs and no history', () async {
      expect(await automations.list(), isEmpty);
      expect(await automations.find('nothing'), isNull);
      expect(await automations.revisions('nothing'), isEmpty);
      expect(automations.isDurable, isTrue);
      expect(automations.collection, NoirCollections.automations);
      expect(automations.historyCollection, NoirCollections.automationHistory);
    });
  });

  group('the codec', () {
    test('every field survives a round trip through the store', () async {
      final Automation full = job(
        id: 'a1',
        schedule: AutomationSchedule.once(DateTime.utc(2026, 5, 2, 3, 15)),
        maxAttempts: 4,
        createdBy: _intent('u-42'),
        createdAt: DateTime.utc(2026, 4, 30, 6, 7, 8),
        updatedAt: DateTime.utc(2026, 4, 30, 9, 10, 11),
        revision: 7,
        nextRunAt: DateTime.utc(2026, 5, 2, 3, 15),
        lastRunAt: DateTime.utc(2026, 5, 1, 9),
        claimedAt: DateTime.utc(2026, 5, 1, 8, 59, 30),
        runCount: 5,
        consecutiveFailures: 2,
        lastError: 'the executor refused a1',
      );

      await automations.insert(full);
      expectSameJob((await automations.find('a1'))!, full);

      // And through a fresh repository over the same bytes, which is the read a
      // restarted process actually performs.
      expectSameJob((await reopen().find('a1'))!, full);
    });

    test('an interval keeps its exact length, not a rounded one', () async {
      final Automation odd = job(
        id: 'a1',
        schedule: AutomationSchedule.interval(
          every: const Duration(minutes: 90, seconds: 7, microseconds: 11),
        ),
      );

      await automations.insert(odd);

      final Automation stored = (await automations.find('a1'))!;
      expect(
        stored.schedule.every,
        const Duration(minutes: 90, seconds: 7, microseconds: 11),
      );
      expect(stored.schedule.isRecurring, isTrue);
    });

    test(
      'a null due time comes back as "no further runs", not as zero',
      () async {
        final Automation finished = job(
          id: 'a1',
          enabled: false,
          clearNextRunAt: true,
          lastRunAt: DateTime.utc(2026, 5, 1, 9),
        );

        await automations.insert(finished);

        final Automation stored = (await automations.find('a1'))!;
        expect(stored.nextRunAt, isNull);
        expect(stored.enabled, isFalse);
        expect(stored.lastRunAt, DateTime.utc(2026, 5, 1, 9));
      },
    );

    test('a missing field is an error that names it, not a default', () async {
      await automations.insert(job(id: 'a1'));
      final String path = '${root.path}/${NoirCollections.automations}/a1.json';
      final Map<String, Object?> envelope =
          jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
      final Map<String, Object?> payload = Map<String, Object?>.of(
        envelope['payload']! as Map<String, Object?>,
      );
      payload.remove('revision');
      payload['runCount'] = 'five';
      File(path).writeAsStringSync(
        jsonEncode(<String, Object?>{...envelope, 'payload': payload}),
      );

      // Both a missing field and a wrongly typed one are reported, each by name.
      await expectLater(
        automations.find('a1'),
        throwsA(
          isA<MalformedRecordError>().having(
            (MalformedRecordError error) => error.field,
            'field',
            'revision',
          ),
        ),
      );
      payload['revision'] = 1;
      File(path).writeAsStringSync(
        jsonEncode(<String, Object?>{...envelope, 'payload': payload}),
      );
      await expectLater(
        automations.find('a1'),
        throwsA(
          isA<MalformedRecordError>().having(
            (MalformedRecordError error) => error.field,
            'field',
            'runCount',
          ),
        ),
      );
    });

    test(
      'a schedule that cannot be rebuilt is refused, not replaced',
      () async {
        const AutomationRecordCodec codec = AutomationRecordCodec();

        expect(
          () => codec.decode('a1', <String, Object?>{
            ...encodeAutomation(job(id: 'a1')),
            'schedule': <String, Object?>{'kind': 'every_full_moon'},
          }),
          throwsA(
            isA<MalformedRecordError>().having(
              (MalformedRecordError error) => error.field,
              'field',
              'schedule.kind',
            ),
          ),
        );
        expect(
          () => codec.decode('a1', <String, Object?>{
            ...encodeAutomation(job(id: 'a1')),
            // A zero interval is not a schedule, and the stored bytes must not
            // be able to talk the codec into one.
            'schedule': <String, Object?>{
              'kind': 'interval',
              'everyMicroseconds': 0,
            },
          }),
          throwsA(
            isA<MalformedRecordError>().having(
              (MalformedRecordError error) => error.field,
              'field',
              'schedule',
            ),
          ),
        );
      },
    );

    test('a job with no user behind it cannot be decoded into one', () async {
      const AutomationRecordCodec codec = AutomationRecordCodec();
      final Map<String, Object?> payload = encodeAutomation(job(id: 'a1'));
      payload['createdBy'] = <String, Object?>{
        'userId': '   ',
        'requestedAt': _created.toIso8601String(),
      };

      expect(
        () => codec.decode('a1', payload),
        throwsA(
          isA<MalformedRecordError>().having(
            (MalformedRecordError error) => error.field,
            'field',
            'createdBy.userId',
          ),
        ),
      );
    });
  });

  group('insert', () {
    test(
      'refuses a duplicate id instead of overwriting the stored job',
      () async {
        await automations.insert(job(id: 'a1', name: 'first'));

        await expectLater(
          automations.insert(job(id: 'a1', name: 'second')),
          throwsA(
            isA<AutomationError>()
                .having((AutomationError e) => e.code, 'code', 'DUPLICATE_ID')
                .having((AutomationError e) => e.id, 'id', 'a1'),
          ),
        );
        expect((await automations.find('a1'))!.name, 'first');
      },
    );

    test('two concurrent inserts of one id leave exactly one job', () async {
      // Exactly one of these can win, and the loser must not have overwritten
      // the winner: this is the read-then-write race the insert path closes.
      await Future.wait(<Future<void>>[
        automations
            .insert(job(id: 'a1', name: 'first'))
            .then<void>((Automation _) {}, onError: (Object _) {}),
        automations
            .insert(job(id: 'a1', name: 'second'))
            .then<void>((Automation _) {}, onError: (Object _) {}),
      ]);

      final List<Automation> stored = await automations.list();
      expect(stored, hasLength(1));
      expect(
        stored.single.name,
        anyOf('first', 'second'),
        reason: 'whichever insert won is the record that is there',
      );
    });
  });

  group('update', () {
    test('applies the mutation and returns what was stored', () async {
      await automations.insert(job(id: 'a1'));

      final Automation updated = await automations.update(
        'a1',
        (Automation current) =>
            current.copyWith(name: 'renamed', revision: current.revision + 1),
      );

      expect(updated.name, 'renamed');
      expect(updated.revision, 2);
      expectSameJob((await automations.find('a1'))!, updated);
    });

    test(
      'an unknown id is the service\'s own failure, not a store error',
      () async {
        await expectLater(
          automations.update('ghost', (Automation current) => current),
          throwsA(
            isA<AutomationError>()
                .having((AutomationError e) => e.code, 'code', 'UNKNOWN_ID')
                .having((AutomationError e) => e.id, 'id', 'ghost'),
          ),
        );
      },
    );

    test(
      'concurrent read-modify-writes to one id cannot lose a write',
      () async {
        await automations.insert(job(id: 'a1'));

        await Future.wait(<Future<Automation>>[
          for (int i = 0; i < 32; i++)
            automations.update(
              'a1',
              (Automation current) =>
                  current.copyWith(runCount: current.runCount + 1),
            ),
        ]);

        expect((await automations.find('a1'))!.runCount, 32);
      },
    );

    test(
      'one occurrence can be claimed exactly once, however many pass',
      () async {
        // This is the property the scheduler depends on: `AutomationService`
        // decides whether *this* call took the job by testing whether its own
        // mutation set the claim, which is only sound if the read-modify-write is
        // atomic. A repository that read and then wrote would hand the same
        // occurrence to every overlapping pass.
        await automations.insert(job(id: 'a1', nextRunAt: _due));
        int took = 0;
        final DateTime due = _due;

        await Future.wait(<Future<Automation>>[
          for (int i = 0; i < 8; i++)
            automations.update('a1', (Automation current) {
              if (!current.isDueAt(due)) return current;
              took++;
              return current.copyWith(claimedAt: due);
            }),
        ]);

        expect(took, 1);
        expect((await automations.find('a1'))!.claimedAt, _due);
        expect((await automations.find('a1'))!.isDueAt(_due), isFalse);
      },
    );

    test('a throwing mutation leaves the stored job untouched', () async {
      await automations.insert(job(id: 'a1', name: 'before'));

      await expectLater(
        automations.update('a1', (Automation current) {
          throw const AutomationError('INVALID_INTERVAL');
        }),
        throwsA(isA<AutomationError>()),
      );

      expect((await automations.find('a1'))!.name, 'before');
    });
  });

  group('history', () {
    test(
      'is append-only, in order, and independent of the live record',
      () async {
        final Automation created = job(id: 'a1');
        await automations.insert(created);
        await automations.appendRevision(revisionOf(created));

        final Automation renamed = await automations.update(
          'a1',
          (Automation current) =>
              current.copyWith(name: 'renamed', revision: current.revision + 1),
        );
        await automations.appendRevision(
          revisionOf(
            renamed,
            change: AutomationChange.edited,
            revision: 2,
            recordedAt: DateTime.utc(2026, 5, 1, 10),
          ),
        );

        final List<AutomationRevision> history = await automations.revisions(
          'a1',
        );
        expect(history, hasLength(2));
        expect(history.map((AutomationRevision r) => r.revision), <int>[1, 2]);
        expect(
          history.map((AutomationRevision r) => r.change),
          <AutomationChange>[AutomationChange.created, AutomationChange.edited],
        );
        // A revision keeps the whole job as it was, so the trail still says what
        // the job was called before it was renamed.
        expect(history.first.snapshot.name, 'Morning digest');
        expect(history.last.snapshot.name, 'renamed');

        // Reopening reads the same trail off disk.
        expect(await reopen().revisions('a1'), hasLength(2));
      },
    );

    test('concurrent appends all land, in append order', () async {
      final Automation created = job(id: 'a1');
      await automations.insert(created);

      await Future.wait(<Future<void>>[
        for (int i = 1; i <= 24; i++)
          automations.appendRevision(
            // Each entry carries the job as it was at that revision, which is
            // what makes the log readable rather than merely countable.
            revisionOf(
              job(id: 'a1', revision: i),
              change: AutomationChange.edited,
              revision: i,
              recordedAt: _created.add(Duration(minutes: i)),
            ),
          ),
      ]);

      final List<AutomationRevision> history = await automations.revisions(
        'a1',
      );
      expect(history, hasLength(24));
      expect(
        history.map((AutomationRevision r) => r.revision),
        List<int>.generate(24, (int i) => i + 1),
        reason: 'the log is in append order, oldest first',
      );
    });

    test('a deleted job keeps the trail that recorded it', () async {
      final Automation created = job(id: 'a1');
      await automations.insert(created);
      await automations.appendRevision(revisionOf(created));

      expect(await automations.delete('a1'), isTrue);
      expect(await automations.find('a1'), isNull);
      expect(await automations.revisions('a1'), hasLength(1));
      expect(await automations.delete('a1'), isFalse);
      expect(await reopen().revisions('a1'), hasLength(1));
    });

    test('a revision filed under the wrong id is refused on read', () async {
      const AutomationHistoryCodec codec = AutomationHistoryCodec();
      final Automation created = job(id: 'a1');
      final Map<String, Object?> payload = codec.encode(
        AutomationHistoryRecord(
          id: 'a1',
          createdAt: _created,
          updatedAt: _created,
          revisions: <AutomationRevision>[revisionOf(created)],
        ),
      );
      final List<Object?> revisions = payload['revisions']! as List<Object?>;
      final Map<String, Object?> entry = Map<String, Object?>.from(
        revisions.single! as Map<String, Object?>,
      );
      entry['automationId'] = 'a2';

      expect(
        () => codec.decode('a1', <String, Object?>{
          ...payload,
          'revisions': <Object?>[entry],
        }),
        throwsA(
          isA<MalformedRecordError>().having(
            (MalformedRecordError error) => error.field,
            'field',
            'revisions[0].automationId',
          ),
        ),
      );
    });
  });

  group('durability', () {
    test('jobs and their history are still there after a reopen', () async {
      final AutomationService service = AutomationService(
        repository: automations,
        // Nothing may run in this test; the gate says so rather than being
        // assumed, because an unstated gate is the thing this whole file exists
        // to rule out.
        gate: const DenyAllPolicyGate(reason: 'no run in a storage test'),
        executor: _RefusingExecutor(),
        clock: _FixedClock(_created),
      );

      await service.create(
        id: 'nightly',
        name: 'Nightly digest',
        action: 'read_screen|Inbox',
        schedule: AutomationSchedule.interval(every: const Duration(hours: 6)),
        intent: _intent('u-7'),
        maxAttempts: 3,
      );
      await service.update('nightly', name: 'Nightly digest (renamed)');
      await service.disable('nightly');

      // Everything above is dropped: the layer is closed and a brand new
      // repository is built over the same directory, which is the only way a
      // row can still be there.
      final DurableAutomationRepository afterRestart = reopen();
      final Automation restored = (await afterRestart.find('nightly'))!;
      expect(restored.name, 'Nightly digest (renamed)');
      expect(restored.enabled, isFalse);
      expect(restored.maxAttempts, 3);
      expect(restored.revision, 3);
      expect(restored.createdBy.userId, 'u-7');
      expect(
        restored.schedule,
        AutomationSchedule.interval(every: const Duration(hours: 6)),
      );

      final List<AutomationRevision> history = await afterRestart.revisions(
        'nightly',
      );
      expect(
        history.map((AutomationRevision r) => r.change),
        <AutomationChange>[
          AutomationChange.created,
          AutomationChange.edited,
          AutomationChange.disabled,
        ],
      );
      // Every snapshot is the job as it was, so the trail explains how it got
      // to where it is.
      expect(history.first.snapshot.name, 'Nightly digest');
      expect(history.last.snapshot.enabled, isFalse);

      // And the service built on the reopened repository sees the same world.
      final AutomationService afterService = AutomationService(
        repository: afterRestart,
        gate: const DenyAllPolicyGate(),
        executor: _RefusingExecutor(),
        clock: _FixedClock(_created),
      );
      expect(await afterService.list(), hasLength(1));
      expect(await afterService.history('nightly'), hasLength(3));
    });

    test(
      'the bytes are real files, in the collections the catalog declares',
      () async {
        await automations.insert(job(id: 'a1'));
        await automations.appendRevision(revisionOf(job(id: 'a1')));

        final File record = File(
          '${root.path}/${NoirCollections.automations}/a1.json',
        );
        expect(record.existsSync(), isTrue);
        expect(record.readAsStringSync(), contains('read_screen|Inbox'));
        expect(
          File(
            '${root.path}/${NoirCollections.automationHistory}/a1.json',
          ).existsSync(),
          isTrue,
        );
        // The store stamps its own envelope, so a record that is not versioned
        // could not be migrated by the next build.
        final Map<String, Object?> envelope =
            jsonDecode(record.readAsStringSync()) as Map<String, Object?>;
        expect(envelope['schemaVersion'], 1);
      },
    );

    test(
      'an in-memory store says so rather than claiming durability',
      () async {
        final DurableAutomationRepository volatile =
            DurableAutomationRepository(
              store: InMemoryKeyValueStore(
                catalog: buildNoirCatalog(),
                clock: () => _created,
              ),
              clock: () => _created,
            );
        expect(volatile.isDurable, isFalse);
        await volatile.insert(job(id: 'a1'));
        expect(await volatile.find('a1'), isNotNull);
      },
    );

    test('a job that cannot be decoded is not offered as runnable', () async {
      await automations.insert(job(id: 'a1'));
      await automations.insert(job(id: 'a2'));
      File(
        '${root.path}/${NoirCollections.automations}/a2.json',
      ).writeAsStringSync('{"schemaVersion":1,"writtenAt":');
      // The healthy job still runs; the damaged one is left out and the store's
      // own recovery path keeps the reason and the bytes.
      final List<Automation> listed = await automations.list();
      expect(listed.map((Automation job) => job.id), <String>['a1']);
      expect(store.recoveries, isNotEmpty);
    });
  });
}

/// An executor that refuses every attempt. The storage tests must never reach an
/// executor, and one that says so is better than one that silently succeeds.
class _RefusingExecutor implements AutomationExecutor {
  @override
  Future<void> execute(AutomationExecutionContext context) async {
    throw StateError('a storage test must not dispatch anything');
  }
}

/// A clock that does not move, so a timestamp in a stored record is the one the
/// test wrote.
class _FixedClock implements Clock {
  const _FixedClock(this._now);

  final DateTime _now;

  @override
  DateTime now() => _now;
}
