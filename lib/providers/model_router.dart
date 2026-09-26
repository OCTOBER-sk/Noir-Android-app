/// Model routing over a live catalog, with rotation handling and a fallback
/// chain for execution.
///
/// The router never invents model ids: every decision comes from the catalog
/// that [ModelDiscovery] actually read, and a discovery failure propagates.
library;

import 'dart:async';

import 'cancellation.dart';
import 'chat_types.dart';
import 'errors.dart';
import 'model_discovery.dart';

/// Runs one request against one model. Injected so the router stays
/// transport-agnostic: production passes the adapter, tests pass a double.
typedef ChatExecutor =
    Future<ChatCompletion> Function(
      ChatRequest request, {
      CancellationToken? cancellation,
    });

/// A snapshot of the live catalog.
class ModelCatalog {
  ModelCatalog({
    required this.models,
    required this.rejectedEntries,
    required this.fetchedAt,
    required this.fromCache,
    required this.source,
  });

  /// Valid models in provider order.
  final List<DiscoveredModel> models;

  /// Entries the parser rejected during the fetch.
  final int rejectedEntries;

  /// When the catalog was fetched.
  final DateTime fetchedAt;

  /// Whether this snapshot was served from the in-memory TTL cache.
  final bool fromCache;

  /// Endpoint the catalog came from.
  final Uri source;

  /// Exact-id lookup.
  DiscoveredModel? byId(String id) {
    for (final DiscoveredModel model in models) {
      if (model.id == id) return model;
    }
    return null;
  }
}

/// Why a route was chosen.
enum RouteReason {
  /// A preferred id survived in the live catalog.
  preferred,

  /// No preferred id survived; the first catalog model that fits was used.
  catalogFallback,

  /// Nothing in the catalog fits the constraints.
  noCandidate,
}

/// The outcome of one routing decision.
class RouteDecision {
  const RouteDecision({
    required this.model,
    required this.reason,
    this.rotatedOut = const <String>[],
  });

  /// The chosen model, or `null` when there is no candidate.
  final DiscoveredModel? model;

  final RouteReason reason;

  /// Preferred ids that were absent or ineligible.
  final List<String> rotatedOut;

  @override
  String toString() => 'RouteDecision(${model?.id ?? 'none'}, $reason)';
}

/// Emitted when preferred model ids are missing from the live catalog.
class ModelRotationEvent {
  const ModelRotationEvent({
    required this.rotatedOut,
    required this.availableModelIds,
    required this.at,
  });

  /// Preferred ids that no longer exist or no longer fit.
  final List<String> rotatedOut;

  /// Every usable model id in the live catalog.
  final List<String> availableModelIds;

  final DateTime at;

  @override
  String toString() => 'ModelRotationEvent(rotated: $rotatedOut)';
}

/// Caches the live catalog and routes requests to models that still exist.
class ModelRouter {
  ModelRouter({
    required this.discovery,
    this.executor,
    this.cacheTtl = const Duration(minutes: 10),
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock;

  final ModelDiscovery discovery;

  /// Optional executor enabling [executeFallback].
  final ChatExecutor? executor;

  /// How long a fetched catalog is reused before refetching.
  final Duration cacheTtl;

  final DateTime Function() _clock;
  final StreamController<ModelRotationEvent> _rotations =
      StreamController<ModelRotationEvent>.broadcast();

  ModelCatalog? _catalog;

  /// Rotation events; safe to listen at any time.
  Stream<ModelRotationEvent> get rotations => _rotations.stream;

  /// Ids of the cached catalog, empty before the first successful fetch.
  List<String> get cachedModelIds =>
      _catalog?.models.map((DiscoveredModel m) => m.id).toList() ??
      const <String>[];

  /// Returns the live catalog, refetching when the TTL expired.
  ///
  /// Propagates discovery failures; no static list is ever substituted.
  Future<ModelCatalog> catalog({bool forceRefresh = false}) async {
    final ModelCatalog? cached = _catalog;
    if (!forceRefresh &&
        cached != null &&
        _clock().difference(cached.fetchedAt) < cacheTtl) {
      return ModelCatalog(
        models: cached.models,
        rejectedEntries: cached.rejectedEntries,
        fetchedAt: cached.fetchedAt,
        fromCache: true,
        source: cached.source,
      );
    }
    final ModelDiscoveryResult result = await discovery.fetch();
    final ModelCatalog fresh = ModelCatalog(
      models: result.models,
      rejectedEntries: result.rejectedEntries,
      fetchedAt: result.fetchedAt,
      fromCache: false,
      source: result.source,
    );
    _catalog = fresh;
    return fresh;
  }

  /// Chooses a model from the live catalog.
  ///
  /// Preferred ids are tried in order; ids that vanished are reported through
  /// [rotations] and skipped. Returns a `null` model with
  /// [RouteReason.noCandidate] when nothing fits — never a fabricated id.
  Future<RouteDecision> route({
    List<String> preferredModelIds = const <String>[],
    bool requireFreeTier = false,
    int? minContextLength,
  }) async {
    final ModelCatalog catalog = await this.catalog();
    bool usable(DiscoveredModel model) {
      if (requireFreeTier && !model.isFree) return false;
      if (minContextLength != null &&
          (model.contextLength ?? 0) < minContextLength) {
        return false;
      }
      return true;
    }

    final List<String> rotated = <String>[];
    for (final String id in preferredModelIds) {
      final DiscoveredModel? model = catalog.byId(id);
      if (model == null || !usable(model)) {
        rotated.add(id);
        _emitRotation(rotated, catalog);
        continue;
      }
      return RouteDecision(
        model: model,
        reason: RouteReason.preferred,
        rotatedOut: List<String>.unmodifiable(rotated),
      );
    }

    for (final DiscoveredModel model in catalog.models) {
      if (!usable(model)) continue;
      return RouteDecision(
        model: model,
        reason: RouteReason.catalogFallback,
        rotatedOut: List<String>.unmodifiable(rotated),
      );
    }
    return RouteDecision(
      model: null,
      reason: RouteReason.noCandidate,
      rotatedOut: List<String>.unmodifiable(rotated),
    );
  }

  /// Executes [request] against a chain of candidates, moving on only for
  /// transient failures (rate limits, network, server, timeout).
  ///
  /// Rethrows the failure of the first non-transient error, or the last
  /// transient error once the chain is exhausted.
  Future<ChatCompletion> executeFallback({
    required ChatRequest request,
    List<String> candidateIds = const <String>[],
    bool requireFreeTier = false,
    CancellationToken? cancellation,
  }) async {
    final ChatExecutor? run = executor;
    if (run == null) {
      throw StateError('ModelRouter.executeFallback requires an executor');
    }
    final List<String> candidates = candidateIds.isNotEmpty
        ? candidateIds
        : await _catalogCandidates(requireFreeTier);
    ProviderException? lastError;
    for (final String id in candidates) {
      cancellation?.throwIfCancelled();
      try {
        return await run(
          request.copyWith(model: id),
          cancellation: cancellation,
        );
      } on ProviderException catch (error) {
        if (!error.isTransient) rethrow;
        lastError = error;
      }
    }
    throw lastError ??
        ProviderException(
          kind: ProviderErrorKind.unknown,
          message: 'no candidate model was available to execute',
        );
  }

  /// Closes the rotation stream.
  Future<void> dispose() => _rotations.close();

  Future<List<String>> _catalogCandidates(bool requireFreeTier) async {
    final ModelCatalog catalog = await this.catalog();
    return catalog.models
        .where((DiscoveredModel model) => !requireFreeTier || model.isFree)
        .map((DiscoveredModel model) => model.id)
        .toList(growable: false);
  }

  void _emitRotation(List<String> rotated, ModelCatalog catalog) {
    if (_rotations.isClosed || rotated.isEmpty) return;
    _rotations.add(
      ModelRotationEvent(
        rotatedOut: List<String>.unmodifiable(rotated),
        availableModelIds: catalog.models
            .map((DiscoveredModel model) => model.id)
            .toList(growable: false),
        at: _clock(),
      ),
    );
  }
}
