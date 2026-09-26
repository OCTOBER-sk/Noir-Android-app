// test/ui/usage_dashboard_screen_test.dart — the Usage Dashboard may only draw
// figures an injected UsageSnapshot actually reported.
//
// Every number the screen used to hard-code (1,240 tokens, \$0.00, "12 / 20
// req/min", "Noir Engine v2") had to go: a dashboard that invents its own
// numbers is worse than one that admits it has none.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/ui/usage_dashboard_screen.dart';

import 'fake_state_source.dart';

void main() {
  group('UsageDashboardScreen', () {
    testWidgets('is unavailable — not invented — when no source is wired', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: UsageDashboardScreen()));

      expect(find.text('No usage source is connected.'), findsOneWidget);
      expect(find.text('Usage Dashboard'), findsOneWidget);
      // Not one metric label survives, so no figure can be read as real.
      expect(find.text('Tokens used today'), findsNothing);
      expect(find.text('Cost today'), findsNothing);
      expect(find.text('Current model'), findsNothing);
      expect(find.text('RPM headroom'), findsNothing);
      expect(find.text('1,240'), findsNothing);
      expect(find.text('Noir Engine v2'), findsNothing);
    });

    testWidgets('loading resolves into the reported snapshot', (tester) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      await tester.pump();

      expect(find.text('Reading usage…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Tokens used today'), findsNothing);

      source.emit(
        const UsageAvailable(
          UsageSnapshot(
            tokensUsed: 4820,
            costUsd: 0.42,
            activeModel: 'openrouter/auto',
            requestsUsed: 7,
            requestsLimit: 40,
            capturedAt: null,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Reading usage…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Tokens used today'), findsOneWidget);
      expect(find.text('4820'), findsOneWidget);
      expect(find.text('Cost today'), findsOneWidget);
      expect(find.text(r'$0.42'), findsOneWidget);
      expect(find.text('Current model'), findsOneWidget);
      expect(find.text('openrouter/auto'), findsOneWidget);
      expect(find.text('RPM headroom'), findsOneWidget);
      expect(find.text('7 / 40 req/min'), findsOneWidget);
      // Nothing was captured, so nothing claims when.
      expect(find.textContaining('Reported at'), findsNothing);
    });

    testWidgets('reports the capture time the snapshot actually carries', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(
        UsageAvailable(
          UsageSnapshot(tokensUsed: 12, capturedAt: DateTime(2026, 1, 2, 3, 4)),
        ),
      );
      await tester.pump();

      expect(find.text('Reported at 2026-01-02 03:04'), findsOneWidget);
    });

    testWidgets('an empty snapshot is empty, not a row of zeroes', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(UsageSnapshot()));
      await tester.pump();

      expect(find.text('No usage has been recorded yet.'), findsOneWidget);
      expect(find.text('Tokens used today'), findsNothing);
      expect(find.text(r'$0.00'), findsNothing);
    });

    testWidgets('a partial snapshot dashes the figures it does not know', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(UsageSnapshot(requestsUsed: 3)));
      await tester.pump();

      expect(find.text('Tokens used today'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(3));
      // A used count without a limit is still shown, just without a ratio.
      expect(find.text('3 req/min'), findsOneWidget);
    });

    testWidgets('a failure shows the reason and retries only on demand', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);
      var retries = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: UsageDashboardScreen(
            source: source.stream,
            onRetry: () => retries++,
          ),
        ),
      );
      source.emit(const UsageFailed('Usage store unreachable.'));
      await tester.pump();

      expect(find.text('Usage store unreachable.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // A failure is not a dashboard full of zeroes.
      expect(find.text('Tokens used today'), findsNothing);
      expect(retries, 0);

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(retries, 1);
    });

    testWidgets('no retry control is drawn when nothing can be retried', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageFailed('Usage store unreachable.'));
      await tester.pump();

      expect(find.text('Usage store unreachable.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a later emission replaces the figures already on screen', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(UsageSnapshot(tokensUsed: 4820)));
      await tester.pump();
      expect(find.text('4820'), findsOneWidget);

      source.emit(
        const UsageAvailable(UsageSnapshot(tokensUsed: 5001, costUsd: 0.07)),
      );
      await tester.pump();

      expect(find.text('4820'), findsNothing);
      expect(find.text('5001'), findsOneWidget);
      expect(find.text(r'$0.07'), findsOneWidget);
    });

    testWidgets('a failure after data removes the stale figures', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(UsageSnapshot(tokensUsed: 4820)));
      await tester.pump();
      expect(find.text('4820'), findsOneWidget);

      source.emit(const UsageFailed('Tracker stopped answering.'));
      await tester.pump();

      expect(find.text('Tracker stopped answering.'), findsOneWidget);
      expect(find.text('4820'), findsNothing);
    });

    testWidgets('a throwing source degrades to a failure, not a blank screen', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.fail(StateError('socket closed'));
      await tester.pump();

      expect(find.textContaining('socket closed'), findsOneWidget);
      expect(find.text('Tokens used today'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a 360dp screen shows the snapshot without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(
        UsageAvailable(
          UsageSnapshot(
            tokensUsed: 4820,
            costUsd: 0.42,
            activeModel: 'openrouter/auto-with-a-very-long-identifier',
            requestsUsed: 7,
            requestsLimit: 40,
            capturedAt: DateTime(2026, 1, 2, 3, 4),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('4820'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
