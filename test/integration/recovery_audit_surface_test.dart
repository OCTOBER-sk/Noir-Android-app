// test/integration/recovery_audit_surface_test.dart — the A4 audit record has to
// be readable by the user, not just held in a list, and it has to be a record a
// real run produced.
//
// The gap this file was about was not hypothetical. `SanitizingRecoveryEngine`
// built a real audit entry for every low-confidence reflection, appended it to
// its own `auditTrail`, and that list had no reader anywhere in `lib/`: a run
// that ended `RECOVERY_NEEDS_REVIEW` was a fact the graph knew and the user
// never saw. It is also a fact the graph's safety log could not show, because
// nothing was ever handed to that log either — and the Safety Center was built
// with no `log` at all, so it rendered "No safety log is connected." while the
// graph was recording decisions.
//
// On driving the run: this file used to call
// `app.recovery.executeReflectionRecovery(Reflection(confidence: 0.3), null)`
// by hand, because the A12 critic scored an execution with
// `executed.toString().contains('failed')` and the shipped executor always
// answers with a `NativeGestureOutcome`, which has the default `toString` — so
// `confidence < 0.5` could not be true on any real run and the audit trail only
// ever grew inside this file. 50767f2 made the critic read the outcome's own
// fields, and that hand-call is gone: every run below now goes through
// `runAutomation`, the one entry point to the pipeline, against a platform that
// dispatches a real gesture and then fails it. Nothing here constructs a
// `Reflection`, and nothing here names the recovery engine.
//
// One substitution beyond the platform, and it is the same one every other
// integration test in this tree makes: no human is present to answer a
// confirmation, so the test answers it the way the Command Centre does. The
// run is otherwise real end to end — the real `ScreenPlanner` over the real
// dump the platform served, the real `PolicyEngine`, the real `ConsentGate`,
// the real `NativeGestureExecutor`, the real `NativeBridge`, the shipped
// `ReflectionCriticImpl`, the real `SanitizingRecoveryEngine`, the real
// `Stream<SafetyEventState>` the Safety Center is handed, and the real
// `SafetyCenterScreen`.
//
// The graph is opened in `setUp` rather than inside `testWidgets` on purpose. A
// widget test body runs in a fake-async zone, and opening the graph does real
// filesystem work whose completion would never be delivered there; `setUp` runs
// in the real zone, so the graph under test is the same one either way — and
// so the failing run the display test renders is a real one, driven from
// `setUp` too.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart'
    show ReflectionEvent, RuntimeResult, kConfidencePlatformErrorCode;
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/core/ui_state_contract.dart' show TaskState;
import 'package:noir_android_app/platform/native_bridge.dart'
    show kCodeNativeDispatchFailed, kMethodDispatchGesture;
import 'package:noir_android_app/safety/policy_engine.dart' show GateResult;
import 'package:noir_android_app/ui/command_centre_screen.dart';
import 'package:noir_android_app/ui/safety_center_screen.dart';

import 'support/noir_test_graph.dart';

/// The accessibility and audit panels read the platform asynchronously, and the
/// Command Centre owns a repeating animation, so `pumpAndSettle` never returns
/// on either screen. Three frames is what the other screen tests in this tree
/// use, and it is enough for the bridge replies and the log replay to land.
Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

void main() {
  ensureNoirBinding();

  late Directory workspace;
  late NoirComposition app;
  late FailingDispatchPlatform platform;

  setUp(() {
    // The platform is connected and answers every read the way a real
    // accessibility service does, and fails the one gesture the app dispatches.
    // The run below is refused nothing on its way there, so what scores it is
    // the platform's own failure and not a stage that stopped it earlier.
    platform = installFailingDispatchPlatformStub();
    workspace = Directory.systemTemp.createTempSync('noir-recovery-');
  });

  tearDown(() async {
    removePlatformStub();
    await app.dispose();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Opens the graph over [workspace], the way the app opens one.
  Future<void> openGraph() async {
    app = await NoirTestGraph.openBare(workspace: workspace);
  }

  /// Asks the graph to act on the screen and lets the run happen.
  ///
  /// `runAutomation` is the only entry point to the pipeline, so this is the
  /// route a tap in the Command Centre takes. The confirmation is answered here
  /// because the only holder of a `PendingConfirmation` in the real app is the
  /// UI, and there is no UI in this test — the answer itself is a real one from
  /// the real gate, and everything downstream of it is the shipped path.
  Future<RuntimeResult?> runFailingAutomation() async {
    final Future<RuntimeResult?> run = app.runAutomation(
      const AutomationRequest(action: 'read_screen', input: 'Send message'),
    );
    final PendingConfirmation confirmation = await app.confirmations.first;
    expect(
      confirmation.action,
      'read_screen',
      reason: 'the gate asks about the run the user asked for',
    );
    confirmation.answer(true);
    return run;
  }

  group('a real failed run reaches the Safety Center\'s event source', () {
    setUp(openGraph);

    test('the A4 audit entry is published on the graph\'s own safety log', () async {
      final String taskId = app.taskRun.controller.taskId;

      // Subscribed before the run, so the record cannot be missed by arriving
      // before this stream had a listener.
      final Future<SafetyEventAvailable> published = app
          .safetyEvents()
          .where((SafetyEventState state) => state is SafetyEventAvailable)
          .cast<SafetyEventAvailable>()
          .firstWhere(
            (SafetyEventAvailable state) => state.events.any(
              (SafetyEvent event) => event.kind == SafetyEventKind.recovery,
            ),
          );

      final RuntimeResult? result = await runFailingAutomation();

      // The run reached the platform and the platform failed it there. Without
      // this the assertions below would still pass on a run that was refused
      // before a single gesture was dispatched, which is a different fact about
      // a different stage.
      expect(
        platform.methods,
        contains(kMethodDispatchGesture),
        reason:
            'a run that never reached the platform proves nothing about what '
            'happens when one does and fails',
      );

      // The critic read the outcome's own fields and landed on the rung for a
      // run that did not happen and was told why. That is the score, read off
      // the run, not a reflection a test supplied.
      final ReflectionEvent reflection = result!.reflectionEvent!;
      expect(reflection.confidenceScore, lessThan(0.5));
      expect(reflection.confidenceScore, kConfidencePlatformErrorCode);
      expect(reflection.degradedToNeedsReview, isTrue);
      expect(reflection.needsReview(), isTrue);

      // And nothing about the run itself moved: the engine still blocks before
      // execution, names the same code, and leaves the task where it left it.
      expect(result.blocked, isTrue);
      expect((result.result as GateResult).message, 'RECOVERY_NEEDS_REVIEW');
      expect(app.taskRun.state, TaskState.failed);
      // The reason the platform gave travels out beside that code rather than
      // being written over it, so the row below still means
      // `RECOVERY_NEEDS_REVIEW` and a caller that has to say what actually went
      // wrong has something specific to say.
      expect(result.failureReason, kCodeNativeDispatchFailed);

      // The badge, the summary and every field of the row are the recovery's
      // own — read off the same audit entry the engine produced, for the run
      // that just happened.
      final List<SafetyEvent> events = (await published).events;
      final SafetyEvent event = events.firstWhere(
        (SafetyEvent event) => event.kind == SafetyEventKind.recovery,
      );

      expect(event.badge, 'RECOVERY_BLOCKED');
      expect(event.summary, 'Low-confidence reflection needs review');
      expect(event.detail, contains('task $taskId'));
      expect(event.detail, contains('confidence 30/100'));
      expect(
        event.detail,
        contains('re-execute-with-sanitized-screen-content'),
      );
      expect(event.detail, contains('sanitized screen used: true'));
      expect(event.occurredAt, isNotNull);
      expect(event.id, isNotEmpty);
      expect(
        events.where((SafetyEvent e) => e.kind == SafetyEventKind.recovery),
        hasLength(1),
        reason: 'one failed run, one record',
      );

      // The untyped trail the engine has always kept now holds the same run,
      // not a second opinion about it: same task, same score, same moment. The
      // score is derived from the run's own reflection and then pinned, so a
      // critic that stopped reading the execution report would move the
      // derived figure and fail here rather than quietly agree.
      final Map<String, dynamic> entry = app.recovery.auditTrail.single;
      expect(entry['taskId'], taskId);
      expect(
        entry['confidenceScore'],
        (reflection.confidenceScore * 100).round(),
      );
      expect(entry['confidenceScore'], 30);
      expect(entry['recoveryPath'], 're-execute-with-sanitized-screen-content');
      expect(entry['sanitizedScreenUsed'], isTrue);
      expect(
        DateTime.parse(entry['timestamp']! as String),
        event.occurredAt,
        reason: 'the record was built once, so it cannot carry two moments',
      );
    });

    test('the run is over before the user is asked anything again', () async {
      await runFailingAutomation();

      // The engine does not re-execute on its own — that would be a retry behind
      // the gate. A degraded run ends in "needs review" and the user starts a
      // fresh one, which goes through classification, the gate and confirmation
      // again from the top. So the whole run was one dispatch, and it failed.
      expect(
        platform.methods.where((String m) => m == kMethodDispatchGesture),
        hasLength(1),
        reason: 'recovery never retries behind the gate',
      );
      expect(app.recovery.auditTrail, hasLength(1));
    });
  });

  group('and the Safety Center renders what the log holds', () {
    // The run happens in setUp, in the real zone, for the reason in the header.
    setUp(() async {
      await openGraph();
      await runFailingAutomation();
    });

    testWidgets('a user who opens the Safety Center sees the recovery', (
      tester,
    ) async {
      // The real app's injection: the graph's log into the Command Centre, which
      // hands the same stream to the Safety Center when the user opens it.
      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            bridge: app.bridge,
            safetyEvents: app.safetyEvents(),
          ),
        ),
      );
      await pumpFrames(tester);
      await tester.tap(find.text('Service on'));
      await pumpFrames(tester);

      expect(find.text('Safety Center'), findsOneWidget);
      expect(find.text('RECOVERY_BLOCKED'), findsOneWidget);
      expect(
        find.text('Low-confidence reflection needs review'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'task ${app.taskRun.controller.taskId}, confidence 30/100',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('re-execute-with-sanitized-screen-content'),
        findsOneWidget,
      );
      // The platform sections are untouched by any of this: the screen audit
      // still reports the real dump the mocked service returned, with the real
      // A6a finding the sanitizer made about it.
      expect(
        find.textContaining(
          'Last dump: 2 node(s) read, 1 stripped by the A6a sanitizer.',
        ),
        findsOneWidget,
      );
      expect(find.text('REASON_ZERO_ALPHA'), findsOneWidget);
      expect(find.text('“concealed instruction”'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Unmounted before the graph goes, so nothing is left holding its bridge.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('and the log is still honest when no recovery has run', () {
    setUp(openGraph);

    test('the source publishes an empty log, not an endless loader', () async {
      final SafetyEventAvailable log = await app
          .safetyEvents()
          .where((SafetyEventState state) => state is SafetyEventAvailable)
          .cast<SafetyEventAvailable>()
          .first;

      // Connected and empty. A graph that has made no decisions has to be able
      // to say that; publishing the loading state instead would leave the Safety
      // Center reporting "still reading" for a process that had read everything.
      // The platform is live and failing every gesture it is offered, so this is
      // an empty log about a graph that had nothing to report, not one that
      // could not have reported.
      expect(log.events, isEmpty);
      expect(app.recovery.auditTrail, isEmpty);
    });

    testWidgets('the screen shows the empty state and invents no rows', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            bridge: app.bridge,
            safetyEvents: app.safetyEvents(),
          ),
        ),
      );
      await pumpFrames(tester);
      await tester.tap(find.text('Service on'));
      await pumpFrames(tester);

      expect(find.text('No safety events have been recorded.'), findsOneWidget);
      expect(find.text('Reading the safety log…'), findsNothing);
      expect(find.text('RECOVERY_BLOCKED'), findsNothing);
      expect(find.text('Low-confidence reflection needs review'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
