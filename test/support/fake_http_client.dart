// Test support: a no-socket `dart:io` HttpClient double.
//
// It lets the provider tests exercise the real `HttpClientTransport` request
// path (method, URI, headers, body write, status/header/stream mapping, abort
// on cancel, socket failure mapping) without opening a socket or contacting
// any host.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A single scripted HTTP exchange.
class RecordedExchange {
  RecordedExchange({
    required this.statusCode,
    required this.headers,
    required this.bodyChunks,
  });

  final int statusCode;
  final Map<String, List<String>> headers;
  final List<String> bodyChunks;
}

/// Minimal `HttpHeaders` double: only set/lookup/forEach are exercised.
class FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = <String>[value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    values
        .putIfAbsent(name.toLowerCase(), () => <String>[])
        .add(value.toString());
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    values.forEach(action);
  }

  @override
  List<String>? operator [](String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `HttpClientRequest` double that records what the transport wrote.
class FakeHttpClientRequest implements HttpClientRequest {
  FakeHttpClientRequest(this.client);

  final FakeHttpClient client;

  @override
  final FakeHttpHeaders headers = FakeHttpHeaders();
  final StringBuffer buffer = StringBuffer();

  bool closed = false;
  bool aborted = false;

  @override
  void write(Object? obj) {
    buffer.write(obj);
  }

  @override
  void add(List<int> data) {
    buffer.write(utf8.decode(data));
  }

  @override
  Future<HttpClientResponse> close() async {
    closed = true;
    client.closedRequests += 1;
    if (client.holdResponses) {
      final Completer<HttpClientResponse> completer =
          Completer<HttpClientResponse>();
      client.held.add(completer);
      return completer.future;
    }
    return client.respond(this);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
    client.aborted += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `HttpClientResponse` double: a `Stream<List<int>>` plus status/headers.
class FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FakeHttpClientResponse({
    required this.statusCode,
    required FakeHttpHeaders headers,
    required Stream<List<int>> stream,
  }) : _headers = headers,
       _stream = stream;

  final Stream<List<int>> _stream;
  final FakeHttpHeaders _headers;

  @override
  final int statusCode;

  @override
  HttpHeaders get headers => _headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `HttpClient` double that returns scripted exchanges in order.
class FakeHttpClient implements HttpClient {
  FakeHttpClient(this.exchanges);

  /// Builds a client whose single response streams [body] as one chunk.
  factory FakeHttpClient.withBody(
    String body, {
    int statusCode = 200,
    Map<String, String> headers = const <String, String>{},
  }) => FakeHttpClient(<RecordedExchange Function(FakeHttpClientRequest)>[
    (FakeHttpClientRequest _) => RecordedExchange(
      statusCode: statusCode,
      headers: headers.map(
        (String k, String v) => MapEntry<String, List<String>>(k, <String>[v]),
      ),
      bodyChunks: <String>[body],
    ),
  ]);

  final List<RecordedExchange Function(FakeHttpClientRequest)> exchanges;
  final List<FakeHttpClientRequest> requests = <FakeHttpClientRequest>[];
  final List<Completer<HttpClientResponse>> held =
      <Completer<HttpClientResponse>>[];

  /// When true, `HttpClientRequest.close` parks until [releaseHeld] is called.
  bool holdResponses = false;

  /// When set, `openUrl` fails with this error (simulated socket failure).
  Object? failWith;

  int closedCalls = 0;
  int closedRequests = 0;
  int aborted = 0;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final Object? failure = failWith;
    if (failure != null) throw failure;
    final FakeHttpClientRequest request = FakeHttpClientRequest(this);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closedCalls += 1;
  }

  /// Completes every parked `close()` with its scripted response.
  void releaseHeld() {
    for (final Completer<HttpClientResponse> completer in held) {
      if (completer.isCompleted) continue;
      final FakeHttpClientRequest request = requests.last;
      if (request.aborted) {
        completer.completeError(const SocketException('aborted'));
      } else {
        completer.complete(respond(request));
      }
    }
  }

  /// Builds the scripted response for [request].
  HttpClientResponse respond(FakeHttpClientRequest request) {
    final int index = requests.indexOf(request);
    final RecordedExchange Function(FakeHttpClientRequest) build =
        exchanges[index < exchanges.length ? index : exchanges.length - 1];
    final RecordedExchange exchange = build(request);
    return FakeHttpClientResponse(
      statusCode: exchange.statusCode,
      headers: FakeHttpHeaders()
        ..values.addAll(
          exchange.headers.map(
            (String k, List<String> v) =>
                MapEntry<String, List<String>>(k.toLowerCase(), v),
          ),
        ),
      stream: Stream<List<int>>.fromIterable(
        exchange.bodyChunks.map(utf8.encode),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
