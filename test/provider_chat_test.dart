// Provider runtime — auth config, typed errors, transport, chat completion and
// SSE streaming. Every assertion drives real lib/providers code through the
// no-socket doubles in test/support; no external endpoint is contacted.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/providers/adapters/openrouter_adapter.dart';
import 'package:noir_android_app/providers/auth_config.dart';
import 'package:noir_android_app/providers/cancellation.dart';
import 'package:noir_android_app/providers/chat_types.dart';
import 'package:noir_android_app/providers/errors.dart';
import 'package:noir_android_app/providers/streaming.dart';
import 'package:noir_android_app/providers/transport.dart';

import 'support/fake_http_client.dart';
import 'support/fake_transport.dart';

ProviderAuthConfig _auth({
  String baseUrl = 'https://gateway.example/api/v1',
  String? apiKey = 'test-key',
}) => ProviderAuthConfig(baseUrl: baseUrl, apiKey: apiKey);

ChatRequest _request({String model = 'vendor/free-model:free'}) => ChatRequest(
  model: model,
  messages: <ChatMessage>[ChatMessage(ChatRole.user, 'hello')],
);

OpenRouterAdapter _adapter(
  FakeTransport transport, {
  ProviderAuthConfig? auth,
  RetryPolicy retry = const RetryPolicy(maxAttempts: 3),
}) => OpenRouterAdapter(
  transport: transport,
  auth: auth ?? _auth(),
  retry: retry,
  sleep: (Duration _) async {},
);

TokenUsage _usageJson(Map<String, dynamic> json) => TokenUsage.fromJson(json);

Map<String, dynamic> _payload(ProviderRequest request) =>
    jsonDecode(request.body!) as Map<String, dynamic>;

void main() {
  group('ProviderAuthConfig', () {
    test('joins base URL path with an endpoint path and keeps base query', () {
      final config = ProviderAuthConfig(
        baseUrl: 'https://gateway.example/api/v1/',
        apiKey: 'k',
        query: const <String, String>{'api-version': '2024-05'},
      );

      final Uri uri = config.resolve('chat/completions', <String, String>{
        'model': 'm',
      });

      expect(uri.host, 'gateway.example');
      expect(uri.path, '/api/v1/chat/completions');
      expect(uri.queryParameters['api-version'], '2024-05');
      expect(uri.queryParameters['model'], 'm');
    });

    test('sends bearer auth, content type and SSE accept headers', () {
      final Map<String, String> json = _auth().requestHeaders();
      expect(json['Authorization'], 'Bearer test-key');
      expect(json['content-type'], 'application/json');
      expect(json['accept'], 'application/json');

      final Map<String, String> sse = _auth().requestHeaders(streaming: true);
      expect(sse['accept'], 'text/event-stream');
      expect(sse['Authorization'], 'Bearer test-key');
    });

    test('omits Authorization when no key is configured (local gateway)', () {
      final Map<String, String> headers = _auth(apiKey: null).requestHeaders();

      expect(headers.containsKey('Authorization'), isFalse);
      expect(_auth(apiKey: null).hasCredentials, isFalse);
    });

    test(
      'merges custom headers but rejects a reserved authorization header',
      () {
        final ProviderAuthConfig config = ProviderAuthConfig(
          baseUrl: 'https://gateway.example',
          apiKey: 'k',
          headers: const <String, String>{'x-tenant': 'noir'},
        );

        expect(config.requestHeaders()['x-tenant'], 'noir');
        expect(
          () => ProviderAuthConfig(
            baseUrl: 'https://gateway.example',
            apiKey: 'k',
            headers: const <String, String>{'authorization': 'Bearer other'},
          ),
          throwsArgumentError,
        );
        expect(
          () => ProviderAuthConfig(
            baseUrl: 'https://gateway.example',
            apiKey: 'k',
            headers: const <String, String>{'content-type': 'text/plain'},
          ),
          throwsArgumentError,
        );
      },
    );

    test('rejects a non-http(s) or blank base URL and a blank key', () {
      expect(
        () => ProviderAuthConfig(baseUrl: 'ftp://gateway.example'),
        throwsArgumentError,
      );
      expect(() => ProviderAuthConfig(baseUrl: '   '), throwsArgumentError);
      expect(
        () => ProviderAuthConfig(baseUrl: 'https://g.example', apiKey: ' '),
        throwsArgumentError,
      );
    });

    test('copyWith re-keys or re-points the config at runtime', () {
      final ProviderAuthConfig rotated = _auth().copyWith(
        baseUrl: 'https://other-gateway.example/v2',
        apiKey: 'rotated-key',
      );

      expect(rotated.baseUrl, 'https://other-gateway.example/v2');
      expect(rotated.requestHeaders()['Authorization'], 'Bearer rotated-key');
      expect(rotated.resolve('models').path, '/v2/models');
      expect(_auth().apiKey, 'test-key', reason: 'the original is unchanged');
    });

    test('describe() never leaks the key material', () {
      final String described = _auth().describe();

      expect(described, contains('gateway.example'));
      expect(described, isNot(contains('test-key')));
      expect(_auth().describe(), isNot(contains('test-key')));
    });
  });

  group('ProviderException', () {
    test('maps HTTP status codes onto typed kinds', () {
      expect(
        ProviderException.fromStatus(401, body: 'no key').kind,
        ProviderErrorKind.auth,
      );
      expect(ProviderException.fromStatus(403).kind, ProviderErrorKind.auth);
      expect(
        ProviderException.fromStatus(429, body: 'slow down').kind,
        ProviderErrorKind.rateLimit,
      );
      expect(
        ProviderException.fromStatus(404).kind,
        ProviderErrorKind.notFound,
      );
      expect(ProviderException.fromStatus(503).kind, ProviderErrorKind.server);
      expect(
        ProviderException.fromStatus(400).kind,
        ProviderErrorKind.malformed,
      );
    });

    test('marks only network, timeout, server and rate-limit as transient', () {
      expect(ProviderException.network('socket').isTransient, isTrue);
      expect(ProviderException.timeout('no first byte').isTransient, isTrue);
      expect(ProviderException.fromStatus(500).isTransient, isTrue);
      expect(ProviderException.fromStatus(429).isTransient, isTrue);
      expect(ProviderException.fromStatus(401).isTransient, isFalse);
      expect(ProviderException.malformed('bad json').isTransient, isFalse);
      expect(ProviderException.cancelled().isTransient, isFalse);
    });

    test('truncates a long body and keeps the status code', () {
      final ProviderException error = ProviderException.fromStatus(
        500,
        body: 'x' * 5000,
      );

      expect(error.statusCode, 500);
      expect(error.body!.length, lessThan(200));
      expect(error.toString(), contains('server'));
    });

    test(
      'does not fabricate a retry-after delay when the header is absent',
      () {
        expect(ProviderException.fromStatus(429).retryAfter, isNull);
      },
    );
  });

  group('HttpClientTransport', () {
    test(
      'writes method, URI, headers and body and maps the response',
      () async {
        final FakeHttpClient client = FakeHttpClient.withBody(
          'data: [DONE]\n\n',
          statusCode: 201,
          headers: const <String, String>{'x-request-id': 'abc'},
        );
        final HttpClientTransport transport = HttpClientTransport(
          httpClient: client,
          ownsClient: false,
        );
        addTearDown(transport.close);

        final TransportResponse response = await transport.send(
          ProviderRequest(
            method: 'POST',
            uri: Uri.parse('https://gateway.example/api/v1/chat/completions'),
            headers: const <String, String>{'authorization': 'Bearer k'},
            body: '{"model":"m"}',
            expectsStream: true,
          ),
        );

        expect(response.statusCode, 201);
        expect(response.header('x-request-id'), 'abc');
        expect(await response.readText(), 'data: [DONE]\n\n');
        expect(client.requests.single.headers['authorization'], <String>[
          'Bearer k',
        ]);
        expect(client.requests.single.buffer.toString(), '{"model":"m"}');
        expect(client.requests.single.closed, isTrue);
        expect(client.closedCalls, 0, reason: 'injected client is not owned');
      },
    );

    test('closes an owned client exactly once', () {
      final FakeHttpClient client = FakeHttpClient.withBody('{}');
      final HttpClientTransport transport = HttpClientTransport(
        httpClient: client,
        ownsClient: true,
      );

      transport.close();
      transport.close();

      expect(client.closedCalls, 1);
    });

    test('aborts the in-flight request when the token is cancelled', () async {
      final FakeHttpClient client = FakeHttpClient.withBody('{}')
        ..holdResponses = true;
      final HttpClientTransport transport = HttpClientTransport(
        httpClient: client,
        ownsClient: false,
      );
      addTearDown(transport.close);
      final CancellationToken token = CancellationToken();

      final Future<TransportResponse> pending = transport.send(
        ProviderRequest(
          method: 'POST',
          uri: Uri.parse('https://gateway.example/api/v1/models'),
        ),
        cancellation: token,
      );
      await pumpEventQueue();
      expect(
        client.held,
        hasLength(1),
        reason: 'request is awaiting a response',
      );

      token.cancel('user stopped');

      await expectLater(
        pending,
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.cancelled,
          ),
        ),
      );
      expect(client.aborted, 1);
      client.releaseHeld();
    });

    test(
      'fails with a network error when the client cannot reach the host',
      () async {
        final FakeHttpClient client = FakeHttpClient.withBody('{}')
          ..failWith = const SocketFailure();
        final HttpClientTransport transport = HttpClientTransport(
          httpClient: client,
          ownsClient: false,
        );
        addTearDown(transport.close);

        await expectLater(
          transport.send(
            ProviderRequest(
              method: 'GET',
              uri: Uri.parse('https://gateway.example/api/v1/models'),
            ),
          ),
          throwsA(
            isA<ProviderException>().having(
              (ProviderException e) => e.kind,
              'kind',
              ProviderErrorKind.network,
            ),
          ),
        );
      },
    );
  });

  group('TokenUsage', () {
    test('parses prompt/completion/total from a real response block', () {
      final TokenUsage usage = TokenUsage.fromJson(const <String, dynamic>{
        'prompt_tokens': 11,
        'completion_tokens': 7,
        'total_tokens': 18,
      });

      expect(usage.promptTokens, 11);
      expect(usage.completionTokens, 7);
      expect(usage.totalTokens, 18);
    });

    test('derives total only when the provider omitted it', () {
      final TokenUsage usage = TokenUsage.fromJson(const <String, dynamic>{
        'prompt_tokens': 3,
        'completion_tokens': 4,
      });

      expect(usage.totalTokens, 7);
    });

    test('accepts numeric strings and rejects nonsense', () {
      expect(
        TokenUsage.fromJson(const <String, dynamic>{
          'prompt_tokens': '5',
          'completion_tokens': '6',
        }).totalTokens,
        11,
      );
      expect(
        () => TokenUsage.fromJson(const <String, dynamic>{
          'prompt_tokens': -1,
          'completion_tokens': 0,
        }),
        throwsA(isA<ProviderException>()),
      );
      expect(
        () => TokenUsage.fromJson(const <String, dynamic>{
          'prompt_tokens': 'many',
          'completion_tokens': 0,
        }),
        throwsA(isA<ProviderException>()),
      );
      expect(() => TokenUsage.fromJson(1), throwsA(isA<ProviderException>()));
    });
  });

  group('ChatRequest validation', () {
    test('rejects a blank model and an empty message list', () {
      expect(() => _request(model: ' '), throwsArgumentError);
      expect(
        () => ChatRequest(model: 'm', messages: const <ChatMessage>[]),
        throwsArgumentError,
      );
    });

    test('round-trips a usage block through its wire form', () {
      final TokenUsage usage = _usageJson(const <String, dynamic>{
        'prompt_tokens': 2,
        'completion_tokens': 3,
        'total_tokens': 5,
      });

      expect(usage.toJson(), const <String, dynamic>{
        'prompt_tokens': 2,
        'completion_tokens': 3,
        'total_tokens': 5,
      });
    });

    test('serialises an OpenAI-compatible body and omits unset knobs', () {
      final Map<String, dynamic> json = _request().toJson(stream: true);

      expect(json['model'], 'vendor/free-model:free');
      expect(json['stream'], isTrue);
      expect(json['stream_options'], <String, dynamic>{'include_usage': true});
      expect(json['messages'], <dynamic>[
        <String, dynamic>{'role': 'user', 'content': 'hello'},
      ]);
      expect(json.containsKey('temperature'), isFalse);
      expect(_request().toJson(stream: false)['stream'], isFalse);
    });

    test('serialises the optional knobs and the provider escape hatch', () {
      final Map<String, dynamic> json = ChatRequest(
        model: 'm',
        messages: <ChatMessage>[ChatMessage(ChatRole.system, 'be terse')],
        temperature: 0.2,
        maxTokens: 256,
        topP: 0.9,
        stop: const <String>['\n\n'],
        extra: const <String, dynamic>{'provider': 'reasoning'},
      ).toJson(stream: false);

      expect(json['temperature'], 0.2);
      expect(json['max_tokens'], 256);
      expect(json['top_p'], 0.9);
      expect(json['stop'], <String>['\n\n']);
      expect(json['provider'], 'reasoning');
      expect(json.containsKey('stream_options'), isFalse);
    });
  });

  group('OpenRouterAdapter.completeChat', () {
    test(
      'posts an OpenAI-compatible chat completion and parses the result',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => jsonResponse(const <String, dynamic>{
            'id': 'chatcmpl-1',
            'model': 'vendor/free-model:free',
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'message': <String, dynamic>{
                  'role': 'assistant',
                  'content': 'hi',
                },
                'finish_reason': 'stop',
              },
            ],
            'usage': <String, dynamic>{
              'prompt_tokens': 9,
              'completion_tokens': 2,
              'total_tokens': 11,
            },
          }),
        ]);
        final OpenRouterAdapter adapter = _adapter(transport);

        final ChatCompletion completion = await adapter.completeChat(
          request: _request(),
        );

        final ProviderRequest sent = transport.requests.single;
        expect(sent.method, 'POST');
        expect(sent.uri.path, '/api/v1/chat/completions');
        expect(sent.uri.host, 'gateway.example');
        expect(sent.expectsStream, isFalse);
        expect(_payload(sent)['stream'], isFalse);
        expect(sent.headers['Authorization'], 'Bearer test-key');
        expect(completion.id, 'chatcmpl-1');
        expect(completion.model, 'vendor/free-model:free');
        expect(completion.content, 'hi');
        expect(completion.finishReason, 'stop');
        expect(completion.usage!.totalTokens, 11);
      },
    );

    test('never fabricates usage when the response omits it', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(const <String, dynamic>{
          'id': 'chatcmpl-2',
          'model': 'm',
          'choices': <dynamic>[
            <String, dynamic>{
              'index': 0,
              'message': <String, dynamic>{'content': 'no usage here'},
              'finish_reason': 'stop',
            },
          ],
        }),
      ]);

      final ChatCompletion completion = await _adapter(
        transport,
      ).completeChat(request: _request());

      expect(completion.content, 'no usage here');
      expect(completion.usage, isNull);
    });

    test('maps 401 onto an auth error and does not retry it', () async {
      final List<Duration> delays = <Duration>[];
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(const <String, dynamic>{
          'error': 'invalid api key',
        }, status: 401),
      ]);
      final OpenRouterAdapter adapter = OpenRouterAdapter(
        transport: transport,
        auth: _auth(),
        sleep: (Duration d) async => delays.add(d),
      );

      await expectLater(
        adapter.completeChat(request: _request()),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.auth,
          ),
        ),
      );
      expect(transport.callCount, 1);
      expect(delays, isEmpty);
    });

    test('reports a malformed body instead of guessing at content', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => rawResponse('not json at all'),
      ]);

      await expectLater(
        _adapter(transport).completeChat(request: _request()),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.malformed,
          ),
        ),
      );
    });

    test('rejects a payload without any choice', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(const <String, dynamic>{
          'id': 'x',
          'choices': <dynamic>[],
        }),
      ]);

      await expectLater(
        _adapter(transport).completeChat(request: _request()),
        throwsA(isA<ProviderException>()),
      );
    });

    test('surfaces a transport/network failure as a typed error', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => throw const SocketFailure(),
      ]);

      await expectLater(
        _adapter(transport).completeChat(request: _request()),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.network,
          ),
        ),
      );
    });
  });

  group('SseParser', () {
    test('joins multi-line data, keeps id/event and ignores comments', () {
      final List<SseEvent> events = <SseEvent>[];
      final SseParser parser = SseParser(events.add);

      parser
        ..addLine(': keep-alive')
        ..addLine('id: 42')
        ..addLine('event: message')
        ..addLine('data: line one')
        ..addLine('data: line two')
        ..addLine('');

      expect(events, hasLength(1));
      expect(events.single.id, '42');
      expect(events.single.event, 'message');
      expect(events.single.data, 'line one\nline two');
      expect(events.single.isDone, isFalse);
    });

    test('handles CRLF frames, unknown fields and the [DONE] sentinel', () {
      final List<SseEvent> events = <SseEvent>[];
      final SseParser parser = SseParser(events.add);

      parser
        ..addLine('data: {"a":1}\r')
        ..addLine('unknown: field')
        ..addLine('\r')
        ..addLine('data: [DONE]')
        ..addLine('');

      expect(events.map((SseEvent e) => e.data), <String>['{"a":1}', '[DONE]']);
      expect(events.last.isDone, isTrue);
    });

    test(
      'flush emits a trailing frame that was never blank-line terminated',
      () {
        final List<SseEvent> events = <SseEvent>[];
        final SseParser parser = SseParser(events.add)
          ..addLine('data: {"tail":true}');

        expect(events, isEmpty);

        parser.flush();

        expect(events.single.data, '{"tail":true}');
      },
    );
  });

  group('OpenRouterAdapter.streamChat', () {
    test(
      'emits ordered text deltas and exactly one terminal completion',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => sseResponse(<String>[
            jsonEncode(const <String, dynamic>{
              'id': 'chatcmpl-3',
              'model': 'vendor/free-model:free',
              'choices': <dynamic>[
                <String, dynamic>{
                  'index': 0,
                  'delta': <String, dynamic>{'role': 'assistant'},
                },
              ],
            }),
            jsonEncode(const <String, dynamic>{
              'choices': <dynamic>[
                <String, dynamic>{
                  'index': 0,
                  'delta': <String, dynamic>{'content': 'Hel'},
                },
              ],
            }),
            jsonEncode(const <String, dynamic>{
              'choices': <dynamic>[
                <String, dynamic>{
                  'index': 0,
                  'delta': <String, dynamic>{'content': 'lo'},
                },
              ],
            }),
            jsonEncode(const <String, dynamic>{
              'choices': <dynamic>[
                <String, dynamic>{
                  'index': 0,
                  'delta': <String, dynamic>{},
                  'finish_reason': 'stop',
                },
              ],
              'usage': <String, dynamic>{
                'prompt_tokens': 4,
                'completion_tokens': 2,
              },
            }),
          ]),
        ]);

        final List<ProviderStreamEvent> events = await _adapter(
          transport,
        ).streamChat(request: _request()).toList();

        expect(
          events.whereType<ProviderTextDelta>().map(
            (ProviderTextDelta e) => e.text,
          ),
          <String>['Hel', 'lo'],
        );
        expect(events.whereType<ProviderUsage>(), hasLength(1));
        expect(events.whereType<ProviderUsage>().single.usage.totalTokens, 6);
        final ProviderCompleted completed = events
            .whereType<ProviderCompleted>()
            .single;
        expect(completed.completion.content, 'Hello');
        expect(completed.completion.finishReason, 'stop');
        expect(completed.completion.usage!.totalTokens, 6);
        expect(events.whereType<ProviderFailed>(), isEmpty);
        expect(events.last, isA<ProviderCompleted>());

        final ProviderRequest sent = transport.requests.single;
        expect(sent.expectsStream, isTrue);
        expect(sent.headers['accept'], 'text/event-stream');
        expect(_payload(sent)['stream'], isTrue);
      },
    );

    test('parses frames that arrive split across byte chunks', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => chunkedSseResponse(<String>[
          'data: {"choices":[{"index":0,"delta":{"cont',
          'ent":"partial"}}]}\n\ndata: {"choices":[{"index":0,"del',
          'ta":{"content":" chunk"},"finish_reason":"stop"}]}\n\n',
        ]),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
      ).streamChat(request: _request()).toList();

      // The first frame was cut mid-JSON across two byte chunks.
      expect(
        events.whereType<ProviderTextDelta>().map(
          (ProviderTextDelta e) => e.text,
        ),
        <String>['partial', ' chunk'],
      );
      expect(
        events.whereType<ProviderCompleted>().single.completion.content,
        'partial chunk',
      );
    });

    test('never invents usage: no usage frame means no usage events', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => sseResponse(<String>[
          jsonEncode(const <String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'delta': <String, dynamic>{'content': 'x'},
              },
            ],
          }),
        ]),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
      ).streamChat(request: _request()).toList();

      expect(events.whereType<ProviderUsage>(), isEmpty);
      expect(
        events.whereType<ProviderCompleted>().single.completion.usage,
        isNull,
      );
    });

    test('fails the stream on a malformed frame and stops emitting', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => sseResponse(<String>[
          jsonEncode(const <String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'delta': <String, dynamic>{'content': 'ok'},
              },
            ],
          }),
          '{ this is not json',
          jsonEncode(const <String, dynamic>{
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'delta': <String, dynamic>{'content': 'never'},
              },
            ],
          }),
        ]),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
      ).streamChat(request: _request()).toList();

      expect(
        events.whereType<ProviderTextDelta>().map(
          (ProviderTextDelta e) => e.text,
        ),
        <String>['ok'],
      );
      final ProviderFailed failed = events.whereType<ProviderFailed>().single;
      expect(failed.error.kind, ProviderErrorKind.malformed);
      expect(events.whereType<ProviderCompleted>(), isEmpty);
      expect(events.last, isA<ProviderFailed>());
    });

    test('maps an in-band error frame onto a typed failure', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => sseResponse(<String>[
          jsonEncode(const <String, dynamic>{
            'error': <String, dynamic>{
              'message': 'Rate limit reached for this key',
              'code': 'rate_limit_exceeded',
            },
          }),
        ], includeDone: false),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
      ).streamChat(request: _request()).toList();

      final ProviderFailed failed = events.whereType<ProviderFailed>().single;
      expect(failed.error.kind, ProviderErrorKind.rateLimit);
      expect(failed.error.message, contains('Rate limit'));
    });

    test(
      'fails fast when a usage frame carries impossible token counts',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => sseResponse(<String>[
            jsonEncode(const <String, dynamic>{
              'choices': <dynamic>[],
              'usage': <String, dynamic>{'prompt_tokens': -3},
            }),
          ]),
        ]);

        final List<ProviderStreamEvent> events = await _adapter(
          transport,
        ).streamChat(request: _request()).toList();

        expect(
          events.whereType<ProviderFailed>().single.error.kind,
          ProviderErrorKind.malformed,
        );
      },
    );

    test(
      'turns a non-success status into one terminal failure event',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => rawResponse(
            'overloaded',
            status: 429,
            headers: const <String, String>{'retry-after': '1'},
          ),
        ]);

        final List<ProviderStreamEvent> events = await _adapter(
          transport,
          retry: RetryPolicy.none,
        ).streamChat(request: _request()).toList();

        final ProviderFailed failed = events.whereType<ProviderFailed>().single;
        expect(failed.error.kind, ProviderErrorKind.rateLimit);
        expect(failed.error.statusCode, 429);
        expect(failed.error.retryAfter, const Duration(seconds: 1));
        expect(events.whereType<ProviderCompleted>(), isEmpty);
      },
    );

    test(
      'completes when the provider closes the stream without [DONE]',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => sseResponse(<String>[
            jsonEncode(const <String, dynamic>{
              'choices': <dynamic>[
                <String, dynamic>{
                  'index': 0,
                  'delta': <String, dynamic>{'content': 'tail'},
                  'finish_reason': 'stop',
                },
              ],
            }),
          ], includeDone: false),
        ]);

        final List<ProviderStreamEvent> events = await _adapter(
          transport,
        ).streamChat(request: _request()).toList();

        expect(events.last, isA<ProviderCompleted>());
        expect((events.last as ProviderCompleted).completion.content, 'tail');
      },
    );

    test('reports a body stream failure as a terminal network error', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => erroringResponse(
          const SocketFailure(),
          chunks: <String>['data: {"choices":[{"index":0,"delta":{'],
        ),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
      ).streamChat(request: _request()).toList();

      expect(
        events.whereType<ProviderFailed>().single.error.kind,
        ProviderErrorKind.network,
      );
    });

    test(
      'rejects an empty SSE body as malformed instead of an empty answer',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => rawResponse('', status: 200),
        ]);

        final List<ProviderStreamEvent> events = await _adapter(
          transport,
        ).streamChat(request: _request()).toList();

        expect(
          events.whereType<ProviderFailed>().single.error.kind,
          ProviderErrorKind.malformed,
        );
      },
    );
  });
}

/// Local stand-in for a socket failure so the mapping is exercised without
/// constructing a real dart:io exception in the assertion surface.
class SocketFailure implements Exception {
  const SocketFailure();
}
