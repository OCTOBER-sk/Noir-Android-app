// test/automations/automation_scheduler_test.dart — the tick that dispatches due
// automations, on its own.
//
// This is the file that would have caught the real defect. A scheduled job was
// durable, gated, listed in the Skill Manager and never fired, because nothing
// in the app ever asked "what is due?" — the tick did not exist, so the
// dispatch seam had no caller outside the tests that called it directly.
//
// Everything the shipped app now relies on is asserted here without a graph:
// the tick calls the seam, the first pass happens as soon as the tick is armed,
// a slow pass is never stacked by the next tick, a stopped or disposed
// scheduler is never re-entered, and a pass that throws is reported as a
// failure rather than counted as one that ran fine.
//
// No test here waits for wall-clock time. The ticker is a stub the test fires by
// hand and the clock is a `FakeClock`, so "the next tick" is a line in the test
// and the assertions are about the contract, not about scheduling luck.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/automations/automations.dart';
import 'package:noir_android_app/core/clock.dart';

/// A ticker the test fires by hand, so no test waits for wall-clock time.
///
/// [startCount] and [cancelCount] are the evidence for "the scheduler armed one
/// timer and cancelled it": a stub that ignored [cancel] would let the overlap
/// and the dispose tests pass for the wrong reason. The callback is also
/// readable *after* a cancel, so a test can hold the handle the way a platform
/// timer would and prove the scheduler itself refuses to act on it.
class _StubTicker implements AutomationTicker {
  Duration? every;
  void Function()? lastTick;
  int startCount = 0;
  int cancelCount = 0;

  @override
  void start(Duration every, void Function() tick) {
    startCount += 1;
    this.every = every;
    lastTick = tick;
  }

  @override
  void cancel() {
    cancelCount += 1;
    lastTick = null;
  }

  /// Fires the armed tick. Does nothing once cancelled, which is what a real
  /// cancelled `Timer.periodic` does.
  void fire() => lastTick?.call();
}

/// The dispatch seam, under the test's control and nothing else's.
///
/// It is a function that records its calls and answers with whatever the test
/// told it to, which is the whole contract the tick has: call this, report what
/// came back, never call it twice at once.
class _StubDueRunner {
  /// How many times the tick asked for due work.
  int calls = 0;

  /// When set, a pass waits on this before answering.
  Completer<void>? hold;

  /// When set, a pass throws this instead of answering.
  Object? failure;

  /// The answer for a pass that is neither held nor failing.
  AutomationPass Function(DateTime at)? answer;

  Future<AutomationPass> call() async {
    calls += 1;
    final Completer<void>? wait = hold;
    if (wait != null) await wait.future;
    final Object? error = failure;
    if (error != null) throw error;
    return answer?.call(DateTime.utc(2026, 5, 1, 9)) ??
        AutomationPassCompleted(at: DateTime.utc(2026, 5, 1, 9), runCount: 0);
  }
}

void main() {
  final DateTime start = DateTime.utc(2026, 5, 1, 9);

  late FakeClock clock;
  late _StubTicker ticker;
  late _StubDueRunner due;
  late List<AutomationPass> published;

  setUp(() {
    clock = FakeClock(start);
    ticker = _StubTicker();
    due = _StubDueRunner();
    published = <AutomationPass>[];
  });

  AutomationScheduler build() {
    final AutomationScheduler scheduler = AutomationScheduler(
      due: due.call,
      clock: clock,
      ticker: ticker,
    );
    addTearDown(scheduler.dispose);
    // Listening from the start, so a pass published while a later line of the
    // test runs is never missed.
    scheduler.passes.listen(published.add);
    return scheduler;
  }

  /// The next pass the scheduler publishes.
  Future<AutomationPass> nextPass(AutomationScheduler scheduler) =>
      scheduler.passes.first;

  group('the tick calls the dispatch seam', () {
    test(
      'one pass happens as soon as it is armed, and one per tick after',
      () async {
        final AutomationScheduler scheduler = build();

        final Future<AutomationPass> first = nextPass(scheduler);
        scheduler.start();

        expect(
          ticker.startCount,
          1,
          reason: 'arming is the whole of what start() does',
        );
        expect(ticker.every, kDefaultAutomationTickInterval);
        // Not a whole interval later: a job that came due while the app was not in
        // front is offered as soon as the app is.
        final AutomationPass opened = await first;
        expect(opened, isA<AutomationPassCompleted>());
        expect(due.calls, 1);

        final Future<AutomationPass> second = nextPass(scheduler);
        ticker.fire();
        expect(await second, isA<AutomationPassCompleted>());
        expect(due.calls, 2);
      },
    );

    test('a second start does not stack a second timer', () async {
      final AutomationScheduler scheduler = build();

      final Future<AutomationPass> first = nextPass(scheduler);
      scheduler.start();
      await first;
      scheduler.start();
      scheduler.start();

      expect(
        ticker.startCount,
        1,
        reason: 'one timer, however often it is asked',
      );
      expect(scheduler.isRunning, isTrue);
    });

    test('an interval that is not positive is refused rather than spun', () {
      expect(
        () => AutomationScheduler(
          due: due.call,
          interval: Duration.zero,
          clock: clock,
          ticker: ticker,
        ),
        throwsA(
          isA<AutomationError>().having(
            (AutomationError error) => error.code,
            'code',
            AutomationError.invalidInterval,
          ),
        ),
      );
    });
  });

  group('a slow pass is never stacked', () {
    test(
      'a tick that arrives mid-pass is reported as skipped, not queued',
      () async {
        final Completer<void> hold = Completer<void>();
        due.hold = hold;
        final AutomationScheduler scheduler = build();

        scheduler.start();
        // The pass is inside the seam and has not answered yet.
        await Future<void>.delayed(Duration.zero);
        expect(due.calls, 1);

        ticker.fire();
        ticker.fire();
        await Future<void>.delayed(Duration.zero);

        expect(
          due.calls,
          1,
          reason: 'a tick that lands mid-pass must not start a second one',
        );
        expect(scheduler.skippedPasses, 2);
        expect(
          published.whereType<AutomationPassSkipped>().map(
            (AutomationPassSkipped pass) => pass.reason,
          ),
          everyElement(AutomationSkipReason.inFlight),
        );
        expect(scheduler.lastPass, isA<AutomationPassSkipped>());

        // And the pass that was already running is not disturbed by the skips: it
        // still publishes its own answer when it finishes.
        hold.complete();
        final AutomationPass completed = await scheduler.passes.firstWhere(
          (AutomationPass pass) => pass is AutomationPassCompleted,
        );
        expect(completed, isA<AutomationPassCompleted>());
        expect(scheduler.isPassing, isFalse);
      },
    );

    test('the next tick after a slow pass runs normally', () async {
      final Completer<void> hold = Completer<void>();
      due.hold = hold;
      final AutomationScheduler scheduler = build();

      final Future<AutomationPass> opening = nextPass(scheduler);
      scheduler.start();
      await Future<void>.delayed(Duration.zero);
      ticker.fire();
      await Future<void>.delayed(Duration.zero);
      hold.complete();
      await opening;

      due.hold = null;
      final Future<AutomationPass> after = nextPass(scheduler);
      ticker.fire();

      expect(await after, isA<AutomationPassCompleted>());
      expect(
        due.calls,
        2,
        reason: 'skipping a tick is not the same as giving up',
      );
    });
  });

  group('a stopped tick is stopped', () {
    test(
      'stopping cancels the timer, and a held callback does nothing',
      () async {
        final AutomationScheduler scheduler = build();
        final Future<AutomationPass> first = nextPass(scheduler);
        scheduler.start();
        await first;

        // The handle a platform timer would still be holding.
        final void Function() held = ticker.lastTick!;
        scheduler.stop();

        expect(ticker.cancelCount, 1, reason: 'the timer is really cancelled');
        expect(scheduler.isRunning, isFalse);
        expect(scheduler.isPassing, isFalse);

        held();
        await Future<void>.delayed(Duration.zero);
        expect(
          due.calls,
          1,
          reason: 'a stopped scheduler is not re-entered by a callback it kept',
        );
      },
    );

    test(
      'stopping twice, or stopping something never started, is harmless',
      () {
        final AutomationScheduler scheduler = build();

        scheduler.stop();
        expect(scheduler.isRunning, isFalse);
        expect(ticker.cancelCount, 0, reason: 'there was no timer to cancel');

        scheduler.start();
        scheduler.stop();
        scheduler.stop();
        expect(ticker.cancelCount, 1);
      },
    );
  });

  group('a disposed tick is never re-entered', () {
    test('dispose cancels the timer and refuses a held callback', () async {
      final AutomationScheduler scheduler = build();
      final Future<AutomationPass> first = nextPass(scheduler);
      scheduler.start();
      await first;
      final void Function() held = ticker.lastTick!;

      await scheduler.dispose();

      expect(scheduler.isDisposed, isTrue);
      expect(scheduler.isRunning, isFalse);
      expect(
        ticker.cancelCount,
        1,
        reason: 'a disposed scheduler leaves no timer behind',
      );

      held();
      await Future<void>.delayed(Duration.zero);
      expect(
        due.calls,
        1,
        reason: 'disposal ends the tick, not just the timer handle',
      );
    });

    test('starting again after disposal is refused, and reported', () async {
      final AutomationScheduler scheduler = build();
      final Future<AutomationPass> first = nextPass(scheduler);
      scheduler.start();
      await first;
      await scheduler.dispose();

      scheduler.start();

      expect(
        ticker.startCount,
        1,
        reason: 'a disposed scheduler arms no second timer',
      );
      expect(scheduler.isRunning, isFalse);
      // Refused, not ignored: a caller that asked and got nothing back has to be
      // able to tell that from a tick that found nothing due. The stream is closed
      // by now, so the state to read is the last one.
      expect(
        scheduler.lastPass,
        isA<AutomationPassSkipped>()
            .having(
              (AutomationPassSkipped pass) => pass.reason,
              'reason',
              AutomationSkipReason.disposed,
            )
            .having((AutomationPassSkipped pass) => pass.at, 'at', start),
      );
    });

    test(
      'the pass stream is closed, so nothing is published after disposal',
      () async {
        final AutomationScheduler scheduler = build();
        final Future<AutomationPass> first = nextPass(scheduler);
        scheduler.start();
        await first;
        await scheduler.dispose();

        expect(
          await scheduler.passes.isEmpty,
          isTrue,
          reason: 'a closed broadcast stream ends for everyone listening',
        );
      },
    );
  });

  group('a pass that did not do its work says so', () {
    test('a pass that throws is a failure, not one that ran fine', () async {
      due.failure = StateError('the record store is gone');
      final AutomationScheduler scheduler = build();

      final Future<AutomationPass> first = nextPass(scheduler);
      scheduler.start();
      final AutomationPass failed = await first;

      expect(failed, isA<AutomationPassFailed>());
      final AutomationPassFailed failure = failed as AutomationPassFailed;
      expect(failure.reason, contains('the record store is gone'));
      expect(failure.cause, isA<StateError>());
      expect(failure.at, start, reason: 'stamped by the injected clock');
      expect(scheduler.passesRun, 1);
      expect(scheduler.lastPass, same(failed));
    });

    test('a failed pass does not stop the next one', () async {
      due.failure = StateError('the record store is gone');
      final AutomationScheduler scheduler = build();

      final Future<AutomationPass> first = nextPass(scheduler);
      scheduler.start();
      await first;

      due.failure = null;
      final Future<AutomationPass> second = nextPass(scheduler);
      ticker.fire();

      expect(await second, isA<AutomationPassCompleted>());
      expect(due.calls, 2, reason: 'one bad pass is not a dead scheduler');
    });

    test('an unavailable answer is not reported as a pass that ran', () async {
      due.answer = (DateTime at) => AutomationPassUnavailable(
        at: at,
        reason: 'A scheduled job needs somewhere durable to live.',
      );
      final AutomationScheduler scheduler = build();

      final Future<AutomationPass> first = nextPass(scheduler);
      scheduler.start();
      final AutomationPass pass = await first;

      expect(pass, isA<AutomationPassUnavailable>());
      expect((pass as AutomationPassUnavailable).reason, contains('durable'));
    });
  });

  group('a pass with nothing due is its own fact', () {
    test('zero runs is not a failure, and not an absent scheduler', () async {
      final AutomationScheduler scheduler = build();

      final Future<AutomationPass> first = nextPass(scheduler);
      scheduler.start();
      final AutomationPass pass = await first;

      final AutomationPassCompleted completed = pass as AutomationPassCompleted;
      expect(completed.runCount, 0);
      expect(completed.ranSomething, isFalse);
      // The three outcomes are separate types, so a caller cannot read "nothing
      // was due" as "there was no scheduler" or as "the pass failed".
      expect(pass, isNot(isA<AutomationPassUnavailable>()));
      expect(pass, isNot(isA<AutomationPassFailed>()));
      expect(pass, isNot(isA<AutomationPassSkipped>()));
    });
  });
}
