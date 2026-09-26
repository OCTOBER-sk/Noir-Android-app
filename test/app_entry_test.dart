// test/app_entry_test.dart — the shipped entry path renders the real graph.
//
// The composition root can be perfect and the app still ship nothing, if
// lib/main.dart forgets to hand it to the UI. These tests drive the real
// `NoirApp` from lib/main.dart: they build a composition over a real
// directory, pump the app, let the splash hand over to the Command Centre, and
// check that what appears on screen came from the graph rather than from a
// widget's own defaults.
//
// Nothing here asserts on a hard-coded string that a widget invents for itself.
// The storage line has to name the directory the test actually created, because
// that line is the app telling the user where their records live.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/automations/automations.dart';
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/main.dart';
import 'package:noir_android_app/platform/accessibility_status.dart';
import 'package:noir_android_app/platform/native_bridge.dart';

const MethodChannel _channel = MethodChannel('com.noir.android/channel');

/// A ticker the test fires by hand.
///
/// The entry wiring is about *when* the tick is armed, not about a cadence, and
/// a widget test must not wait for a real thirty-second `Timer.periodic` to
/// find out. `cancelCount` is how "leaving the foreground cancels the timer" is
/// observed rather than assumed.
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
}

Map<String, dynamic> _connectedStatus() => <String, dynamic>{
  kWireServiceConnected: true,
  kWireCanPerformGestures: true,
  kWireCanRetrieveWindowContent: true,
  kWireHasNodeDump: true,
  kWireLastNodeCount: 0,
  kWireRuntimeSinkInstalled: true,
  kWireGateSource: kGateSource,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('noir-entry-');
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      switch (call.method) {
        case kMethodServiceStatus:
          return _connectedStatus();
        case kMethodGetNodes:
          return <String, dynamic>{'nodes': <Object?>[], 'nodeCount': 0};
        case kMethodPolicyGate:
          return <String, dynamic>{'allowed': true, 'message': 'ok'};
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Built inside [WidgetTester.runAsync] on purpose: opening the data layer
  /// does real file IO, and a widget test runs under a fake clock where a real
  /// asynchronous file operation would never complete.
  Future<NoirComposition> composition(WidgetTester tester) async =>
      (await tester.runAsync(
        () => NoirComposition.open(dataRootCandidates: <Directory>[workspace]),
      ))!;

  /// Tears the graph down in the real async zone.
  ///
  /// `dispose` flushes durable writes and closes broadcast streams, all of
  /// which need real microtask turns. A widget test body runs under a fake
  /// clock that will not drain them, so the teardown is done through
  /// [WidgetTester.runAsync] — the same reason the graph is built there.
  Future<void> teardown(WidgetTester tester, NoirComposition app) async {
    await tester.runAsync(() => app.dispose());
  }

  /// Settles the frames the app asked for without waiting for the Command
  /// Centre's looping loader animation, which never ends.
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('the splash names the real record directory', (tester) async {
    final NoirComposition app = await composition(tester);
    await tester.pumpWidget(NoirApp(composition: app));
    await tester.pump();
    await teardown(tester, app);

    expect(find.text('Noir'), findsOneWidget);
    // The line under the logo is generated from NoirDataLayer.selfReport() and
    // must name the directory the test created.
    final String root = (app.data as DataOpened).root.path;
    expect(find.textContaining(root), findsOneWidget);
    expect(find.textContaining('No durable storage'), findsNothing);
  });

  testWidgets('the splash says so when there is nowhere to store anything', (
    tester,
  ) async {
    // A regular file where a directory has to be: unopenable, on purpose.
    final File blocker = File('${workspace.path}/blocker')
      ..writeAsStringSync('not a directory');
    final NoirComposition app = (await tester.runAsync(
      () => NoirComposition.open(
        dataRootCandidates: <Directory>[Directory(blocker.path)],
      ),
    ))!;
    await tester.pumpWidget(NoirApp(composition: app));
    await tester.pump();
    await teardown(tester, app);

    expect(find.textContaining('No durable storage'), findsOneWidget);
    expect(find.textContaining('will not save anything'), findsOneWidget);
  });

  testWidgets('the Command Centre receives the graph the app built', (
    tester,
  ) async {
    final NoirComposition app = await composition(tester);
    await tester.pumpWidget(NoirApp(composition: app));
    await tester.pump();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 1700));
    await settle(tester);

    // The pre-existing entry path is intact: the header and the composer.
    expect(find.text('NOIr'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    // No provider is configured, so submitting says the backend is absent
    // instead of inventing a reply.
    await tester.enterText(find.byType(TextField).last, 'what can you do?');
    // The send control enables itself from the composer's text, so it only
    // becomes tappable after the rebuild that `onChanged` schedules.
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded).first);
    await settle(tester);
    expect(
      find.textContaining('No provider is configured'),
      findsWidgets,
      reason: 'the real reason from the graph, not a fabricated answer',
    );
    await teardown(tester, app);
  });

  testWidgets('the operations surface is reachable and shows real states', (
    tester,
  ) async {
    final NoirComposition app = await composition(tester);
    await tester.pumpWidget(NoirApp(composition: app));
    await tester.pump();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 1700));
    await settle(tester);

    // The control only exists because a composition injected an operations
    // surface; with nothing wired there would be no button at all.
    final Finder operations = find.byIcon(Icons.tune_rounded);
    expect(operations, findsOneWidget);
    await tester.tap(operations);
    await settle(tester);

    expect(find.text('Run an action'), findsOneWidget);
    // The service is really connected, so the form is live.
    expect(
      find.text('The accessibility service is connected and may act.'),
      findsOneWidget,
    );
    // No confirmation is outstanding, and none is invented.
    expect(find.text('Confirmation required'), findsNothing);

    // The three screens the app used to be unable to reach are all mounted,
    // each showing whatever its own source has actually reported. The timeline
    // has no run behind it, so it says so rather than listing steps that never
    // happened.
    expect(find.text('Live task'), findsOneWidget);
    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('Automations'), findsOneWidget);
    await teardown(tester, app);
  });

  testWidgets('the safety center reports the MCP capability it was given', (
    tester,
  ) async {
    final NoirComposition app = await composition(tester);
    await tester.pumpWidget(NoirApp(composition: app));
    await tester.pump();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 1700));
    await settle(tester);

    // Reach the Safety Center through the accessibility pill in the header.
    await tester.tap(find.text('Service on'));
    await settle(tester);

    expect(find.text('Safety Center'), findsOneWidget);
    // The Safety Center scrolls its own content, so this scrolls the page the
    // same way a user would.
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -600),
    );
    await settle(tester);
    expect(find.text('MCP servers'), findsOneWidget);
    // The store opened and is empty, which is a different statement from
    // "MCP is unavailable" and from "unknown".
    expect(find.textContaining('No MCP server is configured'), findsOneWidget);
    await teardown(tester, app);
  });

  // A graph with no writable record directory, so the tick has something real
  // to report and nothing to wait for: the pass it performs reads no files, so
  // it completes inside the test's fake-async zone — where, as the helpers above
  // say, real file IO would never complete at all.
  Future<NoirComposition> graphWithoutStorage(
    WidgetTester tester, {
    required AutomationTicker ticker,
  }) async {
    final File blocker = File('${workspace.path}/blocker')
      ..writeAsStringSync('not a directory');
    return (await tester.runAsync(
      () => NoirComposition.open(
        dataRootCandidates: <Directory>[Directory(blocker.path)],
        automationTicker: ticker,
      ),
    ))!;
  }

  testWidgets('the tick is armed with the app and disarmed when it is not', (
    tester,
  ) async {
    final _HandTicker ticker = _HandTicker();
    final NoirComposition app = await graphWithoutStorage(
      tester,
      ticker: ticker,
    );

    await tester.pumpWidget(NoirApp(composition: app));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // The app is up, so the tick is armed — and it has already offered what was
    // due, rather than waiting a whole interval to discover it.
    expect(app.automationScheduler.isRunning, isTrue);
    expect(ticker.startCount, 1);
    expect(app.automationScheduler.passesRun, 1);
    // The graph has nowhere to keep a job, so the pass says that. What matters
    // here is that the tick really called the graph's own dispatch: the answer
    // is the graph's, produced by a pass nobody triggered by hand.
    expect(app.automationScheduler.lastPass, isA<AutomationPassUnavailable>());
    expect(
      (app.automationScheduler.lastPass! as AutomationPassUnavailable).reason,
      contains('durable'),
    );

    // The handle a real periodic timer would still be holding.
    final void Function() held = ticker.lastTick!;

    // Leaving the foreground cancels the timer, and a callback that arrives
    // anyway does nothing: no job is offered to a user who is not looking.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(app.automationScheduler.isRunning, isFalse);
    expect(ticker.cancelCount, 1);
    held();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      app.automationScheduler.passesRun,
      1,
      reason: 'a tick that lands while the app is not in front is not a pass',
    );

    // Coming back re-arms it, and offers what is due as soon as it is back.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(app.automationScheduler.isRunning, isTrue);
    expect(ticker.startCount, 2);
    expect(
      app.automationScheduler.passesRun,
      2,
      reason: 'a job that came due while the app was away is offered on return',
    );

    // The splash handing over to the Command Centre is not the app leaving, so
    // the tick survives the handover.
    await tester.pump(const Duration(milliseconds: 1700));
    await settle(tester);
    expect(find.text('NOIr'), findsOneWidget);
    expect(
      app.automationScheduler.isRunning,
      isTrue,
      reason: 'navigating inside the app does not stop the scheduler',
    );
    expect(ticker.cancelCount, 1, reason: 'and the handover cancelled nothing');

    await teardown(tester, app);
  });
}
