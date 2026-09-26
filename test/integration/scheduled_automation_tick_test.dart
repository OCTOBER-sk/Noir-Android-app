// test/integration/scheduled_automation_tick_test.dart — the tick the app now
// runs, driving the real graph.
//
// test/integration/scheduled_automation_test.dart proves the subsystem is
// durable, gated and correct when something calls `runDueAutomations`. This file
// is about the thing that was missing: the caller. Before the tick existed the
// only caller in the repository was that test file, so a job a user created was
// listed in the Skill Manager and never fired.
//
// Every claim here is made through the real composition root — the real data
// layer over a real directory, the real `AutomationService`, the one
// `PolicyEngine`, the real A6 pipeline and the real dispatch — and the only
// thing injected is the ticker, because a test must not wait for wall-clock
// time to prove a cadence. Firing that ticker by hand is what a real timer does
// every thirty seconds; everything downstream of it is the shipped path.
//
// What is scripted, and only this: the platform channel, the passage of time
// (a job's own schedule answers that) and the cadence of the tick.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/automations/automations.dart';
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/platform/accessibility_status.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/ui/safety_center_screen.dart';

/// The channel the platform half of `NativeBridge` speaks on.
const MethodChannel _channel = MethodChannel(kNativeChannelName);

/// A ticker the test fires by hand, so no test waits for wall-clock time.
///
/// `cancelCount` is part of the contract under test: it is how "disposal cancels
/// the timer" is observed rather than assumed.
class _HandTicker implements AutomationTicker {
  void Function()? lastTick;
  int startCount = 0;
  int cancelCount = 0;

  @override
  void start(Duration every, void Function() tick) {
    startCount += 1;
    lastTick = tick;
  }

  @override
  void cancel() {
    cancelCount += 1;
    lastTick = null;
  }

  /// Fires the armed tick, as a real `Timer.periodic` would.
  void fire() => lastTick?.call();
}

/// A screen dump a real accessibility service would return.
List<Map<String, dynamic>> _dump() => <Map<String, dynamic>>[
  <String, dynamic>{
    'text': 'Send message',
    'alpha': 1.0,
    'zOrder': 0,
    'visible': true,
    'screenBounds': <String, dynamic>{
      'left': 10,
      'top': 100,
      'right': 300,
      'bottom': 180,
    },
  },
];

/// The platform half of the bridge, under this test's control and nothing else's.
class _Platform {
  _Platform(this.messenger);

  final TestDefaultBinaryMessenger messenger;
  final List<MethodCall> received = <MethodCall>[];

  void install() {
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      received.add(call);
      switch (call.method) {
        case kMethodServiceStatus:
          return <String, dynamic>{
            kWireServiceConnected: true,
            kWireCanPerformGestures: true,
            kWireCanRetrieveWindowContent: true,
            kWireHasNodeDump: true,
            kWireLastNodeCount: _dump().length,
            kWireRuntimeSinkInstalled: true,
            kWireGateSource: kGateSource,
          };
        case kMethodGetNodes:
          return <String, dynamic>{
            'nodes': _dump(),
            'nodeCount': _dump().length,
          };
        case kMethodPolicyGate:
          return <String, dynamic>{'allowed': true, 'message': 'ok'};
        case kMethodDispatchGesture:
          return <String, dynamic>{'executed': true};
      }
      throw MissingPluginException(call.method);
    });
  }

  void remove() => messenger.setMockMethodCallHandler(_channel, null);

  List<MethodCall> get dispatches => received
      .where((MethodCall call) => call.method == kMethodDispatchGesture)
      .toList();
}

void main() {
  // The graph builds a NativeBridge, which registers a handler on a real
  // MethodChannel, so the binding has to exist before the first graph is opened.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late _Platform platform;
  late _HandTicker ticker;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('noir-tick-');
    ticker = _HandTicker();
    platform = _Platform(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger,
    );
    platform.install();
  });

  tearDown(() {
    platform.remove();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Opens the graph the way the app opens one, with a hand-driven tick.
  Future<NoirComposition> open({
    List<Directory>? root,
    Duration consentTimeout = kDefaultConsentTimeout,
  }) => NoirComposition.open(
    dataRootCandidates: root ?? <Directory>[workspace],
    consentTimeout: consentTimeout,
    automationTicker: ticker,
  );

  /// A job that is already due, created the way a user creates one.
  ///
  /// [firstRunAt] is in the past on purpose: that is what makes the first
  /// occurrence due now, so the test does not have to move a clock the
  /// composition root owns.
  Future<Automation> scheduleDue(
    AutomationService service, {
    required String id,
    String name = 'Morning digest',
    String action = 'read_screen|Send message',
    Duration every = const Duration(hours: 1),
    String userId = 'u-1',
  }) => service.create(
    id: id,
    name: name,
    action: action,
    schedule: AutomationSchedule.interval(every: every),
    intent: UserIntent(userId: userId, requestedAt: DateTime.now().toUtc()),
    firstRunAt: DateTime.now().toUtc().subtract(every * 2),
  );

  /// A job that is not due yet: the whole point of the negative case.
  Future<Automation> scheduleLater(
    AutomationService service, {
    required String id,
    String name = 'Evening digest',
  }) => service.create(
    id: id,
    name: name,
    action: 'read_screen|Send message',
    schedule: AutomationSchedule.interval(every: const Duration(hours: 1)),
    intent: UserIntent(userId: 'u-1', requestedAt: DateTime.now().toUtc()),
    firstRunAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
  );

  group('the tick the app runs is a real dispatch', () {
    test('a due job is offered, waits for a human, and runs once', () async {
      final NoirComposition app = await open();
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleDue(wired.service, id: 'morning');
      addTearDown(app.dispose);

      // Both answers are taken before the tick fires, so neither is missed.
      final Future<AutomationPass> pass = app.automationScheduler.passes.first;
      final Future<PendingConfirmation> ask = app.confirmations.first;
      app.startAutomationScheduler();

      // The tick goes through the graph's own seam, so the request it publishes
      // is the one a manual run would publish, on the stream the Operations
      // Sheet answers.
      final PendingConfirmation confirmation = await ask;
      expect(confirmation.action, 'read_screen');
      expect(confirmation.canBeApproved, isTrue);
      confirmation.answer(true);

      final AutomationPass pass0 = await pass;
      expect(
        (pass0 as AutomationPassCompleted).runCount,
        1,
        reason: 'the tick really dispatched, it did not merely look',
      );

      final List<MethodCall> dispatches = platform.dispatches;
      expect(dispatches, hasLength(1));
      final Map<Object?, Object?> payload =
          dispatches.single.arguments as Map<Object?, Object?>;
      expect(
        (payload['proposal']! as Map<Object?, Object?>)['input'],
        'Send message',
        reason: 'the same request a manual run of the same action would carry',
      );

      // And the run is durable bookkeeping, not a line in a log the process is
      // about to lose.
      final Automation stored = (await wired.service.find('morning'))!;
      expect(stored.runCount, 1);
      expect(stored.lastRunAt, isNotNull);
      expect(stored.lastError, isNull);
      expect(stored.claimedAt, isNull, reason: 'the claim was released');
    });

    test('a job that is not due is left completely alone', () async {
      final NoirComposition app = await open();
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleLater(wired.service, id: 'evening');
      addTearDown(app.dispose);

      final List<PendingConfirmation> asked = <PendingConfirmation>[];
      app.confirmations.listen(asked.add);

      final Future<AutomationPass> pass = app.automationScheduler.passes.first;
      app.startAutomationScheduler();
      final AutomationPass first = await pass;

      // "Nothing was due" is a real answer and is reported as one, with zero
      // runs — never as a failure and never as an absent scheduler.
      final AutomationPassCompleted completed =
          first as AutomationPassCompleted;
      expect(completed.runCount, 0);
      expect(completed.ranSomething, isFalse);
      expect(
        asked,
        isEmpty,
        reason: 'a job that is not due never asks a human',
      );
      expect(platform.dispatches, isEmpty);

      final Automation stored = (await wired.service.find('evening'))!;
      expect(stored.runCount, 0);
      expect(stored.lastRunAt, isNull);
      expect(
        stored.lastError,
        isNull,
        reason: 'a job nobody ran has no error to report',
      );
    });

    test('the tick can do no more than a foreground tap can', () async {
      final NoirComposition app = await open();
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleDue(wired.service, id: 'morning');
      addTearDown(app.dispose);

      // The same switch the Safety Center throws, on the engine the platform
      // calls back into.
      app.policy.uiLock = true;

      final Future<AutomationPass> pass = app.automationScheduler.passes.first;
      app.startAutomationScheduler();
      final AutomationPass answer = await pass;

      // The pass ran and produced a run; the run was denied before the executor,
      // and that is recorded rather than reported as work that happened.
      expect((answer as AutomationPassCompleted).runCount, 1);
      expect(platform.dispatches, isEmpty);
      final Automation stored = (await wired.service.find('morning'))!;
      expect(stored.runCount, 0);
      expect(stored.lastError, contains('POLICY_DENIED'));
    });

    test('one tick at a time, however slow the job behind it is', () async {
      // Short enough that an unanswered confirmation expires inside the test,
      // so the pass really finishes rather than hanging the suite.
      final NoirComposition app = await open(
        consentTimeout: const Duration(milliseconds: 150),
      );
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleDue(wired.service, id: 'morning');
      addTearDown(app.dispose);

      final List<AutomationPass> passes = <AutomationPass>[];
      app.automationScheduler.passes.listen(passes.add);

      app.startAutomationScheduler();
      // The pass is inside the consent gate and has not answered yet.
      expect(app.automationScheduler.isPassing, isTrue);

      // The next tick lands while the first is still running.
      ticker.fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        passes.whereType<AutomationPassSkipped>().single.reason,
        AutomationSkipReason.inFlight,
        reason: 'a slow pass is not stacked, it is reported',
      );
      expect(app.automationScheduler.skippedPasses, 1);
      expect(platform.dispatches, isEmpty, reason: 'nobody confirmed anything');
    });
  });

  group('a tick that cannot work is reported', () {
    test(
      'a graph with no place to keep a job says so, not "nothing was due"',
      () async {
        // A path that cannot be created: a file where a directory has to be.
        final File blocker = File('${workspace.path}/blocker')
          ..writeAsStringSync('not a directory');
        final NoirComposition app = await open(
          root: <Directory>[Directory(blocker.path)],
        );
        addTearDown(app.dispose);

        expect(app.automations, isA<AutomationsUnavailable>());

        final Future<AutomationPass> pass =
            app.automationScheduler.passes.first;
        app.startAutomationScheduler();
        final AutomationPass answer = await pass;

        // The tick ran, and what it has to say is that there was no scheduler to
        // run — a different fact from a pass that found nothing due, and one the
        // caller can tell apart because the types differ.
        expect(
          (answer as AutomationPassUnavailable).reason,
          contains('durable'),
        );
        expect(app.automationScheduler.passesRun, 1);
      },
    );

    test(
      'the reason a tick could not run reaches the graph\'s safety log',
      () async {
        final File blocker = File('${workspace.path}/blocker')
          ..writeAsStringSync('not a directory');
        final NoirComposition app = await open(
          root: <Directory>[Directory(blocker.path)],
        );
        addTearDown(app.dispose);

        // Subscribed before the tick runs, so the record cannot be missed.
        final Future<SafetyEventAvailable> reported = app
            .safetyEvents()
            .where((SafetyEventState state) => state is SafetyEventAvailable)
            .cast<SafetyEventAvailable>()
            .firstWhere(
              (SafetyEventAvailable events) => events.events.any(
                (SafetyEvent event) =>
                    event.detail != null && event.detail!.contains('durable'),
              ),
            );
        app.startAutomationScheduler();
        final SafetyEventAvailable log = await reported;

        // A tick that could not do its work leaves a record with the real reason,
        // rather than a swallowed exception or a reassuring line.
        expect(log.events.last.summary, contains('scheduled'));
        expect(log.events.last.outcome, SafetyEventOutcome.blocked);
        expect(
          app.startup.isReady,
          isFalse,
          reason: 'persistence is the fault',
        );
      },
    );
  });

  group('the tick belongs to the graph\'s lifetime', () {
    test(
      'closing the graph disarms the tick and refuses a held callback',
      () async {
        final NoirComposition app = await open();
        final AutomationsWired wired = app.automations as AutomationsWired;
        await scheduleDue(wired.service, id: 'morning');
        // The lock keeps the pass off a human's answer, so the test is about the
        // tick's lifetime and not about the consent gate's timeout.
        app.policy.uiLock = true;

        final Future<AutomationPass> pass =
            app.automationScheduler.passes.first;
        app.startAutomationScheduler();
        expect((await pass as AutomationPassCompleted).runCount, 1);
        // The handle a real periodic timer would still be holding.
        final void Function() held = ticker.lastTick!;
        expect(ticker.startCount, 1);

        await app.dispose();

        expect(
          ticker.cancelCount,
          1,
          reason: 'disposal leaves no timer behind',
        );
        expect(app.automationScheduler.isRunning, isFalse);
        expect(app.automationScheduler.isDisposed, isTrue);

        // A callback that outlived the graph offers work to a closed one, and the
        // graph answers with the same typed absence any caller would get.
        held();
        expect(
          await app.runDueAutomations(),
          isA<AutomationDispatchUnavailable>(),
        );
        final Automation stored = (await wired.service.find('morning'))!;
        expect(
          stored.lastError,
          contains('POLICY_DENIED'),
          reason:
              'exactly the one run the tick made before disposal, and no more',
        );
      },
    );
  });
}
