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
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/main.dart';
import 'package:noir_android_app/platform/accessibility_status.dart';
import 'package:noir_android_app/platform/native_bridge.dart';

const MethodChannel _channel = MethodChannel('com.noir.android/channel');

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
}
