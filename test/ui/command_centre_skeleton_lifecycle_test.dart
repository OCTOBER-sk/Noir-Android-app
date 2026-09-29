// test/ui/command_centre_skeleton_lifecycle_test.dart — the skeleton loader is
// cleared by the event that actually ends a tool call.
//
// The bug this pins down: `pushRealEvent` set `_showSkeleton = true` on
// `ToolCallStarted` and cleared it only on `ActionCompletedWithUndoWindow`.
// Those two events do not bracket a tool call. `AgentRuntimePipeline` awaits
// `undoWindow.open(5, ...)` *before* `execute.run(plan)`
// (lib/agent/agent_runtime.dart:75-76), so on a real run the order is
//
//   ActionCompletedWithUndoWindow  -> _showSkeleton = false
//   ToolCallStarted                -> _showSkeleton = true
//   ToolCallCompleted              -> nothing at all
//
// and the loader then spins for the rest of the session with no event left that
// can stop it.
//
// The events are pushed through the screen's injected `events` stream, which is
// the same wire `main.dart` connects to `composition.taskRun.events`, so this
// exercises the production delivery path rather than calling the state directly.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_controller.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

import 'fake_state_source.dart';

void main() {
  const Key skeleton = Key('command-centre-skeleton');

  /// The order `AgentRuntimePipeline` really produces for one tool run.
  List<NoirUiEvent> productionToolRunOrder({required bool success}) =>
      <NoirUiEvent>[
        ActionCompletedWithUndoWindow(
          'action undo-1',
          true,
          const Duration(seconds: 5),
        ),
        ToolCallStarted('gesture', 1),
        ToolCallCompleted('gesture', success),
      ];

  Future<FakeStateSource<NoirUiEvent>> pumpScreen(WidgetTester tester) async {
    final controller = ConversationController();
    addTearDown(controller.close);
    final events = FakeStateSource<NoirUiEvent>();
    addTearDown(events.close);

    await tester.pumpWidget(
      MaterialApp(
        home: CommandCentreScreen(
          controller: controller,
          events: events.stream,
        ),
      ),
    );
    return events;
  }

  /// Delivery is asynchronous, so each event needs its own pump.
  Future<void> deliver(
    WidgetTester tester,
    FakeStateSource<NoirUiEvent> events,
    NoirUiEvent event,
  ) async {
    events.emit(event);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  group('CommandCentreScreen skeleton lifecycle', () {
    testWidgets('a tool call that finishes stops the loader', (tester) async {
      final events = await pumpScreen(tester);

      for (final NoirUiEvent event in productionToolRunOrder(success: true)) {
        await deliver(tester, events, event);
      }

      expect(
        find.byKey(skeleton),
        findsNothing,
        reason: 'ToolCallCompleted ends a tool call, so the loader must stop.',
      );
    });

    testWidgets('a failed tool call also stops the loader', (tester) async {
      final events = await pumpScreen(tester);

      for (final NoirUiEvent event in productionToolRunOrder(success: true)) {
        await deliver(tester, events, event);
      }
      // Same ordering, but the bridge reported the gesture never executed.
      await deliver(tester, events, ToolCallCompleted('gesture', false));

      expect(
        find.byKey(skeleton),
        findsNothing,
        reason: 'A failed tool call is still a finished tool call.',
      );
    });

    testWidgets('the loader is shown while a tool call is in flight', (
      tester,
    ) async {
      final events = await pumpScreen(tester);

      await deliver(
        tester,
        events,
        ActionCompletedWithUndoWindow(
          'action undo-1',
          true,
          const Duration(seconds: 5),
        ),
      );
      await deliver(tester, events, ToolCallStarted('gesture', 1));

      // Guards the fix from over-correcting into "never show the loader".
      expect(find.byKey(skeleton), findsOneWidget);
    });

    testWidgets('the tool micro-copy still renders from the same run', (
      tester,
    ) async {
      final events = await pumpScreen(tester);

      for (final NoirUiEvent event in productionToolRunOrder(success: true)) {
        await deliver(tester, events, event);
      }

      // The loader fix must not cost the rows the earlier heartbeat wired.
      expect(find.text('Using gesture…'), findsOneWidget);
      expect(find.text('gesture completed.'), findsOneWidget);
    });
  });
}
