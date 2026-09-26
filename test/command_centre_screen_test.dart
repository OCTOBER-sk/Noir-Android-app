import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_controller.dart';
import 'package:noir_android_app/providers/usage_tracker.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

void main() {
  Finder composer() => find.byType(TextField);

  String composerText(WidgetTester tester) =>
      tester.widget<TextField>(composer()).controller?.text ?? '';

  Finder actionButton(IconData icon) =>
      find.ancestor(of: find.byIcon(icon), matching: find.byType(InkWell));

  VoidCallback? actionHandler(WidgetTester tester, IconData icon) =>
      tester.widget<InkWell>(actionButton(icon)).onTap;

  /// The header "Streaming…" indicator is only opaque while a stream is real.
  double headerStreamOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.text('Streaming…'),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  Future<void> tapAction(WidgetTester tester, IconData icon) async {
    await tester.tap(find.byIcon(icon));
    // The controller broadcasts asynchronously, so drain the microtask queue
    // and rebuild before asserting.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  group('CommandCentreScreen', () {
    testWidgets('starts empty with no fabricated conversation content', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: CommandCentreScreen()));

      expect(find.text('Noir Command Centre'), findsOneWidget);
      expect(find.text('Auto-tasks'), findsOneWidget);
      expect(headerStreamOpacity(tester), 0.0);
      expect(actionHandler(tester, Icons.arrow_upward_rounded), isNull);
    });

    testWidgets('disables the send action until text is composed', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: CommandCentreScreen()));

      expect(actionHandler(tester, Icons.arrow_upward_rounded), isNull);

      await tester.enterText(composer(), '   ');
      await tester.pump();

      expect(actionHandler(tester, Icons.arrow_upward_rounded), isNull);

      await tester.enterText(composer(), 'Summarise my tasks');
      await tester.pump();

      expect(actionHandler(tester, Icons.arrow_upward_rounded), isNotNull);
    });

    testWidgets('quick-action chips fill the real composer', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CommandCentreScreen()));

      await tester.tap(find.text('Auto-tasks'));
      await tester.pump();

      expect(composerText(tester), 'Summarise today\'s automation tasks.');
      expect(actionHandler(tester, Icons.arrow_upward_rounded), isNotNull);

      await tester.enterText(composer(), '');
      await tester.pump();
      await tester.tap(find.text('Safety checks'));
      await tester.pump();

      expect(composerText(tester), 'Run the safety checks before acting.');
    });

    testWidgets('sending without a backend records the user turn only', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(controller: controller)),
      );

      await tester.enterText(composer(), 'Run the safety checks');
      await tester.pump();
      await tapAction(tester, Icons.arrow_upward_rounded);

      expect(find.text('Run the safety checks'), findsOneWidget);
      expect(
        find.text('No assistant backend is connected — nothing was generated.'),
        findsOneWidget,
      );
      expect(controller.messages, hasLength(1));
      expect(controller.messages.single.role, MessageRole.user);
      expect(controller.hasActiveStream, isFalse);
      expect(composerText(tester), isEmpty);
      expect(actionHandler(tester, Icons.arrow_upward_rounded), isNull);
    });

    testWidgets('the no-backend note follows the turn it describes', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(controller: controller)),
      );

      await tester.enterText(composer(), 'ping');
      await tester.pump();
      await tapAction(tester, Icons.arrow_upward_rounded);

      expect(find.text('ping'), findsOneWidget);
      expect(
        find.text('No assistant backend is connected — nothing was generated.'),
        findsOneWidget,
      );
      final user = tester.getTopLeft(find.text('ping'));
      final note = tester.getTopLeft(
        find.text('No assistant backend is connected — nothing was generated.'),
      );
      expect(note.dy, greaterThan(user.dy));
    });

    testWidgets('an injected responder streams assistant text and can stop', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      final prompts = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            responder: (prompt, conversation) {
              prompts.add(prompt);
              final messageId = conversation.beginAssistantMessage();
              conversation.appendAssistantDelta(messageId, 'Two ');
              conversation.appendAssistantDelta(messageId, 'steps done.');
            },
          ),
        ),
      );

      await tester.enterText(composer(), 'Clean up my inbox');
      await tester.pump();
      await tapAction(tester, Icons.arrow_upward_rounded);

      expect(prompts, ['Clean up my inbox']);
      expect(find.text('Two steps done.'), findsOneWidget);
      expect(controller.messages, hasLength(2));
      expect(controller.messages.last.role, MessageRole.assistant);
      expect(controller.hasActiveStream, isTrue);
      expect(find.byType(AnimatedBlinkingCaret), findsOneWidget);
      expect(headerStreamOpacity(tester), 1.0);

      await tapAction(tester, Icons.stop_rounded);

      expect(controller.hasActiveStream, isFalse);
      expect(controller.messages.last.isStreaming, isFalse);
      expect(find.byType(AnimatedBlinkingCaret), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
      expect(find.text('Two steps done.'), findsOneWidget);
    });

    testWidgets('an owned controller is released when the screen unmounts', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: CommandCentreScreen()));

      await tester.enterText(composer(), 'ping');
      await tester.pump();
      await tapAction(tester, Icons.arrow_upward_rounded);
      expect(find.text('ping'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(home: SizedBox.shrink()),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('header usage reflects a real tracker or reports idle', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: CommandCentreScreen()));
      expect(find.text('Usage idle'), findsOneWidget);

      final usage = UsageTracker()..record(tokens: 128);
      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(usage: usage)),
      );

      expect(find.text('in 0  out 128'), findsOneWidget);
    });

    testWidgets('swapping controllers closes only the one the screen owned', (
      tester,
    ) async {
      // The responder hands back the very controller the screen is bound to,
      // so the screen-owned instance is observable from the test.
      ConversationController? owned;
      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            responder: (prompt, conversation) => owned = conversation,
          ),
        ),
      );

      await tester.enterText(composer(), 'ping');
      await tester.pump();
      await tapAction(tester, Icons.arrow_upward_rounded);

      expect(owned, isNotNull);
      expect(owned!.isClosed, isFalse);

      final injected = ConversationController();
      addTearDown(injected.close);
      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(controller: injected)),
      );

      expect(owned!.isClosed, isTrue);
      expect(injected.isClosed, isFalse);

      // The replaced controller no longer drives the screen.
      injected.submitUserMessage('from the new controller');
      await tester.pump();
      expect(find.text('from the new controller'), findsOneWidget);
      expect(find.text('ping'), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(home: SizedBox.shrink()),
      );

      // An injected controller is never closed by the screen, on swap or on
      // unmount: the test's own teardown owns it.
      expect(injected.isClosed, isFalse);
    });
  });
}
