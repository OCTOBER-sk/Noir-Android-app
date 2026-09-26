/// Transport seam: one injected HTTP abstraction, no network in unit tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cancellation.dart';
import 'errors.dart';

/// A single outbound HTTP request.
class ProviderRequest {
  ProviderRequest({
    required this.method,
    required this.uri,
    Map<String, String> headers = const <String, String>{},
    this.body,
    this.expectsStream = false,
  }) : headers = Map<String, String>.unmodifiable(headers);

  /// Creates a request whose [payload] is JSON-encoded into the body.
  factory ProviderRequest.json({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required Object payload,
    bool expectsStream = false,
  }) => ProviderRequest(
    method: method,
    uri: uri,
    headers: headers,
    body: jsonEncode(payload),
    expectsStream: expectsStream,
  );

  final String method;
  final Uri uri;
  final Map<String, String> headers;

  /// Encoded request body; `null` for bodyless verbs such as GET.
  final String? body;

  /// Whether the caller intends to consume the response as a byte stream.
  final bool expectsStream;

  /// Safe to log: headers (which may carry credentials) are omitted.
  @override
  String toString() => 'ProviderRequest($method $uri)';
}

/// A response whose body is exposed as a byte stream.
class TransportResponse {
  TransportResponse({
    required this.statusCode,
    this.headers = const <String, String>{},
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Case-insensitive header lookup.
  String? header(String name) {
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  /// Reads the whole body as UTF-8 text. Single subscription only.
  Future<String> readText() => body.transform(utf8.decoder).join();
}

/// The seam every provider call goes through.
///
/// Production code injects [HttpClientTransport]; tests inject a double, so the
/// suite never opens a socket.
abstract class ProviderTransport {
  /// Performs [request], honouring [cancellation] by aborting the exchange.
  ///
  /// Throws [ProviderException] (`cancelled` or `network`) when the request
  /// cannot be completed.
  Future<TransportResponse> send(
    ProviderRequest request, {
    CancellationToken? cancellation,
  });

  /// Releases any resources held by the transport.
  void close();
}

/// [ProviderTransport] backed by a `dart:io` [HttpClient].
///
/// The client is injectable so production can share one, and so tests can pass
/// a double and assert the exact bytes written.
class HttpClientTransport implements ProviderTransport {
  HttpClientTransport({
    HttpClient? httpClient,
    this.ownsClient = false,
    this.connectionTimeout,
  }) : _injected = httpClient;

  final HttpClient? _injected;
  final bool ownsClient;
  final Duration? connectionTimeout;

  HttpClient? _client;
  bool _closed = false;

  /// The client actually used; created on first use when not injected.
  HttpClient get client => _client ??= _createClient();

  HttpClient _createClient() {
    final HttpClient? injected = _injected;
    if (injected != null) return injected;
    final HttpClient created = HttpClient();
    if (connectionTimeout != null) {
      created.connectionTimeout = connectionTimeout!;
    }
    return created;
  }

  @override
  Future<TransportResponse> send(
    ProviderRequest request, {
    CancellationToken? cancellation,
  }) {
    cancellation?.throwIfCancelled();
    final Completer<TransportResponse> completer =
        Completer<TransportResponse>();
    HttpClientRequest? pending;

    void Function() removeListener = () {};
    if (cancellation != null) {
      removeListener = cancellation.addListener(() {
        pending?.abort();
        if (!completer.isCompleted) {
          completer.completeError(
            ProviderException.cancelled(cancellation.reason),
          );
        }
      });
    }

    Future<void>(() async {
      try {
        final HttpClientRequest pendingRequest = await client.openUrl(
          request.method,
          request.uri,
        );
        pending = pendingRequest;
        if (completer.isCompleted) {
          pendingRequest.abort();
          return;
        }
        request.headers.forEach(pendingRequest.headers.set);
        final String? body = request.body;
        if (body != null) pendingRequest.write(body);
        final HttpClientResponse response = await pendingRequest.close();
        if (completer.isCompleted) {
          // The caller already gave up (cancelled or timed out): release the
          // socket instead of leaking the unread response.
          response.detachSocket().ignore();
          return;
        }
        completer.complete(
          TransportResponse(
            statusCode: response.statusCode,
            headers: _flattenHeaders(response.headers),
            body: response,
          ),
        );
      } on Object catch (error) {
        if (!completer.isCompleted) {
          completer.completeError(ProviderException.from(error));
        }
      } finally {
        removeListener();
      }
    }).ignore();

    return completer.future;
  }

  @override
  void close() {
    if (!ownsClient || _closed) return;
    _closed = true;
    (_client ?? _injected)?.close(force: true);
    _client = null;
  }

  static Map<String, String> _flattenHeaders(HttpHeaders headers) {
    final Map<String, String> flattened = <String, String>{};
    headers.forEach((String name, List<String> values) {
      flattened[name] = values.join(', ');
    });
    return flattened;
  }
}
