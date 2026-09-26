// lib/providers/mcp/mcp_transport.dart — injectable connections.
//
// The client never touches a socket or a process. It talks to this interface,
// so a test can drive a recorded byte stream while production uses a real HTTP
// endpoint or a real child process.
//
// Two rules the implementations share:
//
//   * stderr of an MCP server is diagnostics, never protocol. A server that
//     writes a JSON-looking line to stderr must not be able to inject a frame.
//   * a request that is cancelled or times out is ABANDONED through
//     [McpTransport.onRequestAbandoned], so the implementation can abort the
//     HTTP exchange or drop the process write instead of leaking a socket.
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'mcp_framing.dart';
import 'mcp_protocol.dart';

/// A bidirectional JSON-RPC message pipe.
abstract class McpTransport {
  /// `http` or `stdio`. Only ever used in diagnostics.
  String get kind;

  /// Incoming frames, already split and decoded from bytes.
  Stream<String> get frames;

  bool get isClosed;

  /// The client stopped waiting for [requestId] (timeout, cancellation, close).
  /// A transport that holds a per-request resource aborts it here; a transport
  /// that multiplexes over one pipe simply drops the eventual reply.
  void abandon(String requestId);

  /// Writes one frame. Implementations append whatever framing they need.
  Future<void> send(String frame);

  Future<void> close();
}

// ---------------------------------------------------------------------------
// HTTP (MCP Streamable HTTP transport)
// ---------------------------------------------------------------------------

class McpHttpRequest {
  const McpHttpRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;
}

/// One HTTP reply. [contentType] is the parsed media type when the server sent
/// one, and [body] is streamed so an SSE reply can be read incrementally.
class McpHttpResponse {
  McpHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.contentType,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String? contentType;
  final Stream<List<int>> body;

  static Future<String> readBodyAsText(Stream<List<int>> body) async {
    final StringBuffer buffer = StringBuffer();
    await for (final List<int> chunk in body) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
    }
    return buffer.toString();
  }
}

/// A request in flight. [abort] is what a cancellation actually calls: the
/// socket is torn down, not merely forgotten.
abstract class McpHttpExchange {
  Future<McpHttpResponse> get result;

  void abort();
}

abstract class McpHttpClient {
  Future<McpHttpExchange> open(McpHttpRequest request);
}

/// dart:io backed HTTP client. This is the only class in the MCP runtime that
/// opens a socket, and it is replaceable.
class IoMcpHttpClient implements McpHttpClient {
  IoMcpHttpClient({
    io.HttpClient? httpClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? io.HttpClient();

  final io.HttpClient _http;
  final Duration requestTimeout;

  @override
  Future<McpHttpExchange> open(McpHttpRequest request) async {
    final io.HttpClientRequest ioRequest = await _http
        .openUrl(request.method, request.url)
        .timeout(requestTimeout);
    request.headers.forEach(ioRequest.headers.set);
    ioRequest.write(request.body);
    return _IoMcpHttpExchange(ioRequest);
  }
}

class _IoMcpHttpExchange implements McpHttpExchange {
  _IoMcpHttpExchange(this._request) : _result = _resolve(_request);

  final io.HttpClientRequest _request;
  final Future<McpHttpResponse> _result;

  static Future<McpHttpResponse> _resolve(io.HttpClientRequest request) async {
    final io.HttpClientResponse response = await request.close();
    final Map<String, String> headers = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    return McpHttpResponse(
      statusCode: response.statusCode,
      headers: headers,
      contentType: response.headers.contentType?.mimeType,
      body: response,
    );
  }

  @override
  Future<McpHttpResponse> get result => _result;

  @override
  void abort() {
    _request.abort();
  }
}

/// MCP over HTTP. One JSON-RPC message per POST; a `text/event-stream` reply is
/// decoded frame by frame, a JSON reply is a single frame, and a 2xx with no
/// body is a notification acknowledgement.
class McpHttpTransport implements McpTransport {
  McpHttpTransport({
    required this.endpoint,
    McpHttpClient? client,
    this.headers = const <String, String>{},
  }) : _client = client ?? IoMcpHttpClient();

  final Uri endpoint;
  final McpHttpClient _client;
  final Map<String, String> headers;

  final StreamController<String> _frames = StreamController<String>.broadcast();
  final Map<String, McpHttpExchange> _exchanges = <String, McpHttpExchange>{};
  final Set<String> _abandonedBeforeOpen = <String>{};
  final List<String> _abandonedOrder = <String>[];
  String? _sessionId;
  bool _closed = false;

  /// Session id the server handed out, echoed on every later request as the MCP
  /// Streamable HTTP transport requires.
  String? get sessionId => _sessionId;

  @override
  String get kind => 'http';

  @override
  Stream<String> get frames => _frames.stream;

  @override
  bool get isClosed => _closed;

  @override
  void abandon(String requestId) {
    final McpHttpExchange? exchange = _exchanges.remove(requestId);
    if (exchange != null) {
      exchange.abort();
      return;
    }
    // The cancel beat the connection into existence. Remember it, so the
    // exchange is aborted the moment it exists instead of hanging forever.
    if (_abandonedBeforeOpen.add(requestId)) {
      _abandonedOrder.add(requestId);
      const int keep = 128;
      while (_abandonedOrder.length > keep) {
        _abandonedBeforeOpen.remove(_abandonedOrder.removeAt(0));
      }
    }
  }

  @override
  Future<void> send(String frame) async {
    if (_closed) {
      throw const McpTransportException(
        kMcpTransportClosed,
        'MCP HTTP transport is closed',
      );
    }
    final McpHttpExchange exchange = await _open(
      McpHttpRequest(
        method: 'POST',
        url: endpoint,
        headers: <String, String>{
          'content-type': 'application/json',
          'accept': 'application/json, text/event-stream',
          if (_sessionId != null) 'mcp-session-id': _sessionId!,
          ...headers,
        },
        body: frame,
      ),
    );
    final String key = _requestIdOf(frame) ?? '#notification';
    _exchanges[key] = exchange;
    if (_abandonedBeforeOpen.remove(key)) {
      _exchanges.remove(key);
      exchange.abort();
    }

    try {
      final McpHttpResponse response = await exchange.result;
      final String? session = response.headers['mcp-session-id'];
      if (session != null && session.isNotEmpty) _sessionId = session;

      if (response.statusCode == 202 || response.statusCode == 204) {
        await McpHttpResponse.readBodyAsText(response.body);
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _failWithStatus(response);
      }
      await _deliverBody(response);
    } on McpException {
      rethrow;
    } catch (error) {
      throw McpTransportException(
        kMcpTransportFailure,
        'MCP HTTP exchange failed: ${mcpScrubExcerpt('$error', max: 80)}',
      );
    } finally {
      // The exchange stays registered until the body has been read: a request
      // cancelled while a slow or streaming body is still open has to be
      // abortable, and a cancel is the only way out of a stalled read.
      _exchanges.remove(key);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final McpHttpExchange exchange in _exchanges.values.toList()) {
      exchange.abort();
    }
    _exchanges.clear();
    if (!_frames.isClosed) await _frames.close();
  }

  Future<McpHttpExchange> _open(McpHttpRequest request) async {
    try {
      return await _client.open(request);
    } on McpException {
      rethrow;
    } catch (error) {
      throw McpTransportException(
        kMcpTransportFailure,
        'MCP HTTP request to $endpoint failed: ${mcpScrubExcerpt('$error', max: 80)}',
      );
    }
  }

  Future<void> _failWithStatus(McpHttpResponse response) async {
    final String text = await McpHttpResponse.readBodyAsText(response.body);
    if (text.trim().isNotEmpty) {
      try {
        final McpMessage message = McpMessage.decode(text);
        if (message.error != null) throw message.error!;
      } on McpException catch (error) {
        if (error is McpRemoteErrorException) rethrow;
      }
    }
    throw McpTransportException(
      kMcpHttpStatus,
      'MCP HTTP ${response.statusCode} from $endpoint',
      statusCode: response.statusCode,
    );
  }

  Future<void> _deliverBody(McpHttpResponse response) async {
    final String contentType =
        response.contentType ?? response.headers['content-type'] ?? '';
    if (contentType.startsWith('text/event-stream')) {
      final McpLineSplitter lines = McpLineSplitter(
        onFramingFailure: _reportFraming,
      );
      final McpSseDecoder decoder = McpSseDecoder();
      await for (final List<int> chunk in response.body) {
        for (final String line in lines.addBytes(chunk)) {
          for (final String frame in decoder.addLine(line)) {
            _emit(frame);
          }
        }
      }
      for (final String line in lines.close()) {
        for (final String frame in decoder.addLine(line)) {
          _emit(frame);
        }
      }
      for (final String frame in decoder.close()) {
        _emit(frame);
      }
      return;
    }
    final String text = await McpHttpResponse.readBodyAsText(response.body);
    if (text.trim().isNotEmpty) _emit(text);
  }

  void _reportFraming(McpFramingException failure) {
    if (!_frames.isClosed) _frames.addError(failure);
  }

  void _emit(String frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }

  static String? _requestIdOf(String frame) {
    try {
      final Object? decoded = jsonDecode(frame);
      if (decoded is Map && decoded['id'] != null) return '${decoded['id']}';
    } on FormatException {
      // An unparseable outbound frame is the caller's problem; the client
      // builds every frame, so this cannot happen in production.
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// stdio
// ---------------------------------------------------------------------------

/// The process a stdio MCP server runs as.
abstract class McpProcessHandle {
  Stream<List<int>> get stdoutBytes;
  Stream<List<int>> get stderrBytes;

  /// Writes raw bytes to the server's stdin. Framing belongs to the transport,
  /// not to the handle.
  void write(String data);

  Future<bool> kill();
}

abstract class McpProcessStarter {
  Future<McpProcessHandle> start();
}

/// dart:io backed process starter, used in production.
class IoMcpProcessStarter implements McpProcessStarter {
  const IoMcpProcessStarter({
    required this.executable,
    this.arguments = const <String>[],
    this.workingDirectory,
    this.environment,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;

  @override
  Future<McpProcessHandle> start() async {
    try {
      final io.Process process = await io.Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      return _IoProcessHandle(process);
    } on io.ProcessException catch (error) {
      throw McpTransportException(
        kMcpProcessStartFailed,
        'MCP server process $executable could not start: '
        '${mcpScrubExcerpt(error.message, max: 80)}',
      );
    }
  }
}

class _IoProcessHandle implements McpProcessHandle {
  _IoProcessHandle(this._process);

  final io.Process _process;

  @override
  Stream<List<int>> get stdoutBytes => _process.stdout;

  @override
  Stream<List<int>> get stderrBytes => _process.stderr;

  @override
  void write(String data) => _process.stdin.write(data);

  @override
  Future<bool> kill() async => _process.kill();
}

/// MCP over a child process, newline-delimited JSON on stdin/stdout.
///
/// stdout is protocol. stderr is surfaced on [diagnostics] and nothing else, so
/// server logging can never be replayed into the session as a message.
class McpStdioTransport implements McpTransport {
  McpStdioTransport({required this.starter});

  final McpProcessStarter starter;

  final StreamController<String> _frames = StreamController<String>.broadcast();
  final StreamController<String> _diagnostics =
      StreamController<String>.broadcast();
  Future<McpProcessHandle>? _starting;
  McpProcessHandle? _process;
  bool _closed = false;

  /// Server logging. Never protocol, never parsed.
  Stream<String> get diagnostics => _diagnostics.stream;

  @override
  String get kind => 'stdio';

  @override
  Stream<String> get frames => _frames.stream;

  @override
  bool get isClosed => _closed;

  @override
  void abandon(String requestId) {
    // A stdio server multiplexes over one pipe, so there is no per-request
    // resource to abort: the eventual reply is simply ignored, because the
    // client has already stopped waiting for that id.
  }

  /// Starts the server process if it is not running yet. Idempotent.
  Future<void> start() async {
    if (_closed) {
      throw const McpTransportException(
        kMcpTransportClosed,
        'MCP stdio transport is closed',
      );
    }
    if (_process != null) return;
    final McpProcessHandle process = await _resolveStart();
    _process = process;
    final McpFrameSplitter splitter = McpFrameSplitter(
      onFramingFailure: _reportFraming,
    );
    process.stdoutBytes.listen(
      (List<int> chunk) {
        for (final String frame in splitter.addBytes(chunk)) {
          _emit(frame);
        }
      },
      onError: (Object error) => _reportFraming(
        McpFramingException(
          kMcpTransportFailure,
          'MCP stdio stdout failed: ${mcpScrubExcerpt('$error', max: 60)}',
        ),
      ),
    );
    process.stderrBytes.listen((List<int> chunk) {
      if (_diagnostics.isClosed) return;
      _diagnostics.add(utf8.decode(chunk, allowMalformed: true));
    }, onError: (Object _) {});
  }

  @override
  Future<void> send(String frame) async {
    if (_closed) {
      throw const McpTransportException(
        kMcpTransportClosed,
        'MCP stdio transport is closed',
      );
    }
    await start();
    // Newline-delimited JSON: the framing belongs here so the process handle
    // stays a dumb byte sink.
    _process!.write('$frame\n');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final McpProcessHandle? process = _process;
    _process = null;
    _starting = null;
    if (process != null) {
      try {
        await process.kill();
      } on Object {
        // The process is already gone; closing is still a success.
      }
    }
    if (!_frames.isClosed) await _frames.close();
    if (!_diagnostics.isClosed) await _diagnostics.close();
  }

  Future<McpProcessHandle> _resolveStart() {
    return _starting ??= _startOnce();
  }

  Future<McpProcessHandle> _startOnce() async {
    try {
      return await starter.start();
    } on McpException {
      rethrow;
    } catch (error) {
      throw McpTransportException(
        kMcpProcessStartFailed,
        'MCP server process could not start: ${mcpScrubExcerpt('$error', max: 80)}',
      );
    }
  }

  void _reportFraming(McpFramingException failure) {
    if (!_frames.isClosed) _frames.addError(failure);
  }

  void _emit(String frame) {
    if (!_frames.isClosed) _frames.add(frame);
  }
}
