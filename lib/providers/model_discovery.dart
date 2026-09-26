/// Live model discovery from a real `/models`-style endpoint.
///
/// There is no built-in model list: if the endpoint cannot be read, discovery
/// fails loudly and the caller decides what to do.
library;

import 'dart:convert';

import 'auth_config.dart';
import 'cancellation.dart';
import 'chat_types.dart';
import 'errors.dart';
import 'provider_client.dart';
import 'transport.dart';

/// One model entry returned by a provider.
class DiscoveredModel {
  const DiscoveredModel({
    required this.id,
    required this.displayName,
    required this.contextLength,
    required this.createdAtSeconds,
    required this.promptPricePerToken,
    required this.completionPricePerToken,
    required this.raw,
  });

  /// Provider model id, e.g. `vendor/alpha:free`.
  final String id;

  /// Human-readable name when the provider supplied one.
  final String? displayName;

  /// Context window in tokens, when advertised.
  final int? contextLength;

  /// Creation timestamp in seconds since epoch, when advertised.
  final int? createdAtSeconds;

  /// Price per prompt token, when advertised and parsable.
  final double? promptPricePerToken;

  /// Price per completion token, when advertised and parsable.
  final double? completionPricePerToken;

  /// The original JSON object, for provider-specific fields.
  final Map<String, dynamic> raw;

  /// Price per 1M prompt tokens, or `null` when unknown.
  double? get promptPricePer1MTokens =>
      promptPricePerToken == null ? null : promptPricePerToken! * 1e6;

  /// Price per 1M completion tokens, or `null` when unknown.
  double? get completionPricePer1MTokens =>
      completionPricePerToken == null ? null : completionPricePerToken! * 1e6;

  /// Whether the provider advertised any pricing at all.
  bool get hasPricing =>
      promptPricePerToken != null || completionPricePerToken != null;

  /// Free either because the id advertises a free tier or because it is free.
  bool get isFree =>
      id.endsWith(':free') ||
      (hasPricing && promptPricePerToken == 0 && completionPricePerToken == 0);

  @override
  String toString() => 'DiscoveredModel($id)';
}

/// Optional narrowing applied to a discovered catalog.
class ModelDiscoveryFilter {
  const ModelDiscoveryFilter({
    this.freeOnly = false,
    this.minContextLength,
    this.idPrefix,
  });

  /// Keep only models that report themselves as free.
  final bool freeOnly;

  /// Keep only models with at least this context length.
  final int? minContextLength;

  /// Keep only model ids starting with this prefix.
  final String? idPrefix;
}

/// The outcome of one discovery call.
class ModelDiscoveryResult {
  const ModelDiscoveryResult({
    required this.models,
    required this.rejectedEntries,
    required this.rejectedIds,
    required this.fetchedAt,
    required this.source,
  });

  /// Valid, de-duplicated entries in provider order.
  final List<DiscoveredModel> models;

  /// How many payload entries were dropped as unusable.
  final int rejectedEntries;

  /// Ids (or placeholders) of the dropped entries, for diagnostics.
  final List<String> rejectedIds;

  /// When the fetch completed.
  final DateTime fetchedAt;

  /// Endpoint the catalog came from.
  final Uri source;

  /// Looks up a model by exact id.
  DiscoveredModel? byId(String id) {
    for (final DiscoveredModel model in models) {
      if (model.id == id) return model;
    }
    return null;
  }
}

/// Fetches and parses a provider model catalog.
class ModelDiscovery {
  ModelDiscovery({
    required this.transport,
    required this.auth,
    RetryPolicy retry = const RetryPolicy(),
    ProviderTimeouts timeouts = const ProviderTimeouts(),
    Sleeper? sleep,
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock,
       _client = ProviderHttpClient(
         transport: transport,
         retry: retry,
         timeouts: timeouts,
         sleep: sleep,
       );

  /// Path appended to the base URL.
  static const String modelsPath = 'models';

  final ProviderTransport transport;
  final ProviderAuthConfig auth;
  final DateTime Function() _clock;
  final ProviderHttpClient _client;

  /// Fetches the live catalog.
  ///
  /// Throws [ProviderException] for auth, network, timeout and malformed
  /// failures; it never substitutes a built-in list.
  Future<ModelDiscoveryResult> fetch({
    CancellationToken? cancellation,
    ModelDiscoveryFilter filter = const ModelDiscoveryFilter(),
  }) async {
    final ProviderRequest request = ProviderRequest(
      method: 'GET',
      uri: auth.resolve(modelsPath),
      headers: auth.requestHeaders(),
    );
    final String body = await _client.sendText(
      request: request,
      cancellation: cancellation,
    );
    return parseModelsPayload(
      body,
      source: request.uri,
      filter: filter,
      fetchedAt: _clock(),
    );
  }

  /// Parses a `/models` payload, dropping entries that are not usable models.
  ///
  /// Accepts a decoded object or its JSON text. Entries without a non-empty
  /// string `id`, entries that are not objects and duplicate ids are rejected
  /// rather than surfaced.
  static ModelDiscoveryResult parseModelsPayload(
    Object? payload, {
    Uri? source,
    ModelDiscoveryFilter filter = const ModelDiscoveryFilter(),
    DateTime? fetchedAt,
  }) {
    Object? decoded = payload;
    if (payload is String) {
      try {
        decoded = jsonDecode(payload);
      } on FormatException catch (error) {
        throw ProviderException.malformed(
          'models payload was not valid JSON: ${error.message}',
        );
      }
    }
    if (decoded is! Map) {
      throw ProviderException.malformed('models payload was not an object');
    }
    final Object? data = decoded['data'];
    if (data is! List) {
      throw ProviderException.malformed('models payload had no "data" list');
    }

    final List<DiscoveredModel> models = <DiscoveredModel>[];
    final List<String> rejected = <String>[];
    final Set<String> seen = <String>{};

    for (final Object? entry in data) {
      if (entry is! Map) {
        rejected.add('<not-an-object>');
        continue;
      }
      final Object? rawId = entry['id'];
      if (rawId is! String || rawId.trim().isEmpty) {
        rejected.add(rawId == null ? '<missing-id>' : '<invalid-id>');
        continue;
      }
      final String id = rawId.trim();
      if (!seen.add(id)) {
        rejected.add(id);
        continue;
      }
      final DiscoveredModel model = _modelFromJson(id, entry);
      if (!_matches(model, filter)) continue;
      models.add(model);
    }

    return ModelDiscoveryResult(
      models: List<DiscoveredModel>.unmodifiable(models),
      rejectedEntries: rejected.length,
      rejectedIds: List<String>.unmodifiable(rejected),
      fetchedAt: fetchedAt ?? DateTime.now(),
      source: source ?? Uri.parse('about:blank'),
    );
  }

  static bool _matches(DiscoveredModel model, ModelDiscoveryFilter filter) {
    if (filter.freeOnly && !model.isFree) return false;
    if (filter.minContextLength != null &&
        (model.contextLength ?? 0) < filter.minContextLength!) {
      return false;
    }
    final String? prefix = filter.idPrefix;
    if (prefix != null && !model.id.startsWith(prefix)) return false;
    return true;
  }

  static DiscoveredModel _modelFromJson(
    String id,
    Map<Object?, Object?> entry,
  ) {
    final Map<String, dynamic> raw = <String, dynamic>{
      for (final MapEntry<Object?, Object?> e in entry.entries)
        '${e.key}': e.value,
    };
    final Object? pricing = entry['pricing'];
    final Map<Object?, Object?> prices = pricing is Map
        ? pricing
        : const <Object?, Object?>{};
    return DiscoveredModel(
      id: id,
      displayName: entry['name'] is String ? entry['name']! as String : null,
      contextLength: _int(entry['context_length']),
      createdAtSeconds: _int(entry['created']),
      promptPricePerToken: _price(prices['prompt']),
      completionPricePerToken: _price(prices['completion']),
      raw: raw,
    );
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// Parses a price string. Anything unparsable becomes `null` — never a guess.
  static double? _price(Object? value) {
    if (value is num) {
      if (!value.isFinite || value < 0) return null;
      return value.toDouble();
    }
    if (value is! String) return null;
    final double? parsed = double.tryParse(value.trim());
    if (parsed == null || !parsed.isFinite || parsed < 0) return null;
    return parsed;
  }
}
