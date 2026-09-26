// Provider runtime — live model discovery and routing.
//
// Discovery parses a real /models-style payload through the injected
// transport; there is no static fallback list anywhere in this path.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/providers/auth_config.dart';
import 'package:noir_android_app/providers/cancellation.dart';
import 'package:noir_android_app/providers/chat_types.dart';
import 'package:noir_android_app/providers/errors.dart';
import 'package:noir_android_app/providers/model_discovery.dart';
import 'package:noir_android_app/providers/model_router.dart';
import 'package:noir_android_app/providers/transport.dart';

import 'support/fake_transport.dart';

ProviderAuthConfig _auth() => ProviderAuthConfig(
  baseUrl: 'https://gateway.example/api/v1',
  apiKey: 'test-key',
);

/// A realistic OpenAI-compatible /models payload, including junk entries that a
/// parser must reject rather than surface as usable models.
const Map<String, dynamic> _modelsPayload = <String, dynamic>{
  'object': 'list',
  'data': <dynamic>[
    <String, dynamic>{
      'id': 'vendor/alpha:free',
      'name': 'Vendor Alpha',
      'context_length': 32768,
      'created': 1717171717,
      'pricing': <String, dynamic>{'prompt': '0', 'completion': '0'},
    },
    <String, dynamic>{
      'id': 'vendor/beta',
      'name': 'Vendor Beta',
      'context_length': 8192,
      'pricing': <String, dynamic>{
        'prompt': '0.0000015',
        'completion': '0.0000075',
      },
    },
    <String, dynamic>{'id': '   ', 'name': 'blank id'},
    <String, dynamic>{'name': 'no id at all'},
    <String, dynamic>{'id': 42},
    'not-an-object',
    <String, dynamic>{'id': 'vendor/alpha:free', 'name': 'duplicate of alpha'},
  ],
};

ModelDiscovery _discovery(FakeTransport transport) => ModelDiscovery(
  transport: transport,
  auth: _auth(),
  sleep: (Duration _) async {},
);

ChatRequest _request() => ChatRequest(
  model: 'vendor/alpha:free',
  messages: <ChatMessage>[ChatMessage(ChatRole.user, 'hello')],
);

void main() {
  group('ModelDiscovery.fetch', () {
    test('issues an authenticated GET against the models endpoint', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(_modelsPayload),
      ]);

      await _discovery(transport).fetch();

      final ProviderRequest sent = transport.requests.single;
      expect(sent.method, 'GET');
      expect(sent.uri.path, '/api/v1/models');
      expect(sent.body, isNull);
      expect(sent.headers['Authorization'], 'Bearer test-key');
    });

    test('parses a real models payload into typed entries', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(_modelsPayload),
      ]);

      final ModelDiscoveryResult result = await _discovery(transport).fetch();

      expect(result.models, hasLength(2));
      expect(result.models.first.id, 'vendor/alpha:free');
      expect(result.models.first.displayName, 'Vendor Alpha');
      expect(result.models.first.contextLength, 32768);
      expect(result.models.first.createdAtSeconds, 1717171717);
      expect(result.models.first.isFree, isTrue);
      expect(result.models.last.id, 'vendor/beta');
      expect(result.models.last.isFree, isFalse);
      expect(result.models.last.promptPricePer1MTokens, closeTo(1.5, 1e-9));
      expect(result.models.last.completionPricePer1MTokens, closeTo(7.5, 1e-9));
      expect(result.source.path, '/api/v1/models');
    });

    test('drops invalid and duplicate entries and reports how many', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(_modelsPayload),
      ]);

      final ModelDiscoveryResult result = await _discovery(transport).fetch();

      expect(result.rejectedEntries, 5);
      expect(result.models.map((DiscoveredModel m) => m.id).toSet(), <String>{
        'vendor/alpha:free',
        'vendor/beta',
      });
      expect(
        result.rejectedIds,
        contains('vendor/alpha:free'),
        reason: 'the duplicate occurrence is reported',
      );
      expect(
        result.models.where((DiscoveredModel m) => m.id == 'vendor/alpha:free'),
        hasLength(1),
        reason: 'a duplicate id is never surfaced twice',
      );
    });

    test('treats a payload without a data list as malformed', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) =>
            jsonResponse(const <String, dynamic>{'object': 'list'}),
      ]);

      await expectLater(
        _discovery(transport).fetch(),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.malformed,
          ),
        ),
      );
    });

    test(
      'surfaces an auth failure instead of falling back to a static list',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => jsonResponse(const <String, dynamic>{
            'error': 'missing key',
          }, status: 401),
        ]);

        await expectLater(
          _discovery(transport).fetch(),
          throwsA(
            isA<ProviderException>().having(
              (ProviderException e) => e.kind,
              'kind',
              ProviderErrorKind.auth,
            ),
          ),
        );
        expect(transport.callCount, 1);
      },
    );

    test('retries a transient discovery failure', () async {
      final List<Duration> delays = <Duration>[];
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => rawResponse('unavailable', status: 503),
        (ProviderRequest _) => jsonResponse(_modelsPayload),
      ]);

      final ModelDiscoveryResult result = await ModelDiscovery(
        transport: transport,
        auth: _auth(),
        sleep: (Duration d) async => delays.add(d),
      ).fetch();

      expect(result.models, hasLength(2));
      expect(transport.callCount, 2);
      expect(delays, hasLength(1));
    });

    test('applies the free-only and context-length filters', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        for (int i = 0; i < 3; i++)
          (ProviderRequest _) => jsonResponse(_modelsPayload),
      ]);
      final ModelDiscovery discovery = _discovery(transport);

      final ModelDiscoveryResult free = await discovery.fetch(
        filter: const ModelDiscoveryFilter(freeOnly: true),
      );
      expect(free.models.map((DiscoveredModel m) => m.id), <String>[
        'vendor/alpha:free',
      ]);

      final ModelDiscoveryResult longContext = await discovery.fetch(
        filter: const ModelDiscoveryFilter(minContextLength: 16384),
      );
      expect(longContext.models.map((DiscoveredModel m) => m.id), <String>[
        'vendor/alpha:free',
      ]);

      final ModelDiscoveryResult prefixed = await discovery.fetch(
        filter: const ModelDiscoveryFilter(idPrefix: 'vendor/beta'),
      );
      expect(prefixed.models.map((DiscoveredModel m) => m.id), <String>[
        'vendor/beta',
      ]);
    });

    test('honours cancellation without issuing a request', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[]);
      final CancellationToken token = CancellationToken()..cancel('stop');

      await expectLater(
        _discovery(transport).fetch(cancellation: token),
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
  });

  group('ModelRouter', () {
    late FakeTransport transport;

    ModelRouter router({Duration ttl = const Duration(minutes: 10)}) {
      transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(_modelsPayload),
      ]);
      return ModelRouter(discovery: _discovery(transport), cacheTtl: ttl);
    }

    test(
      'loads the catalog from the endpoint and caches it for the TTL',
      () async {
        final ModelRouter r = router();

        final ModelCatalog first = await r.catalog();
        final ModelCatalog second = await r.catalog();

        expect(first.models, hasLength(2));
        expect(first.fromCache, isFalse);
        expect(second.fromCache, isTrue);
        expect(transport.callCount, 1);
        expect(first.rejectedEntries, 5);
      },
    );

    test('refetches when the TTL has expired or a refresh is forced', () async {
      DateTime now = DateTime.utc(2026, 1, 1);
      transport = FakeTransport(<FakeHandler>[
        for (int i = 0; i < 3; i++)
          (ProviderRequest _) => jsonResponse(_modelsPayload),
      ]);
      final ModelRouter r = ModelRouter(
        discovery: ModelDiscovery(
          transport: transport,
          auth: _auth(),
          clock: () => now,
          sleep: (Duration _) async {},
        ),
        cacheTtl: const Duration(minutes: 10),
        clock: () => now,
      );

      await r.catalog();
      now = now.add(const Duration(minutes: 11));
      final ModelCatalog afterTtl = await r.catalog();
      expect(afterTtl.fromCache, isFalse);
      expect(transport.callCount, 2);

      await r.catalog(forceRefresh: true);
      expect(transport.callCount, 3);
    });

    test(
      'routes to the first preferred model present in the live catalog',
      () async {
        final RouteDecision decision = await router().route(
          preferredModelIds: <String>['vendor/beta', 'vendor/alpha:free'],
        );

        expect(decision.model!.id, 'vendor/beta');
        expect(decision.reason, RouteReason.preferred);
        expect(decision.rotatedOut, isEmpty);
      },
    );

    test(
      'reports rotated-out models and falls through the preference list',
      () async {
        final ModelRouter r = router();
        final Future<ModelRotationEvent> nextRotation = r.rotations.first;

        final RouteDecision decision = await r.route(
          preferredModelIds: <String>['vendor/gone:free', 'vendor/alpha:free'],
        );

        final ModelRotationEvent rotation = await nextRotation;
        expect(decision.model!.id, 'vendor/alpha:free');
        expect(decision.reason, RouteReason.preferred);
        expect(decision.rotatedOut, <String>['vendor/gone:free']);
        expect(rotation.rotatedOut, <String>['vendor/gone:free']);
        expect(rotation.availableModelIds, <String>[
          'vendor/alpha:free',
          'vendor/beta',
        ]);
      },
    );

    test(
      'falls back to a live catalog model when no preference survives',
      () async {
        final RouteDecision decision = await router().route(
          preferredModelIds: <String>['vendor/gone:free'],
        );

        expect(decision.reason, RouteReason.catalogFallback);
        expect(decision.model, isNotNull);
        expect(decision.rotatedOut, <String>['vendor/gone:free']);
      },
    );

    test('honours the free-tier constraint', () async {
      final RouteDecision decision = await router().route(
        preferredModelIds: <String>['vendor/beta'],
        requireFreeTier: true,
      );

      expect(decision.model!.id, 'vendor/alpha:free');
      expect(decision.reason, RouteReason.catalogFallback);
    });

    test('returns no candidate instead of a fabricated model id', () async {
      final RouteDecision decision = await router().route(
        preferredModelIds: <String>['vendor/absent:free'],
        requireFreeTier: true,
        minContextLength: 999999,
      );

      expect(decision.model, isNull);
      expect(decision.reason, RouteReason.noCandidate);
    });

    test(
      'propagates a discovery failure rather than serving a static list',
      () async {
        final FakeTransport failing = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => jsonResponse(const <String, dynamic>{
            'error': 'nope',
          }, status: 401),
        ]);
        final ModelRouter r = ModelRouter(discovery: _discovery(failing));

        await expectLater(r.catalog(), throwsA(isA<ProviderException>()));
        await expectLater(r.route(), throwsA(isA<ProviderException>()));
      },
    );

    test(
      'walks the fallback chain on rate limits and returns the survivor',
      () async {
        final List<String> attempted = <String>[];
        final ModelRouter r = ModelRouter(
          discovery: _discovery(
            FakeTransport(<FakeHandler>[
              (ProviderRequest _) => jsonResponse(_modelsPayload),
            ]),
          ),
          executor:
              (ChatRequest request, {CancellationToken? cancellation}) async {
                attempted.add(request.model);
                if (request.model == 'vendor/alpha:free') {
                  throw ProviderException.fromStatus(429);
                }
                return ChatCompletion(
                  id: 'c1',
                  model: request.model,
                  content: 'from ${request.model}',
                  finishReason: 'stop',
                );
              },
        );

        final ChatCompletion completion = await r.executeFallback(
          request: _request(),
          candidateIds: <String>['vendor/alpha:free', 'vendor/beta'],
        );

        expect(attempted, <String>['vendor/alpha:free', 'vendor/beta']);
        expect(completion.model, 'vendor/beta');
        expect(completion.content, 'from vendor/beta');
      },
    );

    test('rethrows the last error once the chain is exhausted', () async {
      final ModelRouter r = ModelRouter(
        discovery: _discovery(
          FakeTransport(<FakeHandler>[
            (ProviderRequest _) => jsonResponse(_modelsPayload),
          ]),
        ),
        executor:
            (ChatRequest request, {CancellationToken? cancellation}) async {
              throw ProviderException.fromStatus(429);
            },
      );

      await expectLater(
        r.executeFallback(
          request: _request(),
          candidateIds: <String>['vendor/alpha:free', 'vendor/beta'],
        ),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.rateLimit,
          ),
        ),
      );
    });

    test(
      'a non-transient failure is not retried against other models',
      () async {
        final List<String> attempted = <String>[];
        final ModelRouter r = ModelRouter(
          discovery: _discovery(
            FakeTransport(<FakeHandler>[
              (ProviderRequest _) => jsonResponse(_modelsPayload),
            ]),
          ),
          executor:
              (ChatRequest request, {CancellationToken? cancellation}) async {
                attempted.add(request.model);
                throw ProviderException.fromStatus(401);
              },
        );

        await expectLater(
          r.executeFallback(
            request: _request(),
            candidateIds: <String>['vendor/alpha:free', 'vendor/beta'],
          ),
          throwsA(isA<ProviderException>()),
        );
        expect(attempted, <String>['vendor/alpha:free']);
      },
    );

    test('exposes the live catalog ids for callers and UI surfaces', () async {
      final ModelRouter r = router();

      await r.catalog();

      expect(r.cachedModelIds, <String>['vendor/alpha:free', 'vendor/beta']);
      expect(r.cachedModelIds, isNot(contains('noir-engine/pro-v2:free')));
      await r.dispose();
    });
  });

  group('DiscoveredModel pricing', () {
    test('keeps per-token prices and converts them per 1M tokens', () {
      final DiscoveredModel model = ModelDiscovery.parseModelsPayload(
        const <String, dynamic>{
          'data': <dynamic>[
            <String, dynamic>{
              'id': 'vendor/gamma',
              'pricing': <String, dynamic>{
                'prompt': '0.00000025',
                'completion': '0',
              },
            },
          ],
        },
      ).models.single;

      expect(model.promptPricePerToken, closeTo(0.00000025, 1e-12));
      expect(model.promptPricePer1MTokens, closeTo(0.25, 1e-9));
      expect(model.completionPricePer1MTokens, closeTo(0, 1e-9));
      expect(model.hasPricing, isTrue);
      expect(model.isFree, isFalse, reason: 'a paid prompt price is charged');
    });

    test('an entry without pricing is exposed without invented numbers', () {
      final DiscoveredModel model = ModelDiscovery.parseModelsPayload(
        const <String, dynamic>{
          'data': <dynamic>[
            <String, dynamic>{'id': 'vendor/delta:free'},
          ],
        },
      ).models.single;

      expect(model.hasPricing, isFalse);
      expect(model.promptPricePer1MTokens, isNull);
      expect(model.completionPricePer1MTokens, isNull);
      expect(model.isFree, isTrue, reason: 'the id advertises a free tier');
    });

    test('unparsable pricing values are dropped, not guessed', () {
      final DiscoveredModel model = ModelDiscovery.parseModelsPayload(
        const <String, dynamic>{
          'data': <dynamic>[
            <String, dynamic>{
              'id': 'vendor/epsilon',
              'pricing': <String, dynamic>{'prompt': 'free', 'completion': ''},
            },
          ],
        },
      ).models.single;

      expect(model.hasPricing, isFalse);
      expect(model.promptPricePer1MTokens, isNull);
    });
  });

  group('ModelDiscovery.parseModelsPayload', () {
    test('rejects a payload that is not an object', () {
      expect(
        () => ModelDiscovery.parseModelsPayload('nope'),
        throwsA(isA<ProviderException>()),
      );
      expect(
        () => ModelDiscovery.parseModelsPayload(const <String, dynamic>{
          'data': 'list',
        }),
        throwsA(isA<ProviderException>()),
      );
    });

    test('returns an empty catalog when the list is genuinely empty', () {
      final ModelDiscoveryResult result = ModelDiscovery.parseModelsPayload(
        const <String, dynamic>{'object': 'list', 'data': <dynamic>[]},
      );

      expect(result.models, isEmpty);
      expect(result.rejectedEntries, 0);
    });

    test('json-decodes a string payload', () {
      final ModelDiscoveryResult result = ModelDiscovery.parseModelsPayload(
        jsonEncode(_modelsPayload),
      );

      expect(result.models, hasLength(2));
    });
  });
}
