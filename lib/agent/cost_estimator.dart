import '../providers/llm_provider.dart';
import '../providers/usage_tracker.dart';

/// Estimated cost and budget impact for a model call (V2.1 §7 A9).
class CostEstimate {
  /// Cost in USD for the estimated call.
  final double costUsd;

  /// Total tokens for the estimated call (input + output).
  final int totalTokens;

  /// Whether the call would exceed the daily token cap.
  final bool wouldExceedDailyCap;

  /// Whether the call would exceed the dollar cap.
  final bool wouldExceedDollarCap;

  /// Creates a new [CostEstimate].
  const CostEstimate({
    required this.costUsd,
    required this.totalTokens,
    required this.wouldExceedDailyCap,
    required this.wouldExceedDollarCap,
  });
}

/// Cost estimator that runs before model selection (V2.1 §7 A9).
///
/// Flow: Task → CostEstimator (tokens / \$ / free-tier budget) → budget
/// remaining? → model selection / fallback → call.
class CostEstimator {
  /// Backing usage tracker that records committed usage.
  final UsageTracker tracker;

  /// Daily token cap (default 1 000 000).
  final int dailyCap;

  /// Dollar cap (default 0.0 since we run free-only).
  final double dollarCap;

  CostEstimator._(this.tracker, this.dailyCap, this.dollarCap);

  /// Creates a [CostEstimator] bound to [tracker].
  ///
  /// [dailyCap] defaults to 1000000 tokens. [dollarCap] defaults to 0.0
  /// (free-only).
  factory CostEstimator(
    UsageTracker tracker, {
    int dailyCap = 1000000,
    double dollarCap = 0.0,
  }) {
    return CostEstimator._(tracker, dailyCap, dollarCap);
  }

  /// Estimates cost and budget impact for [model] with [inputTokens] and
  /// [outputTokens].
  ///
  /// [costUsd] is `0.0` for free models (detected via `:free` suffix or
  /// [openrouterPoolsideFree]); otherwise computed from
  /// [LLMProviderCapabilities.costPerMillionInput] / `Output` when non-zero.
  /// [totalTokens] is `inputTokens + outputTokens`.
  /// [wouldExceedDailyCap] is true when committed + estimated tokens exceeds
  /// [dailyCap].
  /// [wouldExceedDollarCap] is true when committed cost + estimated cost
  /// exceeds [dollarCap].
  CostEstimate estimate(String model, int inputTokens, int outputTokens) {
    final totalTokens = inputTokens + outputTokens;
    final costUsd = _costFor(model, inputTokens, outputTokens);

    final committedTokens = tracker.entries
        .fold<int>(0, (sum, e) => sum + e.inputTokens + e.outputTokens);
    final wouldExceedDailyCap = committedTokens + totalTokens > dailyCap;
    final wouldExceedDollarCap = tracker.totalCost + costUsd > dollarCap;

    return CostEstimate(
      costUsd: costUsd,
      totalTokens: totalTokens,
      wouldExceedDailyCap: wouldExceedDailyCap,
      wouldExceedDollarCap: wouldExceedDollarCap,
    );
  }

  /// Returns `true` if the estimated call fits within both caps.
  ///
  /// Returns `false` if either [CostEstimate.wouldExceedDailyCap] or
  /// [CostEstimate.wouldExceedDollarCap] is true.
  bool canAfford(String model, int inputTokens, int outputTokens) {
    final e = estimate(model, inputTokens, outputTokens);
    return !e.wouldExceedDailyCap && !e.wouldExceedDollarCap;
  }

  /// Computes USD cost for [model].
  double _costFor(String model, int inputTokens, int outputTokens) {
    // Free-tier detection: any model ending with :free is free.
    if (model == openrouterPoolsideFree || model.endsWith(':free')) {
      return 0.0;
    }
    final caps = _capabilitiesFor(model);
    if (caps.costPerMillionInput == 0.0 && caps.costPerMillionOutput == 0.0) {
      return 0.0;
    }
    return (inputTokens * caps.costPerMillionInput +
            outputTokens * caps.costPerMillionOutput) /
        1000000.0;
  }

  /// Looks up capabilities for [model].
  ///
  /// Free model handled above. Known paid models have explicit costs;
  /// unknown models fall back to a non-zero default so [dollarCap] guards
  /// still trigger when running free-only.
  LLMProviderCapabilities _capabilitiesFor(String model) {
    // Known paid models with illustrative costs.
    const paid = <String, LLMProviderCapabilities>{
      'gpt-4o': LLMProviderCapabilities(
        streaming: true,
        vision: true,
        toolUse: true,
        contextWindow: 128000,
        costPerMillionInput: 5.0,
        costPerMillionOutput: 15.0,
      ),
      'claude-3-5-sonnet': LLMProviderCapabilities(
        streaming: true,
        vision: true,
        toolUse: true,
        contextWindow: 200000,
        costPerMillionInput: 3.0,
        costPerMillionOutput: 15.0,
      ),
      'gemini-1.5-pro': LLMProviderCapabilities(
        streaming: true,
        vision: true,
        toolUse: true,
        contextWindow: 1000000,
        costPerMillionInput: 3.5,
        costPerMillionOutput: 10.5,
      ),
    };
    if (paid.containsKey(model)) return paid[model]!;
    // Default non-zero cost for any other non-free model.
    return const LLMProviderCapabilities(
      streaming: true,
      vision: false,
      toolUse: false,
      contextWindow: 128000,
      costPerMillionInput: 5.0,
      costPerMillionOutput: 15.0,
    );
  }
}
