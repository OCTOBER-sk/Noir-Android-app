import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_controller.dart';

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  group('ConversationController', () {
    test('submits a user message without generating assistant text', () {
      final controller = ConversationController();
      addTearDown(controller.close);

      final message = controller.submitUserMessage('Hello');

      expect(message.id, 'user-1');
      expect(message.role, MessageRole.user);
      expect(message.text, 'Hello');
      expect(message.isStreaming, isFalse);
      expect(controller.messages, hasLength(1));
      expect(controller.messages.single, same(message));
      expect(controller.hasActiveStream, isFalse);
    });

    test('rejects blank user input', () {
      final controller = ConversationController();
      addTearDown(controller.close);

      expect(() => controller.submitUserMessage(' \t\n'), throwsArgumentError);
      expect(controller.messages, isEmpty);
    });

    test('aggregates assistant deltas by message ID', () {
      final controller = ConversationController();
      addTearDown(controller.close);
      final firstMessageId = controller.beginAssistantMessage();

      expect(controller.appendAssistantDelta(firstMessageId, 'Hel'), isTrue);
      expect(controller.appendAssistantDelta(firstMessageId, 'lo'), isTrue);
      controller.stopActiveStream();

      final secondMessageId = controller.beginAssistantMessage();
      expect(controller.appendAssistantDelta(secondMessageId, 'New'), isTrue);
      expect(
        controller.appendAssistantDelta(secondMessageId, ' reply'),
        isTrue,
      );

      expect(controller.messageById(firstMessageId)!.text, 'Hello');
      expect(controller.messageById(secondMessageId)!.text, 'New reply');
      expect(controller.messageById(firstMessageId)!.isStreaming, isFalse);
      expect(controller.messageById(secondMessageId)!.isStreaming, isTrue);
    });

    test('rejects blank assistant deltas', () {
      final controller = ConversationController();
      addTearDown(controller.close);
      final messageId = controller.beginAssistantMessage();

      expect(controller.appendAssistantDelta(messageId, ' \n\t'), isFalse);
      expect(controller.messageById(messageId)!.text, isEmpty);
    });

    test('stopping the active stream is idempotent and terminal', () async {
      final controller = ConversationController();
      addTearDown(controller.close);
      final events = <NoirUiEvent>[];
      final subscription = controller.events.listen(events.add);
      final messageId = controller.beginAssistantMessage();
      controller.appendAssistantDelta(messageId, 'partial');

      controller.stopActiveStream();
      controller.stopActiveStream();
      await flushEvents();

      expect(controller.hasActiveStream, isFalse);
      expect(controller.messageById(messageId)!.isStreaming, isFalse);
      expect(controller.appendAssistantDelta(messageId, ' late'), isFalse);
      expect(controller.messageById(messageId)!.text, 'partial');
      expect(events, hasLength(3));
      expect(events.last, isA<AssistantStreamStopped>());
      expect((events.last as AssistantStreamStopped).messageId, messageId);

      await subscription.cancel();
    });

    test('broadcasts events asynchronously in operation order', () async {
      final controller = ConversationController();
      addTearDown(controller.close);
      final events = <NoirUiEvent>[];
      final subscription = controller.events.listen(events.add);

      final userMessage = controller.submitUserMessage('Question');
      final assistantMessageId = controller.beginAssistantMessage();
      controller.appendAssistantDelta(assistantMessageId, 'Answer');
      controller.stopActiveStream();

      expect(controller.events.isBroadcast, isTrue);
      expect(events, isEmpty);
      await flushEvents();
      expect(events, [
        isA<UserMessageSubmitted>(),
        isA<AssistantMessageStarted>(),
        isA<AssistantDeltaReceived>(),
        isA<AssistantStreamStopped>(),
      ]);
      expect((events[0] as UserMessageSubmitted).messageId, userMessage.id);
      expect(
        (events[1] as AssistantMessageStarted).messageId,
        assistantMessageId,
      );

      await subscription.cancel();
    });

    test('closing terminates an active stream and closes events', () async {
      final controller = ConversationController();
      final events = <NoirUiEvent>[];
      var isDone = false;
      final subscription = controller.events.listen(
        events.add,
        onDone: () {
          isDone = true;
        },
      );
      final messageId = controller.beginAssistantMessage();

      await controller.close();

      expect(isDone, isTrue);
      expect(controller.isClosed, isTrue);
      expect(controller.hasActiveStream, isFalse);
      expect(controller.messageById(messageId)!.isStreaming, isFalse);
      expect(events.whereType<AssistantStreamStopped>(), hasLength(1));
      await subscription.cancel();
    });
  });
}
