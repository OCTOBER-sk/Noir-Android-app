import 'dart:async';

import 'conversation_models.dart';

export 'conversation_models.dart';

class ConversationController {
  final List<ConversationMessage> _messages = <ConversationMessage>[];
  final StreamController<NoirUiEvent> _eventController =
      StreamController<NoirUiEvent>.broadcast();
  Future<void>? _closeFuture;
  int _userMessageCount = 0;
  int _assistantMessageCount = 0;
  String? _activeMessageId;

  List<ConversationMessage> get messages =>
      List<ConversationMessage>.unmodifiable(_messages);
  String? get activeMessageId => _activeMessageId;
  bool get hasActiveStream => _activeMessageId != null;
  bool get isClosed => _closeFuture != null;
  Stream<NoirUiEvent> get events => _eventController.stream;
  Stream<NoirUiEvent> get eventStream => _eventController.stream;

  ConversationMessage submitUserMessage(String text) {
    _ensureOpen();
    if (text.trim().isEmpty) {
      throw ArgumentError.value(
        text,
        'text',
        'User message must not be blank.',
      );
    }

    final message = ConversationMessage(
      id: _nextUserMessageId(),
      role: MessageRole.user,
      text: text,
    );
    _messages.add(message);
    _eventController.add(UserMessageSubmitted(message.id, message.text));
    return message;
  }

  String beginAssistantMessage() {
    _ensureOpen();
    if (hasActiveStream) {
      throw StateError('An assistant stream is already active.');
    }

    final messageId = _nextAssistantMessageId();
    _messages.add(
      ConversationMessage(
        id: messageId,
        role: MessageRole.assistant,
        isStreaming: true,
      ),
    );
    _activeMessageId = messageId;
    _eventController.add(AssistantMessageStarted(messageId));
    return messageId;
  }

  bool appendAssistantDelta(String messageId, String delta) {
    _ensureOpen();
    if (delta.trim().isEmpty) {
      return false;
    }

    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index < 0) {
      return false;
    }

    final message = _messages[index];
    if (message.role != MessageRole.assistant ||
        !message.isStreaming ||
        _activeMessageId != messageId) {
      return false;
    }

    final updatedMessage = message.copyWith(text: message.text + delta);
    _messages[index] = updatedMessage;
    _eventController.add(
      AssistantDeltaReceived(messageId, delta, updatedMessage.text),
    );
    return true;
  }

  void stopActiveStream() {
    final messageId = _activeMessageId;
    if (messageId == null) {
      return;
    }

    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index >= 0) {
      _messages[index] = _messages[index].copyWith(isStreaming: false);
    }
    _activeMessageId = null;
    _eventController.add(AssistantStreamStopped(messageId));
  }

  Future<void> close() {
    final closeFuture = _closeFuture;
    if (closeFuture != null) {
      return closeFuture;
    }

    stopActiveStream();
    final future = _eventController.close();
    _closeFuture = future;
    return future;
  }

  ConversationMessage? messageById(String messageId) {
    for (final message in _messages) {
      if (message.id == messageId) {
        return message;
      }
    }
    return null;
  }

  void _ensureOpen() {
    if (isClosed) {
      throw StateError('The conversation controller is closed.');
    }
  }

  String _nextUserMessageId() {
    _userMessageCount++;
    return 'user-$_userMessageCount';
  }

  String _nextAssistantMessageId() {
    _assistantMessageCount++;
    return 'assistant-$_assistantMessageCount';
  }
}
