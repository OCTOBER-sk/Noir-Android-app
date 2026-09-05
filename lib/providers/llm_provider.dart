import 'dart:async';

/// Model identifier constant for the OpenRouter free-tier poolside model.
///
/// Hardcoded model string only — the API key is never stored here; it is
/// injected at runtime via `--dart-define=OPENROUTER_API_KEY`.
const String openrouterPoolsideFree = 'poolside/laguna-s-2.1:free';

/// A single chat message exchanged with an LLM provider.
class ChatMessage {
  /// Sender role: `system`, `user`, or `assistant`.
  final String role;

  /// Message text content.
  final String content;

  /// Creates a new [ChatMessage].
  ChatMessage({required this.role, required this.content});
}

/// Token usage snapshot for a single provider request.
class Usage {
  /// Number of input (prompt) tokens consumed.
  final int inputTokens;

  /// Number of output (completion) tokens consumed.
  final int outputTokens;

  /// Cost in USD for this request. `0.0` for free tiers.
  final double costUsd;

  /// Wall-clock latency of the completed request.
  final Duration latency;

  /// Creates a new [Usage] record.
  Usage({
    required this.inputTokens,
    required this.outputTokens,
    required this.costUsd,
    required this.latency,
  });
}

/// Capabilities advertised by a provider adapter.
class LLMProviderCapabilities {
  /// Whether the provider supports streaming responses.
  final bool streaming;

  /// Whether the provider accepts vision/image inputs.
  final bool vision;

  /// Whether the provider supports tool/function calling.
  final bool toolUse;

  /// Maximum context window in tokens.
  final int contextWindow;

  /// Per-million-token input cost in USD.
  final double costPerMillionInput;

  /// Per-million-token output cost in USD.
  final double costPerMillionOutput;

  /// Creates a new [LLMProviderCapabilities].
  const LLMProviderCapabilities({
    required this.streaming,
    required this.vision,
    required this.toolUse,
    required this.contextWindow,
    required this.costPerMillionInput,
    required this.costPerMillionOutput,
  });
}

/// Abstract contract every LLM provider adapter must implement.
abstract class LLMProvider {
  /// Human-readable name of the provider.
  String get name;

  /// The model identifier served by this adapter.
  String get model;

  /// Capabilities advertised by this provider.
  LLMProviderCapabilities get capabilities;

  /// Streams chat completion text chunks for the given [messages].
  ///
  /// Each event is a single decoded text chunk emitted as the provider
  /// produces tokens. The stream closes when the provider signals completion.
  Stream<String> streamChat(List<ChatMessage> messages);
}
