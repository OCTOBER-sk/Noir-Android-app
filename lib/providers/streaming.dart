/// Incremental server-sent-events parsing and OpenAI-compatible decoding.
library;

import 'dart:convert';

import 'chat_types.dart';
import 'errors.dart';

/// One decoded SSE frame.
class SseEvent {
  const SseEvent({this.id, this.event, this.retry, required this.data});

  final String? id;
  final String? event;

  /// `retry:` field in milliseconds, when the provider sent a valid one.
  final int? retry;

  /// Frame payload; multi-line data fields are joined with `\n`.
  final String data;

  /// Whether this is the OpenAI-compatible end-of-stream sentinel.
  bool get isDone => data.trim() == '[DONE]';

  @override
  String toString() => 'SseEvent(event: $event, data: ${data.length} chars)';
}

/// Incremental SSE frame reader: feed it lines, it emits complete frames.
///
/// Handles CRLF, comment lines, unknown fields and multi-line `data:` payloads,
/// and tolerates a final frame that was never blank-line terminated.
class SseParser {
  SseParser(this.onEvent);

  final void Function(SseEvent event) onEvent;

  final List<String> _dataLines = <String>[];
  String? _id;
  String? _event;
  int? _retry;

  /// Feeds one line (without its terminator).
  void addLine(String line) {
    final String raw = line.endsWith('\r')
        ? line.substring(0, line.length - 1)
        : line;
    if (raw.isEmpty) {
      _dispatch();
      return;
    }
    if (raw.startsWith(':')) return; // comment / keep-alive
    final int colon = raw.indexOf(':');
    final String field = colon < 0 ? raw : raw.substring(0, colon);
    String value = colon < 0 ? '' : raw.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        _dataLines.add(value);
      case 'event':
        _event = value;
      case 'id':
        _id = value;
      case 'retry':
        final int? millis = int.tryParse(value.trim());
        if (millis != null && millis >= 0) _retry = millis;
    }
  }

  /// Emits a frame that was still buffered when the stream ended.
  void flush() => _dispatch();

  void _dispatch() {
    if (_dataLines.isEmpty) {
      _reset();
      return;
    }
    final SseEvent event = SseEvent(
      id: _id,
      event: _event,
      retry: _retry,
      data: _dataLines.join('\n'),
    );
    _reset();
    onEvent(event);
  }

  void _reset() {
    _dataLines.clear();
    _id = null;
    _event = null;
    _retry = null;
  }
}

/// Base class for everything [ChatStreamDecoder] can emit.
abstract class ProviderStreamEvent {
  const ProviderStreamEvent();
}

/// An incremental piece of assistant text.
class ProviderTextDelta extends ProviderStreamEvent {
  const ProviderTextDelta(this.text, {this.index = 0});

  final String text;

  /// Choice index the delta belongs to.
  final int index;

  @override
  String toString() => 'ProviderTextDelta($index: ${text.length} chars)';
}

/// Provider-reported usage for the whole request.
class ProviderUsage extends ProviderStreamEvent {
  const ProviderUsage(this.usage);

  final TokenUsage usage;

  @override
  String toString() => 'ProviderUsage($usage)';
}

/// The terminal success event; always the last event of a stream.
class ProviderCompleted extends ProviderStreamEvent {
  const ProviderCompleted(this.completion);

  /// Completion with all deltas joined and the finish reason applied.
  final ChatCompletion completion;

  @override
  String toString() => 'ProviderCompleted(${completion.model})';
}

/// The terminal failure event; always the last event of a stream.
class ProviderFailed extends ProviderStreamEvent {
  const ProviderFailed(this.error);

  final ProviderException error;

  @override
  String toString() => 'ProviderFailed(${error.kind})';
}

/// Decodes OpenAI-compatible SSE frames into [ProviderStreamEvent]s.
///
/// The decoder is incremental and frame-at-a-time: the caller owns subscription
/// lifetime, cancellation and deadlines, so a stalled stream is handled
/// outside the parser.
class ChatStreamDecoder {
  final StringBuffer _content = StringBuffer();
  String? _id;
  String? _model;
  String? _finishReason;
  TokenUsage? _usage;
  bool _sawFrame = false;
  bool _failed = false;

  /// Whether at least one JSON frame decoded successfully.
  bool get sawFrame => _sawFrame;

  /// Text accumulated from every delta so far.
  String get content => _content.toString();

  /// Completion built from the accumulated state.
  ChatCompletion completion() => ChatCompletion(
    id: _id ?? '',
    model: _model ?? '',
    content: _content.toString(),
    finishReason: _finishReason,
    usage: _usage,
  );

  /// Decodes one frame. Returns the events to emit; a [ProviderFailed] result
  /// is terminal and further frames are ignored.
  List<ProviderStreamEvent> add(SseEvent frame) {
    if (_failed) return const <ProviderStreamEvent>[];
    if (frame.isDone) return const <ProviderStreamEvent>[];

    final Object? decoded;
    try {
      decoded = jsonDecode(frame.data);
    } on FormatException catch (error) {
      _failed = true;
      return <ProviderStreamEvent>[
        ProviderFailed(
          ProviderException.malformed(
            'unparsable SSE payload: ${error.message}',
            body: frame.data,
          ),
        ),
      ];
    }
    if (decoded is! Map) {
      _failed = true;
      return <ProviderStreamEvent>[
        ProviderFailed(
          ProviderException.malformed(
            'SSE payload was not a JSON object',
            body: frame.data,
          ),
        ),
      ];
    }
    final Map<String, dynamic> payload = Map<String, dynamic>.from(decoded);
    _sawFrame = true;

    final Object? error = payload['error'];
    if (error != null) {
      _failed = true;
      return <ProviderStreamEvent>[ProviderFailed(_inBandError(error))];
    }

    final List<ProviderStreamEvent> events = <ProviderStreamEvent>[];
    final Object? id = payload['id'];
    if (id is String && id.isNotEmpty) _id = id;
    final Object? model = payload['model'];
    if (model is String && model.isNotEmpty) _model = model;

    final Object? rawUsage = payload['usage'];
    if (rawUsage != null) {
      try {
        final TokenUsage usage = TokenUsage.fromJson(rawUsage);
        _usage = usage;
        events.add(ProviderUsage(usage));
      } on ProviderException catch (error) {
        _failed = true;
        events.add(ProviderFailed(error));
        return events;
      }
    }

    final Object? choices = payload['choices'];
    if (choices != null && choices is! List) {
      _failed = true;
      events.add(
        ProviderFailed(
          ProviderException.malformed(
            'SSE "choices" was not a list',
            body: frame.data,
          ),
        ),
      );
      return events;
    }

    final List<Object?> choiceList = choices is List
        ? choices
        : const <Object?>[];
    for (final Object? choice in choiceList) {
      if (choice is! Map) continue;
      final Object? index = choice['index'];
      final int choiceIndex = index is int ? index : 0;
      final Object? finishReason = choice['finish_reason'];
      if (finishReason is String && finishReason.isNotEmpty) {
        _finishReason = finishReason;
      }
      final Object? delta = choice['delta'] ?? choice['message'];
      if (delta is! Map) continue;
      final Object? text = delta['content'];
      if (text is! String || text.isEmpty) continue;
      _content.write(text);
      events.add(ProviderTextDelta(text, index: choiceIndex));
    }
    return events;
  }

  static ProviderException _inBandError(Object raw) {
    final Map<String, dynamic> detail = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{'message': raw.toString()};
    final String message =
        (detail['message'] ?? detail['error'] ?? 'provider reported an error')
            .toString();
    final String marker =
        '${detail['code'] ?? ''} ${detail['type'] ?? ''} $message'
            .toLowerCase();
    final ProviderErrorKind kind;
    if (marker.contains('rate limit') ||
        marker.contains('rate_limit') ||
        marker.contains('429')) {
      kind = ProviderErrorKind.rateLimit;
    } else if (marker.contains('context length') ||
        marker.contains('too long')) {
      kind = ProviderErrorKind.malformed;
    } else if (marker.contains('unauthorized') ||
        marker.contains('api key') ||
        marker.contains('auth')) {
      kind = ProviderErrorKind.auth;
    } else {
      kind = ProviderErrorKind.unknown;
    }
    return ProviderException(kind: kind, message: message);
  }
}
