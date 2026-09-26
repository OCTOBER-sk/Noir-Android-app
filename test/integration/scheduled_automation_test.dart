// test/integration/scheduled_automation_test.dart — the scheduled automation
// subsystem as the shipped app runs it.
//
// The bug this file exists to prevent is the one test/composition_reachability_
// test.dart is about, one level down: a subsystem that the app *can* name but
// cannot *use*. So every claim here is made through the real composition root —
// the real data layer over a real directory, the real `AutomationService`, the
// one `PolicyEngine`, the real A6 pipeline and the real dispatch — and the
// assertions are the ones a plausible-looking stub would fail:
//
//   1. The graph holds a real service over durable records, and it is the *same*
//      gate and executor the graph reports, not copies of them.
//   2. A job a user asked for is on disk, and is still there after the graph is
//      closed and a new one is opened over the same directory.
//   3. A due job is offered to the policy gate: the UI lock and the biometric
//      rule stop it before anything runs, exactly as they stop a manual run.
//   4. A job the user confirms reaches the platform once and only once, and the
//      run is written back to the durable record.
//   5. A job nobody confirms never reaches the platform, and its failure is
//      recorded rather than reported as a success.
//   6. With nowhere to store a job the app says the subsystem is unavailable —
//      a typed state and a named startup fault, not a silent absence.
//
// What is scripted, and only this: the platform channel, which a connected
// accessibility service would answer, and the passage of time, which a job's own
// schedule answers. The dispatch that follows is the real `NativeBridge` call
// the platform would receive.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/automations/automations.dart';
import 'package:noir_android_app/core/automation_wiring.dart';
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/data/data.dart';
import 'package:noir_android_app/platform/accessibility_status.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/ui/skill_manager_screen.dart';

/// The channel the platform half of `NativeBridge` speaks on.
const MethodChannel _channel = MethodChannel(kNativeChannelName);

/// A screen dump a real accessibility service would return: one node with text
/// and real bounds, and one that is invisible, so the executor has something
/// real to aim at and something real to refuse.
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
  <String, dynamic>{
    'text': 'invisible instruction',
    'alpha': 0.0,
    'zOrder': 0,
    'visible': true,
    'screenBounds': <String, dynamic>{
      'left': 0,
      'top': 0,
      'right': 0,
      'bottom': 0,
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

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('noir-scheduled-');
    platform = _Platform(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger,
    );
    platform.install();
  });

  tearDown(() {
    platform.remove();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Opens the graph the way the app opens one: over a real directory.
  Future<NoirComposition> open({
    Duration consentTimeout = kDefaultConsentTimeout,
  }) {
    return NoirComposition.open(
      dataRootCandidates: <Directory>[workspace],
      consentTimeout: consentTimeout,
    );
  }

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

  group('the graph holds a real scheduler over durable records', () {
    test('the service, the gate and the executor are the shipped ones', () async {
      final NoirComposition app = await open();
      addTearDown(app.dispose);

      final AutomationsWired wired = app.automations as AutomationsWired;
      expect(wired.service, isA<AutomationService>());
      // One gate and one executor in the graph, not a copy of each.
      expect(wired.service.gate, same(wired.gate));
      expect(wired.service.executor, same(wired.executor));
      expect(wired.gate, isA<PolicyEngineAutomationGate>());
      expect(wired.executor, isA<ConsentGatedAutomationExecutor>());
      // And the repository is the data layer's own, on the durable store.
      expect(
        wired.repository,
        same((app.data as DataOpened).layer.automations),
      );
      expect(wired.repository.isDurable, isTrue);
      expect(wired.service.repository, same(wired.repository));

      // Not a stub in the sense that matters: the gate is backed by this graph's
      // single PolicyEngine, so a lock the UI sets is a lock the scheduler sees.
      app.policy.uiLock = true;
      final PolicyGateDecision decision = await wired.gate.evaluate(
        await wired.service.create(
          id: 'gated',
          name: 'Gated',
          action: 'read_screen|Send message',
          schedule: AutomationSchedule.once(
            DateTime.now().toUtc().add(const Duration(hours: 1)),
          ),
          intent: UserIntent(
            userId: 'u-1',
            requestedAt: DateTime.now().toUtc(),
          ),
        ),
      );
      expect(decision.approved, isFalse);
      expect(decision.reason, contains('UI_LOCK'));
    });

    test('startup records the subsystem as one of the steps it took', () async {
      final NoirComposition app = await open();
      addTearDown(app.dispose);

      final StartupStep step = app.startupSteps.firstWhere(
        (StartupStep step) => step.subsystem == kAutomationsStartupSubsystem,
      );
      expect(step.ok, isTrue);
      expect(
        step.detail,
        contains(NoirCollections.automations),
        reason: 'the step says where the records are',
      );
      // A step that is ok is not a fault, so the readiness claim is unaffected.
      expect(app.startup.isReady, isTrue);
      expect(app.isReady, isTrue);
    });
  });

  group('a scheduled job is persisted', () {
    test('is on disk, and is there again after the graph is reopened', () async {
      final NoirComposition first = await open();
      final AutomationsWired wired = first.automations as AutomationsWired;

      final Automation created = await scheduleDue(
        wired.service,
        id: 'morning',
        name: 'Morning digest',
      );
      expect(created.revision, 1);
      expect(created.nextRunAt!.isBefore(DateTime.now().toUtc()), isTrue);

      // The record is a file in the collection the catalog declares, not a row in
      // a map that dies with the process.
      final DataOpened data = first.data as DataOpened;
      final File record = File(
        '${data.root.path}/${NoirCollections.automations}/morning.json',
      );
      expect(record.existsSync(), isTrue);
      expect(record.readAsStringSync(), contains('read_screen|Send message'));

      final List<AutomationRevision> history = await wired.service.history(
        'morning',
      );
      expect(history, hasLength(1));
      expect(history.single.change, AutomationChange.created);
      await first.dispose();

      // A brand new graph over the same directory: nothing carried over in
      // memory, so the job can only have come off disk.
      final NoirComposition second = await open();
      addTearDown(second.dispose);
      final AutomationsWired reopened = second.automations as AutomationsWired;
      expect(
        reopened.service.repository,
        isNot(same(wired.service.repository)),
      );

      final Automation restored = (await reopened.service.find('morning'))!;
      expect(restored.name, 'Morning digest');
      expect(restored.action, 'read_screen|Send message');
      expect(
        restored.schedule,
        AutomationSchedule.interval(every: const Duration(hours: 1)),
      );
      expect(restored.createdBy.userId, 'u-1');
      expect(restored.nextRunAt, created.nextRunAt);
      expect(await reopened.service.history('morning'), hasLength(1));
      expect(await second.scheduledAutomations(), hasLength(1));
    });

    test('is listed by the app\'s own skills stream', () async {
      final NoirComposition app = await open();
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleDue(wired.service, id: 'morning');

      final SkillListAvailable available =
          await app.skills().firstWhere(
                (SkillListState state) => state is SkillListAvailable,
              )
              as SkillListAvailable;
      expect(
        available.records.map((SkillRecord record) => record.id),
        contains('morning'),
      );
      addTearDown(app.dispose);
    });
  });

  group('a due job is still behind the policy gate', () {
    test('the UI lock stops it before anything runs', () async {
      final NoirComposition app = await open();
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleDue(wired.service, id: 'morning');
      addTearDown(app.dispose);

      // The same switch the Safety Center throws, on the engine the platform
      // calls back into.
      app.policy.uiLock = true;

      final AutomationDispatched dispatched =
          await app.runDueAutomations() as AutomationDispatched;

      expect(dispatched.runs, hasLength(1));
      final AutomationRun run = dispatched.runs.single;
      expect(run.outcome, AutomationOutcome.denied);
      expect(run.attempts, 0, reason: 'the executor was never called');
      expect(run.error, contains('UI_LOCK'));
      expect(platform.dispatches, isEmpty);
      // Nobody was asked to confirm: the gate stopped it before the pipeline.
      // And a denial is not a run, so the job's counters did not move.
      final Automation stored = (await wired.service.find('morning'))!;
      expect(stored.runCount, 0);
      expect(stored.lastRunAt, isNull);
      expect(stored.lastError, contains('POLICY_DENIED'));
    });

    test('a job the policy wants a biometric for cannot be approved', () async {
      final NoirComposition app = await open();
      final AutomationsWired wired = app.automations as AutomationsWired;
      // `delete` classifies as HIGH_RISK, so the PolicyEngine asks for a
      // biometric, and this build cannot perform one — the same rule a manual
      // run is refused under.
      await scheduleDue(
        wired.service,
        id: 'purge',
        name: 'Purge drafts',
        action: 'delete|Purge',
      );
      addTearDown(app.dispose);

      final AutomationDispatched dispatched =
          await app.runDueAutomations() as AutomationDispatched;

      expect(dispatched.runs.single.outcome, AutomationOutcome.denied);
      expect(dispatched.runs.single.error, contains('biometric'));
      expect(platform.dispatches, isEmpty);
      expect((await wired.service.find('purge'))!.lastError, isNotNull);
    });

    test(
      'an action Noir cannot read as a request is refused, not guessed',
      () async {
        final NoirComposition app = await open();
        final AutomationsWired wired = app.automations as AutomationsWired;
        await scheduleDue(
          wired.service,
          id: 'vague',
          action: 'do the thing I said earlier',
        );
        addTearDown(app.dispose);

        final PolicyGateDecision decision = await wired.gate.evaluate(
          (await wired.service.find('vague'))!,
        );
        expect(decision.approved, isFalse);
        expect(decision.reason, contains('not a request Noir can run'));

        final AutomationDispatched dispatched =
            await app.runDueAutomations() as AutomationDispatched;
        expect(dispatched.runs.single.outcome, AutomationOutcome.denied);
        expect(platform.dispatches, isEmpty);
      },
    );
  });

  group('a due job is still behind a human', () {
    test('a confirmed job reaches the platform once, and is recorded', () async {
      final NoirComposition app = await open();
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleDue(wired.service, id: 'morning');
      addTearDown(app.dispose);

      final Future<AutomationDispatch> dispatch = app.runDueAutomations();
      // The confirmation the scheduler's run published is the same object a
      // manual run publishes, on the same stream the Operations Sheet answers.
      final PendingConfirmation confirmation = await app.confirmations.first;
      expect(confirmation.action, 'read_screen');
      expect(confirmation.canBeApproved, isTrue);
      confirmation.answer(true);

      final AutomationDispatched dispatched =
          await dispatch as AutomationDispatched;
      expect(dispatched.runs.single.outcome, AutomationOutcome.succeeded);
      expect(dispatched.runs.single.attempts, 1);

      final List<MethodCall> dispatches = platform.dispatches;
      expect(dispatches, hasLength(1));
      final Map<Object?, Object?> payload =
          dispatches.single.arguments as Map<Object?, Object?>;
      expect(
        (payload['proposal']! as Map<Object?, Object?>)['action'],
        'read_screen',
        reason: 'the job asked for the same request a manual run would',
      );
      expect(
        (payload['proposal']! as Map<Object?, Object?>)['input'],
        'Send message',
      );
      expect(app.gate.approvedActions, isEmpty, reason: 'single use');

      // The run is bookkeeping the durable record keeps, not a line in a log the
      // process is about to lose.
      final Automation stored = (await wired.service.find('morning'))!;
      expect(stored.runCount, 1);
      expect(stored.lastRunAt, isNotNull);
      expect(stored.lastError, isNull);
      expect(stored.claimedAt, isNull, reason: 'the claim was released');
    });

    test('a job nobody answers never reaches the platform', () async {
      // Short enough that the unanswered request expires inside the test, so
      // this is the real "silence is not consent" path and not a hang.
      final NoirComposition app = await open(
        consentTimeout: const Duration(milliseconds: 150),
      );
      final AutomationsWired wired = app.automations as AutomationsWired;
      await scheduleDue(wired.service, id: 'morning');
      addTearDown(app.dispose);

      final Future<AutomationDispatch> dispatch = app.runDueAutomations();
      final PendingConfirmation confirmation = await app.confirmations.first;
      expect(confirmation.isAnswered, isFalse);

      final AutomationDispatched dispatched =
          await dispatch as AutomationDispatched;

      expect(dispatched.runs.single.outcome, AutomationOutcome.failed);
      expect(platform.dispatches, isEmpty);
      // The failure is recorded rather than reported as a success, and the job
      // is still due because nothing answered it.
      final Automation stored = (await wired.service.find('morning'))!;
      expect(stored.runCount, 0);
      expect(stored.lastError, isNotNull);
      expect(stored.isDueAt(DateTime.now().toUtc()), isTrue);
    });
  });

  group('no store means a stated absence, not a silent one', () {
    test('the app says the subsystem is unavailable and why', () async {
      // A path that cannot be created: a file where a directory has to be.
      final File blocker = File('${workspace.path}/blocker')
        ..writeAsStringSync('not a directory');
      final NoirComposition app = await NoirComposition.open(
        dataRootCandidates: <Directory>[Directory(blocker.path)],
      );
      addTearDown(app.dispose);

      expect(app.automations, isA<AutomationsUnavailable>());
      expect(
        (app.automations as AutomationsUnavailable).reason,
        contains('durable'),
      );
      // The startup record says so too, rather than printing a reassuring line.
      final StartupStep step = app.startupSteps.firstWhere(
        (StartupStep step) => step.subsystem == kAutomationsStartupSubsystem,
      );
      expect(step.ok, isFalse);
      expect(
        app.startup.faultLines.any(
          (String line) => line.startsWith(kAutomationsStartupSubsystem),
        ),
        isTrue,
      );
      // And no caller can mistake the absence for "nothing was due".
      final AutomationDispatch dispatch = await app.runDueAutomations();
      expect(dispatch, isA<AutomationDispatchUnavailable>());
      expect(await app.scheduledAutomations(), isEmpty);
    });
  });
}
