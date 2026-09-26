// test/mcp_transport_test.dart — the injectable MCP transports.
//
// The client under test is the production McpClient. The only things faked are
// the two edges a real server connection would use: an HTTP exchange and a
// child process. No sockets and no processes are created here, so the tests are
// deterministic: the HTTP client returns a scripted body and the process pushes
// a scripted byte stream, including chunks that split a frame in half.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/providers/mcp/mcp_client.dart';
import 'package:noir_android_app/providers/mcp/mcp_framing.dart';
import 'package:noir_android_app/providers/mcp/mcp_protocol.dart';
import 'package:noir_android_app/providers/mcp/mcp_transport.dart';

// ---------------------------------------------------------------------------
// HTTP edge
// ---------------------------------------------------------------------------

class FakeHttpExchange implements McpHttpExchange {
  FakeHttpExchange(this.request, this.handler, {this.onAbort});

  final McpHttpRequest request;
  final Future<McpHttpResponse> Function(McpHttpRequest request) handler;
  final void Function()? onAbort;
  bool aborted = false;

  @override
  void abort() {
    aborted = true;
    onAbort?.call();
  }

  @override
  Future<McpHttpResponse> get result => handler(request);
}

class FakeHttpClient implements McpHttpClient {
  FakeHttpClient(this.handler);

  final Future<McpHttpResponse> Function(McpHttpRequest request) handler;
  final List<McpHttpRequest> requests = <McpHttpRequest>[];
  final List<String> abortedBodies = <String>[];

  @override
  Future<McpHttpExchange> open(McpHttpRequest request) {
    requests.add(request);
    return Future<McpHttpExchange>.value(
      FakeHttpExchange(
        request,
        handler,
        onAbort: () => abortedBodies.add(request.body),
      ),
    );
  }
}

McpHttpResponse jsonBody(Object? payload, {int status = 200}) =>
    McpHttpResponse(
      statusCode: status,
      headers: <String, String>{'content-type': 'application/json'},
      contentType: 'application/json',
      body: Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
    );

McpHttpResponse sseBody(List<String> events) => McpHttpResponse(
  statusCode: 200,
  headers: <String, String>{'content-type': 'text/event-stream'},
  contentType: 'text/event-stream',
  body: Stream<List<int>>.value(utf8.encode(events.join('\n\n'))),
);

McpHttpResponse emptyBody({int status = 202}) => McpHttpResponse(
  statusCode: status,
  headers: <String, String>{},
  contentType: null,
  body: const Stream<List<int>>.empty(),
);

/// The id of the JSON-RPC request in a raw POST body, or null for a
/// notification.
String? idOf(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is Map && decoded['id'] != null) return '${decoded['id']}';
  return null;
}

String? methodOf(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is Map && decoded['method'] != null) {
    return '${decoded['method']}';
  }
  return null;
}

Map<String, dynamic> handshakePayload() => <String, dynamic>{
  'protocolVersion': mcpProtocolVersion,
  'capabilities': <String, dynamic>{
    'tools': <String, dynamic>{},
    'resources': <String, dynamic>{},
  },
  'serverInfo': <String, dynamic>{'name': 'http-notes', 'version': '1.0.0'},
};

String replyTo(String body) {
  final Map<String, dynamic> request = jsonDecode(body) as Map<String, dynamic>;
  final Object? id = request['id'];
  switch (request['method']) {
    case kMcpMethodInitialize:
      return jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': handshakePayload(),
      });
    case kMcpMethodToolsList:
      return jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'result': <String, dynamic>{
          'tools': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'read_note',
              'annotations': <String, dynamic>{'readOnlyHint': true},
            },
          ],
        },
      });
    default:
      return jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'error': <String, dynamic>{
          'code': -32601,
          'message': 'Method not found',
        },
      });
  }
}

// ---------------------------------------------------------------------------
// Process edge
// ---------------------------------------------------------------------------

class FakeProcessHandle implements McpProcessHandle {
  final StreamController<List<int>> stdout = StreamController<List<int>>();
  final StreamController<List<int>> stderr = StreamController<List<int>>();
  final List<String> written = <String>[];
  int killCount = 0;

  /// Installed by [serveMcpRequests] so the fake answers what it is sent, the
  /// way a real stdio server does. A reply is only ever written in response to a
  /// request that actually arrived.
  void Function(String frame)? onWrite;

  @override
  Stream<List<int>> get stdoutBytes => stdout.stream;

  @override
  Stream<List<int>> get stderrBytes => stderr.stream;

  @override
  void write(String data) {
    written.add(data);
    onWrite?.call(data);
  }

  @override
  Future<bool> kill() async {
    killCount += 1;
    if (!stdout.isClosed) await stdout.close();
    if (!stderr.isClosed) await stderr.close();
    return true;
  }

  Future<void> dispose() async {
    if (!stdout.isClosed) await stdout.close();
    if (!stderr.isClosed) await stderr.close();
  }
}

class FakeProcessStarter implements McpProcessStarter {
  FakeProcessStarter(this.handle);

  final FakeProcessHandle handle;
  int startCount = 0;

  @override
  Future<McpProcessHandle> start() async {
    startCount += 1;
    return handle;
  }
}

/// A JSON-RPC response envelope. A reply never carries a method: a frame with
/// both a method and an id is a request, and the client refuses server-initiated
/// requests by default.
String replyFrame(Object id, Map<String, dynamic> result) {
  return jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  });
}

/// Answers every request the client writes to the pipe, as an MCP stdio server
/// would. [chunkSize] deliberately breaks the reply into pieces so the framing
/// is exercised the way a real pipe exercises it.
void serveMcpRequests(
  FakeProcessHandle process, {
  required Map<String, dynamic> Function(String method) resultFor,
  int chunkSize = 0,
}) {
  process.onWrite = (String data) {
    final String frame = data.trimRight();
    final Map<String, dynamic> message =
        jsonDecode(frame) as Map<String, dynamic>;
    final Object? id = message['id'];
    if (id == null) return; // a notification is never answered
    final String body = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': resultFor('${message['method']}'),
    });
    final List<int> bytes = utf8.encode('$body\n');
    if (chunkSize <= 0) {
      process.stdout.add(bytes);
      return;
    }
    for (int offset = 0; offset < bytes.length; offset += chunkSize) {
      final int end = (offset + chunkSize) > bytes.length
          ? bytes.length
          : offset + chunkSize;
      process.stdout.add(bytes.sublist(offset, end));
    }
  };
}

Map<String, dynamic> defaultServerResult(String method) {
  switch (method) {
    case kMcpMethodInitialize:
      return handshakePayload();
    case kMcpMethodToolsList:
      return <String, dynamic>{
        'tools': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'note_reader'},
        ],
      };
    case kMcpMethodResourcesList:
      return <String, dynamic>{
        'resources': <Map<String, dynamic>>[
          <String, dynamic>{'uri': 'notes://today', 'name': 'today'},
        ],
      };
    default:
      return <String, dynamic>{};
  }
}

void main() {
  group('frame splitter (newline-delimited JSON)', () {
    test('a frame split across three byte chunks is reassembled', () {
      final McpFrameSplitter splitter = McpFrameSplitter();
      final String frame = jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
      });
      final List<int> bytes = utf8.encode('$frame\n');

      final List<String> first = splitter.addBytes(bytes.sublist(0, 5));
      expect(first, isEmpty);

      final List<String> second = splitter.addBytes(bytes.sublist(5, 12));
      expect(second, isEmpty);

      final List<String> third = splitter.addBytes(bytes.sublist(12));
      expect(third, hasLength(1));
      expect(jsonDecode(third.single), <String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
      });
    });

    test('two frames in one chunk and CRLF endings both work', () {
      final McpFrameSplitter splitter = McpFrameSplitter();

      final List<String> frames = splitter.addBytes(
        utf8.encode('{"a":1}\r\n{"b":2}\r\n'),
      );

      expect(frames, <String>['{"a":1}', '{"b":2}']);
    });

    test('a frame with no trailing newline is flushed on close', () {
      final McpFrameSplitter splitter = McpFrameSplitter();
      splitter.addText('{"a":1}');

      expect(splitter.close(), <String>['{"a":1}']);
    });

    test('an oversized frame is dropped with a typed framing failure', () {
      McpFramingException? failure;
      final McpFrameSplitter splitter = McpFrameSplitter(
        maxFrameBytes: 16,
        onFramingFailure: (error) => failure = error,
      );

      final List<String> frames = splitter.addText('x' * 64);

      expect(frames, isEmpty);
      expect(failure, isNotNull);
      expect(failure!.code, kMcpFrameTooLarge);
    });
  });

  group('SSE decoder', () {
    test('data payloads become frames and comments are ignored', () {
      final McpSseDecoder decoder = McpSseDecoder();
      final List<String> frames = <String>[];

      frames.addAll(decoder.addLine(': keep-alive'));
      frames.addAll(decoder.addLine('event: message'));
      frames.addAll(decoder.addLine('data: {"a":1}'));
      frames.addAll(decoder.addLine(''));

      expect(frames, <String>['{"a":1}']);
    });

    test('a multi-line data field is joined with newlines', () {
      final McpSseDecoder decoder = McpSseDecoder();
      final List<String> frames = <String>[];

      frames.addAll(decoder.addLine('data: {"a":'));
      frames.addAll(decoder.addLine('data: 1}'));
      frames.addAll(decoder.addLine(''));

      expect(frames.single, contains('\n'));
      expect(jsonDecode(frames.single), <String, dynamic>{'a': 1});
    });
  });

  group('MCP over HTTP transport', () {
    test(
      'a JSON reply drives a real initialize and tools/list round trip',
      () async {
        final FakeHttpClient http = FakeHttpClient((request) async {
          return jsonBody(jsonDecode(replyTo(request.body)));
        });
        final McpHttpTransport transport = McpHttpTransport(
          endpoint: Uri.parse('https://mcp.test/rpc'),
          client: http,
        );
        final McpClient client = McpClient(transport: transport);

        final McpInitializeResult result = await client.initialize();
        final List<McpToolSpec> tools = await client.listTools();

        expect(result.serverInfo.name, 'http-notes');
        expect(tools.single.name, 'read_note');

        // initialize, notifications/initialized, tools/list
        expect(http.requests, hasLength(3));
        final McpHttpRequest first = http.requests.first;
        expect(first.method, 'POST');
        expect(first.url, Uri.parse('https://mcp.test/rpc'));
        expect(first.headers['content-type'], contains('application/json'));
        expect(first.headers['accept'], contains('text/event-stream'));
        final Map<String, dynamic> sent =
            jsonDecode(first.body) as Map<String, dynamic>;
        expect(sent['method'], kMcpMethodInitialize);
        expect(sent['params']['protocolVersion'], mcpProtocolVersion);

        await client.close();
      },
    );

    test(
      'a session id returned by the server is echoed on later requests',
      () async {
        int call = 0;
        final FakeHttpClient http = FakeHttpClient((request) async {
          if (idOf(request.body) == null) return emptyBody();
          call += 1;
          final McpHttpResponse response = jsonBody(
            jsonDecode(replyTo(request.body)),
          );
          return call == 1
              ? McpHttpResponse(
                  statusCode: response.statusCode,
                  headers: <String, String>{
                    ...response.headers,
                    'mcp-session-id': 'sess-42',
                  },
                  contentType: response.contentType,
                  body: response.body,
                )
              : response;
        });
        final McpHttpTransport transport = McpHttpTransport(
          endpoint: Uri.parse('https://mcp.test/rpc'),
          client: http,
        );
        final McpClient client = McpClient(transport: transport);

        await client.initialize();
        expect(transport.sessionId, 'sess-42');

        await client.listTools();
        expect(http.requests.last.headers['mcp-session-id'], 'sess-42');
        expect(methodOf(http.requests.last.body), kMcpMethodToolsList);

        await client.close();
      },
    );

    test('a text/event-stream reply is decoded into frames', () async {
      final FakeHttpClient http = FakeHttpClient((request) async {
        final String? id = idOf(request.body);
        if (id == null) return emptyBody();
        if (methodOf(request.body) == kMcpMethodInitialize) {
          return jsonBody(jsonDecode(replyTo(request.body)));
        }
        // No trailing blank line: a legal end-of-stream flush must still yield
        // the frame.
        return sseBody(<String>[
          'event: message\ndata: ${jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{
              'tools': <Map<String, dynamic>>[
                <String, dynamic>{'name': 'streamed_note'},
              ],
            },
          })}',
        ]);
      });
      final McpHttpTransport transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/rpc'),
        client: http,
      );
      final McpClient client = McpClient(transport: transport);

      await client.initialize();
      final List<McpToolSpec> tools = await client.listTools();

      expect(tools.single.name, 'streamed_note');
      await client.close();
    });

    test(
      'an HTTP error status with a JSON-RPC error body is a typed remote error',
      () async {
        final FakeHttpClient http = FakeHttpClient((request) async {
          final String id =
              (jsonDecode(request.body) as Map<String, dynamic>)['id']!
                  as String;
          return jsonBody(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{
              'code': -32000,
              'message': 'server exploded',
            },
          }, status: 500);
        });
        final McpHttpTransport transport = McpHttpTransport(
          endpoint: Uri.parse('https://mcp.test/rpc'),
          client: http,
        );
        final McpClient client = McpClient(transport: transport);

        await expectLater(
          client.initialize(),
          throwsA(
            isA<McpRemoteErrorException>()
                .having((e) => e.remoteCode, 'remoteCode', -32000)
                .having(
                  (e) => e.message,
                  'message',
                  contains('server exploded'),
                ),
          ),
        );

        await client.close();
      },
    );

    test(
      'an HTTP error status without a JSON-RPC body is a transport failure',
      () async {
        final FakeHttpClient http = FakeHttpClient(
          (request) async => McpHttpResponse(
            statusCode: 502,
            headers: <String, String>{'content-type': 'text/plain'},
            contentType: 'text/plain',
            body: Stream<List<int>>.value(utf8.encode('upstream is down')),
          ),
        );
        final McpHttpTransport transport = McpHttpTransport(
          endpoint: Uri.parse('https://mcp.test/rpc'),
          client: http,
        );
        final McpClient client = McpClient(transport: transport);

        await expectLater(
          client.initialize(),
          throwsA(
            isA<McpTransportException>()
                .having((e) => e.code, 'code', kMcpHttpStatus)
                .having((e) => e.statusCode, 'statusCode', 502),
          ),
        );

        await client.close();
      },
    );

    test('a cancelled request aborts the HTTP exchange', () async {
      final FakeHttpClient http = FakeHttpClient((request) async {
        final String? id = idOf(request.body);
        if (id == null) return emptyBody();
        if (methodOf(request.body) == kMcpMethodInitialize) {
          return jsonBody(jsonDecode(replyTo(request.body)));
        }
        // The server accepted the POST and then went quiet: the body never
        // completes, so only a real abort can release the socket.
        return McpHttpResponse(
          statusCode: 200,
          headers: <String, String>{'content-type': 'application/json'},
          contentType: 'application/json',
          body: StreamController<List<int>>().stream,
        );
      });
      final McpHttpTransport transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/rpc'),
        client: http,
      );
      final McpClient client = McpClient(transport: transport);
      await client.initialize();
      final McpCancellationToken token = McpCancellationToken();

      final Future<List<McpToolSpec>> pending = client.listTools(
        cancellation: token,
      );
      await pumpEventQueue();
      token.cancel('user pressed stop');

      await expectLater(pending, throwsA(isA<McpCancelledException>()));
      expect(
        http.abortedBodies,
        hasLength(1),
        reason: 'the exchange must be aborted, not leaked',
      );
      expect(transport.isClosed, isFalse);

      await client.close();
    });

    test('a cancel that beats the connection is not silently dropped', () async {
      final FakeHttpClient http = FakeHttpClient(
        (request) async => emptyBody(),
      );
      final McpHttpTransport transport = McpHttpTransport(
        endpoint: Uri.parse('https://mcp.test/rpc'),
        client: http,
      );
      // Abandon an id before anything is written. The transport must remember
      // the intent, so that when a matching exchange finally opens it is aborted
      // immediately rather than hanging on a body that never ends.
      transport.abandon('mcp-1');
      transport.abandon('mcp-1');
      expect(transport.isClosed, isFalse);

      await transport.send(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'mcp-1',
          'method': kMcpMethodToolsList,
        }),
      );
      expect(http.abortedBodies, hasLength(1));
      await transport.close();
    });

    test(
      'a 202 reply for a notification is accepted without a frame',
      () async {
        final FakeHttpClient http = FakeHttpClient((request) async {
          if (idOf(request.body) == null) return emptyBody();
          return jsonBody(jsonDecode(replyTo(request.body)));
        });
        final McpHttpTransport transport = McpHttpTransport(
          endpoint: Uri.parse('https://mcp.test/rpc'),
          client: http,
        );
        final McpClient client = McpClient(transport: transport);

        await client.initialize();
        await client.notify('notifications/progress', <String, dynamic>{
          'progress': 1,
        });

        // initialize, notifications/initialized, notifications/progress
        expect(http.requests, hasLength(3));
        final Map<String, dynamic> notification =
            jsonDecode(http.requests.last.body) as Map<String, dynamic>;
        expect(notification['method'], 'notifications/progress');
        expect(notification.containsKey('id'), isFalse);

        await client.close();
      },
    );
  });

  group('MCP over stdio-like transport', () {
    test('the process is started lazily, once', () async {
      final FakeProcessHandle process = FakeProcessHandle();
      final FakeProcessStarter starter = FakeProcessStarter(process);
      final McpStdioTransport transport = McpStdioTransport(starter: starter);

      expect(starter.startCount, 0);
      await transport.send('{"jsonrpc":"2.0","method":"ping"}');
      await transport.send('{"jsonrpc":"2.0","method":"ping"}');

      expect(starter.startCount, 1);
      expect(process.written, <String>[
        '{"jsonrpc":"2.0","method":"ping"}\n',
        '{"jsonrpc":"2.0","method":"ping"}\n',
      ]);

      await transport.close();
      await process.dispose();
    });

    test('a full session runs over the pipe with NDJSON framing', () async {
      final FakeProcessHandle process = FakeProcessHandle();
      final McpStdioTransport transport = McpStdioTransport(
        starter: FakeProcessStarter(process),
      );
      await transport.start();
      serveMcpRequests(process, resultFor: defaultServerResult);
      final McpClient client = McpClient(transport: transport);

      final McpInitializeResult result = await client.initialize();
      final List<McpToolSpec> tools = await client.listTools();
      final List<McpResourceSpec> resources = await client.listResources();

      expect(result.serverInfo.name, 'http-notes');
      expect(tools.single.name, 'note_reader');
      expect(resources.single.uri, 'notes://today');
      expect(process.written.first, contains('"id":"mcp-1"'));
      expect(
        process.written.every((String frame) => frame.endsWith('\n')),
        isTrue,
        reason: 'NDJSON framing',
      );
      expect(
        process.written.any((String f) => f.contains(kMcpMethodInitialized)),
        isTrue,
        reason: 'the initialized notification goes over the same pipe',
      );

      await client.close();
      await process.dispose();
    });

    test('a reply split into seven-byte chunks still parses', () async {
      final FakeProcessHandle process = FakeProcessHandle();
      final McpStdioTransport transport = McpStdioTransport(
        starter: FakeProcessStarter(process),
      );
      await transport.start();
      serveMcpRequests(process, resultFor: defaultServerResult, chunkSize: 7);
      final McpClient client = McpClient(transport: transport);

      final McpInitializeResult result = await client.initialize();
      final List<McpToolSpec> tools = await client.listTools();

      expect(result.serverInfo.name, 'http-notes');
      expect(tools.single.name, 'note_reader');

      await client.close();
      await process.dispose();
    });

    test('stderr is diagnostics only and never parsed as protocol', () async {
      final FakeProcessHandle process = FakeProcessHandle();
      final McpStdioTransport transport = McpStdioTransport(
        starter: FakeProcessStarter(process),
      );
      await transport.start();
      final List<String> diagnostics = <String>[];
      final List<String> protocolFrames = <String>[];
      final StreamSubscription<String> sub = transport.diagnostics.listen(
        diagnostics.add,
      );
      final StreamSubscription<String> frames = transport.frames.listen(
        protocolFrames.add,
      );

      process.stderr.add(utf8.encode('warning: {not json}\n'));
      process.stderr.add(utf8.encode('trace: still fine\n'));
      await pumpEventQueue();

      expect(diagnostics.join(), contains('still fine'));
      expect(
        protocolFrames,
        isEmpty,
        reason: 'stderr must never be treated as a protocol frame',
      );

      await sub.cancel();
      await frames.cancel();
      await transport.close();
      await process.dispose();
    });

    test('closing the transport kills the process', () async {
      final FakeProcessHandle process = FakeProcessHandle();
      final McpStdioTransport transport = McpStdioTransport(
        starter: FakeProcessStarter(process),
      );
      await transport.send('{"jsonrpc":"2.0","method":"ping"}');

      await transport.close();

      expect(process.killCount, 1);
      expect(transport.isClosed, isTrue);
      await process.dispose();
    });

    test('a write after close is a typed transport failure', () async {
      final FakeProcessHandle process = FakeProcessHandle();
      final McpStdioTransport transport = McpStdioTransport(
        starter: FakeProcessStarter(process),
      );
      await transport.send('{"jsonrpc":"2.0","method":"ping"}');
      await transport.close();

      await expectLater(
        transport.send('{"jsonrpc":"2.0","method":"ping"}'),
        throwsA(
          isA<McpTransportException>().having(
            (e) => e.code,
            'code',
            kMcpTransportClosed,
          ),
        ),
      );
      await process.dispose();
    });

    test(
      'a process that cannot start surfaces a typed transport failure',
      () async {
        final McpStdioTransport transport = McpStdioTransport(
          starter: _FailingProcessStarter(),
        );

        await expectLater(
          transport.send('{"jsonrpc":"2.0","method":"ping"}'),
          throwsA(
            isA<McpTransportException>().having(
              (e) => e.code,
              'code',
              kMcpProcessStartFailed,
            ),
          ),
        );
      },
    );
  });
}

class _FailingProcessStarter implements McpProcessStarter {
  @override
  Future<McpProcessHandle> start() async {
    throw const McpTransportException(
      kMcpProcessStartFailed,
      'no such executable: noir-mcp',
    );
  }
}
