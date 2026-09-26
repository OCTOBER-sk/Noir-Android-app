// lib/automations/automation_scheduler.dart
// The tick that dispatches due automations.
//
// This file is the caller that did not exist. `AutomationService` was durable,
// gated, cancellable and correct, and the composition root exposed
// `runDueAutomations` for whoever wanted to ask "what is due?" — and the only
// caller in the whole repository was a test. A user could create a scheduled
// job, see it listed in the Skill Manager, close the app and come back, and it
// would never fire: implemented, covered, and unreachable from the app.
//
// What it is: a repeating tick over one seam, [AutomationDueRunner]. The tick
// calls the seam, reports what came back, and never calls it twice at once.
//
// What it is not, and will not pretend to be:
//
//   * It is not a platform alarm. This build has no `AlarmManager`, no
//     `WorkManager` and no background service, so there is genuinely nothing
//     that runs while the process is dead. A job that comes due while the app is
//     closed runs when the app next comes up — which is why the first pass
//     happens the moment the tick is armed rather than an interval later — and
//     not at the instant it was due. The caller owns that promise: the app arms
//     the tick while it is in front of the user and disarms it otherwise.
//   * It does not gate anything. It calls whatever seam it is given, and the
//     composition root's seam is `runDueAutomations` — the same
//     `PolicyEngineAutomationGate`, the same `ConsentGatedAutomationExecutor` and
//     therefore the same human confirmation a manual run needs. There is no
//     second, cheaper path through here.
//   * It does not claim work happened. Every outcome is a typed [AutomationPass],
//     so "nothing was due", "there is no scheduler to run with", "the tick was
//     refused" and "the pass threw" stay four different facts, and none of them
//     can be read as a pass that ran fine.

import 'dart:async';

import '../core/clock.dart';
import 'automation_models.dart';

/// How often the tick looks for work while it is armed.
///
/// Thirty seconds is a foreground-only cadence, chosen because a pass that finds
/// nothing is cheap — it reads the durable job records and returns — while a
/// pass that finds something waits on a human anyway, so a shorter interval
/// would buy almost nothing and cost a directory listing a minute apart forever.
const Duration kDefaultAutomationTickInterval = Duration(seconds: 30);

/// Creates the repeating tick.
///
/// Injected for two reasons, both about honesty rather than convenience: a test
/// can fire a tick by hand instead of waiting for wall-clock time, and the
/// scheduler can be *seen* to cancel what it armed.
abstract interface class AutomationTicker {
  /// Arms a repeating [tick] and returns. A [start] on an already-armed ticker
  /// replaces the previous one.
  void start(Duration every, void Function() tick);

  /// Stops it. A callback held from before the cancel must do nothing, which is
  /// what a cancelled `Timer.periodic` guarantees and what this scheduler also
  /// checks for itself rather than trusting.
  void cancel();
}

/// The shipped ticker: one real `Timer.periodic`.
///
/// One instance per scheduler, never shared: it holds the single timer it armed,
/// so two schedulers sharing one would cancel each other's tick.
class SystemAutomationTicker implements AutomationTicker {
  Timer? _timer;

  @override
  void start(Duration every, void Function() tick) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (Timer _) => tick());
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

/// The dispatch seam the tick calls: offer whatever is due, and answer with the
/// typed outcome.
///
/// Typed in this library rather than as the composition root's own dispatch type
/// so that `lib/automations` does not have to import the composition root, and
/// so the tick can be exercised without building a graph. The root adapts its
/// dispatch into an [AutomationPass] and hands that over; there is still only
/// one dispatch path in the app.
typedef AutomationDueRunner = Future<AutomationPass> Function();

/// One pass of the tick, and what came of it.
sealed class AutomationPass {
  const AutomationPass({required this.at});

  /// When the tick's clock read, so a caller can order passes without a
  /// wall-clock of its own.
  final DateTime at;

  @override
  String toString() => '$runtimeType at ${at.toUtc().toIso8601String()}';
}

/// The seam answered. [runCount] is how many runs the pass produced.
///
/// Zero is a real answer and not a failure: nothing was due. [ranSomething] is
/// there so a caller never has to infer it by hand.
final class AutomationPassCompleted extends AutomationPass {
  AutomationPassCompleted({required super.at, required this.runCount}) {
    if (runCount < 0) {
      throw const AutomationError(
        AutomationError.invalidRunCount,
        detail: 'a pass cannot have produced a negative number of runs',
      );
    }
  }

  /// The runs the pass produced, including the ones the gate denied or a user
  /// refused.
  final int runCount;

  /// Whether any work was actually offered to the gate.
  bool get ranSomething => runCount > 0;

  @override
  String toString() =>
      'AutomationPassCompleted($runCount run(s) at '
      '${at.toUtc().toIso8601String()})';
}

/// The pass could not be performed because there is no scheduler to run with —
/// no durable records, or a graph that is closed.
///
/// Not a pass with zero runs: the difference between "there was nothing to do"
/// and "there is nothing to run with" is the difference between a job the user
/// wrote and a subsystem that is not there, and only one of them is the user's
/// business.
final class AutomationPassUnavailable extends AutomationPass {
  AutomationPassUnavailable({required super.at, required this.reason});

  /// The real reason, in the words the graph used.
  final String reason;

  @override
  String toString() =>
      'AutomationPassUnavailable($reason at ${at.toUtc().toIso8601String()})';
}

/// Why a tick did not become a pass.
enum AutomationSkipReason {
  /// A pass was still running. A slow pass is never stacked: the tick is skipped
  /// and reported, and the next one runs normally.
  inFlight,

  /// The scheduler has been disposed and will never run again, so a start that
  /// asked for a pass is refused rather than answered with one.
  disposed,
}

/// The tick did not become a pass, and why not.
final class AutomationPassSkipped extends AutomationPass {
  AutomationPassSkipped({required super.at, required this.reason});

  /// Why the tick did not become a pass.
  final AutomationSkipReason reason;

  @override
  String toString() =>
      'AutomationPassSkipped(${reason.name} at '
      '${at.toUtc().toIso8601String()})';
}

/// The pass threw. The real error is carried, never replaced with "the tick
/// failed", and a thrown pass does not stop the next one: this build would
/// rather keep offering jobs and say each time that it could not.
final class AutomationPassFailed extends AutomationPass {
  AutomationPassFailed({required super.at, required this.reason, this.cause});

  /// The error, in the words it reported itself with.
  final String reason;

  /// The error itself, for a caller that wants to branch on its type.
  final Object? cause;

  @override
  String toString() =>
      'AutomationPassFailed($reason at ${at.toUtc().toIso8601String()})';
}

/// Drives due automations from a running app.
///
/// The lifecycle it guarantees, and the limits of that guarantee:
///
///   * [start] arms the tick and runs one pass at once, so work that came due
///     while the app was not in front is offered the moment it is.
///   * Ticks never overlap. A tick that arrives while a pass is in flight is
///     reported as [AutomationPassSkipped] with [AutomationSkipReason.inFlight]
///     and nothing is queued, because a queue would be a second scheduler with
///     none of the bound the service puts on a single pass.
///   * [stop] cancels the timer and the scheduler stops acting, including on a
///     callback it kept from before. A pass already in flight is not cancelled:
///     it may be waiting on a human, and a withdrawn consent gate is not a
///     decision.
///   * [dispose] is the end. The timer is cancelled, every later tick and every
///     later [start] is refused, and [passes] is closed.
///
/// What it cannot do, because this build has no platform alarm: run anything
/// while the app is not in front. [start] and [stop] are the whole of the
/// foreground promise, and the caller that owns them is the app.
class AutomationScheduler {
  /// [due] is called once per pass and answers with the typed outcome.
  /// [interval] must be positive. [ticker] exists so the cadence can be driven
  /// by hand; production passes nothing and gets [SystemAutomationTicker].
  AutomationScheduler({
    required AutomationDueRunner due,
    Duration interval = kDefaultAutomationTickInterval,
    Clock? clock,
    AutomationTicker? ticker,
  }) : _due = due,
       _interval = interval,
       _clock = clock ?? const SystemClock(),
       _ticker = ticker ?? SystemAutomationTicker() {
    if (interval <= Duration.zero) {
      throw const AutomationError(
        AutomationError.invalidInterval,
        detail: 'the tick interval must be strictly positive',
      );
    }
  }

  final AutomationDueRunner _due;
  final Duration _interval;
  final Clock _clock;
  final AutomationTicker _ticker;

  final StreamController<AutomationPass> _passes =
      StreamController<AutomationPass>.broadcast();

  AutomationPass? _lastPass;
  bool _armed = false;
  bool _inFlight = false;
  bool _disposed = false;
  int _passesRun = 0;
  int _skippedPasses = 0;

  /// How long between passes.
  Duration get interval => _interval;

  /// Whether the tick is armed. False before the first [start], after [stop] and
  /// after [dispose].
  bool get isRunning => _armed;

  /// Whether a pass is executing right now, which is also what makes a tick
  /// skip.
  bool get isPassing => _inFlight;

  /// Whether this scheduler has been disposed and will never run again.
  bool get isDisposed => _disposed;

  /// The most recent pass, whatever kind it was.
  ///
  /// Readable after [dispose] on purpose, so a refused [start] can still be
  /// inspected; [passes] is closed by then and delivers nothing further.
  AutomationPass? get lastPass => _lastPass;

  /// Passes that reached the seam, whether they completed or failed. A skipped
  /// tick is not one of them: it never asked.
  int get passesRun => _passesRun;

  /// Ticks that were refused because a pass was already running.
  int get skippedPasses => _skippedPasses;

  /// Every pass, in order, for a caller that wants to watch. Broadcast, and
  /// closed by [dispose].
  Stream<AutomationPass> get passes => _passes.stream;

  /// Arms the tick and offers whatever is already due.
  ///
  /// Idempotent while it is running: a second call neither stacks a second
  /// timer nor runs a second pass. After [dispose] it is refused, and the
  /// refusal is published — a caller that asked and got nothing back has to be
  /// able to tell that from a tick that found nothing due.
  void start() {
    if (_disposed) {
      _publish(
        AutomationPassSkipped(
          at: _clock.now(),
          reason: AutomationSkipReason.disposed,
        ),
      );
      return;
    }
    if (_armed) return;
    _armed = true;
    _ticker.start(_interval, _onTick);
    // At once, not after an interval: a job whose time came while the app was
    // not in front has been due for as long as it has been due, and the user is
    // looking at the app right now.
    unawaited(_run());
  }

  /// Cancels the timer and stops acting. A pass in flight is not cancelled: it
  /// may be waiting on a human, and withdrawing a consent gate is not a decision.
  /// It ends on its own terms, or with the graph it belongs to.
  void stop() {
    if (!_armed) return;
    _armed = false;
    _ticker.cancel();
  }

  /// Ends the tick for good: the timer is cancelled, no later tick or [start] is
  /// honoured, and [passes] is closed.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    // Closed without awaiting the done future, for the same reason the
    // composition root's controllers are: a broadcast controller that never had
    // a subscriber never completes `close()`, and awaiting it in teardown is how
    // a suite ends up with a wedged app.
    if (!_passes.isClosed) unawaited(_passes.close());
  }

  /// The tick's own callback. Guards on both the disposed flag and the armed
  /// flag, so a handle kept from before a [stop] or a [dispose] does nothing
  /// rather than trusting the platform timer to have been collected.
  void _onTick() {
    if (_disposed || !_armed) return;
    unawaited(_run());
  }

  Future<void> _run() async {
    if (_inFlight) {
      _skippedPasses += 1;
      _publish(
        AutomationPassSkipped(
          at: _clock.now(),
          reason: AutomationSkipReason.inFlight,
        ),
      );
      return;
    }
    _inFlight = true;
    try {
      final AutomationPass pass = await _due();
      _passesRun += 1;
      _publish(pass);
    } on Object catch (error) {
      // A thrown pass is a typed failure, not a swallowed exception and not a
      // pass that ran fine: the caller can see what happened and when.
      _passesRun += 1;
      _publish(
        AutomationPassFailed(at: _clock.now(), reason: '$error', cause: error),
      );
    } finally {
      _inFlight = false;
    }
  }

  void _publish(AutomationPass pass) {
    _lastPass = pass;
    if (_passes.isClosed) return;
    _passes.add(pass);
  }
}
