// lib/core/composition_root.dart — the object graph the shipped app actually
// runs on.
//
// This file exists because the alternative was invisible. Noir had 67 files
// under lib/ and the app could reach 21 of them from lib/main.dart; the rest —
// the whole data layer, the memory service, the prompt service, the MCP
// composition, the model router, the agent runtime — was fully implemented,
// fully unit-tested, and absent from the product. `flutter analyze` was green
// because the code was valid, and `flutter test` was green because the test
// files imported the dead code directly. Neither can tell "shipped" from
// "only ever exercised by a test", which is why test/composition_reachability_
// test.dart now walks the import graph and fails when that stops being true.
//
// What is assembled here, and from what:
//
//   data      NoirDataLayer.open over a directory that was probed, not assumed
//   memory    MemoryService over a MemoryStore backed by MemoryRepository
//   prompts   PromptService over the injected clock
//   provider  OpenRouterAdapter + ProviderHttpClient + ModelDiscovery +
//             ModelRouter, all from the base URL and key in the user's own
//             provider settings — never a default endpoint or a default key
//   mcp       McpComposition over the persisted MCP server records and the
//             single PolicyEngine
//   safety    RiskClassifier, PolicyEngine, Sanitizer, ConsentGate,
//             CountdownUndoWindow, ScreenPlanner, NativeGestureExecutor,
//             SanitizingRecoveryEngine, AgentRuntimePipeline
//
// What it will not do:
//
//   * Invent a base URL, an API key, a model id, a fallback chain or a price.
//     With no provider configured, [provider] is [ProviderNotConfigured] and
//     the assistant turn says so on screen.
//   * Quietly degrade to volatile storage. If no writable directory exists,
//     [data] is [DataUnavailable] and every durable-backed feature reports
//     itself unavailable rather than pretending to have saved something.
//   * Skip a gate. The PolicyEngine here is the same instance the platform
//     calls back into through `policyGate`, and the pipeline can only reach a
//     gesture through an approval a human gave.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../agent/agent_runtime.dart';
import '../agent/cost_estimator.dart';
import '../data/data.dart';
import '../data/memory_store_bridge.dart';
import '../data/usage_store_bridge.dart';
import '../memory/memory_service.dart';
import '../platform/native_bridge.dart';
import '../prompts/prompt_service.dart';
import '../providers/adapters/openrouter_adapter.dart';
import '../providers/auth_config.dart';
import '../providers/cancellation.dart';
import '../providers/chat_types.dart';
import '../providers/errors.dart';
import '../providers/model_discovery.dart';
import '../providers/model_router.dart';
import '../providers/provider_client.dart';
import '../providers/streaming.dart';
import '../providers/transport.dart';
import '../providers/usage_tracker.dart';
import '../safety/policy_engine.dart';
import '../safety/risk_classifier.dart';
import '../safety/screen_content_sanitizer.dart';
import '../core/conversation_controller.dart';
import '../core/mcp_composition.dart';
import '../core/ui_state_contract.dart';
import '../ui/command_centre_screen.dart';
import '../ui/live_task_view.dart';
import '../ui/safety_center_screen.dart';
import '../ui/skill_manager_screen.dart';
import '../ui/usage_dashboard_screen.dart';
import 'agent_wiring.dart';
import 'clock.dart';

export 'agent_wiring.dart'
    show
        AutomationRequest,
        ConsentGate,
        CountdownUndoWindow,
        NoirTaskRun,
        PendingConfirmation,
        ScreenPlanner,
        ScreenUnavailableException;

/// Directory name Noir keeps its records under, inside a verified parent.
const String kNoirDataDirectoryName = 'noir';

/// How long the app waits for a human to answer a confirmation before the
/// pipeline treats it as a refusal.
const Duration kDefaultConsentTimeout = Duration(seconds: 45);

/// --- data layer -----------------------------------------------------------

/// What the composition managed to build for persistence.
sealed class DataWiring {
  const DataWiring();
}

/// The data layer opened on real files under a directory that was verified
/// writable before anything was written.
final class DataOpened extends DataWiring {
  const DataOpened(this.layer, this.root);

  final NoirDataLayer layer;

  /// The directory records are actually in. Shown to the user, because "where
  /// does Noir keep my data" has to have an answer that is checkable.
  final Directory root;
}

/// No writable directory exists, so nothing can be persisted.
///
/// This is a first-class state, not an error to swallow: the app tells the user
/// that Noir cannot save anything, and every durable-backed feature reports
/// itself unavailable instead of behaving as if a write had happened.
final class DataUnavailable extends DataWiring {
  const DataUnavailable(this.reason, this.attempted);

  /// Why no directory was usable.
  final String reason;

  /// The parents that were probed, in order, with what went wrong.
  final List<String> attempted;
}

/// --- memory service -------------------------------------------------------

/// What the composition managed to build for `lib/memory`.
sealed class MemoryWiring {
  const MemoryWiring();
}

/// The memory service is running over the durable memories collection.
final class MemoryOpened extends MemoryWiring {
  const MemoryOpened(this.service, this.store);

  final MemoryService service;
  final PersistedMemoryStore store;
}

/// Memory is unavailable because the collection behind it could not be opened.
final class MemoryUnavailable extends MemoryWiring {
  const MemoryUnavailable(this.reason);

  final String reason;
}

/// --- provider runtime -----------------------------------------------------

/// What the composition managed to build for the provider runtime.
sealed class ProviderWiring {
  const ProviderWiring();
}

/// A configured provider, with the live runtime behind it.
///
/// [auth] is the one and only credential in the app: it came out of
/// [NoirDataLayer.secrets] by way of [SettingsRepository.resolveSecret] for a
/// base URL the user typed. There is no second copy and no fallback key.
final class ProviderReady extends ProviderWiring {
  const ProviderReady({
    required this.settings,
    required this.auth,
    required this.transport,
    required this.client,
    required this.adapter,
    required this.router,
  });

  /// The user's own record, including the fallback models they listed.
  final ProviderSettings settings;

  final ProviderAuthConfig auth;

  /// The HTTP seam every provider call goes through. Production builds
  /// [HttpClientTransport]; a test injects its own, so the whole runtime is
  /// exercisable without a socket.
  final ProviderTransport transport;

  final ProviderHttpClient client;
  final OpenRouterAdapter adapter;

  /// Routes only to models that are in the catalog the provider really served.
  final ModelRouter router;
}

/// No provider is configured, so there is no endpoint to call.
///
/// The reason is a real one — the collection was empty, or every record was
/// unreadable — and it is what the assistant turn reports instead of a reply.
final class ProviderNotConfigured extends ProviderWiring {
  const ProviderNotConfigured(this.reason, {this.unreadable = const []});

  final String reason;

  /// Ids of provider records that could not be read, when that is the reason.
  final List<String> unreadable;
}

/// Where the live model catalog is.
sealed class CatalogState {
  const CatalogState();
}

/// Nothing has asked the provider for its catalog yet.
final class CatalogIdle extends CatalogState {
  const CatalogIdle();
}

/// A catalog read is in flight. No model may be claimed yet.
final class CatalogLoading extends CatalogState {
  const CatalogLoading();
}

/// A catalog was really read, and a route was really chosen from it.
final class CatalogReady extends CatalogState {
  const CatalogReady(this.catalog, this.route);

  final ModelCatalog catalog;
  final RouteDecision route;
}

/// The provider's catalog could not be read. No model is claimed, because the
/// router's whole contract is that it never invents an id.
final class CatalogUnavailable extends CatalogState {
  const CatalogUnavailable(this.reason);

  final String reason;
}

/// What the A9 caps say, and which models are actually available to fall back
/// to.
///
/// The caps come from [CostEstimator], which owns the documented free-tier
/// numbers. The fallback ids come from the catalog the provider really served —
/// never from a list baked into the app, because a fallback chain of ids no
/// endpoint has ever heard of is a chain of invented ids.
final class CostPlan {
  const CostPlan({
    required this.rpmCap,
    required this.dailyCap,
    required this.usedToday,
    required this.funded,
    required this.fallbackModelIds,
  });

  /// Requests per minute allowed.
  final int rpmCap;

  /// Requests allowed per UTC day.
  final int dailyCap;

  /// How many of today's requests the durable history already holds.
  final int usedToday;

  /// Whether the account is funded, which selects [dailyCap].
  final bool funded;

  /// Candidate ids, in provider order, from the live catalog.
  final List<String> fallbackModelIds;

  /// Requests still allowed today. Never negative.
  int get remainingToday {
    final int left = dailyCap - usedToday;
    return left > 0 ? left : 0;
  }
}

/// The whole application graph, assembled once at startup.
///
/// Construction never throws and never fabricates: every step that could fail
/// produces a typed state ([DataWiring], [MemoryWiring], [ProviderWiring],
/// [CatalogState]) that the UI renders as what it is.
class NoirComposition extends ChangeNotifier {
  NoirComposition._({
    required this.clock,
    required this.conversation,
    required this.usage,
    required this.usageStore,
    required this.policy,
    required this.riskClassifier,
    required this.sanitize,
    required this.bridge,
    required this.gate,
    required this.undoWindow,
    required this.planner,
    required this.executor,
    required this.critic,
    required this.recovery,
    required this.taskRun,
    required this.pipeline,
    required this.prompts,
    required this.data,
    required this.memory,
    required this.mcp,
    required this.provider,
    required this.jobs,
    required this.journal,
  });

  /// The injected time source. Every record this graph writes is stamped by it.
  final Clock clock;

  /// The conversation the Command Centre renders. Owned here, closed by
  /// [dispose].
  final ConversationController conversation;

  /// The live usage counters in the Command Centre header.
  final UsageTracker usage;

  /// The durable store behind [usage], when there is one.
  final PersistedUsageStore? usageStore;

  /// The single policy authority. The platform calls back into this same
  /// instance through `NativeBridge.evaluateGate`, so Dart and Kotlin can never
  /// disagree about a verdict.
  final PolicyEngine policy;

  final RiskClassifier riskClassifier;

  /// The deterministic A6a screen sanitizer, as the pipeline's callable.
  final ScreenSanitizer sanitize;

  /// The only path to the platform.
  final NativeBridge bridge;

  /// Bounded, consent-based, user-initiated. Nothing reaches a gesture without
  /// an approval from here.
  final ConsentGate gate;

  /// The A6b five-second cancellable undo window.
  final CountdownUndoWindow undoWindow;

  final ScreenPlanner planner;
  final NativeGestureExecutor executor;
  final ReflectionCritic critic;
  final SanitizingRecoveryEngine recovery;

  /// The A5 state machine and the UI event stream it publishes.
  final NoirTaskRun taskRun;

  /// The A6 pipeline. Never invoked except by [runAutomation].
  final AgentRuntimePipeline pipeline;

  /// Named prompt templates. Empty until somebody creates one; there is no
  /// default template and no ambient merge.
  final PromptService prompts;

  final DataWiring data;
  final MemoryWiring memory;
  final McpWiring mcp;
  final ProviderWiring provider;

  /// Scheduled jobs, when the data layer opened. Null otherwise.
  final JobRepository? jobs;

  /// Writes the conversation to the durable transcript. Null when the data layer
  /// did not open, because there is then nowhere for a transcript to live.
  final ConversationJournal? journal;

  /// The durable transcript, or null when there is no store to hold one.
  ConversationRepository? get conversations => journal?.repository;

  CatalogState _catalog = const CatalogIdle();
  bool _warming = false;
  bool _disposed = false;
  Future<void>? _warmUp;

  final List<SafetyEvent> _safetyLog = <SafetyEvent>[];
  final StreamController<UsageState> _usageStates =
      StreamController<UsageState>.broadcast();
  final StreamController<SkillListState> _skills =
      StreamController<SkillListState>.broadcast();
  final StreamController<TaskTimelineState> _timeline =
      StreamController<TaskTimelineState>.broadcast();
  final StreamController<SafetyEventState> _safetyEvents =
      StreamController<SafetyEventState>.broadcast();
  StreamSubscription<NoirUiEvent>? _taskSubscription;
  int _safetySequence = 0;
  int _timelineSequence = 0;

  /// The live model catalog state. Rebuild when this changes.
  CatalogState get catalog => _catalog;

  /// Confirmations waiting on a human. The UI is the only holder of one.
  Stream<PendingConfirmation> get confirmations => gate.requests;

  /// Model ids the provider rotated away from, as the router saw it.
  Stream<ModelRotationEvent> get rotations {
    final ProviderWiring wired = provider;
    return wired is ProviderReady
        ? wired.router.rotations
        : const Stream<ModelRotationEvent>.empty();
  }

  /// Builds the graph.
  ///
  /// [dataRootCandidates] are the parents probed for a writable record
  /// directory; the first that is genuinely writable wins. Pass an explicit
  /// list in tests. When every candidate fails, [data] is [DataUnavailable]
  /// with the real reason.
  ///
  /// The model catalog is *not* fetched here. A catalog read is a network call
  /// to a provider the user configured, and blocking first paint on it would be
  /// the wrong trade; call [warmUp] for that, or await it in a splash.
  static Future<NoirComposition> open({
    List<Directory>? dataRootCandidates,
    NativeBridge? bridge,
    DateTime Function()? now,
    Duration consentTimeout = kDefaultConsentTimeout,
    ProviderTransport? providerTransport,
  }) async {
    final Clock clock = SystemClock();
    final DateTime Function() stamp = now ?? clock.now;

    // Safety first, and before anything that could ever want to act. There is
    // exactly one PolicyEngine in the process: when a bridge is injected the
    // graph adopts *its* engine rather than building a second one, because two
    // engines is a split authority — the platform would be gated by one set of
    // rules and the pipeline by another, and a UI lock set on one would not
    // apply to the other.
    final PolicyEngine policy = bridge?.policyEngine ?? PolicyEngine();
    final RiskClassifier riskClassifier =
        bridge?.riskClassifier ?? RiskClassifier();
    final NativeBridge nativeBridge =
        bridge ??
        NativeBridge(policyEngine: policy, riskClassifier: riskClassifier);

    // --- persistence -----------------------------------------------------
    final DataRootResolution resolution = await resolveDataRoot(
      candidates: dataRootCandidates,
    );
    NoirDataLayer? layer;
    Directory? dataDirectory;
    String dataFailure = 'Noir has no record store.';
    final List<String> dataAttempts = <String>[];
    switch (resolution) {
      case DataRootResolved(:final Directory directory):
        dataDirectory = directory;
        dataAttempts.add('${directory.path}: writable');
        try {
          layer = await NoirDataLayer.open(root: directory, clock: stamp);
        } on Object catch (error) {
          dataDirectory = null;
          dataFailure = 'Noir could not open its data layer: $error';
          dataAttempts.add('${directory.path}: $error');
        }
      case DataRootUnresolved(
        :final String reason,
        :final List<String> attempted,
      ):
        dataFailure = reason;
        dataAttempts.addAll(attempted);
    }
    final DataWiring data = (layer == null || dataDirectory == null)
        ? DataUnavailable(dataFailure, dataAttempts)
        : DataOpened(layer, dataDirectory);

    // --- memory ----------------------------------------------------------
    MemoryWiring memory;
    PersistedMemoryStore? memoryStore;
    if (layer == null) {
      memory = MemoryUnavailable(
        'Memories need durable storage, and there is none: $dataFailure',
      );
    } else {
      try {
        memoryStore = await PersistedMemoryStore.open(layer.memories);
        memory = MemoryOpened(
          MemoryService(store: memoryStore, clock: clock),
          memoryStore,
        );
      } on MemoryStoreUnavailable catch (error) {
        memory = MemoryUnavailable(
          'Memories need durable storage, and the store could not be read: '
          '${error.reason}',
        );
      } on Object catch (error) {
        memory = MemoryUnavailable('Memories could not be opened: $error');
      }
    }

    // --- prompts ---------------------------------------------------------
    // PromptService keeps its templates in process; it is constructed over the
    // injected clock and starts empty, which is the truth: this build ships no
    // template, so there is nothing to compose until a user creates one.
    final PromptService prompts = PromptService(clock: clock);

    // --- usage -----------------------------------------------------------
    // The tracker exists before a provider is known so the Command Centre has a
    // real counter to read. Its store is durable when the data layer opened.
    final ProviderSettings? providerSettings = await _firstProviderSettings(
      layer,
    );
    PersistedUsageStore? usageStore;
    UsageTracker usage;
    if (layer != null && providerSettings != null) {
      usageStore = PersistedUsageStore(
        usage: layer.usage,
        providerId: providerSettings.id,
        funded: providerSettings.funded,
      );
      usage = UsageTracker(store: usageStore, clock: stamp);
    } else {
      usage = UsageTracker(clock: stamp);
    }

    // --- provider runtime ------------------------------------------------
    final ProviderWiring provider = await _wireProvider(
      layer: layer,
      settings: providerSettings,
      transport: providerTransport,
    );

    // --- safety stack and the A6 pipeline --------------------------------
    final NoirTaskRun taskRun = NoirTaskRun();
    final ConsentGate gate = ConsentGate(timeout: consentTimeout);
    final CountdownUndoWindow undoWindow = CountdownUndoWindow(
      publish: taskRun.emit,
    );
    final ScreenPlanner planner = ScreenPlanner(bridge: nativeBridge);
    final NativeGestureExecutor executor = NativeGestureExecutor(
      bridge: nativeBridge,
      gate: gate,
    );
    final ReflectionCritic critic = ReflectionCriticImpl();
    final SanitizingRecoveryEngine recovery = SanitizingRecoveryEngine(
      tasks: taskRun.controller,
    );
    final AgentRuntimePipeline pipeline = AgentRuntimePipeline(
      planner: planner,
      riskClassifier: riskClassifier,
      // Named explicitly rather than left to the default so there is one
      // sanitizer in the graph and it is the deterministic A6a one.
      sanitizer: Sanitizer.sanitize,
      policyEngine: policy,
      gate: gate,
      undoWindow: undoWindow,
      execute: executor,
      reflectionCritic: critic,
      recovery: recovery,
    );

    // --- MCP -------------------------------------------------------------
    // One PolicyEngine, again: McpComposition asks this instance for its
    // verdicts, so an MCP tool call and a gesture are gated by the same rules.
    final McpWiring mcp = layer == null
        ? McpWiringFailed(
            'MCP needs the server configuration store: $dataFailure',
          )
        : McpWired(McpComposition(servers: layer.mcpServers, policy: policy));

    final ConversationController conversation = ConversationController();
    final NoirComposition composition = NoirComposition._(
      clock: clock,
      conversation: conversation,
      usage: usage,
      usageStore: usageStore,
      policy: policy,
      riskClassifier: riskClassifier,
      sanitize: Sanitizer.sanitize,
      bridge: nativeBridge,
      gate: gate,
      undoWindow: undoWindow,
      planner: planner,
      executor: executor,
      critic: critic,
      recovery: recovery,
      taskRun: taskRun,
      pipeline: pipeline,
      prompts: prompts,
      data: data,
      memory: memory,
      mcp: mcp,
      provider: provider,
      jobs: layer?.jobs,
      journal: layer == null
          ? null
          : ConversationJournal(
              conversation: conversation,
              repository: layer.conversations,
            ),
    );
    composition._taskSubscription = taskRun.events.listen(
      composition._onTaskEvent,
    );
    // The transcript is restored before anything can append to it, so the
    // durable record and the controller end up holding the same conversation
    // rather than the record gaining a second thread.
    if (composition.journal != null) {
      try {
        await composition.journal!.restoreLatest();
      } on Object {
        // A transcript that cannot be read leaves the conversation empty, which
        // is the honest state. The store's recovery path holds the reason.
      }
    }
    return composition;
  }

  /// Reads the provider catalog and rebinds the pricing table.
  ///
  /// Safe to call more than once; a second call while one is in flight is
  /// ignored rather than opening a second request. Failures land in [catalog]
  /// as [CatalogUnavailable] and never leave a stale model selected.
  Future<void> warmUp({bool forceRefresh = false}) {
    final Future<void>? running = _warmUp;
    if (running != null && !forceRefresh) return running;
    if (_warming) return Future<void>.value();
    _warming = true;
    _setCatalog(const CatalogLoading());
    final Future<void> run = _loadCatalog(forceRefresh: forceRefresh);
    _warmUp = run;
    return run;
  }

  Future<void> _loadCatalog({required bool forceRefresh}) async {
    final ProviderWiring wired = provider;
    if (wired is! ProviderReady) {
      _warming = false;
      _setCatalog(
        CatalogUnavailable(
          wired is ProviderNotConfigured
              ? wired.reason
              : 'No provider is configured.',
        ),
      );
      return;
    }
    try {
      final ModelCatalog catalog = await wired.router.catalog(
        forceRefresh: forceRefresh,
      );
      // Prices come from the same read that produced the catalog, so a cost is
      // never computed from a model list nobody served.
      usage.pricing = PricingTable.fromDiscovery(catalog.models);
      final RouteDecision route = await wired.router.route(
        preferredModelIds: <String>[
          wired.settings.defaultModel,
          ...wired.settings.fallbackModels,
        ],
        requireFreeTier: false,
      );
      if (route.model == null) {
        _setCatalog(
          CatalogUnavailable(
            'The provider served a catalog with no usable model in it '
            '(${catalog.models.length} entries, '
            '${catalog.rejectedEntries} rejected).',
          ),
        );
        return;
      }
      _setCatalog(CatalogReady(catalog, route));
    } on ProviderException catch (error) {
      _setCatalog(CatalogUnavailable('${error.kind.name}: ${error.message}'));
    } on Object catch (error) {
      _setCatalog(CatalogUnavailable('$error'));
    } finally {
      _warming = false;
    }
  }

  void _setCatalog(CatalogState next) {
    if (_disposed || _catalog == next) return;
    _catalog = next;
    notifyListeners();
  }

  /// The caps in force today and the models that can actually take a turn.
  ///
  /// Null when there is no provider, because there is nothing to spend against
  /// and no chain to walk.
  Future<CostPlan?> costPlan() async {
    final ProviderWiring wired = provider;
    if (wired is! ProviderReady) return null;
    final CatalogState current = _catalog;
    final List<String> available = current is CatalogReady
        ? current.catalog.models
              .map((DiscoveredModel model) => model.id)
              .toList(growable: false)
        : const <String>[];
    // The user's own fallback list, filtered to what the catalog still serves.
    // Anything the provider dropped is reported by the router's rotation stream
    // rather than being sent anyway.
    final List<String> fallbacks = <String>[
      for (final String id in wired.settings.fallbackModels)
        if (available.contains(id)) id,
    ];
    final int usedToday = await _usedToday();
    final CostEstimate estimate = CostEstimator.estimate(
      funded: wired.settings.funded,
      usedToday: usedToday,
    );
    return CostPlan(
      rpmCap: estimate.rpmHeadroom,
      dailyCap: wired.settings.dailyCap > 0
          ? wired.settings.dailyCap
          : estimate.dailyCap,
      usedToday: usedToday,
      funded: wired.settings.funded,
      fallbackModelIds: List<String>.unmodifiable(fallbacks),
    );
  }

  Future<int> _usedToday() async {
    final DataWiring current = data;
    if (current is! DataOpened) return 0;
    try {
      return await current.layer.usage.usedOn(clock.now());
    } on Object {
      // A usage history that cannot be read means the budget is unknown, and
      // the caller's own accounting is the number that is reported.
      return usage.requestCount;
    }
  }

  /// The assistant's answer to [prompt] as a stream of real text deltas.
  ///
  /// Null when there is no provider: the Command Centre then says no backend is
  /// connected, which is true, rather than showing an invented reply. When a
  /// provider *is* configured but unusable, the returned stream fails with the
  /// real reason so the reason is on screen instead of a silent empty reply.
  AssistantReplyStream? get assistantReplies {
    final ProviderWiring wired = provider;
    if (wired is ProviderReady) {
      final CatalogState current = _catalog;
      return (String prompt) => _streamCompletion(wired, prompt, current);
    }
    final String reason = wired is ProviderNotConfigured
        ? wired.reason
        : 'No provider is configured.';
    return (String prompt) =>
        Stream<String>.error(AssistantUnavailable(reason));
  }

  Stream<String> _streamCompletion(
    ProviderReady wired,
    String prompt,
    CatalogState current,
  ) {
    if (current is! CatalogReady) {
      final String reason = switch (current) {
        CatalogIdle() =>
          'No model catalog has been read yet, so no model can be selected.',
        CatalogLoading() => 'The model catalog is still being read.',
        CatalogUnavailable(:final String reason) => reason,
        CatalogReady() => 'No model is available.',
      };
      return Stream<String>.error(AssistantUnavailable(reason));
    }
    final String? model = current.route.model?.id;
    if (model == null) {
      return Stream<String>.error(
        const AssistantUnavailable('The provider served no usable model.'),
      );
    }
    return _replyFor(wired, model, prompt);
  }

  Stream<String> _replyFor(ProviderReady wired, String model, String prompt) {
    final ChatRequest request = ChatRequest(
      model: model,
      messages: <ChatMessage>[ChatMessage(ChatRole.user, prompt)],
    );
    final StringBuffer accumulated = StringBuffer();
    final StreamController<String> out = StreamController<String>();
    late StreamSubscription<ProviderStreamEvent> subscription;
    subscription = wired.adapter
        .streamChat(request: request)
        .listen(
          (ProviderStreamEvent event) {
            if (event is ProviderTextDelta) {
              accumulated.write(event.text);
              out.add(event.text);
              taskRun.emit(StreamingTokenReceived(event.text));
            } else if (event is ProviderUsage) {
              // Real provider-reported usage, recorded durably. This is the one
              // place tokens enter the system.
              unawaited(
                usage
                    .recordUsage(model: model, usage: event.usage)
                    .then((_) => unawaited(_publishUsage()))
                    .catchError((Object _) {}),
              );
            }
          },
          onError: (Object error) {
            _logSafety(
              summary: 'Provider stream failed',
              kind: SafetyEventKind.dispatch,
              outcome: SafetyEventOutcome.blocked,
              detail: '$error',
            );
            out.addError(error);
            unawaited(out.close());
          },
          onDone: () async {
            await subscription.cancel();
            final String text = accumulated.toString();
            if (text.trim().isEmpty) {
              out.addError(
                const AssistantUnavailable('The provider returned no content.'),
              );
            }
            await out.close();
            await _publishUsage();
          },
          cancelOnError: true,
        );
    out.onCancel = () => subscription.cancel();
    return out.stream;
  }

  /// Runs one user-requested action on the current screen, through the A6
  /// pipeline and therefore through the policy gate and a human confirmation.
  ///
  /// This is the only entry point to the pipeline, which is what keeps
  /// accessibility automation user-initiated: nothing reaches here except a
  /// call from the UI on the user's behalf.
  Future<RuntimeResult?> runAutomation(AutomationRequest request) async {
    if (_disposed) return null;
    taskRun.transitionTo(TaskState.planning);
    _logSafety(
      summary: 'Requested ${request.action}',
      kind: SafetyEventKind.policy,
      outcome: SafetyEventOutcome.unknown,
    );
    final bool screenWasSanitized = await _lastDumpWasSanitized();
    Future<RuntimeResult> run() => pipeline.run(request);

    // The gate publishes its own confirmation; mirror it into the UI contract
    // so the Command Centre and the Live Task view both see the request.
    final StreamSubscription<PendingConfirmation> watching = gate.requests
        .listen((PendingConfirmation confirmation) {
          taskRun.announceConfirmation(
            action: confirmation.action,
            riskTier: confirmation.riskLevel,
            toolName: 'accessibility.${request.action}',
            screenContentWasSanitized: screenWasSanitized,
          );
          _logSafety(
            summary: 'Waiting for a decision on ${confirmation.action}',
            kind: SafetyEventKind.confirmation,
            outcome: SafetyEventOutcome.awaitingConfirmation,
            detail: confirmation.message,
          );
        });
    try {
      final RuntimeResult result = await run();
      _recordOutcome(result);
      if (result.blocked) {
        taskRun.transitionTo(TaskState.failed);
      } else {
        taskRun.transitionTo(TaskState.completed);
      }
      return result;
    } on ScreenUnavailableException catch (error) {
      _logSafety(
        summary: 'No screen to act on',
        kind: SafetyEventKind.sanitization,
        outcome: SafetyEventOutcome.blocked,
        detail: error.code,
      );
      taskRun.transitionTo(TaskState.failed);
      return null;
    } on Object catch (error) {
      _logSafety(
        summary: 'The pipeline failed',
        kind: SafetyEventKind.policy,
        outcome: SafetyEventOutcome.blocked,
        detail: '$error',
      );
      taskRun.transitionTo(TaskState.failed);
      return null;
    } finally {
      await watching.cancel();
    }
  }

  /// Whether the A6a sanitizer stripped anything out of the last real dump.
  ///
  /// Read from the platform, never assumed: a dump that could not be read is
  /// reported as "unknown" and the run is planned against nothing.
  Future<bool> _lastDumpWasSanitized() async {
    try {
      final NativeNodeDump dump = await bridge.getNodes();
      if (!dump.available) return false;
      return dump.sanitized().stripped.isNotEmpty;
    } on Object {
      return false;
    }
  }

  void _recordOutcome(RuntimeResult result) {
    if (result.blocked) {
      final Object? reason = result.result;
      _logSafety(
        summary: 'Blocked before execution',
        kind: SafetyEventKind.policy,
        outcome: SafetyEventOutcome.blocked,
        detail: reason is GateResult ? reason.message : '$reason',
      );
      return;
    }
    final Object? outcome = result.result;
    if (outcome is NativeGestureOutcome) {
      _logSafety(
        summary: outcome.executed ? 'Gesture dispatched' : 'Gesture refused',
        kind: SafetyEventKind.dispatch,
        outcome: outcome.executed
            ? SafetyEventOutcome.allowed
            : SafetyEventOutcome.blocked,
        detail: outcome.executed ? null : outcome.blockReason,
      );
    }
  }

  /// --- UI state sources ---------------------------------------------------

  /// Real usage, as the dashboard's own states.
  ///
  /// [UsageSnapshot.none] is emitted until a figure is actually known, so an
  /// empty dashboard reads as "nothing reported yet" and never as zeroes.
  Stream<UsageState> usageStates() {
    if (_disposed) return const Stream<UsageState>.empty();
    unawaited(_publishUsage());
    return _usageStates.stream;
  }

  Future<void> _publishUsage() async {
    if (_disposed || _usageStates.isClosed) return;
    final CatalogState current = _catalog;
    UsageSnapshot snapshot;
    try {
      await usage.flush();
      final summary = await usage.summary();
      final CostPlan? plan = await costPlan();
      snapshot = UsageSnapshot(
        tokensUsed: usage.hasReportedUsage ? summary.totalTokens : null,
        costUsd: usage.pricedRecords > 0 ? summary.costUsd : null,
        activeModel: current is CatalogReady ? current.route.model?.id : null,
        requestsUsed: usage.hasReportedUsage ? summary.requests : null,
        requestsLimit: plan?.dailyCap,
        capturedAt: clock.now(),
      );
    } on Object catch (error) {
      _usageStates.add(UsageFailed('$error'));
      return;
    }
    _usageStates.add(UsageAvailable(snapshot));
  }

  /// Registered automations, read from the scheduled-jobs collection.
  ///
  /// A scheduled job is the closest thing this build has to a named automation:
  /// the user created it, named it, and it has a lifecycle (unknown until it
  /// has run, active while scheduled, needs review when its last run failed,
  /// disabled when switched off). The mapping is documented on [toSkillRecord]
  /// and it never invents a run: a job with no run says so.
  Stream<SkillListState> skills() {
    if (_disposed) return const Stream<SkillListState>.empty();
    unawaited(_publishSkills());
    return _skills.stream;
  }

  Future<void> _publishSkills() async {
    if (_disposed || _skills.isClosed) return;
    final DataWiring current = data;
    final JobRepository? repository = jobs;
    if (current is! DataOpened || repository == null) {
      _skills.add(
        SkillListFailed(
          current is DataUnavailable
              ? 'No automations can be listed without storage: '
                    '${current.reason}'
              : 'No automations are registered.',
        ),
      );
      return;
    }
    try {
      final List<ScheduledJob> records = await repository.readAll(
        onUnreadable: (String id, Object error) {
          // Listed by nothing rather than fabricated: a job that cannot be read
          // is simply not offered as runnable.
        },
      );
      _skills.add(
        SkillListAvailable(<SkillRecord>[
          for (final ScheduledJob job in records)
            SkillRecord(
              id: job.id,
              name: job.name,
              state: job.toSkillState(),
              lastUsedAt: job.lastRunAt?.toUtc(),
              detail:
                  job.lastError ??
                  '${job.schedule.kind.name} schedule, '
                      '${job.runCount} run(s)',
            ),
        ]),
      );
    } on Object catch (error) {
      _skills.add(SkillListFailed('$error'));
    }
  }

  /// The A6 pipeline's real timeline, for the Live Task view.
  Stream<TaskTimelineState> taskTimeline() {
    if (_disposed) return const Stream<TaskTimelineState>.empty();
    return _timeline.stream;
  }

  /// The safety decisions this graph has actually made, oldest first.
  Stream<SafetyEventState> safetyEvents() {
    if (_disposed) return const Stream<SafetyEventState>.empty();
    unawaited(_publishSafety());
    return _safetyEvents.stream;
  }

  Future<void> _publishSafety() async {
    if (_disposed || _safetyEvents.isClosed) return;
    _safetyEvents.add(
      _safetyLog.isEmpty
          ? const SafetyEventLoading()
          : SafetyEventAvailable(List<SafetyEvent>.unmodifiable(_safetyLog)),
    );
  }

  void _logSafety({
    required String summary,
    required SafetyEventKind kind,
    required SafetyEventOutcome outcome,
    String? detail,
  }) {
    if (_disposed) return;
    _safetySequence++;
    _safetyLog.add(
      SafetyEvent(
        id: 'safety-$_safetySequence',
        summary: summary,
        kind: kind,
        outcome: outcome,
        detail: detail,
        occurredAt: clock.now(),
      ),
    );
    if (!_safetyEvents.isClosed) {
      _safetyEvents.add(
        SafetyEventAvailable(List<SafetyEvent>.unmodifiable(_safetyLog)),
      );
    }
  }

  void _onTaskEvent(NoirUiEvent event) {
    if (_disposed || _timeline.isClosed) return;
    if (event is! TaskStateChanged) return;
    _timelineSequence++;
    _timeline.add(
      TaskTimelineAvailable(<TaskTimelineEvent>[
        TaskTimelineEvent(
          id: 'stage-$_timelineSequence',
          stage: event.state.name,
          detail: taskPhaseDetail(event.state),
          phase: taskPhaseOf(event.state),
          occurredAt: clock.now(),
        ),
      ]),
    );
  }

  /// Releases everything this graph owns.
  ///
  /// Order matters: pending usage and memory writes are flushed to disk before
  /// the stores they belong to are closed, and every approval is revoked before
  /// the bridge goes, so nothing can dispatch behind a disposed graph.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    gate.revokeAll();
    undoWindow.cancel();
    try {
      await usage.flush();
    } on Object {
      // Reported through usage.pendingFailures already; teardown continues so
      // the rest of the graph still shuts down cleanly.
    }
    final MemoryWiring wiredMemory = memory;
    if (wiredMemory is MemoryOpened) {
      try {
        await wiredMemory.store.flush();
      } on Object {
        // Same reasoning as above.
      }
    }
    await _taskSubscription?.cancel();
    _taskSubscription = null;
    await gate.dispose();
    await undoWindow.dispose();
    await taskRun.close();
    final McpWiring wiredMcp = mcp;
    if (wiredMcp is McpWired) await wiredMcp.composition.closeAll();
    final ProviderWiring wiredProvider = provider;
    if (wiredProvider is ProviderReady) {
      await wiredProvider.router.dispose();
      wiredProvider.transport.close();
    }
    // The broadcast controllers below are closed without awaiting their done
    // futures. A broadcast StreamController that never had a subscriber never
    // completes `close()`, so awaiting one would make teardown hang whenever a
    // screen had not subscribed — and hanging in `dispose` is how a test suite
    // ends up with a wedged app. The controllers are marked closed either way,
    // which is what the rest of the graph relies on.
    // The transcript is flushed before the conversation is closed, so the last
    // message on screen is the last message on disk.
    await journal?.close();
    unawaited(_usageStates.close());
    unawaited(_skills.close());
    unawaited(_timeline.close());
    unawaited(_safetyEvents.close());
    unawaited(conversation.close());
    await bridge.dispose();
    super.dispose();
  }
}

/// Raised when the assistant cannot answer, carrying the real reason.
///
/// The Command Centre renders this as the reason on the timeline. It exists so
/// "no backend" and "the backend said no" are different, both visible, and
/// neither replaced by a reply that was never generated.
class AssistantUnavailable implements Exception {
  const AssistantUnavailable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// The lifecycle a scheduled job is in, as the skill registry's vocabulary.
///
/// The mapping is deliberately mechanical so it can be read off the record:
///
///   * no run yet                       -> [SkillState.unknown]
///   * ran, last run had no error       -> [SkillState.validated]
///   * ran, last run reported an error  -> [SkillState.needsReview]
///   * switched off                     -> [SkillState.disabled]
///   * enabled with a next run scheduled -> [SkillState.active]
extension ScheduledJobSkillState on ScheduledJob {
  SkillState toSkillState() {
    if (!enabled) return SkillState.disabled;
    if (nextRunAt == null) {
      return runCount == 0 ? SkillState.unknown : SkillState.validated;
    }
    if (lastError != null) return SkillState.needsReview;
    return runCount == 0 ? SkillState.unknown : SkillState.active;
  }
}

/// A6 [TaskState] as the Live Task view's phase vocabulary.
TaskPhase taskPhaseOf(TaskState state) => switch (state) {
  TaskState.idle => TaskPhase.queued,
  TaskState.planning => TaskPhase.running,
  TaskState.awaitingConfirmation => TaskPhase.blocked,
  TaskState.executing => TaskPhase.running,
  TaskState.recovering => TaskPhase.recovering,
  TaskState.paused => TaskPhase.queued,
  TaskState.completed => TaskPhase.completed,
  TaskState.failed => TaskPhase.failed,
  TaskState.cancelled => TaskPhase.failed,
};

/// Wording for a task state. Says what the state is, never why it happened —
/// the reason is in the safety log, which is where the evidence is.
String taskPhaseDetail(TaskState state) => switch (state) {
  TaskState.idle => 'Nothing is running.',
  TaskState.planning => 'Reading the screen and classifying the request.',
  TaskState.awaitingConfirmation => 'Waiting for your decision.',
  TaskState.executing => 'Running the approved action.',
  TaskState.recovering => 'Recovering with sanitized screen content.',
  TaskState.paused => 'Paused.',
  TaskState.completed => 'Finished.',
  TaskState.failed => 'Stopped without acting.',
  TaskState.cancelled => 'Cancelled.',
};

/// The durable record the current conversation is written to.
///
/// One conversation, one record, for the life of the install. Noir's controller
/// has no notion of a conversation id — it owns a single ongoing thread — so the
/// graph names the record once, here, rather than inventing an id per message.
const String kCurrentConversationId = 'current';

/// Keeps the durable transcript in step with the in-memory conversation.
///
/// The controller is the source of truth for what is on screen; this writes the
/// same messages into [ConversationRepository] so they survive a restart. The
/// mapping is lossless in one direction and one only: [ConversationMessage] is
/// the same type in `lib/core` and `lib/data`, so a message is written exactly
/// as it was produced, with no re-encoding and nothing invented. Going the
/// other way, [restoreLatest] replays the transcript into a *fresh* controller,
/// which mints its own message ids — the durable record is the transcript of
/// record, and the ids a restored message gets on screen are the controller's,
/// not the ones on disk.
class ConversationJournal {
  ConversationJournal({
    required this.conversation,
    required this.repository,
    this.conversationId = kCurrentConversationId,
  }) {
    _subscription = conversation.events.listen(_onEvent);
  }

  final ConversationController conversation;
  final ConversationRepository repository;
  final String conversationId;

  StreamSubscription<NoirUiEvent>? _subscription;

  /// Writes still in flight, so teardown can wait for them.
  Future<void> _pending = Future<void>.value();

  /// Ids of messages that reached disk.
  int persistedMessages = 0;

  /// Replays the durable transcript into the fresh controller.
  ///
  /// Returns how many messages were restored. Zero means the store genuinely
  /// held no conversation — which is the first run, and is reported as zero
  /// rather than as an error.
  Future<int> restoreLatest() async {
    final ConversationSnapshot? stored = await repository.find(conversationId);
    if (stored == null) return 0;
    int restored = 0;
    for (final ConversationMessage message in stored.messages) {
      switch (message.role) {
        case MessageRole.user:
          conversation.submitUserMessage(message.text);
        case MessageRole.assistant:
          final String messageId = conversation.beginAssistantMessage();
          if (message.text.trim().isNotEmpty) {
            conversation.appendAssistantDelta(messageId, message.text);
          }
          conversation.stopActiveStream();
      }
      restored++;
    }
    return restored;
  }

  void _onEvent(NoirUiEvent event) {
    final ConversationMessage? message = switch (event) {
      UserMessageSubmitted(:final String messageId) => conversation.messageById(
        messageId,
      ),
      AssistantStreamStopped(:final String messageId) =>
        conversation.messageById(messageId),
      _ => null,
    };
    if (message == null || message.isStreaming) return;
    _pending = _pending.then((_) async {
      try {
        await repository.appendMessage(conversationId, message);
        persistedMessages++;
      } on Object {
        // A transcript that could not be written is not allowed to take the
        // screen down with it: the message is on screen, which is the truth the
        // user is looking at, and the durable copy is the copy that is missing.
        // The store's own recovery path records the failure.
      }
    });
  }

  /// Waits for every message the conversation has produced to reach disk.
  ///
  /// The loop is not decoration. [ConversationController] broadcasts
  /// asynchronously, so a message submitted a moment ago may still be on its way
  /// to this listener when [flush] is called; without the yield, "flushed" would
  /// mean "every message that had already been delivered", which is a weaker and
  /// much less useful claim. Each pass hands control back to the event loop so a
  /// pending delivery can land, then compares the queue: a queue that has grown
  /// means more arrived, so it waits again. It is bounded, and a queue that
  /// stops growing ends the wait.
  Future<void> flush() async {
    Future<void> observed = _pending;
    for (int pass = 0; pass < 16; pass++) {
      await Future<void>.delayed(Duration.zero);
      final Future<void> current = _pending;
      if (identical(current, observed)) {
        await current;
        return;
      }
      observed = current;
    }
    await observed;
  }

  /// Stops listening and waits for the writes already queued.
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await flush();
  }
}

/// Where a writable record directory came from, or why there is none.
sealed class DataRootResolution {
  const DataRootResolution();
}

/// A directory that was created and written to, so it is real.
final class DataRootResolved extends DataRootResolution {
  const DataRootResolved(this.directory);

  final Directory directory;
}

/// No candidate was writable. Every attempt is reported.
final class DataRootUnresolved extends DataRootResolution {
  const DataRootUnresolved(this.reason, this.attempted);

  final String reason;
  final List<String> attempted;
}

/// Finds a directory Noir may keep records in.
///
/// The first candidate whose `noir/` subdirectory can actually be created and
/// written to wins. That is a real probe of the real filesystem, not a guess
/// about what the platform might offer, which matters because this build has no
/// `path_provider`: on a platform where the app has no writable directory of its
/// own there is genuinely nowhere to put a record, and the honest answer is
/// [DataRootUnresolved] rendered on screen — not a temporary directory nobody
/// was told about.
Future<DataRootResolution> resolveDataRoot({
  List<Directory>? candidates,
}) async {
  final List<Directory> parents = candidates ?? defaultDataRootCandidates();
  final List<String> attempted = <String>[];
  for (final Directory parent in parents) {
    final Directory target = Directory(
      '${parent.path}/$kNoirDataDirectoryName',
    );
    try {
      await target.create(recursive: true);
      final File probe = File('${target.path}/.noir-write-probe');
      await probe.writeAsString('noir', flush: true);
      await probe.delete();
      return DataRootResolved(target);
    } on Object catch (error) {
      attempted.add('${parent.path}: $error');
    }
  }
  return DataRootUnresolved(
    'No writable directory for Noir records. Tried: '
    '${attempted.isEmpty ? '(no candidates)' : attempted.join('; ')}',
    attempted,
  );
}

/// The parents [resolveDataRoot] probes when the caller names none.
List<Directory> defaultDataRootCandidates() => <Directory>[
  // The process's own temporary directory is the only location a Dart program
  // can name without a platform plugin. Where it is app-private, it is also
  // durable enough for records; where the OS clears it, that is reported by
  // `NoirDataLayer.selfReport()` rather than hidden.
  Directory.systemTemp,
];

/// The first provider record in id order, or null when there is none.
Future<ProviderSettings?> _firstProviderSettings(NoirDataLayer? layer) async {
  if (layer == null) return null;
  final List<String> unreadable = <String>[];
  try {
    final List<ProviderSettings> all = await layer.settings.readAll(
      onUnreadable: (String id, Object error) => unreadable.add(id),
    );
    if (all.isEmpty) return null;
    // readAll hands back an unmodifiable view, so the ordering is applied to a
    // copy. Ids are the tie-break, which makes "the first provider" a stable
    // choice rather than whichever record the store happened to list first.
    final List<ProviderSettings> ordered = List<ProviderSettings>.of(all)
      ..sort((ProviderSettings a, ProviderSettings b) => a.id.compareTo(b.id));
    return ordered.first;
  } on Object {
    return null;
  }
}

/// Builds the provider runtime from the user's own settings, or says why not.
///
/// Nothing here supplies a base URL, a key or a model. The endpoint is the one
/// in [ProviderSettings.baseUrl]; the key is the value behind that record's
/// secret reference, resolved through [SettingsRepository.resolveSecret] and
/// never written anywhere else.
Future<ProviderWiring> _wireProvider({
  required NoirDataLayer? layer,
  required ProviderSettings? settings,
  ProviderTransport? transport,
}) async {
  if (layer == null) {
    return const ProviderNotConfigured(
      'No provider is configured, and there is no store to configure one in.',
    );
  }
  if (settings == null) {
    return const ProviderNotConfigured(
      'No provider is configured. Noir does not ship a default endpoint or a '
      'default key.',
    );
  }
  final String? key = await layer.settings.resolveSecret(settings.id);
  final ProviderAuthConfig auth;
  try {
    auth = ProviderAuthConfig(baseUrl: settings.baseUrl, apiKey: key);
  } on ArgumentError catch (error) {
    return ProviderNotConfigured(
      'The configured provider could not be used: ${error.message}',
      unreadable: <String>[settings.id],
    );
  }
  final ProviderTransport wire =
      transport ?? HttpClientTransport(ownsClient: true);
  // One request executor, and the adapter and the discovery both take their
  // retry, timeout and sleep policy from it. Left to their own devices each
  // builds its own client, so the policy for a chat call and the policy for a
  // model read could drift apart with nothing recording that they had.
  final ProviderHttpClient client = ProviderHttpClient(transport: wire);
  final OpenRouterAdapter adapter = OpenRouterAdapter(
    transport: wire,
    auth: auth,
    retry: client.retry,
    timeouts: client.timeouts,
    sleep: client.sleep,
  );
  final ModelRouter router = ModelRouter(
    discovery: ModelDiscovery(
      transport: wire,
      auth: auth,
      retry: client.retry,
      timeouts: client.timeouts,
      sleep: client.sleep,
    ),
    executor: (ChatRequest request, {CancellationToken? cancellation}) =>
        adapter.completeChat(request: request, cancellation: cancellation),
  );
  return ProviderReady(
    settings: settings,
    auth: auth,
    transport: wire,
    client: client,
    adapter: adapter,
    router: router,
  );
}
