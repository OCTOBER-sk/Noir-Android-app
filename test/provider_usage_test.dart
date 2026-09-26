// Provider runtime — durable-friendly usage tracking and cost accounting.
//
// Usage is only ever recorded from a real response `usage` block; the tests
// assert that a response without usage leaves the tracker untouched.

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/providers/adapters/openrouter_adapter.dart';
import 'package:noir_android_app/providers/auth_config.dart';
import 'package:noir_android_app/providers/chat_types.dart';
import 'package:noir_android_app/providers/errors.dart';
import 'package:noir_android_app/providers/model_discovery.dart';
import 'package:noir_android_app/providers/transport.dart';
import 'package:noir_android_app/providers/usage_tracker.dart';

import 'support/fake_transport.dart';

ProviderAuthConfig _auth() => ProviderAuthConfig(
  baseUrl: 'https://gateway.example/api/v1',
  apiKey: 'test-key',
);

TokenUsage _usage(int prompt, int completion) =>
    TokenUsage(promptTokens: prompt, completionTokens: completion);

/// Durable store double: survives new tracker instances, like a file-backed
/// store would, and records the durability contract explicitly.
class FakeDurableStore implements UsageStore {
  final List<UsageRecord> written = <UsageRecord>[];

  @override
  Future<void> append(UsageRecord record) async {
    written.add(record);
  }

  @override
  Future<List<UsageRecord>> readAll() async => List<UsageRecord>.of(written);
}

PricingTable _pricing() => PricingTable.fromDiscovery(
  ModelDiscovery.parseModelsPayload(const <String, dynamic>{
    'data': <dynamic>[
      <String, dynamic>{
        'id': 'vendor/alpha:free',
        'pricing': <String, dynamic>{'prompt': '0', 'completion': '0'},
      },
      <String, dynamic>{
        'id': 'vendor/beta',
        'pricing': <String, dynamic>{
          'prompt': '0.0000015',
          'completion': '0.0000075',
        },
      },
    ],
  }).models,
);

void main() {
  group('UsageTracker.recordUsage', () {
    test('records provider-reported tokens and derived cost', () async {
      final FakeDurableStore store = FakeDurableStore();
      final UsageTracker tracker = UsageTracker(
        store: store,
        pricing: _pricing(),
      );

      final UsageRecord record = await tracker.recordUsage(
        model: 'vendor/beta',
        usage: _usage(1000, 500),
      );

      expect(record.model, 'vendor/beta');
      expect(record.source, UsageSource.providerReported);
      expect(record.promptTokens, 1000);
      expect(record.completionTokens, 500);
      expect(record.totalTokens, 1500);
      expect(
        record.costUsd,
        closeTo(1000 * 0.0000015 + 500 * 0.0000075, 1e-12),
      );
      expect(tracker.requestCount, 1);
      expect(tracker.promptTokens, 1000);
      expect(tracker.completionTokens, 500);
      expect(tracker.tokensUsed, 1500);
      expect(tracker.totalCostUsd, closeTo(0.00525, 1e-12));
      expect(store.written, hasLength(1));
    });

    test('never invents a cost for a model with unknown pricing', () async {
      final UsageTracker tracker = UsageTracker(pricing: _pricing());

      final UsageRecord record = await tracker.recordUsage(
        model: 'vendor/unpriced',
        usage: _usage(10, 10),
      );

      expect(record.costUsd, isNull);
      expect(tracker.totalCostUsd, 0);
      expect(tracker.unpricedRecords, 1);
      expect(tracker.pricedRecords, 0);
      expect(tracker.tokensUsed, 20, reason: 'tokens are still accounted for');
    });

    test('a free model records a real zero cost', () async {
      final UsageTracker tracker = UsageTracker(pricing: _pricing());

      final UsageRecord record = await tracker.recordUsage(
        model: 'vendor/alpha:free',
        usage: _usage(200, 100),
      );

      expect(record.costUsd, 0);
      expect(tracker.pricedRecords, 1);
    });

    test('usage is durable through the injected store', () async {
      final FakeDurableStore store = FakeDurableStore();
      final UsageTracker first = UsageTracker(
        store: store,
        pricing: _pricing(),
      );
      await first.recordUsage(model: 'vendor/beta', usage: _usage(10, 5));

      // A fresh tracker over the same store sees the persisted history.
      final UsageTracker second = UsageTracker(
        store: store,
        pricing: _pricing(),
      );
      final UsageSummary summary = await second.summary();

      expect(summary.requests, 1);
      expect(summary.totalTokens, 15);
      expect(summary.costUsd, closeTo(0.0000525, 1e-12));
      await second.flush();
      expect(store.written, hasLength(1));
    });

    test('rejects usage that a provider could not have reported', () {
      // TokenUsage is the only way into the tracker, and it refuses counts a
      // provider cannot have reported.
      expect(
        () => TokenUsage(promptTokens: -1, completionTokens: 0),
        throwsArgumentError,
      );
      expect(
        () => TokenUsage(promptTokens: 0, completionTokens: -5, totalTokens: 1),
        throwsArgumentError,
      );
      expect(
        () => TokenUsage.fromJson(const <String, dynamic>{'prompt_tokens': -1}),
        throwsA(
          isA<ProviderException>().having(
            (ProviderException e) => e.kind,
            'kind',
            ProviderErrorKind.malformed,
          ),
        ),
      );
    });
  });

  group('UsageTracker counters', () {
    test('tracks requests per minute inside a rolling window', () async {
      DateTime now = DateTime.utc(2026, 1, 1, 12);
      final UsageTracker tracker = UsageTracker(
        clock: () => now,
        rpmWindow: const Duration(minutes: 1),
      );

      await tracker.recordUsage(model: 'm', usage: _usage(1, 1));
      await tracker.recordUsage(model: 'm', usage: _usage(1, 1));
      expect(tracker.rpmUsed, 2);

      now = now.add(const Duration(seconds: 30));
      expect(tracker.rpmUsed, 2);

      now = now.add(const Duration(seconds: 45));
      expect(tracker.rpmUsed, 0, reason: 'the window has rolled over');
      expect(tracker.requestCount, 2, reason: 'totals are not windowed');
    });

    test('the unattributed counter stays out of usage history', () async {
      final FakeDurableStore store = FakeDurableStore();
      final UsageTracker tracker = UsageTracker(
        store: store,
        clock: () {
          return DateTime.utc(2026, 1, 1);
        },
      );

      tracker.record(tokens: 128);

      expect(tracker.tokensUsed, 128);
      expect(tracker.completionTokens, 128);
      expect(tracker.rpmUsed, 0);
      expect(tracker.requestCount, 0);
      expect(store.written, isEmpty);
    });

    test('a summary reflects only persisted records', () async {
      final FakeDurableStore store = FakeDurableStore();
      final UsageTracker tracker = UsageTracker(
        store: store,
        pricing: _pricing(),
        clock: () => DateTime.utc(2026, 1, 1),
      );
      tracker.record(tokens: 500);
      await tracker.recordUsage(model: 'vendor/beta', usage: _usage(4, 2));

      final UsageSummary summary = await tracker.summary();

      expect(summary.requests, 1);
      expect(summary.totalTokens, 6);
      expect(summary.unpricedRecords, 0);
      expect(summary.lastRecordAt, isNotNull);
    });
  });

  group('PricingTable', () {
    test('exposes only models that carried pricing in discovery', () {
      final PricingTable pricing = _pricing();

      expect(pricing.hasPricingFor('vendor/beta'), isTrue);
      expect(pricing.hasPricingFor('vendor/nope'), isFalse);
      expect(pricing.promptPer1MTokens('vendor/nope'), isNull);
      expect(PricingTable.empty.knownModelIds, isEmpty);
    });
  });

  group('adapter to tracker integration', () {
    test(
      'a completion with usage feeds the tracker with real numbers',
      () async {
        final FakeDurableStore store = FakeDurableStore();
        final UsageTracker tracker = UsageTracker(
          store: store,
          pricing: _pricing(),
        );
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest _) => jsonResponse(<String, dynamic>{
            'id': 'c1',
            'model': 'vendor/beta',
            'choices': <dynamic>[
              <String, dynamic>{
                'index': 0,
                'message': <String, dynamic>{'content': 'hello'},
                'finish_reason': 'stop',
              },
            ],
            'usage': <String, dynamic>{
              'prompt_tokens': 12,
              'completion_tokens': 3,
            },
          }),
        ]);
        final OpenRouterAdapter adapter = OpenRouterAdapter(
          transport: transport,
          auth: _auth(),
          sleep: (Duration _) async {},
        );

        final ChatCompletion completion = await adapter.completeChat(
          request: ChatRequest(
            model: 'vendor/beta',
            messages: <ChatMessage>[ChatMessage(ChatRole.user, 'hi')],
          ),
        );
        final TokenUsage? usage = completion.usage;
        expect(usage, isNotNull);
        await tracker.recordUsage(model: completion.model, usage: usage!);

        expect(tracker.tokensUsed, 15);
        expect(tracker.promptTokens, 12);
        expect(tracker.completionTokens, 3);
        expect(store.written.single.source, UsageSource.providerReported);
      },
    );

    test('a completion without usage leaves the tracker at zero', () async {
      final UsageTracker tracker = UsageTracker(pricing: _pricing());
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest _) => jsonResponse(<String, dynamic>{
          'id': 'c2',
          'model': 'vendor/beta',
          'choices': <dynamic>[
            <String, dynamic>{
              'index': 0,
              'message': <String, dynamic>{'content': 'hello'},
              'finish_reason': 'stop',
            },
          ],
        }),
      ]);
      final OpenRouterAdapter adapter = OpenRouterAdapter(
        transport: transport,
        auth: _auth(),
        sleep: (Duration _) async {},
      );

      final ChatCompletion completion = await adapter.completeChat(
        request: ChatRequest(
          model: 'vendor/beta',
          messages: <ChatMessage>[ChatMessage(ChatRole.user, 'hi')],
        ),
      );

      expect(completion.usage, isNull);
      final TokenUsage? usage = completion.usage;
      if (usage != null) {
        await tracker.recordUsage(model: completion.model, usage: usage);
      }
      expect(tracker.tokensUsed, 0);
      expect(tracker.requestCount, 0);
    });
  });

  group('UsageRecord', () {
    test('serialises to plain JSON for a durable store', () {
      final UsageRecord record = UsageRecord(
        id: 'r1',
        model: 'vendor/beta',
        promptTokens: 2,
        completionTokens: 3,
        costUsd: 0.5,
        source: UsageSource.providerReported,
        recordedAt: DateTime.utc(2026, 1, 1),
      );

      final Map<String, dynamic> json = record.toJson();

      expect(json['id'], 'r1');
      expect(json['model'], 'vendor/beta');
      expect(json['prompt_tokens'], 2);
      expect(json['completion_tokens'], 3);
      expect(json['total_tokens'], 5);
      expect(json['cost_usd'], 0.5);
      expect(json['source'], 'provider_reported');
      expect(json['recorded_at'], '2026-01-01T00:00:00.000Z');
    });

    test('round-trips through fromJson', () {
      final UsageRecord record = UsageRecord(
        id: 'r2',
        model: null,
        promptTokens: 0,
        completionTokens: 4,
        costUsd: null,
        source: UsageSource.unattributed,
        recordedAt: DateTime.utc(2026, 2, 3, 4, 5),
      );

      final UsageRecord restored = UsageRecord.fromJson(record.toJson());

      expect(restored.id, 'r2');
      expect(restored.model, isNull);
      expect(restored.totalTokens, 4);
      expect(restored.costUsd, isNull);
      expect(restored.source, UsageSource.unattributed);
      expect(restored.recordedAt, record.recordedAt);
    });
  });
}
