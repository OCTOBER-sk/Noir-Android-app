// test/integration/recovery_audit_surface_test.dart — the A4 audit record has to
// be readable by the user, not just held in a list.
//
// The gap this file is about was not hypothetical. `SanitizingRecoveryEngine`
// built a real audit entry for every low-confidence reflection, appended it to
// its own `auditTrail`, and that list had no reader anywhere in `lib/`: a run
// that ended `RECOVERY_NEEDS_REVIEW` was a fact the graph knew and the user
// never saw. It is also a fact the graph's safety log could not show, because
// nothing was ever handed to that log either — and the Safety Center was built
// with no `log` at all, so it rendered "No safety log is connected." while the
// graph was recording decisions.
//
// Every assertion here is made through the real composition root: the real data
// layer over a real directory, the real `PolicyEngine`, the real
// `SanitizingRecoveryEngine` the pipeline holds, the real
// `Stream<SafetyEventState>` the Safety Center is handed, and the real
// `SafetyCenterScreen`. Only two things are substituted, and both are the same
// two every other integration test in this tree substitutes: the platform channel
// and the fact that no human is present to answer a confirmation.
//
// On driving the engine directly: the critic used to be unreachable here —
// `ReflectionCritic.computeConfidence` scored an execution with
// `executed.toString().contains('failed')`, and the shipped executor always
// answers with a `NativeGestureOutcome`, which has the default `toString` — so
// this file had to call `app.recovery.executeReflectionRecovery` itself and say
// so. That has changed: the critic now reads the outcome's own fields, and a
// real failed run through `runAutomation` reaches the recovery branch. The
// end-to-end proof of that lives in test/composition_root_test.dart, where the
// platform is made to fail a dispatched gesture.
//
// These tests still drive the engine directly, and that is a deliberate choice
// rather than a workaround: they pin what the Safety Center renders for a given
// audit record, so the record is supplied directly and the row can be read
// without arranging a platform failure to produce it. Everything downstream of
// the call — the engine, the audit entry, the graph's own log, the screen — is
// the shipped path.
//
// The graph is opened in `setUp` rather than inside `testWidgets` on purpose. A
// widget test body runs in a fake-async zone, and opening the graph does real
// filesystem work whose completion would never be delivered there; `setUp` runs
// in the real zone, so the graph under test is the same one either way.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart'
    show Reflection, RuntimeResult;
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/core/ui_state_contract.dart' show TaskState;
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

  setUp(() async {
    installConnectedPlatformStub();
    workspace = Directory.systemTemp.createTempSync('noir-recovery-');
    app = await NoirTestGraph.openBare(workspace: workspace);
  });

  tearDown(() async {
    removePlatformStub();
    await app.dispose();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Runs the graph's own A4 recovery on a reflection the critic would have
  /// scored below the threshold, and returns what the run actually returned.
  ///
  /// The reflection is supplied rather than produced, so the assertions below
  /// are about one known record — the header explains why. `executed` is null
  /// here because this file is about the *display* of a record, not about what
  /// produced one: there is no executor answer to hand it, and the engine reads
  /// the answer for exactly one thing now, which is whether it can name a
  /// specific reason. Null carries no reason, so what the Safety Center is
  /// asserted against below is the bare `RECOVERY_NEEDS_REVIEW` run, and the
  /// test that a reason travels beside it without touching the row lives in
  /// test/composition_root_test.dart, where a real failed run produces one.
  Future<RuntimeResult> runRecovery() =>
      app.recovery.executeReflectionRecovery(Reflection(confidence: 0.3), null);

  group('a real recovery run reaches the Safety Center\'s event source', () {
    test(
      'the A4 audit entry is published on the graph\'s own safety log',
      () async {
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

        final RuntimeResult result = await runRecovery();
        final List<SafetyEvent> events = (await published).events;
        final SafetyEvent event = events.firstWhere(
          (SafetyEvent event) => event.kind == SafetyEventKind.recovery,
        );

        // The badge, the summary and every field of the row are the recovery's own.
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
          reason: 'one recovery run, one record',
        );

        // The untyped trail the engine has always kept now holds the same run, not
        // a second opinion about it: same task, same score, same moment.
        final Map<String, dynamic> entry = app.recovery.auditTrail.single;
        expect(entry['taskId'], taskId);
        expect(entry['confidenceScore'], 30);
        expect(
          entry['recoveryPath'],
          're-execute-with-sanitized-screen-content',
        );
        expect(entry['sanitizedScreenUsed'], isTrue);
        expect(
          DateTime.parse(entry['timestamp']! as String),
          event.occurredAt,
          reason: 'the record was built once, so it cannot carry two moments',
        );

        // And nothing about the run itself moved: this is display plumbing. The
        // engine still blocks before execution, names the same code, and leaves
        // the task where it left it.
        expect(result.blocked, isTrue);
        expect((result.result as GateResult).message, 'RECOVERY_NEEDS_REVIEW');
        expect(app.taskRun.state, TaskState.failed);
        // This run had no executor answer, so it names no specific reason, and
        // none is made up. The row above is therefore the whole of what a
        // recovery run reports when nothing downstream of the executor had
        // anything to say — the reason a *reasoned* recovery run carries rides
        // beside this code and is not folded into it.
        expect(
          result.failureReason,
          isNull,
          reason: 'a recovery run with no reason to report invents none',
        );
      },
    );
  });
  group('and the Safety Center renders what the log holds', () {
    // The run happens in setUp, in the real zone, for the reason in the header.
    setUp(runRecovery);

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
      // The two platform sections are untouched by any of this: the screen
      // audit still reports the real dump the mocked service returned.
      expect(
        find.textContaining('Last dump read cleanly: 0 node(s)'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Unmounted before the graph goes, so nothing is left holding its bridge.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('and the log is still honest when no recovery has run', () {
    test('the source publishes an empty log, not an endless loader', () async {
      final SafetyEventAvailable log = await app
          .safetyEvents()
          .where((SafetyEventState state) => state is SafetyEventAvailable)
          .cast<SafetyEventAvailable>()
          .first;

      // Connected and empty. A graph that has made no decisions has to be able
      // to say that; publishing the loading state instead would leave the Safety
      // Center reporting "still reading" for a process that had read everything.
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
