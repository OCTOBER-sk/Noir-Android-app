// test/ui/command_centre_assistant_stream_test.dart — the Command Centre drives
// a real assistant stream, and reports what actually happened to it.
//
// The screen owns the conversation (an injected ConversationController), but
// the assistant backend is injected as a plain delta stream. Whatever that
// stream does — nothing, fail, or run out of time under a cancel — the timeline
// says so, and nothing is ever fabricated to fill the gap.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_controller.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';

import 'fake_state_source.dart';

void main() {
  Finder composer() => find.byType(TextField);

  Future<void> tapSend(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> tapStop(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// The prompt is the only text the composer field is fed with.
  Future<void> compose(WidgetTester tester, String prompt) async {
    await tester.enterText(composer(), prompt);
    await tester.pump();
  }

  group('CommandCentreScreen assistant stream', () {
    testWidgets('an injected reply streams into the timeline row by row', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      final deltas = FakeStateSource<String>();
      final prompts = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            replyStream: (prompt) {
              prompts.add(prompt);
              return deltas.stream;
            },
          ),
        ),
      );

      await compose(tester, 'Clean up my inbox');
      await tapSend(tester);

      expect(prompts, ['Clean up my inbox']);
      expect(controller.messages, hasLength(2));
      expect(controller.messages.last.role, MessageRole.assistant);
      expect(controller.messages.last.isStreaming, isTrue);
      expect(controller.hasActiveStream, isTrue);
      // No delta has arrived yet, so the turn shows a loader and no text.
      expect(find.text('Two '), findsNothing);
      expect(find.text('Two steps done.'), findsNothing);

      deltas.emit('Two ');
      await tester.pump();
      expect(find.text('Two '), findsOneWidget);
      expect(find.byType(AnimatedBlinkingCaret), findsOneWidget);

      deltas.emit('steps done.');
      await tester.pump();
      expect(find.text('Two steps done.'), findsOneWidget);
      expect(find.text('Two '), findsNothing);
      expect(controller.hasActiveStream, isTrue);

      // The stream is ended, not awaited: a widget test body runs in the
      // binding's fake-async zone, where awaiting real stream delivery would
      // deadlock. The `done` event is delivered by the next pump.
      unawaited(deltas.close());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(controller.hasActiveStream, isFalse);
      expect(controller.messages.last.isStreaming, isFalse);
      expect(find.text('Two steps done.'), findsOneWidget);
      expect(find.byType(AnimatedBlinkingCaret), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
    });

    testWidgets('a stream that ends without content says so', (tester) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      // This body ends the stream itself, so it registers no teardown close
      // (see FakeStateSource.close).
      final deltas = FakeStateSource<String>();

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            replyStream: (prompt) => deltas.stream,
          ),
        ),
      );

      await compose(tester, 'ping');
      await tapSend(tester);
      // The stream is ended, not awaited: a widget test body runs in the
      // binding's fake-async zone, where awaiting real stream delivery would
      // deadlock. The `done` event is delivered by the next pump.
      unawaited(deltas.close());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('The assistant returned no content.'), findsOneWidget);
      expect(controller.hasActiveStream, isFalse);
    });

    testWidgets('a failing stream is reported and the stream is stopped', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      final deltas = FakeStateSource<String>();
      addTearDown(deltas.close);

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            replyStream: (prompt) => deltas.stream,
          ),
        ),
      );

      await compose(tester, 'ping');
      await tapSend(tester);
      deltas.emit('par');
      await tester.pump();

      deltas.fail(StateError('provider refused the request'));
      await tester.pump();

      expect(
        find.textContaining('The assistant stream failed'),
        findsOneWidget,
      );
      expect(
        find.textContaining('provider refused the request'),
        findsOneWidget,
      );
      expect(controller.hasActiveStream, isFalse);
      // Whatever was genuinely received is kept; nothing more is invented.
      expect(find.text('par'), findsOneWidget);
      expect(find.byType(AnimatedBlinkingCaret), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
    });

    testWidgets('a source that throws while being asked reports unavailable', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            replyStream: (prompt) => throw StateError('no route to provider'),
          ),
        ),
      );

      await compose(tester, 'ping');
      await tapSend(tester);

      expect(
        find.textContaining('The assistant stream failed'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(controller.hasActiveStream, isFalse);
    });

    testWidgets('cancelling an active stream stops it and says so', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      final deltas = FakeStateSource<String>();
      addTearDown(deltas.close);

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            replyStream: (prompt) => deltas.stream,
          ),
        ),
      );

      await compose(tester, 'ping');
      await tapSend(tester);
      deltas.emit('half a th');
      await tester.pump();

      await tapStop(tester);

      expect(
        find.text('Cancelled — the assistant stream was stopped.'),
        findsOneWidget,
      );
      expect(controller.hasActiveStream, isFalse);
      expect(find.text('half a th'), findsOneWidget);

      // A cancelled stream is really detached: later deltas change nothing.
      deltas.emit(' and some more');
      await tester.pump();

      expect(find.text('half a th'), findsOneWidget);
      expect(find.text('half a th and some more'), findsNothing);
    });

    testWidgets('a cancelled prompt leaves the composer ready for the next', (
      tester,
    ) async {
      final controller = ConversationController();
      addTearDown(controller.close);
      final deltas = FakeStateSource<String>();
      addTearDown(deltas.close);
      final prompts = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          home: CommandCentreScreen(
            controller: controller,
            replyStream: (prompt) {
              prompts.add(prompt);
              return deltas.stream;
            },
          ),
        ),
      );

      await compose(tester, 'first');
      await tapSend(tester);
      await tapStop(tester);

      await compose(tester, 'second');
      await tapSend(tester);

      expect(prompts, ['first', 'second']);
      expect(controller.messages, hasLength(4));
    });

    testWidgets(
      'no assistant source is reported as unavailable, not answered',
      (tester) async {
        final controller = ConversationController();
        addTearDown(controller.close);

        await tester.pumpWidget(
          MaterialApp(home: CommandCentreScreen(controller: controller)),
        );

        await compose(tester, 'ping');
        await tapSend(tester);

        expect(
          find.text(
            'No assistant backend is connected — nothing was generated.',
          ),
          findsOneWidget,
        );
        expect(controller.messages, hasLength(1));
        expect(controller.hasActiveStream, isFalse);
      },
    );

    testWidgets('a closed conversation reports instead of throwing', (
      tester,
    ) async {
      final controller = ConversationController();
      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(controller: controller)),
      );
      await controller.close();

      await compose(tester, 'ping');
      await tapSend(tester);

      expect(
        find.text('This conversation is closed — nothing was sent.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
