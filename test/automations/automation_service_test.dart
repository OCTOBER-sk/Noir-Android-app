// The scheduled automation subsystem: CRUD, deterministic scheduling from an
// injected clock, bounded dispatch, cancellation and the policy gate.
//
// Nothing here is seeded: every job in every test is created by the test itself,
// and the repository starts empty.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/automations/automations.dart';
import 'package:noir_android_app/core/clock.dart';

/// A gate whose verdict the test controls, recording what it was asked about.
class _StubGate implements AutomationPolicyGate {
  bool approves = true;
  String reason = 'user approved';

  /// Ids this gate refuses, whatever [approves] says.
  Set<String> deniedIds = <String>{};
  final List<String> evaluated = <String>[];

  @override
  Future<PolicyGateDecision> evaluate(Automation automation) async {
    evaluated.add(automation.id);
    if (deniedIds.contains(automation.id)) {
      return PolicyGateDecision.denied('refused $reason');
    }
    return approves
        ? PolicyGateDecision.approved(reason)
        : PolicyGateDecision.denied(reason);
  }
}

/// An executor that records its calls and can be made to block, fail or ignore
/// cancellation. It is the stand-in for an already policy-gated action: it
/// touches nothing but memory.
class _StubExecutor implements AutomationExecutor {
  /// Automation ids whose run throws.
  Set<String> failFor = <String>{};

  /// When set, every run waits on this before finishing.
  Completer<void>? blocker;

  /// When true, a cancelled token does not stop the executor.
  bool ignoresCancellation = false;

  final List<AutomationExecutionContext> calls = <AutomationExecutionContext>[];

  int active = 0;
  int peakConcurrency = 0;

  List<String> get calledIds =>
      calls.map((AutomationExecutionContext c) => c.automation.id).toList();

  @override
  Future<void> execute(AutomationExecutionContext context) async {
    calls.add(context);
    active += 1;
    if (active > peakConcurrency) {
      peakConcurrency = active;
    }
    try {
      final Completer<void>? wait = blocker;
      if (wait != null) {
        await wait.future;
      }
      if (!ignoresCancellation && context.token.isCancelled) {
        return;
      }
      if (failFor.contains(context.automation.id)) {
        throw StateError('executor refused ${context.automation.id}');
      }
    } finally {
      active -= 1;
    }
  }
}

void main() {
  final DateTime start = DateTime.utc(2026, 5, 1, 9);

  late FakeClock clock;
  late InMemoryAutomationRepository repository;
  late _StubGate gate;
  late _StubExecutor executor;

  setUp(() {
    clock = FakeClock(start);
    repository = InMemoryAutomationRepository();
    gate = _StubGate();
    executor = _StubExecutor();
  });

  AutomationService build({
    int maxConcurrentRuns = 2,
    int maxLogEntries = 100,
    Clock? injectedClock,
    AutomationRepository? repo,
    AutomationPolicyGate? injectedGate,
    AutomationExecutor? injectedExecutor,
  }) {
    return AutomationService(
      repository: repo ?? repository,
      gate: injectedGate ?? gate,
      executor: injectedExecutor ?? executor,
      clock: injectedClock ?? clock,
      maxConcurrentRuns: maxConcurrentRuns,
      maxLogEntries: maxLogEntries,
    );
  }

  UserIntent intentAt([DateTime? at]) =>
      UserIntent(userId: 'u-1', requestedAt: at ?? clock.now());

  /// A job that will be due two minutes from now, used by [makeDue].
  AutomationSchedule soonOnce() =>
      AutomationSchedule.once(clock.now().add(const Duration(minutes: 2)));

  Future<Automation> create(
    AutomationService service, {
    required String id,
    AutomationSchedule? schedule,
    String? name,
    String? action,
    int maxAttempts = 1,
    bool enabled = true,
    DateTime? firstRunAt,
    UserIntent? intent,
  }) {
    return service.create(
      id: id,
      name: name ?? 'Nightly $id',
      action: action ?? 'run $id',
      schedule: schedule ?? soonOnce(),
      intent: intent ?? intentAt(),
      maxAttempts: maxAttempts,
      enabled: enabled,
      firstRunAt: firstRunAt,
    );
  }

  /// Creates [count] one-shot jobs and moves the clock past all of them.
  Future<List<Automation>> makeDue(AutomationService service, int count) async {
    final List<Automation> jobs = <Automation>[];
    for (int i = 1; i <= count; i++) {
      jobs.add(await create(service, id: 'job-$i'));
    }
    clock.advance(const Duration(minutes: 2));
    return jobs;
  }

  group('empty by default', () {
    test('a fresh service holds no jobs, no revisions and no log', () async {
      final AutomationService service = build();

      expect(await repository.list(), isEmpty);
      expect(service.log(), isEmpty);
      expect(await service.runDueJobs(), isEmpty);
      expect(executor.calls, isEmpty);
      expect(gate.evaluated, isEmpty);
    });
  });

  group('create', () {
    test(
      'stores a user-created job with its revision history opened',
      () async {
        final AutomationService service = build();

        final Automation created = await create(
          service,
          id: 'a1',
          name: 'Nightly digest',
          action: 'summarise today',
        );

        expect(created.id, 'a1');
        expect(created.enabled, isTrue);
        expect(created.revision, 1);
        expect(created.runCount, 0);
        expect(created.createdBy.userId, 'u-1');
        expect(created.createdBy, isNotNull);
        expect(created.nextRunAt, start.add(const Duration(minutes: 2)));

        final List<AutomationRevision> history = await repository.revisions(
          'a1',
        );
        expect(history, hasLength(1));
        expect(history.single.revision, 1);
        expect(history.single.change, AutomationChange.created);
        expect(history.single.snapshot.action, 'summarise today');
      },
    );

    test(
      'rejects a duplicate id instead of overwriting the stored job',
      () async {
        final AutomationService service = build();
        await create(service, id: 'a1', action: 'first');

        await expectLater(
          create(service, id: 'a1', action: 'second'),
          throwsA(
            isA<AutomationError>().having(
              (AutomationError e) => e.code,
              'code',
              'DUPLICATE_ID',
            ),
          ),
        );

        final Automation stored = (await repository.find('a1'))!;
        expect(stored.action, 'first');
        expect(await repository.revisions('a1'), hasLength(1));
      },
    );

    test('rejects blank name, blank action and an unusable id', () async {
      final AutomationService service = build();

      await expectLater(
        create(service, id: 'a1', name: '   '),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'EMPTY_NAME',
          ),
        ),
      );
      await expectLater(
        create(service, id: 'a1', action: '  '),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'EMPTY_ACTION',
          ),
        ),
      );
      await expectLater(
        create(service, id: '  '),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'EMPTY_ID',
          ),
        ),
      );
      expect(await repository.list(), isEmpty);
    });

    test('requires the job to be requested by a user', () async {
      final AutomationService service = build();

      await expectLater(
        create(
          service,
          id: 'a1',
          intent: UserIntent(userId: '', requestedAt: clock.now()),
        ),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'EMPTY_USER_ID',
          ),
        ),
      );
      await expectLater(
        create(
          service,
          id: 'a1',
          intent: UserIntent(
            userId: 'u-1',
            requestedAt: start.add(const Duration(hours: 1)),
          ),
        ),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'REQUESTED_IN_FUTURE',
          ),
        ),
      );
      expect(await repository.list(), isEmpty);
    });

    test('rejects a non-positive retry bound', () async {
      final AutomationService service = build();

      await expectLater(
        create(service, id: 'a1', maxAttempts: 0),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'INVALID_MAX_ATTEMPTS',
          ),
        ),
      );
      expect(await repository.list(), isEmpty);
    });
  });

  group('schedules', () {
    test('an interval job is next due exactly one interval ahead', () async {
      final AutomationService service = build();

      final Automation created = await create(
        service,
        id: 'a1',
        schedule: AutomationSchedule.interval(every: const Duration(hours: 2)),
      );

      expect(created.nextRunAt, start.add(const Duration(hours: 2)));
    });

    test('an interval job can start in the past and is then due', () async {
      final AutomationService service = build();

      final Automation created = await create(
        service,
        id: 'a1',
        schedule: AutomationSchedule.interval(every: const Duration(hours: 1)),
        firstRunAt: start.subtract(const Duration(hours: 3)),
      );

      expect(created.nextRunAt, start.subtract(const Duration(hours: 2)));
      expect(created.isDueAt(clock.now()), isTrue);
    });

    test('an explicit one-shot keeps the exact instant it was given', () async {
      final AutomationService service = build();
      final DateTime at = start.add(const Duration(days: 1));

      final Automation created = await create(
        service,
        id: 'a1',
        schedule: AutomationSchedule.once(at),
      );

      expect(created.schedule.kind, AutomationScheduleKind.once);
      expect(created.nextRunAt, at);
    });

    test('rejects an interval that is not a positive duration', () {
      expect(
        () => AutomationSchedule.interval(every: Duration.zero),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'INVALID_INTERVAL',
          ),
        ),
      );
      expect(
        () => AutomationSchedule.interval(every: const Duration(seconds: -1)),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'INVALID_INTERVAL',
          ),
        ),
      );
    });

    test('rejects a one-shot instant that is not in the future', () async {
      final AutomationService service = build();

      await expectLater(
        create(
          service,
          id: 'a1',
          schedule: AutomationSchedule.once(
            start.subtract(const Duration(minutes: 1)),
          ),
        ),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'INVALID_SCHEDULE',
          ),
        ),
      );
      expect(await repository.list(), isEmpty);
    });

    test(
      'rejects a one-shot whose instant is not the scheduled instant',
      () async {
        final AutomationService service = build();
        final DateTime at = start.add(const Duration(hours: 3));

        await expectLater(
          create(
            service,
            id: 'a1',
            schedule: AutomationSchedule.once(at),
            firstRunAt: start,
          ),
          throwsA(
            isA<AutomationError>().having(
              (AutomationError e) => e.code,
              'code',
              'INVALID_SCHEDULE',
            ),
          ),
        );
      },
    );

    test(
      'an interval job whose schedule changes is rescheduled from now',
      () async {
        final AutomationService service = build();
        await create(
          service,
          id: 'a1',
          schedule: AutomationSchedule.interval(
            every: const Duration(hours: 1),
          ),
        );
        clock.advance(const Duration(minutes: 10));

        final Automation updated = await service.update(
          'a1',
          schedule: AutomationSchedule.interval(
            every: const Duration(minutes: 30),
          ),
        );

        expect(updated.nextRunAt, clock.now().add(const Duration(minutes: 30)));
      },
    );

    test('a due time is inclusive and a future one is not due', () async {
      final AutomationService service = build();
      final Automation created = await create(service, id: 'a1');
      final DateTime due = created.nextRunAt!;

      expect(
        created.isDueAt(due.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(created.isDueAt(due), isTrue);
      expect(created.isDueAt(due.add(const Duration(seconds: 1))), isTrue);
    });
  });

  group('update, enable, disable and delete', () {
    test('every configuration change appends an immutable revision', () async {
      final AutomationService service = build();
      await create(service, id: 'a1', action: 'first');

      await service.update('a1', action: 'second');
      await service.update('a1', name: 'renamed');
      final Automation disabled = await service.disable('a1');
      final Automation enabled = await service.enable('a1');

      expect(disabled.revision, 4);
      expect(enabled.revision, 5);

      final List<AutomationRevision> history = await repository.revisions('a1');
      expect(history.map((AutomationRevision r) => r.revision).toList(), <int>[
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(
        history.map((AutomationRevision r) => r.change).toList(),
        <AutomationChange>[
          AutomationChange.created,
          AutomationChange.edited,
          AutomationChange.edited,
          AutomationChange.disabled,
          AutomationChange.enabled,
        ],
      );
      // History is a snapshot trail, not a view of the live record.
      expect(history[0].snapshot.action, 'first');
      expect(history[1].snapshot.action, 'second');
      expect(history.last.snapshot.enabled, isTrue);
      expect(() => history.add(history.first), throwsUnsupportedError);
    });

    test('a run does not move the configuration revision', () async {
      final AutomationService service = build();
      await makeDue(service, 1);

      await service.runDueJobs();

      final Automation stored = (await repository.find('job-1'))!;
      expect(stored.revision, 1);
      expect(await repository.revisions('job-1'), hasLength(1));
    });

    test(
      'a disabled job is not due and enabling recomputes the next run',
      () async {
        final AutomationService service = build();
        await create(
          service,
          id: 'a1',
          schedule: AutomationSchedule.interval(
            every: const Duration(hours: 1),
          ),
        );
        clock.advance(const Duration(minutes: 2));

        final Automation disabled = await service.disable('a1');
        expect(disabled.enabled, isFalse);
        expect(disabled.isDueAt(clock.now()), isFalse);
        expect(await service.runDueJobs(), isEmpty);
        expect(executor.calls, isEmpty);

        clock.advance(const Duration(hours: 3));
        final Automation enabled = await service.enable('a1');
        expect(enabled.enabled, isTrue);
        expect(enabled.isDueAt(clock.now()), isFalse);
        expect(enabled.nextRunAt, clock.now().add(const Duration(hours: 1)));
      },
    );

    test('a one-shot that expired while disabled cannot be re-armed', () async {
      final AutomationService service = build();
      await create(service, id: 'a1');
      await service.disable('a1');
      clock.advance(const Duration(days: 2));

      final Automation enabled = await service.enable('a1');

      expect(enabled.nextRunAt, isNull);
      expect(enabled.isDueAt(clock.now()), isFalse);
    });

    test(
      'rejects updates to an unknown job and leaves the store untouched',
      () async {
        final AutomationService service = build();

        await expectLater(
          service.update('ghost', action: 'x'),
          throwsA(
            isA<AutomationError>().having(
              (AutomationError e) => e.code,
              'code',
              'UNKNOWN_ID',
            ),
          ),
        );
        await expectLater(
          service.enable('ghost'),
          throwsA(
            isA<AutomationError>().having(
              (AutomationError e) => e.code,
              'code',
              'UNKNOWN_ID',
            ),
          ),
        );
        await expectLater(service.delete('ghost'), completion(isFalse));
      },
    );

    test('deletes a job and keeps its audit trail', () async {
      final AutomationService service = build();
      await create(service, id: 'a1');

      expect(await service.delete('a1'), isTrue);
      expect(await repository.find('a1'), isNull);
      expect(await repository.revisions('a1'), hasLength(1));
      expect(await service.delete('a1'), isFalse);
    });
  });

  group('dispatch', () {
    test('runs only the jobs that are due', () async {
      final AutomationService service = build();
      await create(service, id: 'due');
      await create(
        service,
        id: 'later',
        schedule: AutomationSchedule.once(
          clock.now().add(const Duration(days: 1)),
        ),
      );
      await create(
        service,
        id: 'disabled',
        schedule: AutomationSchedule.once(
          clock.now().add(const Duration(minutes: 2)),
        ),
        enabled: false,
      );
      clock.advance(const Duration(minutes: 5));

      final List<AutomationRun> runs = await service.runDueJobs();

      expect(runs.map((AutomationRun r) => r.automationId), <String>['due']);
      expect(executor.calledIds, <String>['due']);
      expect(gate.evaluated, <String>['due']);
    });

    test('records a successful run, counts it and reschedules', () async {
      final AutomationService service = build();
      await create(
        service,
        id: 'a1',
        schedule: AutomationSchedule.interval(every: const Duration(hours: 1)),
        firstRunAt: start.subtract(const Duration(hours: 1, seconds: 1)),
      );

      final List<AutomationRun> runs = await service.runDueJobs();

      expect(runs, hasLength(1));
      expect(runs.single.outcome, AutomationOutcome.succeeded);
      expect(runs.single.attempts, 1);
      expect(runs.single.error, isNull);
      expect(runs.single.automationRevision, 1);
      // The run answers the occurrence it was due for, not the pass instant.
      expect(
        runs.single.scheduledFor,
        start.subtract(const Duration(seconds: 1)),
      );

      final Automation stored = (await repository.find('a1'))!;
      expect(stored.runCount, 1);
      expect(stored.consecutiveFailures, 0);
      expect(stored.lastError, isNull);
      expect(stored.lastRunAt, clock.now());
      expect(stored.claimedAt, isNull);
      // Rescheduled from the occurrence, so a run that started late does not
      // push the whole interval forward.
      expect(
        stored.nextRunAt,
        start
            .subtract(const Duration(seconds: 1))
            .add(const Duration(hours: 1)),
      );
      // Not due again straight away.
      expect(await service.runDueJobs(), isEmpty);
    });

    test('a one-shot disables itself after its single run', () async {
      final AutomationService service = build();
      await makeDue(service, 1);

      await service.runDueJobs();

      final Automation stored = (await repository.find('job-1'))!;
      expect(stored.nextRunAt, isNull);
      expect(stored.enabled, isFalse);
      expect(stored.isDueAt(clock.now()), isFalse);
    });

    test('a failing run records the error and counts the failure', () async {
      executor.failFor = <String>{'job-1'};
      final AutomationService service = build();
      await makeDue(service, 1);

      final List<AutomationRun> runs = await service.runDueJobs();

      expect(runs.single.outcome, AutomationOutcome.failed);
      expect(runs.single.error, contains('executor refused job-1'));
      final Automation stored = (await repository.find('job-1'))!;
      expect(stored.consecutiveFailures, 1);
      expect(stored.runCount, 0);
      expect(stored.lastError, contains('executor refused job-1'));
      expect(stored.claimedAt, isNull);
      expect(service.log().single.outcome, AutomationOutcome.failed);
    });

    test('a success clears the previous failure', () async {
      executor.failFor = <String>{'a1'};
      final AutomationService service = build();
      await create(
        service,
        id: 'a1',
        schedule: AutomationSchedule.interval(
          every: const Duration(minutes: 30),
        ),
        firstRunAt: start.subtract(const Duration(minutes: 31)),
      );
      await service.runDueJobs();
      executor.failFor = <String>{};
      clock.advance(const Duration(minutes: 30));

      await service.runDueJobs();

      final Automation stored = (await repository.find('a1'))!;
      expect(stored.consecutiveFailures, 0);
      expect(stored.lastError, isNull);
      expect(stored.runCount, 1);
    });

    test(
      'retries a failing job up to the configured bound and no further',
      () async {
        executor.failFor = <String>{'a1'};
        final AutomationService service = build();
        await create(service, id: 'a1', maxAttempts: 3);
        clock.advance(const Duration(minutes: 2));

        final List<AutomationRun> runs = await service.runDueJobs();

        expect(executor.calls, hasLength(3));
        expect(
          executor.calls.map((AutomationExecutionContext c) => c.attempt),
          <int>[1, 2, 3],
        );
        expect(runs.single.outcome, AutomationOutcome.failed);
        expect(runs.single.attempts, 3);
      },
    );

    test('a single-attempt job is not retried', () async {
      executor.failFor = <String>{'job-1'};
      final AutomationService service = build();
      await makeDue(service, 1);

      await service.runDueJobs();

      expect(executor.calls, hasLength(1));
      expect(service.log().single.attempts, 1);
    });

    test('a retried job stops at the first success', () async {
      int attempts = 0;
      final AutomationExecutor flaky = _CountingExecutor((_) {
        attempts += 1;
        if (attempts == 1) {
          throw StateError('first attempt failed');
        }
      });
      final AutomationService service = build(injectedExecutor: flaky);
      await create(service, id: 'a1', maxAttempts: 3);
      clock.advance(const Duration(minutes: 2));

      final List<AutomationRun> runs = await service.runDueJobs();

      expect(attempts, 2);
      expect(runs.single.outcome, AutomationOutcome.succeeded);
      expect(runs.single.attempts, 2);
      expect(runs.single.error, isNull);
      expect((await repository.find('a1'))!.consecutiveFailures, 0);
    });

    test('a denied job never reaches the executor', () async {
      gate.approves = false;
      gate.reason = 'no biometric confirmation';
      final AutomationService service = build();
      await makeDue(service, 1);

      final List<AutomationRun> runs = await service.runDueJobs();

      expect(runs.single.outcome, AutomationOutcome.denied);
      expect(runs.single.attempts, 0);
      expect(runs.single.error, contains('no biometric confirmation'));
      expect(executor.calls, isEmpty);
      final Automation stored = (await repository.find('job-1'))!;
      expect(stored.runCount, 0);
      expect(stored.claimedAt, isNull);
      // A denial is not a run, so none of the run bookkeeping moves.
      expect(stored.lastRunAt, isNull);
      expect(stored.consecutiveFailures, 0);
      expect(stored.lastError, contains('POLICY_DENIED'));
      // Rescheduled rather than left to spin.
      expect(stored.isDueAt(clock.now()), isFalse);
    });

    test(
      'a denied recurring job is asked again on its next interval',
      () async {
        gate.approves = false;
        final AutomationService service = build();
        await create(
          service,
          id: 'a1',
          schedule: AutomationSchedule.interval(
            every: const Duration(minutes: 15),
          ),
          firstRunAt: start.subtract(const Duration(minutes: 16)),
        );

        await service.runDueJobs();
        expect(gate.evaluated, <String>['a1']);
        expect(await service.runDueJobs(), isEmpty);

        clock.advance(const Duration(minutes: 15));
        await service.runDueJobs();
        expect(gate.evaluated, <String>['a1', 'a1']);
      },
    );

    test('honours the run limit', () async {
      final AutomationService service = build();
      await makeDue(service, 3);

      final List<AutomationRun> runs = await service.runDueJobs(limit: 2);

      expect(runs, hasLength(2));
      expect(runs.map((AutomationRun r) => r.automationId).toList(), <String>[
        'job-1',
        'job-2',
      ]);
      expect(await service.runDueJobs(), hasLength(1));
    });

    test('runs jobs in due order and never twice for one occurrence', () async {
      final AutomationService service = build();
      await create(
        service,
        id: 'late',
        schedule: AutomationSchedule.once(
          clock.now().add(const Duration(minutes: 5)),
        ),
      );
      await create(
        service,
        id: 'early',
        schedule: AutomationSchedule.once(
          clock.now().add(const Duration(minutes: 1)),
        ),
      );
      clock.advance(const Duration(minutes: 10));

      final List<AutomationRun> runs = await service.runDueJobs();

      expect(runs.map((AutomationRun r) => r.automationId).toList(), <String>[
        'early',
        'late',
      ]);
      expect(service.log().map((AutomationRun r) => r.runId).toList(), <String>[
        'run-0002',
        'run-0001',
      ]);
    });
  });

  group('reads', () {
    test(
      'the service reads jobs, lists them and serves their history',
      () async {
        final AutomationService service = build();
        await create(service, id: 'b1');
        await create(service, id: 'a1');
        await service.update('a1', name: 'renamed');

        expect((await service.find('a1'))!.name, 'renamed');
        expect(await service.find('ghost'), isNull);
        expect(
          (await service.list()).map((Automation a) => a.id).toList(),
          <String>['a1', 'b1'],
        );
        final List<AutomationRevision> history = await service.history('a1');
        expect(
          history.map((AutomationRevision r) => r.revision).toList(),
          <int>[1, 2],
        );
        expect(await service.history('ghost'), isEmpty);
      },
    );

    test('selects the due jobs without running them', () async {
      final AutomationService service = build();
      await makeDue(service, 3);

      final List<Automation> due = await service.selectDueJobs();

      expect(due.map((Automation a) => a.id).toList(), <String>[
        'job-1',
        'job-2',
        'job-3',
      ]);
      expect(executor.calls, isEmpty);
      expect(gate.evaluated, isEmpty);
      expect((await service.selectDueJobs(limit: 1)), hasLength(1));
    });

    test('a recurring schedule reports itself as recurring', () {
      expect(
        AutomationSchedule.interval(
          every: const Duration(minutes: 5),
        ).isRecurring,
        isTrue,
      );
      expect(
        AutomationSchedule.once(DateTime.utc(2026, 5, 2)).isRecurring,
        isFalse,
      );
    });
  });

  group('concurrency', () {
    test('never exceeds the configured number of simultaneous runs', () async {
      final Completer<void> blocker = Completer<void>();
      executor.blocker = blocker;
      final AutomationService service = build(maxConcurrentRuns: 2);
      await makeDue(service, 5);

      final Future<List<AutomationRun>> pending = service.runDueJobs();
      await pumpEventQueue();

      expect(service.runningIds, hasLength(2));
      expect(service.pendingIds, hasLength(3));
      expect(executor.peakConcurrency, 2);
      expect(executor.calls, hasLength(2));

      blocker.complete();
      final List<AutomationRun> runs = await pending;

      expect(runs, hasLength(5));
      expect(executor.peakConcurrency, 2);
      expect(executor.calls, hasLength(5));
    });

    test('a job already claimed is not run a second time', () async {
      final Completer<void> blocker = Completer<void>();
      executor.blocker = blocker;
      final AutomationService service = build(maxConcurrentRuns: 1);
      await makeDue(service, 1);

      final Future<List<AutomationRun>> first = service.runDueJobs();
      await pumpEventQueue();
      expect(service.runningIds, <String>{'job-1'});

      final List<AutomationRun> second = await service.runDueJobs();
      expect(second, isEmpty);
      expect(executor.calls, hasLength(1));
      // Nothing ran, so nothing is reported: a skipped claim is not a run.
      expect(service.log(), isEmpty);

      blocker.complete();
      await first;
      expect((await repository.find('job-1'))!.runCount, 1);
      expect(service.log(), hasLength(1));
    });

    test(
      'two passes that select the same job race for it and only one wins',
      () async {
        // Both passes read the job as due before either has claimed it, which is
        // the only window in which the claim has to be atomic.
        final Completer<void> gate = Completer<void>();
        final _GatedListRepository raced = _GatedListRepository(gate);
        final AutomationService service = build(repo: raced);
        await create(service, id: 'a1');
        clock.advance(const Duration(minutes: 2));

        final Future<List<AutomationRun>> first = service.runDueJobs();
        final Future<List<AutomationRun>> second = service.runDueJobs();
        await pumpEventQueue();
        gate.complete();
        final List<AutomationRun> runs = <AutomationRun>[
          ...await first,
          ...await second,
        ];

        expect(runs, hasLength(1));
        expect(runs.single.outcome, AutomationOutcome.succeeded);
        expect(executor.calls, hasLength(1));
        expect((await service.find('a1'))!.runCount, 1);
        expect(service.log(), hasLength(1));
      },
    );

    test('rejects a non-positive concurrency bound', () {
      expect(
        () => build(maxConcurrentRuns: 0),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'INVALID_CONCURRENCY',
          ),
        ),
      );
    });
  });

  group('cancellation', () {
    test('cancels a running job through its token', () async {
      final Completer<void> blocker = Completer<void>();
      executor.blocker = blocker;
      final AutomationService service = build(maxConcurrentRuns: 1);
      await makeDue(service, 1);

      final Future<List<AutomationRun>> pending = service.runDueJobs();
      await pumpEventQueue();
      expect(service.runningIds, <String>{'job-1'});

      expect(service.cancel('job-1', 'user stopped it'), isTrue);
      expect(executor.calls.single.token.isCancelled, isTrue);
      expect(executor.calls.single.token.reason, 'user stopped it');

      blocker.complete();
      final List<AutomationRun> runs = await pending;

      expect(runs.single.outcome, AutomationOutcome.cancelled);
      final Automation stored = (await repository.find('job-1'))!;
      expect(stored.runCount, 0);
      expect(stored.claimedAt, isNull);
      // A cancelled run leaves the job due so it can be tried again.
      expect(stored.isDueAt(clock.now()), isTrue);
    });

    test(
      'a cancelled run is reported even when the executor ignores it',
      () async {
        final Completer<void> blocker = Completer<void>();
        executor.blocker = blocker;
        executor.ignoresCancellation = true;
        final AutomationService service = build(maxConcurrentRuns: 1);
        await makeDue(service, 1);

        final Future<List<AutomationRun>> pending = service.runDueJobs();
        await pumpEventQueue();
        service.cancel('job-1');
        blocker.complete();
        final List<AutomationRun> runs = await pending;

        expect(runs.single.outcome, AutomationOutcome.cancelled);
        expect((await repository.find('job-1'))!.runCount, 0);
      },
    );

    test('cancels a job that has not started yet', () async {
      final Completer<void> blocker = Completer<void>();
      executor.blocker = blocker;
      final AutomationService service = build(maxConcurrentRuns: 1);
      await makeDue(service, 3);

      final Future<List<AutomationRun>> pending = service.runDueJobs();
      await pumpEventQueue();
      expect(service.pendingIds, <String>{'job-2', 'job-3'});

      expect(service.cancel('job-2'), isTrue);
      blocker.complete();
      final List<AutomationRun> runs = await pending;

      expect(executor.calledIds, <String>['job-1', 'job-3']);
      expect(
        runs
            .where(
              (AutomationRun r) => r.outcome == AutomationOutcome.cancelled,
            )
            .map((AutomationRun r) => r.automationId),
        <String>['job-2'],
      );
      // The cancelled job is still due, so the next pass picks it up.
      expect((await repository.find('job-2'))!.isDueAt(clock.now()), isTrue);
      final List<AutomationRun> again = await service.runDueJobs();
      expect(again.map((AutomationRun r) => r.automationId), <String>['job-2']);
    });

    test('cancelling a job that is not in flight reports false', () async {
      final AutomationService service = build();
      await makeDue(service, 1);

      expect(service.cancel('job-1'), isFalse);
      expect(service.cancel('ghost'), isFalse);
    });

    test('cancelAll stops every running and pending job', () async {
      final Completer<void> blocker = Completer<void>();
      executor.blocker = blocker;
      final AutomationService service = build(maxConcurrentRuns: 2);
      await makeDue(service, 4);

      final Future<List<AutomationRun>> pending = service.runDueJobs();
      await pumpEventQueue();
      expect(service.runningIds, hasLength(2));

      expect(service.cancelAll(), isTrue);
      blocker.complete();
      final List<AutomationRun> runs = await pending;

      // The two that had started are stopped through their token; the other two
      // never reach the executor at all.
      expect(executor.calledIds, <String>['job-1', 'job-2']);
      expect(
        executor.calls.every(
          (AutomationExecutionContext c) => c.token.isCancelled,
        ),
        isTrue,
      );
      expect(
        runs.map((AutomationRun r) => r.outcome).toSet(),
        <AutomationOutcome>{AutomationOutcome.cancelled},
      );
      expect(service.runningIds, isEmpty);
      expect(service.pendingIds, isEmpty);
    });

    test('a cancelled token is never handed to a later run', () async {
      final AutomationService service = build(maxConcurrentRuns: 1);
      await makeDue(service, 1);
      await service.runDueJobs();

      expect(service.runningIds, isEmpty);
      expect(executor.calls.single.token.isCancelled, isFalse);
    });
  });

  group('execution log', () {
    test('records every run outcome newest first', () async {
      executor.failFor = <String>{'job-1'};
      gate.deniedIds = <String>{'job-2'};
      final AutomationService service = build(maxConcurrentRuns: 1);
      await makeDue(service, 3);

      await service.runDueJobs();

      final List<AutomationRun> log = service.log();
      expect(log.map((AutomationRun r) => r.automationId).toList(), <String>[
        'job-3',
        'job-2',
        'job-1',
      ]);
      expect(
        log.map((AutomationRun r) => r.outcome).toList(),
        <AutomationOutcome>[
          AutomationOutcome.succeeded,
          AutomationOutcome.denied,
          AutomationOutcome.failed,
        ],
      );
      expect(
        log.every((AutomationRun r) => r.finishedAt == clock.now()),
        isTrue,
      );
    });

    test('caps what one log entry may keep of a failure', () async {
      final AutomationService loud = build(
        injectedExecutor: _CountingExecutor((AutomationExecutionContext c) {
          throw StateError('x' * (maxAutomationErrorLength * 2));
        }),
      );
      await create(loud, id: 'a1', maxAttempts: 1);
      clock.advance(const Duration(minutes: 2));

      final List<AutomationRun> runs = await loud.runDueJobs();

      expect(runs.single.error!.length, maxAutomationErrorLength);
      expect(
        (await repository.find('a1'))!.lastError!.length,
        maxAutomationErrorLength,
      );
      expect(loud.log(), hasLength(1));
    });

    test('can be filtered to one job', () async {
      final AutomationService service = build(maxConcurrentRuns: 1);
      await makeDue(service, 2);
      await service.runDueJobs();

      expect(
        service
            .log(automationId: 'job-1')
            .map((AutomationRun r) => r.automationId)
            .toList(),
        <String>['job-1'],
      );
    });

    test('drops the oldest entries beyond the retention bound', () async {
      final AutomationService service = build(
        maxConcurrentRuns: 1,
        maxLogEntries: 3,
      );
      await makeDue(service, 5);

      await service.runDueJobs();

      final List<AutomationRun> log = service.log();
      expect(log, hasLength(3));
      expect(log.map((AutomationRun r) => r.automationId).toList(), <String>[
        'job-5',
        'job-4',
        'job-3',
      ]);
      // The retention bound does not touch the job records themselves.
      expect(await repository.list(), hasLength(5));
    });

    test('rejects a non-positive retention bound', () {
      expect(
        () => build(maxLogEntries: 0),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError e) => e.code,
            'code',
            'INVALID_LOG_RETENTION',
          ),
        ),
      );
    });
  });

  group('safety', () {
    test('the deny-all gate blocks every job by default', () async {
      final AutomationService service = build(
        injectedGate: const DenyAllPolicyGate(),
      );
      await makeDue(service, 2);

      final List<AutomationRun> runs = await service.runDueJobs();

      expect(
        runs.map((AutomationRun r) => r.outcome).toSet(),
        <AutomationOutcome>{AutomationOutcome.denied},
      );
      expect(executor.calls, isEmpty);
      expect(
        runs.every((AutomationRun r) => r.error!.contains('DEFAULT_DENY')),
        isTrue,
      );
    });

    test('the gate is consulted before the executor, for every job', () async {
      final AutomationService service = build(maxConcurrentRuns: 1);
      await makeDue(service, 3);

      await service.runDueJobs();

      expect(gate.evaluated, <String>['job-1', 'job-2', 'job-3']);
      expect(executor.calledIds, <String>['job-1', 'job-2', 'job-3']);
    });

    test(
      'the executor receives the gate-approved job and a fresh token',
      () async {
        final AutomationService service = build();
        await create(service, id: 'a1');
        clock.advance(const Duration(minutes: 2));

        await service.runDueJobs();

        final AutomationExecutionContext context = executor.calls.single;
        expect(context.automation.id, 'a1');
        expect(context.runId, 'run-0001');
        expect(context.attempt, 1);
        expect(context.intent.userId, 'u-1');
        expect(context.token.isCancelled, isFalse);
      },
    );

    test('a denial after an approval still stops the next run', () async {
      final AutomationService service = build();
      await create(
        service,
        id: 'a1',
        schedule: AutomationSchedule.interval(
          every: const Duration(minutes: 10),
        ),
        firstRunAt: start.subtract(const Duration(minutes: 11)),
      );
      await service.runDueJobs();
      expect((await repository.find('a1'))!.runCount, 1);

      gate.approves = false;
      clock.advance(const Duration(minutes: 10));
      await service.runDueJobs();

      expect((await repository.find('a1'))!.runCount, 1);
      expect(executor.calls, hasLength(1));
      expect(service.log().first.outcome, AutomationOutcome.denied);
    });
  });
}

/// A repository whose reads are held behind a gate, so two scheduler passes can
/// be made to select the same job before either one claims it.
class _GatedListRepository extends InMemoryAutomationRepository {
  _GatedListRepository(this.gate);

  final Completer<void> gate;

  @override
  Future<List<Automation>> list() async {
    await gate.future;
    return super.list();
  }
}

/// Counts executions and delegates to [body], for the flaky-attempt test.
class _CountingExecutor implements AutomationExecutor {
  _CountingExecutor(this.body);

  final void Function(AutomationExecutionContext context) body;

  @override
  Future<void> execute(AutomationExecutionContext context) async =>
      body(context);
}
