// Usage records and the aggregation the free-tier budget guard depends on.
//
// The point of these tests is durability: totals are derived from stored records,
// survive a restart, and are never lost when several records are written at once.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/noir_schema.dart';

void main() {
  late Directory root;
  late KeyValueStore store;
  late UsageRepository usage;
  var tick = 0;

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_usage_');
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(),
      clock: () => DateTime.utc(2026, 5, 1, 12),
    );
    usage = UsageRepository(
      store: store,
      clock: () => DateTime.utc(2026, 5, 1, 12, 0, tick++),
    );
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  Future<UsageRecord> recordUsage({
    String provider = 'openrouter',
    String model = 'noir-engine/pro-v2:free',
    int promptTokens = 100,
    int completionTokens = 50,
    bool funded = false,
    DateTime? at,
  }) {
    return usage.record(
      provider: provider,
      model: model,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      funded: funded,
      occurredAt: at,
    );
  }

  group('recording', () {
    test('an empty repository aggregates to zero', () async {
      final summary = await usage.summarize();

      expect(summary.requests, isZero);
      expect(summary.promptTokens, isZero);
      expect(summary.completionTokens, isZero);
      expect(summary.totalTokens, isZero);
      expect(summary.isEmpty, isTrue);
      expect(await usage.count(), isZero);
      expect((await usage.dailyTotals()).buckets, isEmpty);
    });

    test('a recorded request comes back with its own fields', () async {
      final at = DateTime.utc(2026, 5, 1, 9, 30);
      final record = await recordUsage(at: at, funded: true);

      expect(record.provider, 'openrouter');
      expect(record.model, 'noir-engine/pro-v2:free');
      expect(record.promptTokens, 100);
      expect(record.completionTokens, 50);
      expect(record.totalTokens, 150);
      expect(record.funded, isTrue);
      expect(record.occurredAt, at);

      final loaded = (await usage.find(record.id))!;
      expect(loaded.id, record.id);
      expect(loaded.occurredAt, at);
      expect(loaded.totalTokens, 150);
    });

    test('every recorded request gets its own id', () async {
      final ids = <String>{};
      for (var i = 0; i < 20; i++) {
        ids.add((await recordUsage()).id);
      }

      expect(ids, hasLength(20));
      expect(await usage.count(), 20);
    });

    test('negative token counts are rejected', () async {
      await expectLater(
        recordUsage(promptTokens: -1),
        throwsA(isA<InvalidDataError>()),
      );
      await expectLater(
        recordUsage(completionTokens: -5),
        throwsA(isA<InvalidDataError>()),
      );
      expect(await usage.count(), isZero);
    });

    test('a blank provider or model is rejected', () async {
      await expectLater(
        recordUsage(provider: ' '),
        throwsA(isA<InvalidDataError>()),
      );
      await expectLater(
        recordUsage(model: ''),
        throwsA(isA<InvalidDataError>()),
      );
    });

    test(
      'a record with a local timestamp is stored as the same instant',
      () async {
        final local = DateTime(2026, 5, 1, 11, 30);

        final record = await recordUsage(at: local, promptTokens: 1);
        final loaded = (await usage.find(record.id))!;

        expect(record.occurredAt.isUtc, isTrue);
        expect(loaded.occurredAt, local.toUtc());
        expect(
          loaded.occurredAt.millisecondsSinceEpoch,
          local.millisecondsSinceEpoch,
        );
      },
    );
  });

  group('aggregation', () {
    test('totals add up across providers, models and funding tiers', () async {
      await recordUsage(promptTokens: 10, completionTokens: 5);
      await recordUsage(promptTokens: 20, completionTokens: 10, funded: true);
      await recordUsage(
        provider: 'ollama',
        model: 'llama3',
        promptTokens: 30,
        completionTokens: 15,
      );

      final summary = await usage.summarize();

      expect(summary.requests, 3);
      expect(summary.promptTokens, 60);
      expect(summary.completionTokens, 30);
      expect(summary.totalTokens, 90);
      expect(summary.isEmpty, isFalse);
    });

    test(
      'the summary is derived from stored records, not a running counter',
      () async {
        await recordUsage(promptTokens: 7, completionTokens: 3);

        // A second process, reading the same directory.
        final reopened = UsageRepository(
          store: JsonFileKeyValueStore(root: root, catalog: buildNoirCatalog()),
          clock: () => DateTime.utc(2026, 5, 1, 13),
        );

        expect((await reopened.summarize()).totalTokens, 10);
        expect((await reopened.count()), 1);
      },
    );

    test('a summary can be narrowed to one provider or one model', () async {
      await recordUsage(promptTokens: 1, completionTokens: 1);
      await recordUsage(
        model: 'other:free',
        promptTokens: 2,
        completionTokens: 2,
      );
      await recordUsage(
        provider: 'ollama',
        promptTokens: 4,
        completionTokens: 4,
      );

      expect((await usage.summarize(provider: 'ollama')).totalTokens, 8);
      expect((await usage.summarize(model: 'other:free')).totalTokens, 4);
      expect(
        (await usage.summarize(
          provider: 'openrouter',
          model: 'other:free',
        )).totalTokens,
        4,
      );
      expect(
        (await usage.summarize(provider: 'does-not-exist')).requests,
        isZero,
      );
    });

    test('a summary can be limited to a time window', () async {
      await recordUsage(
        promptTokens: 1,
        completionTokens: 0,
        at: DateTime.utc(2026, 4, 30, 23),
      );
      await recordUsage(
        promptTokens: 2,
        completionTokens: 0,
        at: DateTime.utc(2026, 5, 1, 0, 1),
      );
      await recordUsage(
        promptTokens: 4,
        completionTokens: 0,
        at: DateTime.utc(2026, 5, 1, 12),
      );

      final day = await usage.summarize(
        from: DateTime.utc(2026, 5, 1),
        to: DateTime.utc(2026, 5, 2),
      );

      expect(day.requests, 2);
      expect(day.totalTokens, 6);
    });

    test('the window ends are inclusive of the lower bound only', () async {
      await recordUsage(promptTokens: 5, at: DateTime.utc(2026, 5, 1, 12));

      expect(
        (await usage.summarize(from: DateTime.utc(2026, 5, 1, 12))).requests,
        1,
      );
      expect(
        (await usage.summarize(to: DateTime.utc(2026, 5, 1, 12))).requests,
        0,
        reason: 'the upper bound is exclusive',
      );
    });

    test('an inverted window returns nothing instead of everything', () async {
      await recordUsage();

      final inverted = await usage.summarize(
        from: DateTime.utc(2026, 5, 2),
        to: DateTime.utc(2026, 5, 1),
      );

      expect(inverted.requests, isZero);
    });

    test('totals split by funding tier', () async {
      await recordUsage(promptTokens: 10, completionTokens: 10, funded: true);
      await recordUsage(promptTokens: 1, completionTokens: 1, funded: false);

      final funded = await usage.summarize(funded: true);
      final unfunded = await usage.summarize(funded: false);

      expect(funded.requests, 1);
      expect(funded.totalTokens, 20);
      expect(unfunded.requests, 1);
      expect(unfunded.totalTokens, 2);
    });

    test('usage today is what the budget guard reads', () async {
      await recordUsage(at: DateTime.utc(2026, 5, 1, 8));
      await recordUsage(at: DateTime.utc(2026, 5, 1, 9));
      await recordUsage(at: DateTime.utc(2026, 4, 30, 9));

      expect(await usage.usedOn(DateTime.utc(2026, 5, 1)), 2);
      expect(await usage.usedOn(DateTime.utc(2026, 4, 30)), 1);
      expect(
        await usage.usedOn(DateTime.utc(2026, 5, 1), funded: true),
        isZero,
      );
    });

    test('remaining daily allowance never goes negative', () async {
      await recordUsage();

      final remaining = await usage.remainingOn(
        DateTime.utc(2026, 5, 1),
        dailyCap: 1,
      );

      expect(remaining, isZero);
      expect(
        await usage.remainingOn(DateTime.utc(2026, 5, 1), dailyCap: 10),
        9,
      );
    });

    test(
      'daily buckets are ordered oldest first and cover only used days',
      () async {
        await recordUsage(
          promptTokens: 1,
          completionTokens: 0,
          at: DateTime.utc(2026, 4, 29, 12),
        );
        await recordUsage(
          promptTokens: 2,
          completionTokens: 0,
          at: DateTime.utc(2026, 4, 30, 12),
        );
        await recordUsage(
          promptTokens: 4,
          completionTokens: 0,
          at: DateTime.utc(2026, 5, 1, 12),
        );
        await recordUsage(
          promptTokens: 8,
          completionTokens: 0,
          at: DateTime.utc(2026, 5, 1, 18),
        );

        final buckets = (await usage.dailyTotals(days: 5)).buckets;

        expect(buckets.map((b) => b.day), <String>[
          '2026-04-29',
          '2026-04-30',
          '2026-05-01',
        ]);
        expect(buckets.last.requests, 2);
        expect(buckets.last.totalTokens, 12);
      },
    );

    test('a daily bucket can be narrowed to one provider', () async {
      await recordUsage(
        provider: 'openrouter',
        promptTokens: 1,
        completionTokens: 0,
        at: DateTime.utc(2026, 5, 1, 12),
      );
      await recordUsage(
        provider: 'ollama',
        promptTokens: 2,
        completionTokens: 0,
        at: DateTime.utc(2026, 5, 1, 12),
      );

      final openrouterOnly = await usage.dailyTotals(provider: 'openrouter');
      final ollamaOnly = await usage.dailyTotals(provider: 'ollama');

      expect(openrouterOnly.buckets.single.day, '2026-05-01');
      expect(openrouterOnly.totalTokens, 1);
      expect(ollamaOnly.totalTokens, 2);
    });

    test('a per-model breakdown sums back to the grand total', () async {
      await recordUsage(model: 'a:free', promptTokens: 1, completionTokens: 1);
      await recordUsage(model: 'b:free', promptTokens: 2, completionTokens: 2);
      await recordUsage(model: 'b:free', promptTokens: 4, completionTokens: 4);

      final byModel = await usage.byModel();
      final total = await usage.summarize();

      expect(byModel.keys.toSet(), <String>{'a:free', 'b:free'});
      expect(byModel['a:free']!.requests, 1);
      expect(byModel['b:free']!.totalTokens, 12);
      expect(
        byModel.values.fold(0, (sum, summary) => sum + summary.totalTokens),
        total.totalTokens,
      );
    });
  });

  group('durability under load', () {
    test('concurrent records are all counted exactly once', () async {
      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < 50; i++)
          recordUsage(promptTokens: 2, completionTokens: 1),
      ]);

      final summary = await usage.summarize();

      expect(summary.requests, 50);
      expect(summary.promptTokens, 100);
      expect(summary.completionTokens, 50);
      expect(await usage.count(), 50);
    });

    test('concurrent records survive a restart with the same totals', () async {
      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < 30; i++)
          recordUsage(promptTokens: 1, completionTokens: 1),
      ]);

      final reopened = UsageRepository(
        store: JsonFileKeyValueStore(root: root, catalog: buildNoirCatalog()),
      );

      final summary = await reopened.summarize();
      expect(summary.requests, 30);
      expect(summary.totalTokens, 60);
    });

    test('a failed write does not corrupt the totals', () async {
      await recordUsage(promptTokens: 10, completionTokens: 10);
      (store as FaultInjectableStore).failNextWrite(StateError('disk full'));

      await expectLater(
        recordUsage(promptTokens: 999),
        throwsA(isA<StateError>()),
      );

      final summary = await usage.summarize();
      expect(summary.requests, 1);
      expect(summary.totalTokens, 20);
      (store as FaultInjectableStore).clearFaults();
      await recordUsage(promptTokens: 1, completionTokens: 1);
      expect((await usage.summarize()).requests, 2);
    });

    test('records survive a restart in full, not just in the totals', () async {
      final first = await recordUsage(
        promptTokens: 11,
        completionTokens: 7,
        at: DateTime.utc(2026, 5, 1, 6),
      );

      final reopened = UsageRepository(
        store: JsonFileKeyValueStore(root: root, catalog: buildNoirCatalog()),
      );
      final loaded = (await reopened.find(first.id))!;

      expect(loaded.promptTokens, 11);
      expect(loaded.completionTokens, 7);
      expect(loaded.occurredAt, DateTime.utc(2026, 5, 1, 6));
      expect(loaded.funded, isFalse);
    });
  });

  group('listing and limits', () {
    test('records are listed newest first with a real total', () async {
      for (var i = 0; i < 5; i++) {
        await recordUsage(
          promptTokens: i + 1,
          at: DateTime.utc(2026, 5, 1, 10 + i),
        );
      }

      final page = await usage.listRecent(limit: 2);

      expect(page.items.map((r) => r.occurredAt), <DateTime>[
        DateTime.utc(2026, 5, 1, 14),
        DateTime.utc(2026, 5, 1, 13),
      ]);
      expect(page.total, 5);
      expect(page.hasMore, isTrue);
    });

    test('listing can be narrowed by provider and model', () async {
      await recordUsage(promptTokens: 1);
      await recordUsage(provider: 'ollama', promptTokens: 2);
      await recordUsage(model: 'other:free', promptTokens: 4);

      expect(
        (await usage.list(provider: 'ollama')).items.single.promptTokens,
        2,
      );
      expect(
        (await usage.list(model: 'other:free')).items.single.promptTokens,
        4,
      );
      expect((await usage.list(provider: 'nobody')).items, isEmpty);
    });

    test('paging walks every record exactly once', () async {
      for (var i = 0; i < 9; i++) {
        await recordUsage(at: DateTime.utc(2026, 5, 1, 0, i));
      }

      final seen = <DateTime>[];
      var request = PageRequest(limit: 4);
      while (true) {
        final page = await usage.listRecent(page: request);
        seen.addAll(page.items.map((r) => r.occurredAt));
        final next = page.nextPage;
        if (next == null) {
          break;
        }
        request = next;
      }

      expect(seen, hasLength(9));
      expect(seen.toSet(), hasLength(9));
    });

    test('a limit above the repository maximum is capped', () async {
      final capped = UsageRepository(
        store: store,
        codec: const UsageRecordCodec(),
        maxPageLimit: 3,
      );

      expect((await capped.listRecent(limit: 100)).limit, 3);
    });

    test('a negative offset or limit is rejected', () {
      expect(
        () => PageRequest.validated(offset: -1),
        throwsA(isA<InvalidPageRequestError>()),
      );
    });
  });

  group('malformed records', () {
    test(
      'a record with a bad token count fails loudly and keeps its bytes',
      () async {
        await store.write(NoirCollections.usage, 'broken', <String, Object?>{
          'provider': 'openrouter',
          'model': 'm:free',
          'promptTokens': -1,
          'completionTokens': 5,
          'funded': false,
          'occurredAt': '2026-05-01T12:00:00.000Z',
          'createdAt': '2026-05-01T12:00:00.000Z',
          'updatedAt': '2026-05-01T12:00:00.000Z',
        });
        final before = await (store as RawStoreAccess).rawEnvelope(
          NoirCollections.usage,
          'broken',
        );

        await expectLater(
          usage.find('broken'),
          throwsA(
            isA<MalformedRecordError>().having(
              (e) => e.field,
              'field',
              'promptTokens',
            ),
          ),
        );
        expect(
          await (store as RawStoreAccess).rawEnvelope(
            NoirCollections.usage,
            'broken',
          ),
          before,
        );
      },
    );

    test('a malformed record does not silently vanish from a total', () async {
      await recordUsage(promptTokens: 10, completionTokens: 10);
      await store.write(NoirCollections.usage, 'broken', <String, Object?>{
        'provider': 'openrouter',
        'model': 'm:free',
        'promptTokens': 'many',
        'completionTokens': 5,
        'funded': false,
        'occurredAt': '2026-05-01T12:00:00.000Z',
        'createdAt': '2026-05-01T12:00:00.000Z',
        'updatedAt': '2026-05-01T12:00:00.000Z',
      });

      await expectLater(
        usage.summarize(),
        throwsA(isA<MalformedRecordError>()),
      );
      final reported = <String>[];
      final summary = await usage.summarize(
        onUnreadable: (id, error) => reported.add(id),
      );
      expect(summary.totalTokens, 20);
      expect(reported, <String>['broken']);
    });
  });
}
