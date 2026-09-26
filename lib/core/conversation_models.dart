export 'ui_state_contract.dart'
    show
        AssistantDeltaReceived,
        AssistantMessageStarted,
        AssistantStreamStopped,
        NoirUiEvent,
        UserMessageSubmitted;

enum MessageRole { user, assistant }

class ConversationMessage {
  final String id;
  final MessageRole role;
  final String text;
  final bool isStreaming;

  const ConversationMessage({
    required this.id,
    required this.role,
    this.text = '',
    this.isStreaming = false,
  });

  String get content => text;

  ConversationMessage copyWith({
    String? id,
    MessageRole? role,
    String? text,
    bool? isStreaming,
  }) {
    return ConversationMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      text: text ?? this.text,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
}
