// lib/agent/cost_estimator.dart — A9 budget caps and the fallback chain order.
//
// Scope note: this file owns the documented free-tier CAP NUMBERS and the
// ordering of a fallback chain. It deliberately owns no model list. The ids in
// a chain come from the catalog the provider really served (see
// ModelRouter.cachedModelIds and lib/core/composition_root.dart), because a
// fallback chain of ids no endpoint has ever heard of is a chain of invented
// ids, and a rotation policy that rotates into one breaks every turn silently.
//
// The cap identifiers mirror the budget table in docs/ verbatim, so the
// lowerCamelCase constant rule is not applicable to this file.
// ignore_for_file: constant_identifier_names
const int OPENROUTER_FREE_RPM_CAP = 20; // fixed regardless of funding
const int OPENROUTER_FREE_DAILY_CAP_UNFUNDED = 50;
const int OPENROUTER_FREE_DAILY_CAP_FUNDED = 1000;

/// What today's budget allows, and which ids a turn may fall back to.
class CostEstimate {
  final int rpmHeadroom;
  final int dailyUsed;
  final int dailyCap;

  /// Candidate ids in provider order. May legitimately be EMPTY: a provider
  /// that served no free models has no chain, and reporting that empty is the
  /// correct answer. It is never padded with placeholder ids to look populated.
  final List<String> fallbackIds;

  CostEstimate(
    this.rpmHeadroom,
    this.dailyUsed,
    this.dailyCap,
    this.fallbackIds,
  );
}

class CostEstimator {
  /// Combine the funded/unfunded cap with the chain the caller actually has.
  ///
  /// [availableFallbackIds] must be ids read from the live catalog, already
  /// filtered to those the user configured. This function does not invent ids,
  /// does not extend the list, and does not reorder it.
  static CostEstimate estimate({
    required bool funded,
    required int usedToday,
    required List<String> availableFallbackIds,
  }) {
    final int cap = funded
        ? OPENROUTER_FREE_DAILY_CAP_FUNDED
        : OPENROUTER_FREE_DAILY_CAP_UNFUNDED;
    return CostEstimate(
      OPENROUTER_FREE_RPM_CAP,
      usedToday,
      cap,
      List<String>.unmodifiable(availableFallbackIds),
    );
  }

  /// The id at position [attempt] in [fallbackIds], or a loud failure once the
  /// chain is exhausted.
  ///
  /// This is index selection only. The caller owns the actual provider call and
  /// the decision to advance [attempt] on a 429 or a rotation; this function
  /// performs no request and never swallows a failure.
  static String resolveWithFallback(List<String> fallbackIds, {int attempt = 0}) {
    if (attempt < 0 || attempt >= fallbackIds.length) {
      throw Exception(
        'Fallback chain exhausted after ${fallbackIds.length} attempt(s); '
        'no further model id is available.',
      );
    }
    return fallbackIds[attempt];
  }
}
