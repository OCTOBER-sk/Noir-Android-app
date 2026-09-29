// test/ui/usage_dashboard_model_visibility_test.dart — V2.3 §2.4, "toggle for
// model-name visibility".
//
// The spec asks for the third of three things on this screen; the first two
// (numeric readouts, RPM headroom) had tests and the toggle did not exist. It
// exists now, so these tests hold it to what it claims.
//
// The pitfall this file is written against: a display toggle can be "tested" by
// building the widget, reaching past it and calling setState, then asserting on
// the tree. That passes whether or not the control is wired to anything. Every
// test here instead pushes a real [UsageAvailable] carrying a real
// [UsageSnapshot.activeModel] down a real stream, taps the real switch, and
// asserts on what the card then says. If the switch's onChanged is severed from
// the state it drives, the identifier stays on screen and these tests go red.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/ui/usage_dashboard_screen.dart';

import 'fake_state_source.dart';

/// A snapshot that reported every figure, so a failure can only be the toggle's
/// doing and not a dash standing in for a value.
const UsageSnapshot kReported = UsageSnapshot(
  tokensUsed: 4820,
  costUsd: 0.42,
  activeModel: 'openrouter/auto',
  requestsUsed: 12,
  requestsLimit: 20,
  capturedAt: null,
);

void main() {
  group('UsageDashboardScreen model-name visibility', () {
    testWidgets('names the model by default, from a real emission', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(kReported));
      await tester.pump();

      // The identifier is the source's, printed because that has always been
      // this card's behaviour: a spec asking for a toggle does not ask for a
      // changed default.
      expect(find.text('openrouter/auto'), findsOneWidget);
      expect(find.text('Current model'), findsOneWidget);
      // And it is a real control, not a label pretending to be one.
      expect(find.byType(Switch), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('tapping the toggle takes the identifier off the screen', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(kReported));
      await tester.pump();
      expect(find.text('openrouter/auto'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('openrouter/auto'), findsNothing);
      // The card is still there, and it says what happened.
      expect(find.text('Current model'), findsOneWidget);
      expect(find.text(kUsageHiddenFigure), findsOneWidget);
      // "Hidden" must not borrow the unknown dash: a dash claims the source
      // never named a model, and the source named one.
      expect(find.text(kUsageUnknownFigure), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('tapping it again puts the identifier back', (tester) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(kReported));
      await tester.pump();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text(kUsageHiddenFigure), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('openrouter/auto'), findsOneWidget);
      expect(find.text(kUsageHiddenFigure), findsNothing);
    });

    testWidgets('hiding the name touches no other reported figure', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(kReported));
      await tester.pump();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('4820'), findsOneWidget);
      expect(find.text(r'$0.42'), findsOneWidget);
      expect(find.text('12 / 20 req/min'), findsOneWidget);
      // Only the name is off; the toggle is a display choice, not a filter.
      expect(find.text('openrouter/auto'), findsNothing);
    });

    testWidgets('the hidden state survives a later emission', (tester) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(const UsageAvailable(kReported));
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // A new reading arrives. The new model is a fresh report from the source
      // and must not become visible behind a preference the user set.
      source.emit(
        const UsageAvailable(
          UsageSnapshot(
            tokensUsed: 5001,
            costUsd: 0.07,
            activeModel: 'anthropic/claude-sonnet-4',
            requestsUsed: 13,
            requestsLimit: 20,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('5001'), findsOneWidget);
      expect(find.text('anthropic/claude-sonnet-4'), findsNothing);
      expect(find.text(kUsageHiddenFigure), findsOneWidget);
    });

    testWidgets('the choice belongs to one screen, not to the snapshot', (
      tester,
    ) async {
      final left = FakeStateSource<UsageState>();
      final right = FakeStateSource<UsageState>();
      addTearDown(left.close);
      addTearDown(right.close);
      // Tall enough that both panels lay their whole body out; a viewport that
      // pushed the toggle off-screen would make this test pass for the wrong
      // reason.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              Expanded(child: UsageDashboardScreen(source: left.stream)),
              Expanded(child: UsageDashboardScreen(source: right.stream)),
            ],
          ),
        ),
      );
      left.emit(const UsageAvailable(kReported));
      right.emit(
        const UsageAvailable(UsageSnapshot(activeModel: 'local/noir-mini')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      // Only the screen the user touched changed: the preference lives in that
      // screen's State, not in UsageSnapshot, which the other screen is
      // rendering from its own source at the same time.
      expect(find.text(kUsageHiddenFigure), findsOneWidget);
      expect(find.text('local/noir-mini'), findsOneWidget);
    });

    testWidgets('no switch is offered when the source named no model', (
      tester,
    ) async {
      final source = FakeStateSource<UsageState>();
      addTearDown(source.close);

      await tester.pumpWidget(
        MaterialApp(home: UsageDashboardScreen(source: source.stream)),
      );
      source.emit(
        const UsageAvailable(
          UsageSnapshot(
            tokensUsed: 4820,
            costUsd: 0.42,
            requestsUsed: 12,
            requestsLimit: 20,
          ),
        ),
      );
      await tester.pump();

      // The source reported no model, so there is no name to hide and a switch
      // over it would be a control that cannot do anything. The card's dash is
      // still a dash here: "unknown" keeps its own meaning, and it is the only
      // dash on screen, so the assertion cannot be satisfied by an unrelated
      // unknown figure.
      expect(find.byType(Switch), findsNothing);
      expect(find.text(kUsageUnknownFigure), findsOneWidget);
      expect(find.text(kUsageHiddenFigure), findsNothing);
    });

    testWidgets('a 360dp screen carries the toggle without overflowing', (
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
            requestsUsed: 12,
            requestsLimit: 20,
            capturedAt: DateTime(2026, 1, 2, 3, 4),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(kUsageHiddenFigure), findsOneWidget);
      expect(
        find.text('openrouter/auto-with-a-very-long-identifier'),
        findsNothing,
      );
    });
  });
}
