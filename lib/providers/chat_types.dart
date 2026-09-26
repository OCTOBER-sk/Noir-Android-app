/// OpenAI-compatible request/response types plus retry and timeout policy.
library;

import 'errors.dart';

/// Chat roles used on the wire.
enum ChatRole {
  system('system'),
  user('user'),
  assistant('assistant'),
  tool('tool');

  const ChatRole(this.wireValue);

  final String wireValue;
}

/// One chat message.
class ChatMessage {
  ChatMessage(this.role, this.content, {this.name});

  final ChatRole role;
  final String content;

  /// Optional participant name for tool/function messages.
  final String? name;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': role.wireValue,
    'content': content,
    if (name != null) 'name': name,
  };
}

/// A chat completion request.
///
/// Only the fields the app sets are serialised, so providers never see keys
/// they do not understand.
class ChatRequest {
  ChatRequest({
    required this.model,
    required this.messages,
    this.temperature,
    this.maxTokens,
    this.topP,
    this.stop,
    this.includeUsage = true,
    this.extra = const <String, dynamic>{},
  }) {
    if (model.trim().isEmpty) {
      throw ArgumentError.value(model, 'model', 'must not be blank');
    }
    if (messages.isEmpty) {
      throw ArgumentError.value(messages, 'messages', 'must not be empty');
    }
  }

  final String model;
  final List<ChatMessage> messages;
  final double? temperature;
  final int? maxTokens;
  final double? topP;
  final List<String>? stop;

  /// Ask streaming providers to include a final `usage` block.
  final bool includeUsage;

  /// Escape hatch for provider-specific keys; overrides nothing above.
  final Map<String, dynamic> extra;

  /// Wire body for this request.
  Map<String, dynamic> toJson({required bool stream}) => <String, dynamic>{
    'model': model,
    'messages': messages
        .map((ChatMessage m) => m.toJson())
        .toList(growable: false),
    if (temperature != null) 'temperature': temperature,
    if (maxTokens != null) 'max_tokens': maxTokens,
    if (topP != null) 'top_p': topP,
    if (stop != null) 'stop': stop,
    'stream': stream,
    if (stream && includeUsage)
      'stream_options': <String, dynamic>{'include_usage': true},
    ...extra,
  };

  /// Copy with a different [model] (used by fallback chains).
  ChatRequest copyWith({String? model}) => ChatRequest(
    model: model ?? this.model,
    messages: messages,
    temperature: temperature,
    maxTokens: maxTokens,
    topP: topP,
    stop: stop,
    includeUsage: includeUsage,
    extra: extra,
  );
}

/// Token counts reported by the provider for one request.
///
/// Only ever built from a real `usage` block; nothing here is estimated.
class TokenUsage {
  TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    int? totalTokens,
  }) : totalTokens = totalTokens ?? promptTokens + completionTokens {
    if (promptTokens < 0 || completionTokens < 0) {
      throw ArgumentError('token counts must not be negative');
    }
    if (this.totalTokens < 0) {
      throw ArgumentError('total token count must not be negative');
    }
  }

  /// Parses a provider `usage` object, tolerating numeric strings.
  factory TokenUsage.fromJson(Object? json) {
    if (json is! Map) {
      throw ProviderException.malformed('usage block was not an object');
    }
    try {
      final Object? total = json['total_tokens'];
      return TokenUsage(
        promptTokens: _count(json['prompt_tokens']),
        completionTokens: _count(json['completion_tokens']),
        totalTokens: total == null ? null : _count(total),
      );
    } on ArgumentError catch (error) {
      throw ProviderException.malformed(
        'invalid usage block: ${error.message}',
      );
    }
  }

  /// Tokens attributed to the prompt.
  final int promptTokens;

  /// Tokens the model produced.
  final int completionTokens;

  /// Provider total, or the sum of both counts when it was omitted.
  final int totalTokens;

  static int _count(Object? value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    if (value is String) {
      final int? parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    throw ArgumentError('token count "$value" is not a non-negative integer');
  }

  /// Wire form of this usage block.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
  };

  @override
  String toString() =>
      'TokenUsage(prompt: $promptTokens, completion: $completionTokens, '
      'total: $totalTokens)';
}

/// A finished (non-streamed) chat completion.
class ChatCompletion {
  const ChatCompletion({
    required this.id,
    required this.model,
    required this.content,
    this.finishReason,
    this.usage,
  });

  /// Parses a provider chat completion body.
  factory ChatCompletion.fromJson(Map<String, dynamic> json) {
    final Object? choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw ProviderException.malformed('response contained no choices');
    }
    final Object? first = choices.first;
    if (first is! Map) {
      throw ProviderException.malformed('first choice was not an object');
    }
    final Object? message = first['message'] ?? first['delta'];
    String content = '';
    if (message is Map) {
      final Object? text = message['content'];
      if (text is String) content = text;
    }
    final Object? finishReason = first['finish_reason'];
    final Object? rawUsage = json['usage'];
    return ChatCompletion(
      id: json['id'] is String ? json['id']! as String : '',
      model: json['model'] is String ? json['model']! as String : '',
      content: content,
      finishReason: finishReason is String ? finishReason : null,
      usage: rawUsage == null ? null : TokenUsage.fromJson(rawUsage),
    );
  }

  final String id;
  final String model;
  final String content;
  final String? finishReason;

  /// Provider-reported usage, or `null` when the response carried none.
  final TokenUsage? usage;

  @override
  String toString() =>
      'ChatCompletion($model, finish: $finishReason, usage: $usage)';
}

/// Bounded retry with exponential backoff.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 250),
    this.multiplier = 2,
    this.maxBackoff = const Duration(seconds: 8),
  });

  /// Policy that performs exactly one attempt.
  static const RetryPolicy none = RetryPolicy(maxAttempts: 1);

  /// Total attempts, including the first one.
  final int maxAttempts;
  final Duration initialBackoff;
  final double multiplier;
  final Duration maxBackoff;

  /// Backoff before retry number [attempt] (1 = after the first failure).
  Duration backoffFor(int attempt) {
    if (attempt < 1) return Duration.zero;
    final double scaled =
        initialBackoff.inMilliseconds * _pow(multiplier, attempt - 1);
    final int capped = scaled.isFinite && scaled < maxBackoff.inMilliseconds
        ? scaled.round()
        : maxBackoff.inMilliseconds;
    return Duration(milliseconds: capped < 0 ? 0 : capped);
  }

  static double _pow(double base, int exponent) {
    double result = 1;
    for (int i = 0; i < exponent; i++) {
      result *= base;
    }
    return result;
  }
}

/// Sleeps for [duration]. Injected so tests never wait for real backoff.
typedef Sleeper = Future<void> Function(Duration duration);

/// Deadlines applied to a single attempt.
class ProviderTimeouts {
  const ProviderTimeouts({
    this.firstByte = const Duration(seconds: 30),
    this.idle = const Duration(seconds: 60),
    this.overall,
  });

  /// Time allowed for response headers.
  final Duration firstByte;

  /// Longest allowed gap between streamed chunks.
  final Duration idle;

  /// Optional wall-clock ceiling for a whole attempt.
  final Duration? overall;
}
