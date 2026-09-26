// E10 — Provider budget guard (per V2.2 §E10).
// Every assertion runs real code from lib/. Scope note, kept honest: the
// cost/budget surface under test here is lib/agent/cost_estimator.dart, which
// is outside the provider-runtime change. The provider layer itself (live
// model discovery, routing, streaming, retries, usage) is covered in
// test/provider_chat_test.dart, test/provider_resilience_test.dart,
// test/provider_discovery_test.dart and test/provider_usage_test.dart. The
// previous assertions in this file that a hard-coded model array was a "live"
// resolved list were removed: live discovery is now performed against a real
// `/models` payload and fails loudly when it cannot be read.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/cost_estimator.dart';

void main() {
  group('Provider budget guard (E10 V2.2)', () {
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

    test(
      'resolveWithFallback walks the chain in order, then fails loudly',
      () async {
        const List<String> ids = <String>['vendor/a:free', 'vendor/b:free'];

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
      },
    );
  });
}
