// test/ui/safety_center_screen_test.dart — the Safety Center keeps its two real
// platform sections and adds an injected SafetyEvent log.
//
// The feed is fed by whatever the app hands the screen. Nothing is invented, and
// the biometric toggle is drawn inert: presenting a switch that reads "on" while
// no policy gate is bound to it would be a lie in a security screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/ui/safety_center_screen.dart';

import 'fake_state_source.dart';

const MethodChannel _platformChannel = MethodChannel(kNativeChannelName);

/// The accessibility and audit panels read the platform asynchronously.
/// pumpAndSettle is unusable here: nothing settles on this screen.
Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('SafetyCenterScreen safety log', () {
    late NativeBridge bridge;

    setUp(() {
      // The platform half is not there at all: every method answers the way an
      // unregistered channel does, so the two real panels render their
      // fail-closed state instead of pretending the service is healthy.
      messenger.setMockMethodCallHandler(
        _platformChannel,
        (call) => throw MissingPluginException(call.method),
      );
      bridge = NativeBridge();
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(_platformChannel, null);
      await bridge.dispose();
    });

    testWidgets('the log is unavailable when no source is wired', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('No safety log is connected.'), findsOneWidget);
      // The real platform sections are unaffected by the missing log.
      expect(find.text('Accessibility bridge unavailable'), findsOneWidget);
      expect(find.textContaining('No screen data'), findsOneWidget);
    });

    testWidgets('loading resolves into the events the source reported', (
      tester,
    ) async {
      final source = FakeStateSource<SafetyEventState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SafetyCenterScreen(bridge: bridge, log: source.stream),
        ),
      );
      await tester.pump();

      expect(find.text('Reading the safety log…'), findsOneWidget);
      expect(find.text('POLICY_BLOCKED'), findsNothing);

      source.emit(
        SafetyEventAvailable(<SafetyEvent>[
          SafetyEvent(
            id: 's1',
            kind: SafetyEventKind.policy,
            outcome: SafetyEventOutcome.blocked,
            summary: 'Payment app open was blocked.',
            occurredAt: DateTime(2026, 1, 2, 3, 4, 5),
          ),
          SafetyEvent(
            id: 's2',
            kind: SafetyEventKind.sanitization,
            outcome: SafetyEventOutcome.unknown,
            summary: '2 node(s) stripped from the last dump.',
            detail: 'REASON_ZERO_ALPHA',
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('Reading the safety log…'), findsNothing);
      expect(find.text('Payment app open was blocked.'), findsOneWidget);
      expect(find.text('POLICY_BLOCKED'), findsOneWidget);
      expect(find.text('03:04:05'), findsOneWidget);
      expect(
        find.text('2 node(s) stripped from the last dump.'),
        findsOneWidget,
      );
      expect(find.text('REASON_ZERO_ALPHA'), findsOneWidget);
      // No timestamp was reported for s2, so none is invented.
      expect(find.text('time unknown'), findsOneWidget);
    });

    testWidgets('an empty log is empty', (tester) async {
      final source = FakeStateSource<SafetyEventState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SafetyCenterScreen(bridge: bridge, log: source.stream),
        ),
      );
      source.emit(const SafetyEventAvailable(<SafetyEvent>[]));
      await tester.pump();

      expect(find.text('No safety events have been recorded.'), findsOneWidget);
    });

    testWidgets('a failure shows the reason and retries only on demand', (
      tester,
    ) async {
      final source = FakeStateSource<SafetyEventState>();
      addTearDown(source.close);
      var retries = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: SafetyCenterScreen(
            bridge: bridge,
            log: source.stream,
            onRetryLog: () => retries++,
          ),
        ),
      );
      source.emit(const SafetyEventFailed('Audit log store unreachable.'));
      await tester.pump();

      expect(find.text('Audit log store unreachable.'), findsOneWidget);
      expect(find.text('Retry log'), findsOneWidget);
      expect(retries, 0);

      // The log sits below the two platform sections, so it has to be brought
      // into view before it can be pressed.
      await tester.ensureVisible(find.text('Retry log'));
      await tester.tap(find.text('Retry log'));
      await tester.pump();

      expect(retries, 1);
    });

    testWidgets('a throwing source degrades to a failure state', (
      tester,
    ) async {
      final source = FakeStateSource<SafetyEventState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SafetyCenterScreen(bridge: bridge, log: source.stream),
        ),
      );
      source.fail(StateError('log socket closed'));
      await tester.pump();

      expect(find.textContaining('log socket closed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a later emission replaces the events already listed', (
      tester,
    ) async {
      final source = FakeStateSource<SafetyEventState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SafetyCenterScreen(bridge: bridge, log: source.stream),
        ),
      );
      source.emit(
        const SafetyEventAvailable(<SafetyEvent>[
          SafetyEvent(id: 's1', summary: 'Stale decision.'),
        ]),
      );
      await tester.pump();
      expect(find.text('Stale decision.'), findsOneWidget);

      source.emit(
        const SafetyEventAvailable(<SafetyEvent>[
          SafetyEvent(id: 's2', summary: 'Fresh decision.'),
        ]),
      );
      await tester.pump();

      expect(find.text('Stale decision.'), findsNothing);
      expect(find.text('Fresh decision.'), findsOneWidget);
    });

    testWidgets('a failure after events removes the stale rows', (
      tester,
    ) async {
      final source = FakeStateSource<SafetyEventState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SafetyCenterScreen(bridge: bridge, log: source.stream),
        ),
      );
      source.emit(
        const SafetyEventAvailable(<SafetyEvent>[
          SafetyEvent(id: 's1', summary: 'Stale decision.'),
        ]),
      );
      await tester.pump();
      expect(find.text('Stale decision.'), findsOneWidget);

      source.emit(const SafetyEventFailed('Audit log store unreachable.'));
      await tester.pump();

      expect(find.text('Stale decision.'), findsNothing);
      expect(find.text('Audit log store unreachable.'), findsOneWidget);
    });

    testWidgets('the biometric toggle is inert, not a live control', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await tester.pump();

      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(tile.onChanged, isNull);
      expect(
        find.text(
          'Not wired to a policy gate yet — this screen cannot '
          'enforce it.',
        ),
        findsOneWidget,
      );
    });
  });
}
