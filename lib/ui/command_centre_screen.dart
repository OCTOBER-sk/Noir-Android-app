import 'package:flutter/material.dart';
import 'package:noir_android_app/core/constants.dart';
import 'package:noir_android_app/ui/message_bubble.dart';
import 'package:noir_android_app/ui/token_counter.dart';

/// A simple monochrome in-memory chat message used by the Command Centre.
class ChatMessage {
  /// Sender role: `user` or `assistant`.
  final String role;

  /// Message text.
  final String content;

  /// Creates a new [ChatMessage].
  ChatMessage({required this.role, required this.content});
}

/// The ChatGPT-style Command Centre shell (V2.1 §D2 thin).
///
/// Renders a scrolling message list plus a monochrome input bar at the
/// bottom. Only the seven allowed Noir colors are used — zero color accents.
class CommandCentreScreen extends StatefulWidget {
  /// Optional callback invoked when a user message is sent.
  final void Function(String text)? onSendMessage;

  /// Creates a new [CommandCentreScreen].
  const CommandCentreScreen({super.key, this.onSendMessage});

  @override
  State<CommandCentreScreen> createState() => _CommandCentreScreenState();
}

class _CommandCentreScreenState extends State<CommandCentreScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
    });
    _controller.clear();
    widget.onSendMessage?.call(text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NoirColors.black,
      body: Column(
        children: [
          const SizedBox(height: 8),
          const TokenCounter(inputTokens: 0, outputTokens: 0, costUsd: 0.0),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              reverse: true,
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return MessageBubble(role: msg.role, content: msg.content);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(color: NoirColors.white),
                    decoration: InputDecoration(
                      hintText: 'Ask Noir anything...',
                      hintStyle: TextStyle(color: NoirColors.gray400),
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: NoirColors.gray900,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  color: NoirColors.gray200,
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
