// lib/agent/cost_estimator.dart — A9
const int OPENROUTER_FREE_RPM_CAP = 20;
const int OPENROUTER_FREE_DAILY_CAP_UNFUNDED = 50;
const int OPENROUTER_FREE_DAILY_CAP_FUNDED = 1000;

class CostEstimate {
  final int rpmHeadroom; final int dailyUsed; final int dailyCap; final List<String> fallbackIds;
  CostEstimate(this.rpmHeadroom, this.dailyUsed, this.dailyCap, this.fallbackIds);
}

class CostEstimator {
  static CostEstimate estimate({required bool funded, required int usedToday}) {
    final cap = funded ? OPENROUTER_FREE_DAILY_CAP_FUNDED : OPENROUTER_FREE_DAILY_CAP_UNFUNDED;
    final remaining = cap - usedToday;
    return CostEstimate(20, usedToday, cap, ['openrouter/free-model-a', 'openrouter/free-model-b']);
  }
}
