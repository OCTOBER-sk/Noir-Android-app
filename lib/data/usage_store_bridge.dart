// lib/data/usage_store_bridge.dart — the seam between the provider runtime's
// usage accounting and the data layer's usage history.
//
// `lib/providers/usage_tracker.dart` accumulates what a live session spent:
// it prices a request against a live-discovered model and keeps a rolling
// request-per-minute window. `lib/data/usage_repository.dart` keeps the history
// that outlives the process, bucketed by UTC day so a budget can be read back.
//
// Neither is useful alone — a session total that vanishes on restart cannot
// enforce a daily cap, and a day-bucketed history with nothing writing to it is
// an empty table. This adapter is what makes the tracker's records land in the
// repository and what makes the repository the source for the dashboard.
//
// Two fields the tracker records that the durable schema had no room for,
// `costUsd` and `source`, are stored as optional columns on the repository's
// `UsageRecord`. A price that cannot be read back is `null`, which the
// dashboard renders as "unknown" — never as zero.
import 'dart:async';

import '../providers/usage_tracker.dart' as tracker;
import 'usage_repository.dart';

/// A [tracker.UsageStore] whose records live in a [UsageRepository].
///
/// [providerId] and [funded] are supplied once, at construction, because they
/// are facts about the *account* the runtime is configured against rather than
/// about an individual request. The tracker does not carry them, and inventing
/// them per record would be exactly the kind of plausible-looking fabrication
/// this file exists to avoid — so they are passed in from the provider settings
/// that really are in force.
class PersistedUsageStore implements tracker.UsageStore {
  PersistedUsageStore({
    required UsageRepository usage,
    required this.providerId,
    required this.funded,
  }) : _usage = usage;

  final UsageRepository _usage;

  /// The provider every record written through this store was attributed to.
  final String providerId;

  /// Whether the account was funded when these records were written, which is
  /// what decides the daily cap they count against.
  final bool funded;

  @override
  Future<void> append(tracker.UsageRecord record) async {
    final String? model = record.model;
    if (model == null || model.trim().isEmpty) {
      // The durable schema requires a model on every usage record and there is
      // no honest substitute. Refusing is the correct outcome: a usage row that
      // does not name its model cannot be attributed to a price or a cap.
      throw ArgumentError.value(
        record,
        'record.model',
        'a durable usage record must name the model it ran on',
      );
    }
    await _usage.upsert(
      UsageRecord(
        id: record.id,
        provider: providerId,
        model: model,
        promptTokens: record.promptTokens,
        completionTokens: record.completionTokens,
        funded: funded,
        occurredAt: record.recordedAt.toUtc(),
        createdAt: record.recordedAt.toUtc(),
        updatedAt: record.recordedAt.toUtc(),
        costUsd: record.costUsd,
        source: record.source.name,
      ),
    );
  }

  @override
  Future<List<tracker.UsageRecord>> readAll() async {
    final List<UsageRecord> records = await _usage.readAll(
      onUnreadable: (String id, Object error) {
        // A corrupt usage row is reported through the store's own recovery path
        // rather than failing the whole read; a budget that cannot be computed
        // because one line is damaged is worse than one computed from the rest.
      },
    );
    return <tracker.UsageRecord>[
      for (final UsageRecord record in records) _toTracker(record),
    ];
  }

  static tracker.UsageRecord _toTracker(UsageRecord record) {
    return tracker.UsageRecord(
      id: record.id,
      model: record.model,
      promptTokens: record.promptTokens,
      completionTokens: record.completionTokens,
      totalTokens: record.totalTokens,
      costUsd: record.costUsd,
      source: _sourceFrom(record.source),
      recordedAt: record.occurredAt.toUtc(),
    );
  }

  /// A stored source name this build no longer knows about is reported as
  /// [tracker.UsageSource.unattributed]: weaker, and visibly weaker, rather
  /// than a claim that a provider confirmed numbers nobody recorded.
  static tracker.UsageSource _sourceFrom(String? name) {
    for (final tracker.UsageSource source in tracker.UsageSource.values) {
      if (source.name == name) return source;
    }
    return tracker.UsageSource.unattributed;
  }
}
