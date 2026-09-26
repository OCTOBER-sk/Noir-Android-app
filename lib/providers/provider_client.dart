/// Shared request execution: bounded retry, deadlines, typed status mapping.
///
/// Both the chat adapter and model discovery run through this class so retry,
/// backoff and error mapping behave identically for every call.
library;

import 'dart:async';

import 'cancellation.dart';
import 'chat_types.dart';
import 'errors.dart';
import 'transport.dart';

/// Executes provider requests with retry, backoff and timeouts applied.
class ProviderHttpClient {
  ProviderHttpClient({
    required this.transport,
    this.retry = const RetryPolicy(),
    this.timeouts = const ProviderTimeouts(),
    Sleeper? sleep,
  }) : sleep = sleep ?? _defaultSleep;

  final ProviderTransport transport;
  final RetryPolicy retry;
  final ProviderTimeouts timeouts;
  final Sleeper sleep;

  /// Sends [request] and returns the response once it is known to be
  /// successful. Non-2xx responses are converted into [ProviderException]s.
  Future<TransportResponse> sendSuccess({
    required ProviderRequest request,
    CancellationToken? cancellation,
  }) async {
    ProviderException? lastError;
    for (int attempt = 1; attempt <= retry.maxAttempts; attempt++) {
      cancellation?.throwIfCancelled();
      final bool lastAttempt = attempt >= retry.maxAttempts;
      TransportResponse response;
      try {
        response = await transport
            .send(request, cancellation: cancellation)
            .timeout(timeouts.firstByte);
      } on Object catch (error) {
        final ProviderException failure = ProviderException.from(error);
        if (lastAttempt || !failure.isTransient) throw failure;
        lastError = failure;
        await _backoff(attempt, failure, cancellation);
        continue;
      }
      cancellation?.throwIfCancelled();
      if (response.isSuccess) return response;
      final String body = await _readErrorBody(response, cancellation);
      final ProviderException failure = statusError(response, body);
      if (lastAttempt || !failure.isTransient) throw failure;
      lastError = failure;
      await _backoff(attempt, failure, cancellation);
    }
    throw lastError ??
        ProviderException(
          kind: ProviderErrorKind.unknown,
          message: 'no attempt made',
        );
  }

  /// Sends [request] and returns the whole response body as text.
  Future<String> sendText({
    required ProviderRequest request,
    CancellationToken? cancellation,
  }) async {
    final TransportResponse response = await sendSuccess(
      request: request,
      cancellation: cancellation,
    );
    return _readBodyText(response, cancellation);
  }

  /// Maps a non-2xx response onto a typed error, using [body] as an excerpt.
  ProviderException statusError(TransportResponse response, String body) =>
      ProviderException.fromStatus(
        response.statusCode,
        body: body,
        headers: response.headers,
      );

  Future<String> _readErrorBody(
    TransportResponse response,
    CancellationToken? cancellation,
  ) async {
    try {
      return await _readBodyText(response, cancellation);
    } on ProviderException {
      return '';
    }
  }

  Future<String> _readBodyText(
    TransportResponse response,
    CancellationToken? cancellation,
  ) {
    final Duration deadline = timeouts.overall ?? timeouts.idle;
    cancellation?.throwIfCancelled();
    return response
        .readText()
        .timeout(
          deadline,
          onTimeout: () => throw ProviderException.timeout(
            'response body stalled for more than $deadline',
          ),
        )
        .then((String text) {
          cancellation?.throwIfCancelled();
          return text;
        });
  }

  Future<void> _backoff(
    int attempt,
    ProviderException failure,
    CancellationToken? cancellation,
  ) async {
    Duration delay = retry.backoffFor(attempt);
    final Duration? requested = failure.retryAfter;
    if (requested != null && requested > delay) delay = requested;
    await sleep(delay);
    cancellation?.throwIfCancelled();
  }

  static Future<void> _defaultSleep(Duration duration) =>
      Future<void>.delayed(duration);
}
