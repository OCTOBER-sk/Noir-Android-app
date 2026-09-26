/// Usage accounting: durable-friendly storage, real token counts, honest cost.
library;

import 'dart:async';

import 'chat_types.dart';
import 'model_discovery.dart';

/// Where a usage record's numbers came from.
enum UsageSource {
  /// Taken from a real provider `usage` block.
  providerReported,

  /// Supplied by the caller without a provider response (e.g. a UI counter).
  unattributed,
}

/// One accounted request.
class UsageRecord {
  const UsageRecord({
    required this.id,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.costUsd,
    required this.source,
    required this.recordedAt,
    int? totalTokens,
  }) : totalTokens = totalTokens ?? promptTokens + completionTokens;

  /// Restores a record previously written by [toJson].
  factory UsageRecord.fromJson(Map<String, dynamic> json) => UsageRecord(
    id: json['id'] is String ? json['id']! as String : '',
    model: json['model'] is String ? json['model']! as String : null,
    promptTokens: _int(json['prompt_tokens']),
    completionTokens: _int(json['completion_tokens']),
    totalTokens: json['total_tokens'] == null
        ? null
        : _int(json['total_tokens']),
    costUsd: _double(json['cost_usd']),
    source: _source(json['source']),
    recordedAt:
        DateTime.tryParse(json['recorded_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  /// Tracker-local unique id.
  final String id;

  /// Model the request ran on, when known.
  final String? model;

  /// Tokens attributed to the prompt.
  final int promptTokens;

  /// Tokens the model produced.
  final int completionTokens;

  /// Provider total, or the sum of both counts.
  final int totalTokens;

  /// Cost in USD, or `null` when pricing for [model] is unknown.
  final double? costUsd;

  final UsageSource source;
  final DateTime recordedAt;

  /// Plain JSON, so a file- or preferences-backed store needs no adapter.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'model': model,
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
    'cost_usd': costUsd,
    'source': source == UsageSource.providerReported
        ? 'provider_reported'
        : 'unattributed',
    'recorded_at': recordedAt.toUtc().toIso8601String(),
  };

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static UsageSource _source(Object? value) => value == 'provider_reported'
      ? UsageSource.providerReported
      : UsageSource.unattributed;

  @override
  String toString() =>
      'UsageRecord($id, $model, $totalTokens tokens, cost: $costUsd)';
}

/// Durable storage seam for usage history.
///
/// Production can back this with a file, preferences or a database; tests back
/// it with a list. The interface is intentionally append-only.
abstract class UsageStore {
  /// Persists one record.
  Future<void> append(UsageRecord record);

  /// Returns every persisted record, oldest first.
  Future<List<UsageRecord>> readAll();
}

/// Non-durable [UsageStore] used when no durable store is injected.
class InMemoryUsageStore implements UsageStore {
  InMemoryUsageStore([List<UsageRecord>? seed])
    : _records = List<UsageRecord>.of(seed ?? const <UsageRecord>[]);

  final List<UsageRecord> _records;

  @override
  Future<void> append(UsageRecord record) async => _records.add(record);

  @override
  Future<List<UsageRecord>> readAll() async =>
      List<UsageRecord>.unmodifiable(_records);
}

/// Per-1M-token prices for the models that actually advertised pricing.
class PricingTable {
  PricingTable(Iterable<DiscoveredModel> models)
    : _byId = <String, DiscoveredModel>{
        for (final DiscoveredModel model in models)
          if (model.hasPricing) model.id: model,
      };

  /// Builds a table from a discovery result.
  factory PricingTable.fromDiscovery(Iterable<DiscoveredModel> models) =>
      PricingTable(models);

  /// Table that prices nothing; every cost stays unknown.
  static final PricingTable empty = PricingTable(const <DiscoveredModel>[]);

  final Map<String, DiscoveredModel> _byId;

  Iterable<String> get knownModelIds => _byId.keys;

  bool hasPricingFor(String modelId) => _byId.containsKey(modelId);

  double? promptPer1MTokens(String modelId) =>
      _byId[modelId]?.promptPricePer1MTokens;

  double? completionPer1MTokens(String modelId) =>
      _byId[modelId]?.completionPricePer1MTokens;
}

/// Aggregated usage across a store.
class UsageSummary {
  const UsageSummary({
    required this.requests,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.costUsd,
    required this.pricedRecords,
    required this.unpricedRecords,
    required this.lastRecordAt,
  });

  final int requests;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final double costUsd;
  final int pricedRecords;
  final int unpricedRecords;
  final DateTime? lastRecordAt;
}

/// Accumulates provider-reported usage and cost.
///
/// Numbers only ever enter through [recordUsage] (which requires a real
/// [TokenUsage]) or the unattributed [record] counter; the tracker never
/// estimates tokens or invents prices.
class UsageTracker {
  UsageTracker({
    UsageStore? store,
    PricingTable? pricing,
    this.rpmWindow = const Duration(minutes: 1),
    DateTime Function() clock = DateTime.now,
  }) : store = store ?? InMemoryUsageStore(),
       _pricing = pricing ?? PricingTable.empty,
       _clock = clock;

  /// Where records are persisted.
  final UsageStore store;

  /// Rolling window used by [rpmUsed].
  final Duration rpmWindow;

  final PricingTable _pricing;
  final DateTime Function() _clock;
  final List<DateTime> _requestTimes = <DateTime>[];
  final List<Future<void>> _pending = <Future<void>>[];
  int _sequence = 0;
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _requests = 0;
  int _pricedRecords = 0;
  int _unpricedRecords = 0;
  double _totalCostUsd = 0;

  int get promptTokens => _promptTokens;
  int get completionTokens => _completionTokens;
  int get tokensUsed => _promptTokens + _completionTokens;
  int get requestCount => _requests;
  int get pricedRecords => _pricedRecords;
  int get unpricedRecords => _unpricedRecords;

  /// Total cost of priced records in USD. Unpriced records contribute nothing.
  double get totalCostUsd => _totalCostUsd;

  /// Whether any provider-reported usage has been recorded.
  bool get hasReportedUsage => _requests > 0;

  /// Requests inside the current rolling window.
  int get rpmUsed {
    _prune();
    return _requestTimes.length;
  }

  /// Adds an unattributed token count without claiming a provider response.
  ///
  /// Kept for surfaces that only need a live counter: it deliberately does not
  /// touch [store], [requestCount] or cost, because there is no response,
  /// model or price behind it.
  void record({int? tokens, String? model}) {
    if (tokens == null) return;
    if (tokens < 0) throw ArgumentError.value(tokens, 'tokens', 'is negative');
    _completionTokens += tokens;
  }

  /// Records usage reported by the provider for one completed request.
  ///
  /// Persists the record through [store] and updates the running totals. The
  /// cost is `null` when [model] has no discovered pricing.
  Future<UsageRecord> recordUsage({
    required String model,
    required TokenUsage usage,
  }) {
    if (usage.promptTokens < 0 || usage.completionTokens < 0) {
      throw ArgumentError('usage token counts must not be negative');
    }
    final DateTime now = _clock();
    final double? cost = _costFor(model, usage);
    final UsageRecord record = UsageRecord(
      id: 'usage-${_sequence++}',
      model: model,
      promptTokens: usage.promptTokens,
      completionTokens: usage.completionTokens,
      costUsd: cost,
      source: UsageSource.providerReported,
      recordedAt: now,
    );

    _promptTokens += usage.promptTokens;
    _completionTokens += usage.completionTokens;
    _requests += 1;
    _requestTimes.add(now);
    if (cost == null) {
      _unpricedRecords += 1;
    } else {
      _pricedRecords += 1;
      _totalCostUsd += cost;
    }

    final Future<void> write = store.append(record);
    _pending.add(write);
    return write.then<UsageRecord>((void _) => record).whenComplete(() {
      _pending.remove(write);
    });
  }

  /// Awaits every in-flight store write.
  Future<void> flush() async {
    while (_pending.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_pending));
    }
  }

  /// Aggregates the persisted history, not just this instance's counters.
  Future<UsageSummary> summary() async {
    await flush();
    final List<UsageRecord> records = await store.readAll();
    int prompt = 0;
    int completion = 0;
    int priced = 0;
    int unpriced = 0;
    double cost = 0;
    DateTime? last;
    for (final UsageRecord record in records) {
      prompt += record.promptTokens;
      completion += record.completionTokens;
      final double? recordCost = record.costUsd;
      if (recordCost == null) {
        unpriced += 1;
      } else {
        priced += 1;
        cost += recordCost;
      }
      if (last == null || record.recordedAt.isAfter(last)) {
        last = record.recordedAt;
      }
    }
    return UsageSummary(
      requests: records.length,
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: prompt + completion,
      costUsd: cost,
      pricedRecords: priced,
      unpricedRecords: unpriced,
      lastRecordAt: last,
    );
  }

  double? _costFor(String model, TokenUsage usage) {
    final double? prompt = _pricing.promptPer1MTokens(model);
    final double? completion = _pricing.completionPer1MTokens(model);
    if (prompt == null || completion == null) return null;
    return usage.promptTokens * prompt / 1e6 +
        usage.completionTokens * completion / 1e6;
  }

  void _prune() {
    final DateTime cutoff = _clock().subtract(rpmWindow);
    _requestTimes.removeWhere((DateTime at) => at.isBefore(cutoff));
  }
}
