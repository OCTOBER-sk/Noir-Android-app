// test/ui/undo_toast_live_control_test.dart — the D15 Undo control is a real
// control, or it is not drawn.
//
// WHAT WAS WRONG. `UndoToast` rendered `_UndoActionButton`: a `SizedBox` with a
// border, the literal caption "Undo", `Semantics(enabled: false)`, and the line
// under it
//
//   'Disabled: undo is not wired to an action executor yet.'
//
// Nothing in the widget tree had an `onTap`, and nothing in the app had a way to
// supply one, so the sentence was the most expensive kind of lie: it described a
// missing feature while the spec (V2.3 §2.1b) and the plan both treat the undo
// window as shipped, and the 5 seconds the countdown was counting were spent on
// a button that could not fire.
//
// WHAT IS ASSERTED HERE, and what is not:
//
//   * The control is live only when an executor is connected. The handler is
//     injected exactly the way `onAnswerConfirmation` is — nullable, supplied
//     by production, absent in a screen with no graph behind it — and a toast
//     with no handler says so in words rather than pretending.
//   * Pressing it reaches the handler with the action the window is offering,
//     reports the outcome that came back, and cannot be pressed twice. The
//     compensating run is single-use because the live window it comes from is.
//   * An action the app cannot reverse renders no control at all.
//
// The dispatch itself is not simulated here: this file never fakes an outcome,
// it hands the toast the value a real `NoirComposition.undo` returns and
// asserts the toast tells the truth about it. That the real executor receives
// exactly one compensating gesture is asserted in test/composition_root_test.dart
// against the real bridge and the real policy gate.
import 'package:flutter/material.dart';
// `SemanticsProperties` is what `Semantics` keeps its arguments in, and it is
// not re-exported by material.dart.
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/core/conversation_controller.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

import 'fake_state_source.dart';

void main() {
  const Key undoControl = Key('undo-toast-control');
  const String staleClaim = 'undo is not wired to an action executor yet';

  /// The copy the toast prints when the compensating run really did dispatch.
  const String performed = 'Undone.';

  /// The event a real window publishes for a navigation: reversible, with the
  /// id `NoirComposition.undo` takes.
  const ActionCompletedWithUndoWindow reversibleWindow =
      ActionCompletedWithUndoWindow(
        'navigate "maps"',
        true,
        Duration(seconds: 5),
        'undo-1',
      );

  /// The event for an action this build cannot reverse.
  const ActionCompletedWithUndoWindow irreversibleWindow =
      ActionCompletedWithUndoWindow(
        'tap "Send message"',
        false,
        Duration(seconds: 5),
        'undo-2',
      );

  Widget host(
    ActionCompletedWithUndoWindow event, {
    Future<UndoResult> Function(String actionId)? onUndo,
  }) => MaterialApp(home: Scaffold(body: UndoToast(event: event, onUndo: onUndo)));

  /// Whether the control advertises itself as a pressable button.
  bool live(WidgetTester tester) {
    final SemanticsProperties properties = tester
        .widget<Semantics>(find.byKey(undoControl))
        .properties;
    expect(properties.button, isTrue, reason: 'the control must be a button');
    expect(properties.label, 'Undo');
    return properties.enabled ?? false;
  }

  group('UndoToast — a live control', () {
    testWidgets('pressing it reaches the executor with the action id', (
      tester,
    ) async {
      final List<String> pressed = <String>[];

      await tester.pumpWidget(
        host(
          reversibleWindow,
          // What `main.dart` installs: the graph's own `NoirComposition.undo`.
          onUndo: (String actionId) async {
            pressed.add(actionId);
            return UndoPerformed(actionId);
          },
        ),
      );

      expect(live(tester), isTrue);
      await tester.tap(find.byKey(undoControl));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(pressed, <String>['undo-1']);
      expect(find.text(performed), findsOneWidget);
    });

    testWidgets('the outcome it reports is the one the executor returned', (
      tester,
    ) async {
      // A compensating run that could not aim at anything reports the
      // platform's own block reason. The toast must print that reason rather
      // than a success the run did not have.
      await tester.pumpWidget(
        host(
          reversibleWindow,
          onUndo: (String actionId) async =>
              const UndoRefused(kCodeMalformedGestureTarget),
        ),
      );

      await tester.tap(find.byKey(undoControl));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text(performed), findsNothing);
      expect(
        find.text('Undo did not run: $kCodeMalformedGestureTarget.'),
        findsOneWidget,
      );
    });

    testWidgets('a second press does nothing: the window is single-use', (
      tester,
    ) async {
      int calls = 0;

      await tester.pumpWidget(
        host(
          reversibleWindow,
          onUndo: (String actionId) async {
            calls++;
            return UndoPerformed(actionId);
          },
        ),
      );

      await tester.tap(find.byKey(undoControl));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(calls, 1);

      // The action has been compensated once. The graph has no second window
      // to answer, and a control that would still fire is a control that would
      // ask the user to undo something that is already undone.
      expect(live(tester), isFalse);
      await tester.tap(find.byKey(undoControl), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(calls, 1);
      expect(find.text(performed), findsOneWidget);
    });
  });

  group('UndoToast — nothing connected, nothing claimed', () {
    testWidgets('the control is disabled and says why', (tester) async {
      await tester.pumpWidget(host(reversibleWindow));

      expect(
        find.byKey(undoControl),
        findsOneWidget,
        reason: 'the pinned reversible toast keeps its Undo label',
      );
      expect(live(tester), isFalse);
      expect(
        find.textContaining('No undo executor is connected'),
        findsOneWidget,
        reason: 'a disabled control owes the user a reason',
      );
    });

    testWidgets('the stale claim is gone from the widget', (tester) async {
      await tester.pumpWidget(host(reversibleWindow, onUndo: (_) async {
        return const UndoPerformed('undo-1');
      }));

      expect(find.textContaining(staleClaim), findsNothing);
    });

    testWidgets('an action that cannot be reversed renders no control', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          irreversibleWindow,
          onUndo: (String actionId) async => UndoPerformed(actionId),
        ),
      );

      expect(find.byKey(undoControl), findsNothing);
      expect(find.text('Undo'), findsNothing);
      expect(find.text('Irreversible action completed.'), findsOneWidget);
    });
  });

  group('CommandCentreScreen threads the undo executor to the toast', () {
    Future<
      ({
        FakeStateSource<NoirUiEvent> events,
        List<String> pressed,
      })
    >
    pumpScreen(
      WidgetTester tester, {
      required bool withExecutor,
    }) async {
      final ConversationController controller = ConversationController();
      addTearDown(controller.close);
      final FakeStateSource<NoirUiEvent> events = FakeStateSource<NoirUiEvent>();
      addTearDown(events.close);
      final List<String> pressed = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            events: events.stream,
            onUndoAction: withExecutor
                ? (String actionId) async {
                    pressed.add(actionId);
                    return UndoPerformed(actionId);
                  }
                : null,
          ),
        ),
      );
      return (events: events, pressed: pressed);
    }

    /// The same wire `main.dart` connects to `composition.taskRun.events`.
    Future<void> deliver(
      WidgetTester tester,
      FakeStateSource<NoirUiEvent> events,
    ) async {
      events.emit(reversibleWindow);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
    }

    testWidgets('the timeline toast reaches the injected executor', (
      tester,
    ) async {
      final harness = await pumpScreen(tester, withExecutor: true);

      await deliver(tester, harness.events);

      expect(find.text('navigate "maps" just happened.'), findsOneWidget);
      expect(live(tester), isTrue);
      await tester.tap(find.byKey(undoControl));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(harness.pressed, <String>['undo-1']);
      expect(find.text(performed), findsOneWidget);
    });

    testWidgets('a screen with no executor renders a disabled control', (
      tester,
    ) async {
      final harness = await pumpScreen(tester, withExecutor: false);

      await deliver(tester, harness.events);

      expect(live(tester), isFalse);
      await tester.tap(find.byKey(undoControl), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        harness.pressed,
        isEmpty,
        reason: 'no handler was injected, so no press can reach one',
      );
    });
  });
}
