import 'package:flutter/material.dart';
import 'package:noir_android_app/core/constants.dart';

/// A ChatGPT-style message bubble that is role-aware and monochrome.
///
/// User messages render white-on-black aligned to the right; assistant
/// messages render black-on-white-gray aligned to the left.
class MessageBubble extends StatelessWidget {
  /// The sender role: `user` or `assistant`.
  final String role;

  /// The message text to display.
  final String content;

  /// Creates a new [MessageBubble].
  const MessageBubble({
    super.key,
    required this.role,
    required this.content,
  });

  /// Whether this bubble represents the user (vs. the assistant).
  bool get isUser => role == 'user';

  @override
  Widget build(BuildContext context) {
    final alignment = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bg = isUser ? NoirColors.black : NoirColors.gray800;
    final fg = isUser ? NoirColors.white : NoirColors.black;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(12),
      topRight: const Radius.circular(12),
      bottomLeft: isUser ? const Radius.circular(12) : Radius.zero,
      bottomRight: isUser ? Radius.zero : const Radius.circular(12),
    );
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 240),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Text(
          content,
          style: TextStyle(color: fg, fontSize: 14),
        ),
      ),
    );
  }
}
