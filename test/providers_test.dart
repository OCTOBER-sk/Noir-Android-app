// E10 — Provider routing + budget guard + fallback chain (per V2.2 §E10).
// Every assertion runs real code from lib/. Honest scope note: FreeModelCache
// still resolves from a local TTL cache — the https://openrouter.ai/api/v1
// models call is not implemented yet — so these tests assert that real
// contract, not a live-network claim.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/cost_estimator.dart';
import 'package:noir_android_app/providers/model_router.dart';

void main() {
  group('Provider routing and budget guard (E10 V2.2)', () {
    late List<String> cachedModelsSnapshot;
    late DateTime lastRefreshSnapshot;

    setUp(() {
      cachedModelsSnapshot = List<String>.of(FreeModelCache.cachedModels);
      lastRefreshSnapshot = FreeModelCache.lastRefresh;
    });

    tearDown(() {
      FreeModelCache.cachedModels = cachedModelsSnapshot;
      FreeModelCache.lastRefresh = lastRefreshSnapshot;
    });

    bool isFreeTier(Iterable<String> ids) =>
        ids.every((id) => id.endsWith(':free'));

    test('ModelRouter resolves the free-tier list held by FreeModelCache', () async {
      final models = await ModelRouter.resolve();

      expect(models, isNotEmpty);
      expect(models, FreeModelCache.cachedModels);
      expect(isFreeTier(models), isTrue);
      expect(models.toSet().length, models.length, reason: 'no duplicates');
    });

    test('FreeModelCache refreshes an expired TTL entry on the next resolve', () async {
      FreeModelCache.lastRefresh = DateTime.now().subtract(
        FreeModelCache.ttl + const Duration(minutes: 1),
      );

      final models = await ModelRouter.resolve();

      expect(
        DateTime.now().difference(FreeModelCache.lastRefresh),
        lessThan(FreeModelCache.ttl),
        reason: 'stale entry must be refreshed',
      );
      expect(isFreeTier(models), isTrue);
    });

    test('a rotation event is non-fatal and does not change routing', () async {
      final before = await ModelRouter.resolve();

      ModelRouter.handleRotationEvent(before.first);

      final after = await ModelRouter.resolve();
      expect(after, before);
    });

    test('fallback array is a three-model free-tier chain', () {
      expect(ModelRouter.fallbackArray, hasLength(3));
      expect(isFreeTier(ModelRouter.fallbackArray), isTrue);
      expect(
        ModelRouter.fallbackArray.toSet().length,
        ModelRouter.fallbackArray.length,
        reason: 'no duplicates',
      );
    });

    test('budget guard constants are the documented free-tier caps', () {
      expect(OPENROUTER_FREE_RPM_CAP, equals(20));
      expect(OPENROUTER_FREE_DAILY_CAP_UNFUNDED, equals(50));
      expect(OPENROUTER_FREE_DAILY_CAP_FUNDED, equals(1000));
    });

    test('CostEstimator applies the funded/unfunded daily cap', () {
      final unfunded = CostEstimator.estimate(funded: false, usedToday: 10);
      expect(unfunded.dailyCap, equals(OPENROUTER_FREE_DAILY_CAP_UNFUNDED));
      expect(unfunded.dailyUsed, equals(10));
      expect(unfunded.rpmHeadroom, equals(OPENROUTER_FREE_RPM_CAP));

      final funded = CostEstimator.estimate(funded: true, usedToday: 10);
      expect(funded.dailyCap, equals(OPENROUTER_FREE_DAILY_CAP_FUNDED));
      expect(funded.dailyUsed, equals(10));
    });

    test('CostEstimator returns a fallback chain, never a single model id', () {
      final estimate = CostEstimator.estimate(funded: false, usedToday: 0);

      expect(estimate.fallbackIds, hasLength(greaterThanOrEqualTo(2)));
      expect(estimate.fallbackIds, isNot(contains('')));
      expect(estimate.fallbackIds.toSet().length, estimate.fallbackIds.length);
    });

    test('resolveWithFallback walks the chain in order, then fails loudly', () async {
      final ids = ModelRouter.fallbackArray;

      for (var attempt = 0; attempt < ids.length; attempt++) {
        expect(
          await CostEstimator.resolveWithFallback(ids, attempt: attempt),
          equals(ids[attempt]),
        );
      }

      await expectLater(
        CostEstimator.resolveWithFallback(ids, attempt: ids.length),
        throwsA(isA<Exception>()),
      );
    });
  });
}
