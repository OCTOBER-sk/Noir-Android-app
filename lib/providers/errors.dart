/// Typed failure surface for every provider call.
///
/// Nothing in the provider layer throws a bare `Exception`: callers can always
/// branch on [ProviderErrorKind] instead of string-matching.
library;

/// Classification of a provider failure.
enum ProviderErrorKind {
  /// Missing/rejected credentials (HTTP 401/403).
  auth,

  /// Provider asked the caller to slow down (HTTP 429).
  rateLimit,

  /// Socket, DNS or transport level failure; no HTTP response was seen.
  network,

  /// A response arrived but could not be understood (bad JSON, bad shape).
  malformed,

  /// The caller cancelled the request.
  cancelled,

  /// No response, no progress, or the overall deadline elapsed.
  timeout,

  /// The requested resource does not exist (HTTP 404).
  notFound,

  /// Provider-side failure (HTTP 5xx).
  server,

  /// Anything that does not fit a more specific kind.
  unknown,
}

/// A provider failure with a machine-readable [kind].
class ProviderException implements Exception {
  ProviderException({
    required this.kind,
    required this.message,
    this.statusCode,
    this.retryAfter,
    this.body,
  });

  /// HTTP response body excerpt, truncated to [maxBodyChars].
  static const int maxBodyChars = 128;

  final ProviderErrorKind kind;
  final String message;
  final int? statusCode;

  /// Server-requested delay (parsed from `Retry-After`, seconds form only).
  final Duration? retryAfter;

  /// Truncated response body, when one was read. Never a full payload.
  final String? body;

  /// Whether a bounded retry is meaningful for this failure.
  bool get isTransient =>
      kind == ProviderErrorKind.network ||
      kind == ProviderErrorKind.timeout ||
      kind == ProviderErrorKind.server ||
      kind == ProviderErrorKind.rateLimit;

  /// True when the failure was caused by the caller cancelling.
  bool get isCancellation => kind == ProviderErrorKind.cancelled;

  /// Builds a typed error from an HTTP status code and response headers.
  factory ProviderException.fromStatus(
    int statusCode, {
    String? body,
    Map<String, String> headers = const <String, String>{},
  }) {
    final ProviderErrorKind kind;
    if (statusCode == 401 || statusCode == 403) {
      kind = ProviderErrorKind.auth;
    } else if (statusCode == 429) {
      kind = ProviderErrorKind.rateLimit;
    } else if (statusCode == 404) {
      kind = ProviderErrorKind.notFound;
    } else if (statusCode >= 500) {
      kind = ProviderErrorKind.server;
    } else if (statusCode >= 400) {
      kind = ProviderErrorKind.malformed;
    } else {
      kind = ProviderErrorKind.unknown;
    }
    return ProviderException(
      kind: kind,
      message: 'provider responded with HTTP $statusCode',
      statusCode: statusCode,
      retryAfter: parseRetryAfter(headers),
      body: _truncate(body),
    );
  }

  /// Wraps an arbitrary throwable from a transport or stream.
  factory ProviderException.from(Object error) {
    if (error is ProviderException) return error;
    if (error is FormatException) {
      return ProviderException.malformed(
        'unparsable payload: ${error.message}',
      );
    }
    return ProviderException.network('transport failure: $error');
  }

  /// The caller cancelled the request.
  factory ProviderException.cancelled([Object? reason]) => ProviderException(
    kind: ProviderErrorKind.cancelled,
    message: reason == null
        ? 'request cancelled'
        : 'request cancelled: $reason',
  );

  /// No response, no progress, or deadline elapsed.
  factory ProviderException.timeout(String message) =>
      ProviderException(kind: ProviderErrorKind.timeout, message: message);

  /// A response arrived but could not be understood.
  factory ProviderException.malformed(String message, {String? body}) =>
      ProviderException(
        kind: ProviderErrorKind.malformed,
        message: message,
        body: _truncate(body),
      );

  /// Socket/DNS/transport failure.
  factory ProviderException.network(String message) =>
      ProviderException(kind: ProviderErrorKind.network, message: message);

  /// Reads a `Retry-After` header in its seconds form. HTTP-date form is
  /// ignored on purpose: a bogus delay is worse than the computed backoff.
  static Duration? parseRetryAfter(Map<String, String> headers) {
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() != 'retry-after') continue;
      final int? seconds = int.tryParse(entry.value.trim());
      if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    }
    return null;
  }

  static String? _truncate(String? body) {
    if (body == null) return null;
    if (body.length <= maxBodyChars) return body;
    return '${body.substring(0, maxBodyChars)}…';
  }

  @override
  String toString() =>
      'ProviderException($kind, status: $statusCode): $message';
}
