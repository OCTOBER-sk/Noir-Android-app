// Provider runtime — cancellation, timeouts and bounded retry/backoff.
//
// Uses the no-socket transport doubles only; the backoff clock is injected so
// the suite never sleeps for real retry delays.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/providers/adapters/openrouter_adapter.dart';
import 'package:noir_android_app/providers/auth_config.dart';
import 'package:noir_android_app/providers/cancellation.dart';
import 'package:noir_android_app/providers/chat_types.dart';
import 'package:noir_android_app/providers/errors.dart';
import 'package:noir_android_app/providers/streaming.dart';
import 'package:noir_android_app/providers/transport.dart';

import 'support/fake_transport.dart';

ProviderAuthConfig _auth() => ProviderAuthConfig(
  baseUrl: 'https://gateway.example/api/v1',
  apiKey: 'test-key',
);

const ProviderTimeouts _fast = ProviderTimeouts(
  firstByte: Duration(milliseconds: 40),
  idle: Duration(milliseconds: 40),
);

const ProviderTimeouts _patient = ProviderTimeouts(
  firstByte: Duration(seconds: 5),
  idle: Duration(seconds: 5),
);

ChatRequest _request() => ChatRequest(
  model: 'vendor/free-model:free',
  messages: <ChatMessage>[ChatMessage(ChatRole.user, 'hello')],
);

OpenRouterAdapter _adapter(
  FakeTransport transport, {
  RetryPolicy retry = const RetryPolicy(maxAttempts: 3),
  ProviderTimeouts timeouts = const ProviderTimeouts(),
  void Function(Duration)? onSleep,
}) => OpenRouterAdapter(
  transport: transport,
  auth: _auth(),
  retry: retry,
  timeouts: timeouts,
  sleep: (Duration d) async {
    onSleep?.call(d);
  },
);

String _chunk(String content, {String? finishReason}) =>
    jsonEncode(<String, dynamic>{
      'choices': <dynamic>[
        <String, dynamic>{
          'index': 0,
          'delta': <String, dynamic>{'content': content},
          if (finishReason != null) 'finish_reason': finishReason,
        },
      ],
    });

void main() {
  group('CancellationToken', () {
    test('starts live, then reports cancellation and keeps the reason', () {
      final CancellationToken token = CancellationToken();
      expect(token.isCancelled, isFalse);
      expect(token.throwIfCancelled, returnsNormally);

      final Future<void> whenCancelled = token.whenCancelled;
      token.cancel('user stopped');

      expect(token.isCancelled, isTrue);
      expect(token.reason, 'user stopped');
      expect(token.throwIfCancelled, throwsA(isA<ProviderException>()));
      expect(whenCancelled, completes);
      token.cancel('again');
      expect(token.reason, 'user stopped', reason: 'first reason wins');
    });

    test('listener removal stops further notifications', () {
      final CancellationToken token = CancellationToken();
      int calls = 0;
      final void Function() remove = token.addListener(() => calls += 1);

      remove();
      token.cancel();

      expect(calls, 0);
    });
  });

  group('cancellation', () {
    test('a pre-cancelled token never reaches the transport', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[]);
      final CancellationToken token = CancellationToken()..cancel('early');

      await expectLater(
        _adapter(
          transport,
        ).completeChat(request: _request(), cancellation: token),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.cancelled,
          ),
        ),
      );
      expect(transport.callCount, 0);
    });

    test(
      'cancelling mid-stream keeps prior deltas and fails terminally',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => chunkedSseResponse(
            <String>[
              'data: ${_chunk('one')}\n\n',
              'data: ${_chunk('two')}\n\n',
            ],
            includeDone: false,
            gap: const Duration(milliseconds: 120),
          ),
        ]);
        final CancellationToken token = CancellationToken();
        final List<ProviderStreamEvent> events = <ProviderStreamEvent>[];

        final StreamSubscription<ProviderStreamEvent> subscription =
            _adapter(transport, timeouts: _patient)
                .streamChat(request: _request(), cancellation: token)
                .listen((ProviderStreamEvent event) {
                  events.add(event);
                  if (event is ProviderTextDelta) token.cancel('user stopped');
                });
        await subscription.asFuture<void>();

        expect(
          events.whereType<ProviderTextDelta>().map(
            (ProviderTextDelta e) => e.text,
          ),
          <String>['one'],
        );
        expect(
          events.whereType<ProviderFailed>().single.error.kind,
          ProviderErrorKind.cancelled,
        );
        expect(events.whereType<ProviderCompleted>(), isEmpty);
      },
    );

    test('cancelling the returned subscription stops the pump', () async {
      int bodyCancels = 0;
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => chunkedSseResponse(
          <String>[
            'data: ${_chunk('one')}\n\n',
            'data: ${_chunk('two')}\n\n',
            'data: ${_chunk('three', finishReason: 'stop')}\n\n',
          ],
          includeDone: false,
          gap: const Duration(milliseconds: 60),
          onBodyCancel: () => bodyCancels += 1,
        ),
      ]);

      final List<ProviderStreamEvent> first = await _adapter(
        transport,
        timeouts: _patient,
      ).streamChat(request: _request()).take(1).toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(first.single, isA<ProviderTextDelta>());
      expect(bodyCancels, 1, reason: 'the body subscription is released');
      expect(transport.callCount, 1);
    });

    test('cancelling before the first byte never opens a request', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => hangingResponse(),
      ]);
      final CancellationToken token = CancellationToken()..cancel('stop');

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
      ).streamChat(request: _request(), cancellation: token).toList();

      expect(events, hasLength(1));
      expect(
        events.whereType<ProviderFailed>().single.error.kind,
        ProviderErrorKind.cancelled,
      );
      expect(transport.callCount, 0);
    });
  });

  group('timeouts', () {
    test('a response that never starts fails as a timeout', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => hangingResponse(),
      ]);

      await expectLater(
        _adapter(transport, timeouts: _fast).completeChat(request: _request()),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.timeout,
          ),
        ),
      );
      expect(transport.callCount, 1, reason: 'a timeout is not retried');
    });

    test('a stream that stalls between chunks fails as a timeout', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => chunkedSseResponse(
          <String>['data: ${_chunk('one')}\n\n', 'data: ${_chunk('two')}\n\n'],
          includeDone: false,
          gap: const Duration(milliseconds: 200),
        ),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
        timeouts: _fast,
      ).streamChat(request: _request()).toList();

      expect(
        events.whereType<ProviderTextDelta>().map(
          (ProviderTextDelta e) => e.text,
        ),
        <String>['one'],
      );
      expect(
        events.whereType<ProviderFailed>().single.error.kind,
        ProviderErrorKind.timeout,
      );
    });

    test('an overall deadline ends a long stream', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => chunkedSseResponse(<String>[
          'data: ${_chunk('a')}\n\n',
          'data: ${_chunk('b')}\n\n',
          'data: ${_chunk('c', finishReason: 'stop')}\n\n',
        ], gap: const Duration(milliseconds: 60)),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
        timeouts: const ProviderTimeouts(
          firstByte: Duration(seconds: 5),
          idle: Duration(seconds: 5),
          overall: Duration(milliseconds: 80),
        ),
      ).streamChat(request: _request()).toList();

      expect(
        events.whereType<ProviderFailed>().single.error.kind,
        ProviderErrorKind.timeout,
      );
      expect(events.whereType<ProviderCompleted>(), isEmpty);
    });
  });

  group('retry and backoff', () {
    test('backs off exponentially and then succeeds', () async {
      final List<Duration> delays = <Duration>[];
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => rawResponse('overloaded', status: 503),
        (ProviderRequest _) => rawResponse('overloaded', status: 503),
        (ProviderRequest _) => jsonResponse(<String, dynamic>{
          'id': 'ok',
          'model': 'vendor/free-model:free',
          'choices': <dynamic>[
            <String, dynamic>{
              'index': 0,
              'message': <String, dynamic>{'content': 'recovered'},
              'finish_reason': 'stop',
            },
          ],
        }),
      ]);

      final ChatCompletion completion = await _adapter(
        transport,
        retry: const RetryPolicy(
          maxAttempts: 3,
          initialBackoff: Duration(milliseconds: 20),
        ),
        onSleep: delays.add,
      ).completeChat(request: _request());

      expect(completion.content, 'recovered');
      expect(delays, <Duration>[
        const Duration(milliseconds: 20),
        const Duration(milliseconds: 40),
      ]);
      expect(transport.callCount, 3);
    });

    test('honours a longer Retry-After than the computed backoff', () async {
      final List<Duration> delays = <Duration>[];
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => rawResponse(
          'slow down',
          status: 429,
          headers: const <String, String>{'retry-after': '3'},
        ),
        (ProviderRequest _) => jsonResponse(<String, dynamic>{
          'choices': <dynamic>[
            <String, dynamic>{
              'index': 0,
              'message': <String, dynamic>{'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
        }),
      ]);

      await _adapter(
        transport,
        retry: const RetryPolicy(
          maxAttempts: 2,
          initialBackoff: Duration(milliseconds: 20),
        ),
        onSleep: delays.add,
      ).completeChat(request: _request());

      expect(delays, <Duration>[const Duration(seconds: 3)]);
    });

    test('stops at maxAttempts and rethrows the last typed error', () async {
      final List<Duration> delays = <Duration>[];
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        for (int i = 0; i < 4; i++)
          (ProviderRequest _) => rawResponse('boom', status: 500),
      ]);

      await expectLater(
        _adapter(
          transport,
          retry: const RetryPolicy(
            maxAttempts: 2,
            initialBackoff: Duration(milliseconds: 20),
          ),
          onSleep: delays.add,
        ).completeChat(request: _request()),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
      expect(transport.callCount, 2);
      expect(delays, hasLength(1));
    });

    test(
      'retries the initial request of a stream, not a mid-stream failure',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => rawResponse('busy', status: 502),
          (ProviderRequest _) => sseResponse(<String>[
            _chunk('after retry', finishReason: 'stop'),
          ]),
        ]);
        final List<Duration> delays = <Duration>[];

        final List<ProviderStreamEvent> events = await _adapter(
          transport,
          onSleep: delays.add,
        ).streamChat(request: _request()).toList();

        expect(transport.callCount, 2);
        expect(delays, hasLength(1));
        expect(events.last, isA<ProviderCompleted>());
      },
    );

    test('a mid-stream failure is terminal and is not retried', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => erroringResponse(
          const SocketFailure(),
          chunks: <String>['data: ${_chunk('partial')}\n\n'],
        ),
      ]);

      final List<ProviderStreamEvent> events = await _adapter(
        transport,
      ).streamChat(request: _request()).toList();

      expect(transport.callCount, 1);
      expect(
        events.whereType<ProviderFailed>().single.error.kind,
        ProviderErrorKind.network,
      );
      expect(
        events.whereType<ProviderTextDelta>().map(
          (ProviderTextDelta e) => e.text,
        ),
        <String>['partial'],
      );
    });

    test('cancellation during backoff prevents a further attempt', () async {
      final CancellationToken token = CancellationToken();
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        for (int i = 0; i < 3; i++)
          (ProviderRequest _) => rawResponse('busy', status: 500),
      ]);

      await expectLater(
        _adapter(
          transport,
          retry: const RetryPolicy(
            maxAttempts: 3,
            initialBackoff: Duration(milliseconds: 20),
          ),
          onSleep: (Duration _) => token.cancel('stop during backoff'),
        ).completeChat(request: _request(), cancellation: token),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.cancelled,
          ),
        ),
      );
      expect(transport.callCount, 1);
    });

    test('RetryPolicy.none performs a single attempt', () {
      expect(RetryPolicy.none.maxAttempts, 1);
      expect(const RetryPolicy().maxAttempts, greaterThan(1));
    });

    test('backoff grows exponentially and is capped', () {
      const RetryPolicy policy = RetryPolicy(
        maxAttempts: 6,
        initialBackoff: Duration(milliseconds: 100),
        multiplier: 2,
        maxBackoff: Duration(milliseconds: 350),
      );

      expect(policy.backoffFor(1), const Duration(milliseconds: 100));
      expect(policy.backoffFor(2), const Duration(milliseconds: 200));
      expect(policy.backoffFor(3), const Duration(milliseconds: 350));
      expect(policy.backoffFor(9), const Duration(milliseconds: 350));
    });
  });
}

/// Local stand-in for a socket-level failure.
class SocketFailure implements Exception {
  const SocketFailure();
}
