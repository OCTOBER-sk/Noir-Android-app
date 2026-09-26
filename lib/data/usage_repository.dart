// lib/data/usage_repository.dart — durable usage records and their totals.
//
// Nothing here keeps a running counter in memory as the source of truth: every
// total is recomputed from the stored records. That is slower than a counter but
// it cannot drift, it survives a restart, and a record that fails to write can
// never leave a phantom count behind. Records are small, so the aggregation cost
// is paid per query instead of per write.

import 'codecs.dart';
import 'collection_repository.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'pagination.dart';
import 'records.dart';

/// One request that reached a provider.
class UsageRecord extends DataRecord {
  UsageRecord({
    required super.id,
    required this.provider,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.funded,
    required this.occurredAt,
    required super.createdAt,
    required super.updatedAt,
  }) {
    if (provider.trim().isEmpty) {
      throw const InvalidDataError('a usage record needs a provider');
    }
    if (model.trim().isEmpty) {
      throw const InvalidDataError('a usage record needs a model');
    }
    if (promptTokens < 0) {
      throw InvalidDataError(
        'promptTokens must not be negative, got $promptTokens',
      );
    }
    if (completionTokens < 0) {
      throw InvalidDataError(
        'completionTokens must not be negative, got $completionTokens',
      );
    }
  }

  final String provider;
  final String model;
  final int promptTokens;
  final int completionTokens;

  /// Whether the account was funded when the request ran. Decides which daily
  /// cap applies, so it is recorded rather than looked up later.
  final bool funded;

  /// When the request happened, in UTC. Buckets by UTC day.
  final DateTime occurredAt;

  int get totalTokens => promptTokens + completionTokens;

  Map<String, Object?> toJson() => <String, Object?>{
    'provider': provider,
    'model': model,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'funded': funded,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  @override
  String toString() =>
      'UsageRecord($id, $provider/$model, $promptTokens + '
      '$completionTokens tokens, funded: $funded, '
      '${occurredAt.toIso8601String()})';
}

/// The `YYYY-MM-DD` bucket a timestamp belongs to, in UTC.
String utcDayKey(DateTime at) {
  final utc = at.toUtc();
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$day';
}

/// The start of the UTC day that contains [at].
DateTime startOfUtcDay(DateTime at) {
  final utc = at.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day);
}

/// Totals for some slice of usage.
class UsageSummary {
  const UsageSummary({
    required this.requests,
    required this.promptTokens,
    required this.completionTokens,
  });

  const UsageSummary.empty()
    : requests = 0,
      promptTokens = 0,
      completionTokens = 0;

  final int requests;
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;

  bool get isEmpty => requests == 0;

  /// Adds [other] into a new summary.
  UsageSummary operator +(UsageSummary other) => UsageSummary(
    requests: requests + other.requests,
    promptTokens: promptTokens + other.promptTokens,
    completionTokens: completionTokens + other.completionTokens,
  );

  @override
  String toString() =>
      'UsageSummary($requests requests, $promptTokens + '
      '$completionTokens = $totalTokens tokens)';
}

/// Usage for one UTC day.
class UsageDayBucket {
  const UsageDayBucket({required this.day, required this.summary});

  /// `YYYY-MM-DD`, UTC.
  final String day;
  final UsageSummary summary;

  int get requests => summary.requests;
  int get totalTokens => summary.totalTokens;

  @override
  String toString() => 'UsageDayBucket($day, $summary)';
}

/// Daily totals, oldest day first.
class DailyUsage {
  const DailyUsage(this.buckets);

  final List<UsageDayBucket> buckets;

  bool get isEmpty => buckets.isEmpty;

  int get totalRequests =>
      buckets.fold(0, (sum, bucket) => sum + bucket.requests);

  int get totalTokens =>
      buckets.fold(0, (sum, bucket) => sum + bucket.totalTokens);

  @override
  String toString() =>
      'DailyUsage(${buckets.length} day(s), '
      '$totalRequests requests)';
}

class UsageRecordCodec extends RecordCodec<UsageRecord> {
  const UsageRecordCodec();

  @override
  Map<String, Object?> encode(UsageRecord record) => record.toJson();

  @override
  UsageRecord decode(String id, Map<String, Object?> json) {
    const collection = NoirCollections.usage;
    final provider = requireString(json, 'provider', collection, id);
    final model = requireString(json, 'model', collection, id);
    final promptTokens = requireInt(json, 'promptTokens', collection, id);
    final completionTokens = requireInt(
      json,
      'completionTokens',
      collection,
      id,
    );
    final funded = optionalBool(json, 'funded', collection, id);
    final occurredAt = requireTimestamp(json, 'occurredAt', collection, id);
    final createdAt = requireTimestamp(json, 'createdAt', collection, id);
    final updatedAt = requireTimestamp(json, 'updatedAt', collection, id);
    try {
      return UsageRecord(
        id: id,
        provider: provider,
        model: model,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        funded: funded,
        occurredAt: occurredAt,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
    } on InvalidDataError catch (error) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: error.message.contains('provider') ? 'provider' : 'model',
        detail: error.message,
        cause: error,
      );
    }
  }
}

class UsageRepository extends CollectionRepository<UsageRecord> {
  UsageRepository({
    required super.store,
    super.codec = const UsageRecordCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.usage);

  int _sequence = 0;

  /// Records one request and returns the stored record.
  ///
  /// The id is derived from the timestamp and a per-repository sequence, so two
  /// requests in the same microsecond still get separate records.
  Future<UsageRecord> record({
    required String provider,
    required String model,
    required int promptTokens,
    required int completionTokens,
    required bool funded,
    DateTime? occurredAt,
  }) async {
    final at = (occurredAt ?? now).toUtc();
    final id = 'u-${at.microsecondsSinceEpoch}-${_sequence++}';
    final saved = await upsert(
      UsageRecord(
        id: id,
        provider: provider,
        model: model,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        funded: funded,
        occurredAt: at,
        createdAt: at,
        updatedAt: at,
      ),
    );
    return saved;
  }

  /// Totals for a slice of usage. The window is [from, to): `from` inclusive,
  /// `to` exclusive. An inverted window matches nothing.
  Future<UsageSummary> summarize({
    DateTime? from,
    DateTime? to,
    String? provider,
    String? model,
    bool? funded,
    void Function(String id, Object error)? onUnreadable,
  }) async {
    var total = const UsageSummary.empty();
    for (final record in await readAll(onUnreadable: onUnreadable)) {
      if (!_matches(
        record,
        from: from,
        to: to,
        provider: provider,
        model: model,
        funded: funded,
      )) {
        continue;
      }
      total =
          total +
          UsageSummary(
            requests: 1,
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
          );
    }
    return total;
  }

  static bool _matches(
    UsageRecord record, {
    DateTime? from,
    DateTime? to,
    String? provider,
    String? model,
    bool? funded,
  }) {
    if (from != null && record.occurredAt.isBefore(from.toUtc())) {
      return false;
    }
    if (to != null && !record.occurredAt.isBefore(to.toUtc())) {
      return false;
    }
    if (provider != null && record.provider != provider) {
      return false;
    }
    if (model != null && record.model != model) {
      return false;
    }
    if (funded != null && record.funded != funded) {
      return false;
    }
    return true;
  }

  /// How many requests were made on the UTC day containing [at].
  Future<int> usedOn(DateTime at, {bool? funded, String? provider}) async {
    final day = startOfUtcDay(at);
    final summary = await summarize(
      from: day,
      to: day.add(const Duration(days: 1)),
      funded: funded,
      provider: provider,
    );
    return summary.requests;
  }

  /// How many requests are still allowed today under [dailyCap].
  Future<int> remainingOn(
    DateTime at, {
    required int dailyCap,
    bool? funded,
    String? provider,
  }) async {
    final used = await usedOn(at, funded: funded, provider: provider);
    final remaining = dailyCap - used;
    return remaining > 0 ? remaining : 0;
  }

  /// Totals per UTC day, oldest first, limited to the [days] most recent days
  /// that actually hold records.
  Future<DailyUsage> dailyTotals({
    int days = 7,
    String? provider,
    String? model,
    void Function(String id, Object error)? onUnreadable,
  }) async {
    if (days < 1) {
      throw const InvalidPageRequestError('days must be at least 1');
    }
    final totals = <String, UsageSummary>{};
    for (final record in await readAll(onUnreadable: onUnreadable)) {
      if (provider != null && record.provider != provider) {
        continue;
      }
      if (model != null && record.model != model) {
        continue;
      }
      final key = utcDayKey(record.occurredAt);
      final current = totals[key] ?? const UsageSummary.empty();
      totals[key] =
          current +
          UsageSummary(
            requests: 1,
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
          );
    }
    final keys = totals.keys.toList()..sort();
    final kept = keys.length <= days ? keys : keys.sublist(keys.length - days);
    return DailyUsage(
      List<UsageDayBucket>.unmodifiable(<UsageDayBucket>[
        for (final key in kept) UsageDayBucket(day: key, summary: totals[key]!),
      ]),
    );
  }

  /// Totals per model id.
  Future<Map<String, UsageSummary>> byModel({
    DateTime? from,
    DateTime? to,
    void Function(String id, Object error)? onUnreadable,
  }) async {
    final totals = <String, UsageSummary>{};
    for (final record in await readAll(onUnreadable: onUnreadable)) {
      if (!_matches(record, from: from, to: to)) {
        continue;
      }
      final current = totals[record.model] ?? const UsageSummary.empty();
      totals[record.model] =
          current +
          UsageSummary(
            requests: 1,
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
          );
    }
    return Map<String, UsageSummary>.unmodifiable(totals);
  }

  /// Newest first, then id, so paging is stable.
  static int compareByRecency(UsageRecord a, UsageRecord b) {
    final byTime = b.occurredAt.compareTo(a.occurredAt);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  /// A page of usage records, newest first.
  Future<Page<UsageRecord>> listRecent({
    PageRequest? page,
    int? limit,
    int? offset,
    String? provider,
    String? model,
    DateTime? from,
    DateTime? to,
    void Function(String id, Object error)? onUnreadable,
  }) async {
    final request = PageRequest.validated(
      offset: offset ?? page?.offset ?? 0,
      limit: limit ?? page?.limit ?? defaultPageLimit,
      maxLimit: maxPageLimit,
    );
    final matches = <UsageRecord>[];
    for (final record in await readAll(onUnreadable: onUnreadable)) {
      if (_matches(
        record,
        from: from,
        to: to,
        provider: provider,
        model: model,
      )) {
        matches.add(record);
      }
    }
    matches.sort(compareByRecency);
    return pageOf<UsageRecord>(matches, request, total: matches.length);
  }

  /// A page of usage records, optionally narrowed by provider, model or window.
  Future<Page<UsageRecord>> list({
    String? provider,
    String? model,
    DateTime? from,
    DateTime? to,
    PageRequest? page,
    int? limit,
    int? offset,
    void Function(String id, Object error)? onUnreadable,
  }) {
    return listRecent(
      page: page,
      limit: limit,
      offset: offset,
      provider: provider,
      model: model,
      from: from,
      to: to,
      onUnreadable: onUnreadable,
    );
  }
}
