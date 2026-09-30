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
//   automations AutomationService over the durable automations collection, the
//             single PolicyEngine, and an executor that goes through
//             runAutomation — so a scheduled job is gated per run exactly like a
//             manual one — driven by the foreground tick this root owns, whose
//             only seam is runDueAutomations
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
import '../automations/automations.dart';
import '../data/data.dart';
import '../data/memory_store_bridge.dart';
import '../data/usage_store_bridge.dart';
import '../memory/memory_service.dart';
import '../platform/native_bridge.dart';
import '../prompts/prompt_service.dart';
import '../providers/adapters/mcp_transport_factory.dart';
import '../providers/adapters/openrouter_adapter.dart';
import '../providers/auth_config.dart';
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
import 'assistant_bridge.dart';
import 'automation_wiring.dart';
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

/// The one subsystem whose absence makes the app not-ready: without a record
/// store there is nowhere for a conversation, a memory, a usage figure or a
/// configured server to live, and a ready screen would be claiming something
/// untrue.
const String kRequiredStartupSubsystem = 'persistence';

/// The rest of the startup sequence, named so a test can assert the order.
const String kSafetyStartupSubsystem = 'safety-policy';
const String kMemoryStartupSubsystem = 'memory';
const String kPromptsStartupSubsystem = 'prompts';
const String kUsageStartupSubsystem = 'usage';
const String kProviderStartupSubsystem = 'provider';
const String kSafetyPipelineStartupSubsystem = 'safety-pipeline';
const String kMcpStartupSubsystem = 'mcp';
const String kAutomationsStartupSubsystem = 'automations';
const String kAssistantStartupSubsystem = 'assistant';
const String kTranscriptStartupSubsystem = 'transcript';

/// How long the app waits for a human to answer a confirmation before the
/// pipeline treats it as a refusal.
const Duration kDefaultConsentTimeout = Duration(seconds: 45);

/// --- startup -------------------------------------------------------------

/// One step of the deterministic startup sequence, in the order it happened.
///
/// Recorded rather than asserted in a comment: the app's readiness claim is only
/// as good as the record of what it actually brought up, and a test can compare
/// the order against a literal.
class StartupStep {
  const StartupStep({required this.subsystem, required this.ok, this.detail});

  /// Stable name, e.g. `persistence`, `provider`, `mcp`.
  final String subsystem;

  /// Whether the step produced a usable subsystem.
  final bool ok;

  /// What happened, in plain words. A reason, never a stack trace and never a
  /// secret.
  final String? detail;

  @override
  String toString() =>
      'StartupStep($subsystem, ${ok ? 'ok' : 'failed'}'
      '${detail == null ? '' : ': $detail'})';
}

/// A subsystem that did not come up, and whether that is fatal.
class StartupFault {
  const StartupFault({
    required this.subsystem,
    required this.reason,
    this.required = false,
  });

  final String subsystem;

  /// Why it did not come up.
  final String reason;

  /// Whether the app can honestly call itself ready with this outstanding.
  ///
  /// True for persistence only: without a record store there is nowhere to keep a
  /// conversation, a memory, a usage record or a configured server, and a screen
  /// that claims to be ready would be claiming something untrue. Everything else
  /// degrades into a stated absence the UI can render, which is what "no provider
  /// is configured" is.
  final bool required;

  @override
  String toString() => 'StartupFault($subsystem: $reason)';
}

/// What the graph managed to bring up.
sealed class StartupState {
  const StartupState(this.steps, this.faults);

  /// The sequence, in the order [NoirComposition.open] ran it.
  final List<StartupStep> steps;

  /// Everything that did not come up. Empty for [StartupReady].
  final List<StartupFault> faults;

  /// Whether the app may claim to be ready.
  ///
  /// False whenever a required subsystem failed, whatever else worked.
  bool get isReady => true;

  /// One line per fault, for a screen that has to say what is wrong.
  List<String> get faultLines => <String>[
    for (final StartupFault fault in faults)
      '${fault.subsystem}: ${fault.reason}',
  ];
}

/// Every step succeeded. The app is ready.
final class StartupReady extends StartupState {
  const StartupReady(List<StartupStep> steps) : super(steps, const []);
}

/// Some optional subsystem did not come up. The app is still ready, and says
/// exactly what is missing rather than pretending the capability exists.
final class StartupDegraded extends StartupState {
  const StartupDegraded(super.steps, super.faults);
}

/// A required subsystem failed. The app is *not* ready, and says which one.
final class StartupFailed extends StartupState {
  const StartupFailed(super.steps, super.faults);

  @override
  bool get isReady => false;
}

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

/// --- scheduled automations -------------------------------------------------

/// What the composition managed to build for `lib/automations`.
///
/// Sealed for the same reason as every other wiring here: a caller has to say
/// whether it holds a real service or a stated absence, so "the subsystem is
/// missing" can never be read as "the subsystem is empty and fine".
sealed class AutomationWiring {
  const AutomationWiring();
}

/// The scheduler is running over the durable automations collection.
///
/// [gate] is the one [PolicyEngine] in the process and [executor] is the graph's
/// own `runAutomation`, so a scheduled job is scored by the same rules as a
/// manual one and has to be confirmed by a human before it reaches the
/// platform. [service] holds those very instances, not copies of them.
final class AutomationsWired extends AutomationWiring {
  const AutomationsWired({
    required this.service,
    required this.repository,
    required this.gate,
    required this.executor,
  });

  /// The real scheduler. `service.gate` and `service.executor` are [gate] and
  /// [executor] below, so there is one gate and one executor in the graph.
  final AutomationService service;

  /// Where the jobs and their append-only history actually live.
  final DurableAutomationRepository repository;

  final PolicyEngineAutomationGate gate;
  final ConsentGatedAutomationExecutor executor;

  @override
  String toString() =>
      'AutomationsWired(${repository.collection}, durable: '
      '${repository.isDurable})';
}

/// There is nowhere to keep a job, so nothing is scheduled.
///
/// A job that could not be stored would be a job the user believes exists and
/// that never runs, so the app says the subsystem is unavailable rather than
/// holding a service over a store it does not have.
final class AutomationsUnavailable extends AutomationWiring {
  const AutomationsUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'AutomationsUnavailable($reason)';
}

/// What one scheduler pass did.
///
/// Sealed so "nothing was due" and "there was no scheduler" cannot be confused:
/// the first is a fact about the clock, the second is a missing capability, and
/// only one of them is something the user asked for.
sealed class AutomationDispatch {
  const AutomationDispatch();
}

/// Every job that was due was offered to the gate, and these are the runs it
/// produced — including the ones the gate denied or a user refused.
final class AutomationDispatched extends AutomationDispatch {
  AutomationDispatched(List<AutomationRun> runs)
    : runs = List<AutomationRun>.unmodifiable(runs);

  final List<AutomationRun> runs;

  /// Whether no job was due, as opposed to runs that were refused.
  bool get nothingWasDue => runs.isEmpty;

  @override
  String toString() => 'AutomationDispatched(${runs.length} run(s))';
}

/// Nothing ran because there is no scheduler to run with.
final class AutomationDispatchUnavailable extends AutomationDispatch {
  const AutomationDispatchUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'AutomationDispatchUnavailable($reason)';
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
    required this.assistant,
    required this.startupSteps,
    required List<StartupFault> startupFaults,
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
    required this.automations,
    required this.provider,
    required this.jobs,
    required this.journal,
    AutomationTicker? automationTicker,
  }) {
    // The tick is built here rather than passed in, because what it calls is
    // this graph's own dispatch seam and nothing else. `open` injects the ticker
    // so a test can drive the cadence by hand; the shipped app passes nothing
    // and gets the real thirty-second `Timer.periodic`.
    automationScheduler = AutomationScheduler(
      due: _offerDueJobs,
      clock: clock,
      ticker: automationTicker,
    );
    for (final StartupFault fault in startupFaults) {
      _faults[fault.subsystem] = fault;
    }
  }

  /// The injected time source. Every record this graph writes is stamped by it.
  final Clock clock;

  /// The conversation the Command Centre renders. Owned here, closed by
  /// [dispose].
  final ConversationController conversation;

  /// The provider-to-conversation bridge: the real request path, from the
  /// controller's history through a named prompt template, real memory
  /// retrieval and the gated MCP runner to the live adapter, the controller's
  /// deltas and real usage.
  final ConversationBridge assistant;

  /// What [open] actually did, in the order it did it. The readiness claim is
  /// computed from this, not asserted beside it. Complete once [open] returns.
  final List<StartupStep> startupSteps;

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

  /// The scheduled automation subsystem: a real [AutomationService] over durable
  /// records, or a stated reason there is none. Never a fabricated service and
  /// never silently absent.
  final AutomationWiring automations;

  final ProviderWiring provider;

  /// Scheduled jobs, when the data layer opened. Null otherwise.
  final JobRepository? jobs;

  /// Writes the conversation to the durable transcript. Null when the data layer
  /// did not open, because there is then nowhere for a transcript to live.
  final ConversationJournal? journal;

  /// The durable transcript, or null when there is no store to hold one.
  ConversationRepository? get conversations => journal?.repository;

  /// The tick that dispatches what is due, owned by this graph and disposed with
  /// it.
  ///
  /// Not armed by [open]: the graph is built before there is a user in front of
  /// it, and the tick's honest promise is "while the app is in front". The app
  /// entry arms it through [startAutomationScheduler] and disarms it through
  /// [stopAutomationScheduler].
  late final AutomationScheduler automationScheduler;

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
  StreamSubscription<AutomationPass>? _schedulerSubscription;
  int _safetySequence = 0;
  int _timelineSequence = 0;

  /// One fault per subsystem, upserted as the graph and the catalog learn more.
  final Map<String, StartupFault> _faults = <String, StartupFault>{};

  /// The live model catalog state. Rebuild when this changes.
  CatalogState get catalog => _catalog;

  /// Whether this graph may claim to be ready.
  ///
  /// False the moment a required subsystem failed. Read by the splash, so a
  /// startup that could not open its store says so instead of printing a
  /// reassuring line over a broken graph.
  bool get isReady => startup.isReady;

  /// What the graph brought up, in plain terms.
  ///
  /// [StartupReady] when every step worked, [StartupDegraded] when an optional
  /// subsystem is absent (no provider configured, memory unavailable) and
  /// [StartupFailed] when a required one is — which is persistence, because
  /// without a record store there is nowhere for anything the user gives Noir to
  /// live.
  StartupState get startup {
    final List<StartupStep> steps = List<StartupStep>.unmodifiable(
      startupSteps,
    );
    final List<StartupFault> faults = List<StartupFault>.unmodifiable(
      _faults.values,
    );
    if (faults.isEmpty) return StartupReady(steps);
    if (faults.any((StartupFault fault) => fault.required)) {
      return StartupFailed(steps, faults);
    }
    return StartupDegraded(steps, faults);
  }

  void _setFault(StartupFault fault) {
    if (_faults[fault.subsystem] == fault) return;
    _faults[fault.subsystem] = fault;
  }

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
  ///
  /// [automationTicker] is a test seam, alongside [providerTransport] and
  /// [mcpTransportFactory]: the shipped app passes nothing and the graph gets a
  /// real `Timer.periodic`, which [startAutomationScheduler] arms when the app
  /// comes up.
  static Future<NoirComposition> open({
    List<Directory>? dataRootCandidates,
    NativeBridge? bridge,
    DateTime Function()? now,
    Duration consentTimeout = kDefaultConsentTimeout,
    ProviderTransport? providerTransport,
    McpTransportFactory? mcpTransportFactory,
    AutomationTicker? automationTicker,
  }) async {
    final Clock clock = SystemClock();
    final DateTime Function() stamp = now ?? clock.now;

    // The record of what this startup did, in the order it happened. Every step
    // below appends to it, so [startup] is computed from what really ran rather
    // than from a promise about what should have. One fault per subsystem, keyed
    // by name so a later read of the same subsystem refines the earlier one
    // instead of stacking a second, vaguer complaint on top of it.
    final List<StartupStep> steps = <StartupStep>[];
    final Map<String, StartupFault> faults = <String, StartupFault>{};
    void step(String subsystem, {required bool ok, String? detail}) {
      steps.add(StartupStep(subsystem: subsystem, ok: ok, detail: detail));
      if (ok) return;
      faults[subsystem] = StartupFault(
        subsystem: subsystem,
        reason: detail ?? 'It could not be started.',
        required: subsystem == kRequiredStartupSubsystem,
      );
    }

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
    step(
      kSafetyStartupSubsystem,
      ok: true,
      detail: 'one PolicyEngine, one RiskClassifier, one platform bridge',
    );

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
    if (data is DataOpened) {
      step(
        kRequiredStartupSubsystem,
        ok: true,
        detail: 'records at ${data.root.path}',
      );
    } else {
      step(kRequiredStartupSubsystem, ok: false, detail: dataFailure);
    }

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
    step(
      kMemoryStartupSubsystem,
      ok: memory is MemoryOpened,
      detail: switch (memory) {
        MemoryOpened() => 'service over the durable memories collection',
        MemoryUnavailable(:final String reason) => reason,
      },
    );

    // --- prompts ---------------------------------------------------------
    // PromptService keeps its templates in process; it is constructed over the
    // injected clock and starts empty, which is the truth: this build ships no
    // template, so there is nothing to compose until a user creates one.
    final PromptService prompts = PromptService(clock: clock);
    step(
      kPromptsStartupSubsystem,
      ok: true,
      detail: 'no template ships with the app; a turn names the one it wants',
    );

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

    step(
      kUsageStartupSubsystem,
      ok: true,
      detail: usageStore == null
          ? 'counters in memory; no durable usage store'
          : 'durable usage store for provider ${providerSettings!.id}',
    );

    // --- provider runtime ------------------------------------------------
    final ProviderWiring provider = await _wireProvider(
      layer: layer,
      settings: providerSettings,
      transport: providerTransport,
    );
    step(
      kProviderStartupSubsystem,
      ok: provider is ProviderReady,
      detail: switch (provider) {
        ProviderReady(:final ProviderSettings settings) =>
          'endpoint ${settings.baseUrl} with the key from the secret store',
        ProviderNotConfigured(:final String reason) => reason,
      },
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
      // The executor is the app's only real tool-run boundary, so it is the
      // honest emitter for the tool lifecycle events the Command Centre
      // renders as "Using <tool>…" / "<tool> completed.".
      publish: taskRun.emit,
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

    step(
      kSafetyPipelineStartupSubsystem,
      ok: true,
      detail: 'planner, gate, undo window, executor, critic, recovery',
    );

    // --- MCP -------------------------------------------------------------
    // One PolicyEngine, again: McpComposition asks this instance for its
    // verdicts, so an MCP tool call and a gesture are gated by the same rules.
    final McpWiring mcp = layer == null
        ? McpWiringFailed(
            'MCP needs the server configuration store: $dataFailure',
          )
        : McpWired(
            McpComposition(
              servers: layer.mcpServers,
              policy: policy,
              // Production opens sockets here and nowhere else; a test injects a
              // scripted transport through the same seam.
              transportFactory: mcpTransportFactory,
            ),
          );
    step(
      kMcpStartupSubsystem,
      ok: mcp is McpWired,
      detail: switch (mcp) {
        McpWired() => 'persisted servers only, every call behind the gate',
        McpWiringFailed(:final String reason) => reason,
      },
    );

    // --- scheduled automations --------------------------------------------
    // The scheduler, the gate and the executor are three separate decisions and
    // all three are made here rather than defaulted anywhere:
    //
    //   * the repository is the durable one, so a job a user created is still
    //     there after a restart;
    //   * the gate is this graph's *own* PolicyEngine and RiskClassifier, the
    //     same pair the platform calls back into and the pipeline scores with, so
    //     a scheduled job gets no privilege a manual one would not get;
    //   * the executor is the graph's own `runAutomation`, so a due job is
    //     classified, published for confirmation and only then allowed to touch
    //     the platform. It is late-bound for the same reason [reportTurn] is: a
    //     job cannot be dispatched before [open] has returned, by which time the
    //     graph exists.
    late final NoirComposition composition;
    final PolicyEngineAutomationGate automationGate =
        PolicyEngineAutomationGate(
          policy: policy,
          riskClassifier: riskClassifier,
        );
    final ConsentGatedAutomationExecutor automationExecutor =
        ConsentGatedAutomationExecutor(
          run: (AutomationRequest request) =>
              composition.runAutomation(request),
        );
    final AutomationWiring automations;
    if (layer == null) {
      automations = AutomationsUnavailable(
        'A scheduled job needs somewhere durable to live, and there is none: '
        '$dataFailure',
      );
    } else {
      automations = AutomationsWired(
        repository: layer.automations,
        gate: automationGate,
        executor: automationExecutor,
        service: AutomationService(
          repository: layer.automations,
          gate: automationGate,
          executor: automationExecutor,
          clock: clock,
        ),
      );
    }
    step(
      kAutomationsStartupSubsystem,
      ok: automations is AutomationsWired,
      detail: switch (automations) {
        AutomationsWired(:final DurableAutomationRepository repository) =>
          'durable ${repository.collection} records, gated by the one '
              'PolicyEngine, run through the consent-gated pipeline',
        AutomationsUnavailable(:final String reason) => reason,
      },
    );

    // --- conversation and the assistant bridge ---------------------------
    // The bridge is built before the graph it belongs to, and reports through a
    // sink that reads the graph once it exists. A turn cannot start before [open]
    // returns, so the closure is never called with an unassigned graph.
    final ConversationController conversation = ConversationController();
    void reportTurn(AssistantTurnLog entry) => composition._logTurn(entry);
    final McpComposition? mcpComposition = mcp is McpWired
        ? mcp.composition
        : null;
    final ConversationBridge assistant = ConversationBridge(
      conversation: conversation,
      usage: usage,
      prompts: prompts,
      clock: clock,
      // The live adapter, when there is one. With no provider there is no stream
      // to open, so the bridge is built over a function that reports the same
      // typed absence the UI already renders rather than over a fake.
      streamChat: switch (provider) {
        ProviderReady(
          :final OpenRouterAdapter adapter,
          :final ModelRouter router,
        ) =>
          (ChatRequest request, {CancellationToken? cancellation}) {
            // A turn is only ever sent to a model the live catalog really
            // serves. An id the provider never listed is refused here rather
            // than put on the wire, and the router's own fallback may pick a
            // different served model instead.
            final String requested = request.model;
            if (!router.cachedModelIds.contains(requested)) {
              return Stream<ProviderStreamEvent>.error(
                ProviderException(
                  kind: ProviderErrorKind.malformed,
                  message: 'The provider never served the model "$requested".',
                ),
              );
            }
            return adapter.streamChat(
              request: request,
              cancellation: cancellation,
            );
          },
        _ => _noProviderStream,
      },
      memories: switch (memory) {
        MemoryOpened(:final MemoryService service) => service,
        MemoryUnavailable() => null,
      },
      // The only MCP path a turn can take: McpComposition.callTool, which is
      // where the allowlist, the classification, the policy verdict and the
      // user/biometric facts are enforced.
      toolRunner: mcpComposition == null
          ? null
          : (AssistantToolCall call) => mcpComposition.callTool(
              call.serverId,
              call.toolName,
              call.arguments,
              confirmation: call.confirmation,
            ),
      onLog: reportTurn,
      // A recorded usage figure is a state change the dashboard renders, so the
      // graph is told to republish. It is a notification, not a second accounting
      // path: the tracker did the counting.
      onUsage: (TokenUsage _, String __) => composition._publishUsage(),
    );
    step(
      kAssistantStartupSubsystem,
      ok: true,
      detail: provider is ProviderReady
          ? 'history, prompt, memory and MCP wired into the live adapter'
          : 'no provider to stream from; a turn reports that',
    );

    composition = NoirComposition._(
      startupFaults: faults.values.toList(growable: false),
      clock: clock,
      conversation: conversation,
      assistant: assistant,
      startupSteps: steps,
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
      automations: automations,
      provider: provider,
      jobs: layer?.jobs,
      journal: layer == null
          ? null
          : ConversationJournal(
              conversation: conversation,
              repository: layer.conversations,
            ),
      automationTicker: automationTicker,
    );
    composition._taskSubscription = taskRun.events.listen(
      composition._onTaskEvent,
    );
    // A tick that cannot do its work is reported on the safety log, so the
    // reason is in the graph's own record rather than only in a test's.
    composition._schedulerSubscription = composition.automationScheduler.passes
        .listen(composition._onSchedulerPass);
    // The transcript is restored before anything can append to it, so the
    // durable record and the controller end up holding the same conversation
    // rather than the record gaining a second thread.
    if (composition.journal != null) {
      try {
        final int restored = await composition.journal!.restoreLatest();
        step(
          kTranscriptStartupSubsystem,
          ok: true,
          detail: 'transcript replayed: $restored message(s)',
        );
      } on Object catch (error) {
        // A transcript that cannot be read leaves the conversation empty, which
        // is the honest state. The store's recovery path holds the reason.
        step(
          kTranscriptStartupSubsystem,
          ok: false,
          detail: 'the stored transcript could not be replayed: $error',
        );
      }
    } else {
      step(
        kTranscriptStartupSubsystem,
        ok: false,
        detail: 'no store, so no transcript is kept',
      );
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
    // A catalog that could not be read is a provider fault, not a separate
    // mystery: the endpoint and the key may both be fine and the read may still
    // fail, and the readiness line has to name what actually happened.
    if (next is CatalogUnavailable && provider is ProviderReady) {
      _setFault(
        StartupFault(
          subsystem: kProviderStartupSubsystem,
          reason: 'the model catalog could not be read: ${next.reason}',
        ),
      );
    }
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
      availableFallbackIds: fallbacks,
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
    // The model line the Command Centre shows is owed to the UI here: this is
    // the one place a model is genuinely selected, with the provider that
    // served it. Emitted before the reply starts so the row leads the tokens.
    // The daily spend is read asynchronously; the model line itself does not
    // wait on it, so a slow or unopened data layer cannot delay the first
    // token. `estimatedTokens` is the real spend so far today, not a guess.
    unawaited(
      _usedToday().then((int usedToday) {
        taskRun.emit(CostEstimateResolved(wired.settings.id, model, usedToday));
      }),
    );
    return _replyFor(wired, model, prompt);
  }

  Stream<String> _replyFor(ProviderReady wired, String model, String prompt) {
    // The Command Centre has already put the user's turn on the controller by the
    // time it asks for a reply; this makes sure of it rather than assuming it, so
    // a caller that skips that step still gets a request that matches what is on
    // screen.
    assistant.ensureUserTurn(prompt);
    // The real request path: the controller's history, a named template if the
    // caller named one, retrieved memory facts and the gated MCP runner, all
    // assembled by the bridge over the live adapter. The Command Centre still
    // owns the assistant turn, so the bridge only forwards deltas here.
    return assistant
        .deltas(AssistantTurnRequest(model: model, userText: prompt))
        .map((String delta) {
          // The A5 timeline still sees every token the provider really sent.
          taskRun.emit(StreamingTokenReceived(delta));
          return delta;
        })
        .transform(_assistantFailures);
  }

  /// Runs one assistant turn on this graph and returns what really happened.
  ///
  /// The headless sibling of [assistantReplies]: the same bridge, the same
  /// request assembly and the same typed failures, with this graph driving the
  /// assistant turn itself. A caller that names a template, supplies tool calls
  /// or wants the typed outcome uses this; the Command Centre uses the stream.
  Future<AssistantTurnOutcome> sendAssistantTurn(
    AssistantTurnRequest request,
  ) async {
    // The headless path still owes the UI the same contract the Command Centre
    // gets: every token the provider really sent is announced on the timeline.
    return assistant.send(
      request,
      onDelta: (String delta) => taskRun.emit(StreamingTokenReceived(delta)),
    );
  }

  /// Runs one user-requested action on the current screen, through the A6
  /// pipeline and therefore through the policy gate and a human confirmation.
  ///
  /// This is the only entry point to the pipeline, which is what keeps
  /// accessibility automation user-initiated: nothing reaches here except a
  /// call from the UI on the user's behalf — or a scheduled job, whose executor
  /// is this very method, so a job asks for the same consent a tap does.
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

  /// Compensates the action an undo window is still offering.
  ///
  /// This is the D15 control's whole implementation, and it is the *only* way
  /// out of an undo window. Four things are decided here, and none of them is
  /// decided by the UI:
  ///
  ///   * Which action. The press names a window id, and it is answered against
  ///     the live window alone. A window that has elapsed, or one that has
  ///     already been compensated, is refused, so the compensating run below
  ///     can start at most once per action.
  ///   * Whether there is anything to reverse. An action whose verb has no
  ///     inverse this build can dispatch is refused, which is the same fact the
  ///     window published as `reversible: false` and the reason the control is
  ///     not drawn for it.
  ///   * Whether it may happen. The compensation is run through [runAutomation],
  ///     so it is planned against the live screen, scored by the same
  ///     [RiskClassifier], vetted by the same [PolicyEngine] and confirmed by a
  ///     human through the same [ConsentGate] as any tap. The undo does not
  ///     reuse the original approval — that one was single-use and covered one
  ///     dispatch — and it never reaches a gesture without a new one.
  ///   * What to tell the user. The result is whatever the platform confirmed,
  ///     and the reason when it confirmed nothing. There is no path here that
  ///     returns a success the executor did not report.
  Future<UndoResult> undo(String actionId) async {
    if (_disposed) return const UndoRefused(kUndoNoLiveWindow);
    final LiveUndoWindow? live = undoWindow.live;
    if (live == null || live.actionId != actionId) {
      return const UndoRefused(kUndoNoLiveWindow);
    }
    final Compensation? compensation = live.action.compensation;
    if (compensation == null) {
      return const UndoRefused(kUndoNotCompensatable);
    }
    // The user's decision ends the window whatever the compensation goes on to
    // do. That is what makes it single-use: the next press finds no live window
    // to answer, so an action can be compensated exactly once.
    undoWindow.cancel();
    _logSafety(
      summary: 'Undo requested for ${live.action.description}',
      kind: SafetyEventKind.policy,
      outcome: SafetyEventOutcome.unknown,
    );
    final RuntimeResult? result = await runAutomation(
      AutomationRequest(
        action: compensation.action,
        input: compensation.input,
        targetNodeIndex: compensation.targetNodeIndex,
      ),
    );
    return _undoResult(actionId, result);
  }

  /// What a compensating run really amounted to.
  ///
  /// A null result is the run never reaching an outcome at all — the screen
  /// could not be read, or the pipeline threw — and is reported as such rather
  /// than as a success. A blocked run is reported with the reason the gate gave.
  UndoResult _undoResult(String actionId, RuntimeResult? result) {
    if (result == null) return const UndoRefused(kUndoCouldNotRun);
    final Object? outcome = result.result;
    if (result.blocked) {
      if (outcome is GateResult && outcome.allowed) {
        // The policy allowed the compensation and nobody answered the gate: the
        // gate's own bound produced this, and silence is a refusal.
        return const UndoRefused(kUndoNotApproved);
      }
      return UndoRefused(
        outcome is GateResult ? outcome.message : kUndoCouldNotRun,
      );
    }
    if (executionConfirmed(outcome)) return UndoPerformed(actionId);
    return UndoRefused(
      outcome is NativeGestureOutcome ? outcome.blockReason : kUndoUnconfirmed,
    );
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

  /// --- scheduled automations ----------------------------------------------

  /// Offers every due scheduled job to the gate and runs what it approves.
  ///
  /// One call of the tick: what this method does is unchanged, but it is no
  /// longer a method only a test calls. [automationScheduler] calls it on an
  /// interval while the app is in front, and every run it produces goes through
  /// the same policy gate and the same human confirmation a manual run needs, so
  /// a scheduled job gets no privilege the button in the Operations Sheet would
  /// not.
  ///
  /// [AutomationDispatchUnavailable] when the subsystem is unavailable, and
  /// never a fabricated empty result: "nothing was due" and "there is no
  /// scheduler" are different facts and a caller has to be able to tell them
  /// apart.
  Future<AutomationDispatch> runDueAutomations({int? limit}) async {
    if (_disposed) {
      return const AutomationDispatchUnavailable(
        'The graph is closed, so no job was offered to the gate.',
      );
    }
    return switch (automations) {
      AutomationsWired(:final AutomationService service) =>
        AutomationDispatched(await service.runDueJobs(limit: limit)),
      AutomationsUnavailable(:final String reason) =>
        AutomationDispatchUnavailable(reason),
    };
  }

  /// Arms the tick that dispatches due automations.
  ///
  /// The app-facing half of the scheduler, and the whole of the foreground
  /// promise this build can make. There is no platform alarm here — no
  /// `AlarmManager`, no `WorkManager`, no background service — so the only thing
  /// that can ask "what is due?" is a running app. The caller is `NoirApp`,
  /// which arms the tick when the app comes up and disarms it when the app
  /// leaves, so a job whose time came while the app was closed runs when the app
  /// next opens, and never while the process is dead. Nothing about that is
  /// implied beyond it: the guarantee is "while the app is in front", not
  /// "at the instant it was due".
  void startAutomationScheduler() => automationScheduler.start();

  /// Disarms the tick and cancels its timer. A pass already in flight is not
  /// cancelled, because it may be waiting on a human and withdrawing a consent
  /// gate is not a decision.
  void stopAutomationScheduler() => automationScheduler.stop();

  /// One tick, answered in the scheduler's own typed vocabulary.
  ///
  /// Late-bound to [runDueAutomations] on purpose, and there is no second
  /// dispatch path: the tick goes through the same gate, the same consent and
  /// the same durable records a manual run and a direct caller use. The mapping
  /// is total, so no answer can be lost — an unavailable subsystem stays
  /// [AutomationPassUnavailable] rather than being flattened into a pass that
  /// found nothing due.
  Future<AutomationPass> _offerDueJobs() async {
    final AutomationDispatch dispatch = await runDueAutomations();
    return switch (dispatch) {
      AutomationDispatched(:final List<AutomationRun> runs) =>
        AutomationPassCompleted(at: clock.now(), runCount: runs.length),
      AutomationDispatchUnavailable(:final String reason) =>
        AutomationPassUnavailable(at: clock.now(), reason: reason),
    };
  }

  /// Reports a tick that could not do its work.
  ///
  /// A pass that ran is already accounted for: the runs themselves are durable
  /// records, and a run the gate denied or a user refused says so on the job the
  /// Skill Manager lists. A pass that *failed*, or that had no scheduler to run
  /// with, is a different kind of absence and is recorded here with the real
  /// reason rather than left looking like a night when nothing happened.
  ///
  /// Stated plainly, because the alternative is a comment that implies more than
  /// this build can do: the Safety Center is constructed without this log — see
  /// `SafetyCenterScreen` at lib/ui/command_centre_screen.dart:418 — so today it
  /// is a record the graph keeps and [safetyEvents] publishes, not a line the
  /// user reads on a screen. What the user can see is the job's own `lastError`
  /// in the Skill Manager, and, when there is no store at all, the startup fault
  /// on the splash.
  void _onSchedulerPass(AutomationPass pass) {
    switch (pass) {
      case AutomationPassFailed(:final String reason):
        _logSafety(
          summary: 'The scheduled-automation tick failed',
          kind: SafetyEventKind.policy,
          outcome: SafetyEventOutcome.blocked,
          detail: reason,
        );
      case AutomationPassUnavailable(:final String reason):
        _logSafety(
          summary: 'No scheduled automation could be offered',
          kind: SafetyEventKind.policy,
          outcome: SafetyEventOutcome.blocked,
          detail: reason,
        );
      case AutomationPassCompleted():
      case AutomationPassSkipped():
        // A pass that ran is in the job's own record, and a tick that was
        // skipped because another was still going is not a fault at all.
        break;
    }
  }

  /// The scheduled jobs the durable repository holds, oldest id first.
  ///
  /// Empty when the subsystem is unavailable or the records cannot be read: the
  /// store's recovery path holds the reason, and a listing that invented a
  /// placeholder job would be worse than one that admits it has nothing.
  Future<List<Automation>> scheduledAutomations() async {
    final AutomationWiring wired = automations;
    if (wired is! AutomationsWired) return const <Automation>[];
    try {
      return await wired.service.list();
    } on Object {
      return const <Automation>[];
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

  /// Registered automations, read from the durable records this graph holds.
  ///
  /// Two collections, because the app has two: the `lib/automations` jobs, which
  /// the scheduler in [automations] dispatches behind the gate, and the legacy
  /// scheduled jobs. Both are things a user created and named, and both have a
  /// lifecycle (unknown until it has run, active while scheduled, needs review
  /// when its last run failed, disabled when switched off). The mapping is
  /// mechanical and documented on [ScheduledJobSkillState] and
  /// [AutomationSkillState], and it never invents a run: a job with no run says
  /// so.
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
          for (final Automation automation in await scheduledAutomations())
            SkillRecord(
              id: automation.id,
              name: automation.name,
              state: automation.toSkillState(),
              lastUsedAt: automation.lastRunAt?.toUtc(),
              detail:
                  automation.lastError ??
                  '${automation.schedule.kind.name} schedule, '
                      '${automation.runCount} run(s), revision '
                      '${automation.revision}',
            ),
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

  /// Forwards one of the bridge's log lines into the safety log.
  ///
  /// The bridge redacts before it hands a line over, so what lands here is what
  /// the Safety Center can show: what a turn did, never what the user typed, what
  /// a memory held or what a server sent.
  void _logTurn(AssistantTurnLog entry) {
    if (_disposed) return;
    _logSafety(
      summary: entry.summary,
      kind: entry.untrusted
          ? SafetyEventKind.sanitization
          : SafetyEventKind.dispatch,
      outcome: SafetyEventOutcome.unknown,
      detail: entry.detail,
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
    // The tick goes first, before anything it can reach starts closing: after
    // this a callback the platform timer kept does nothing, and no pass can
    // start against a graph that is on its way out. A pass already in flight is
    // not cancelled — it may be waiting on a human, and withdrawing a consent
    // gate is not a decision.
    automationScheduler.stop();
    gate.revokeAll();
    undoWindow.cancel();
    // A turn in flight is holding a provider stream and may still be writing
    // usage, so it is drained first: closing a store underneath a running turn
    // is how a real usage record goes missing.
    try {
      await assistant.settle();
    } on Object {
      // Reported through the safety log; teardown continues so the rest of the
      // graph still shuts down cleanly.
    }
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
    await _schedulerSubscription?.cancel();
    _schedulerSubscription = null;
    // Last, so nothing is still listening to the tick as it closes: the pass
    // stream is closed without awaiting its done future, for the same reason the
    // broadcast controllers below are.
    await automationScheduler.dispose();
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
  const AssistantUnavailable(this.reason, {this.cause});

  final String reason;

  /// The bridge's typed failure, when this unavailability came from a turn. Null
  /// for a graph-level absence (no provider configured), where no turn was ever
  /// attempted.
  final AssistantTurnFailure? cause;

  @override
  String toString() => reason;
}

/// Maps a bridge failure onto the reason the Command Centre renders.
///
/// The widget shows [AssistantUnavailable.toString], which is the reason and
/// nothing else, so the wording on screen is unchanged; the typed
/// [AssistantTurnFailure] travels beside it for anything that wants the kind.
final StreamTransformer<String, String> _assistantFailures =
    StreamTransformer<String, String>.fromHandlers(
      handleError:
          (Object error, StackTrace stackTrace, EventSink<String> sink) {
            if (error is AssistantTurnFailure) {
              sink.addError(
                AssistantUnavailable(error.reason, cause: error),
                stackTrace,
              );
              return;
            }
            sink.addError(error, stackTrace);
          },
    );

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

/// A scheduled automation as the skill registry's vocabulary.
///
/// The same mechanical mapping as [ScheduledJobSkillState], so a job the
/// scheduler owns and a legacy scheduled job read alike in the Skill Manager:
///
///   * switched off                              -> [SkillState.disabled]
///   * enabled, nothing run yet                  -> [SkillState.unknown]
///   * ran clean, still scheduled                -> [SkillState.active]
///   * finished a one-shot, ran clean             -> [SkillState.validated]
///   * last run left an error behind             -> [SkillState.needsReview]
///
/// A claimed job reads as active: the claim is an in-flight run, and hiding that
/// would make a job that is running right now look idle.
extension AutomationSkillState on Automation {
  SkillState toSkillState() {
    if (!enabled) return SkillState.disabled;
    if (lastError != null) return SkillState.needsReview;
    if (nextRunAt == null) {
      return runCount == 0 ? SkillState.unknown : SkillState.validated;
    }
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

/// The streaming call a bridge uses when no provider is configured.
///
/// It fails immediately with a typed absence rather than producing a stream of
/// nothing: a turn that cannot be sent has to say so, and a silently empty stream
/// is indistinguishable from a model that replied with silence.
Stream<ProviderStreamEvent> _noProviderStream(
  ChatRequest request, {
  CancellationToken? cancellation,
}) => Stream<ProviderStreamEvent>.error(
  const AssistantTurnFailure(
    kind: AssistantTurnFailureKind.notConfigured,
    reason: 'No provider is configured.',
  ),
);

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
  if (key == null || key.isEmpty) {
    // The record exists but carries no credential. Noir will not invent one and
    // will not silently run the endpoint unauthenticated behind the user's back.
    return ProviderNotConfigured(
      'The provider "${settings.displayName}" has no credential saved. Noir '
      'does not ship a default key.',
      unreadable: <String>[settings.id],
    );
  }
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
