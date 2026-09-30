// test/composition_root_test.dart — the composition root actually builds the
// graph, and it builds it out of real things.
//
// The failure this file exists to prevent is not a crash. It is the one
// described in test/composition_reachability_test.dart: a module that is
// implemented, covered and unreachable from the app. Reachability is necessary
// but not sufficient — a file can be imported by lib/main.dart and still
// contribute nothing, and a "composition root" can construct objects and then
// never use them.
//
// So these tests assert four things that a plausible-looking fake would fail:
//
//   1. The graph constructs, and every member is the real type.
//   2. The data layer is real files: a fact written through MemoryService is
//      still there after the composition is disposed and rebuilt over the same
//      directory.
//   3. Nothing is invented. With no provider configured there is no endpoint,
//      no key, no model, no price and no cost plan, and each of those absences
//      is a typed state rather than a plausible value.
//   4. The safety gate is still in front of the screen, in front of MCP, and
//      in front of the gesture: an automation that nobody confirmed never
//      reaches the platform channel.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/agent/cost_estimator.dart';
import 'package:noir_android_app/automations/automations.dart';
import 'package:noir_android_app/core/agent_wiring.dart';
import 'package:noir_android_app/core/automation_wiring.dart';
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/core/conversation_controller.dart';
import 'package:noir_android_app/core/mcp_composition.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/data/data.dart' hide MemoryEntry, UsageRecord;
import 'package:noir_android_app/data/memory_repository.dart' as data_memory;
import 'package:noir_android_app/data/usage_repository.dart' as data_usage;
import 'package:noir_android_app/memory/memory_service.dart';
import 'package:noir_android_app/platform/accessibility_status.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/prompts/prompt_service.dart';
import 'package:noir_android_app/providers/transport.dart';
import 'package:noir_android_app/providers/usage_tracker.dart' hide UsageRecord;
import 'package:noir_android_app/safety/policy_engine.dart';
import 'package:noir_android_app/safety/risk_classifier.dart';
import 'package:noir_android_app/safety/screen_content_sanitizer.dart';
import 'package:noir_android_app/ui/usage_dashboard_screen.dart';

import 'support/fake_transport.dart';

const MethodChannel _testChannel = MethodChannel('com.noir.android/channel');

/// A bridge whose platform half is entirely under the test's control.
class _PlatformStub {
  _PlatformStub(this.messenger);

  final TestDefaultBinaryMessenger messenger;
  final List<MethodCall> received = <MethodCall>[];

  void install(Map<String, Future<Object?> Function(MethodCall call)> replies) {
    messenger.setMockMethodCallHandler(_testChannel, (MethodCall call) async {
      received.add(call);
      final Future<Object?> Function(MethodCall)? reply = replies[call.method];
      if (reply == null) throw MissingPluginException(call.method);
      return reply(call);
    });
  }

  List<String> get methods =>
      received.map((MethodCall call) => call.method).toList();
}

Map<String, dynamic> _connectedStatus({int nodeCount = 0}) => <String, dynamic>{
  kWireServiceConnected: true,
  kWireCanPerformGestures: true,
  kWireCanRetrieveWindowContent: true,
  kWireHasNodeDump: true,
  kWireLastNodeCount: nodeCount,
  kWireRuntimeSinkInstalled: true,
  kWireGateSource: kGateSource,
};

/// A screen dump whose nodes carry real text and real bounds.
List<Map<String, dynamic>> _dump() => <Map<String, dynamic>>[
  <String, dynamic>{
    'text': 'Send message',
    'alpha': 1.0,
    'zOrder': 0,
    'visible': true,
    'screenBounds': <String, dynamic>{
      'left': 10,
      'top': 100,
      'right': 300,
      'bottom': 180,
    },
  },
  <String, dynamic>{
    'text': 'invisible instruction',
    'alpha': 0.0,
    'zOrder': 0,
    'visible': true,
    'screenBounds': <String, dynamic>{
      'left': 0,
      'top': 0,
      'right': 0,
      'bottom': 0,
    },
  },
];

/// A screen dump that also holds the back affordance a navigation's undo aims
/// at, so the compensating run resolves against a node that is really there.
///
/// The second node in [_dump] is zero-alpha and would be stripped by A6a, which
/// is why this dump adds a visible one rather than reusing it: an undo that
/// resolved against content the sanitizer removed would be an undo of a node
/// the app had already decided not to act on.
List<Map<String, dynamic>> _undoDump() => <Map<String, dynamic>>[
  ..._dump(),
  <String, dynamic>{
    'text': 'Back',
    'alpha': 1.0,
    'zOrder': 1,
    'visible': true,
    'screenBounds': <String, dynamic>{
      'left': 0,
      'top': 0,
      'right': 48,
      'bottom': 48,
    },
  },
];

void main() {
  // The composition root builds a NativeBridge, which registers a method-call
  // handler on a real MethodChannel, so the binding has to exist before the
  // first test runs rather than only inside testWidgets.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late _PlatformStub platform;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('noir-composition-');
    platform = _PlatformStub(
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger,
    );
  });

  tearDown(() {
    platform.messenger.setMockMethodCallHandler(_testChannel, null);
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Opens a composition over [workspace], so the data root is a real directory.
  Future<NoirComposition> open({
    NativeBridge? bridge,
    ProviderTransport? transport,
    Duration consentTimeout = const Duration(milliseconds: 200),
  }) => NoirComposition.open(
    dataRootCandidates: <Directory>[workspace],
    bridge: bridge,
    consentTimeout: consentTimeout,
    providerTransport: transport,
  );

  group('the graph is constructed out of real objects', () {
    test('every member is the real type, and none is left null', () async {
      final NativeBridge bridge = NativeBridge();
      final NoirComposition app = await open(bridge: bridge);
      addTearDown(app.dispose);

      // The pre-existing entry path, unchanged and real.
      expect(app.conversation, isA<ConversationController>());
      expect(app.usage, isA<UsageTracker>());

      // The safety stack.
      expect(app.policy, isA<PolicyEngine>());
      expect(app.riskClassifier, isA<RiskClassifier>());
      expect(app.bridge, same(bridge));
      expect(app.gate, isA<ConsentGate>());
      expect(app.undoWindow, isA<CountdownUndoWindow>());
      expect(app.planner, isA<ScreenPlanner>());
      expect(app.executor, isA<NativeGestureExecutor>());
      expect(app.critic, isA<ReflectionCritic>());
      expect(app.recovery, isA<SanitizingRecoveryEngine>());
      expect(app.pipeline, isA<AgentRuntimePipeline>());

      // The A5 task machine and the UI contract it publishes on.
      expect(app.taskRun, isA<NoirTaskRun>());
      expect(app.taskRun.controller, isA<TaskController>());
      expect(app.taskRun.state, TaskState.idle);

      // Persistence, memory, prompts, MCP.
      expect(app.prompts, isA<PromptService>());
      expect(app.data, isA<DataOpened>());
      expect(app.memory, isA<MemoryOpened>());
      expect(app.mcp, isA<McpWired>());
      expect(app.jobs, isA<JobRepository>());

      // The scheduled automations, and the collaborators behind them: the one
      // PolicyEngine in the process, and the graph's own runAutomation as the
      // executor, so a job is gated exactly like a tap.
      final AutomationsWired automations = app.automations as AutomationsWired;
      expect(automations.service, isA<AutomationService>());
      expect(automations.gate, isA<PolicyEngineAutomationGate>());
      expect(automations.executor, isA<ConsentGatedAutomationExecutor>());
      expect(automations.service.gate, same(automations.gate));
      expect(automations.service.executor, same(automations.executor));
      expect(
        automations.repository,
        same((app.data as DataOpened).layer.automations),
      );
      expect(automations.repository.isDurable, isTrue);

      // The deterministic A6a sanitizer is the one bound into the pipeline,
      // not a default that happens to be the same shape.
      expect(app.sanitize, same(Sanitizer.sanitize));
    });

    test('the data layer really is files, and says where they are', () async {
      final NoirComposition app = await open();
      addTearDown(app.dispose);

      final DataOpened opened = app.data as DataOpened;
      expect(opened.root.existsSync(), isTrue);
      expect(opened.layer.store.isDurable, isTrue);
      expect(opened.layer.selfReport()['backend'], contains('JsonFile'));
      expect(opened.layer.selfReport()['root'], opened.root.path);
    });

    test(
      'an unwritable data root is an explicit state, not a fake one',
      () async {
        // A path that cannot be created: a file, not a directory.
        final File blocker = File('${workspace.path}/blocker')
          ..writeAsStringSync('not a directory');
        final NoirComposition app = await NoirComposition.open(
          dataRootCandidates: <Directory>[Directory(blocker.path)],
        );
        addTearDown(app.dispose);

        final DataUnavailable unavailable = app.data as DataUnavailable;
        expect(unavailable.reason, isNotEmpty);
        expect(unavailable.attempted, isNotEmpty);
        // Nothing durable-backed pretends to work.
        expect(app.memory, isA<MemoryUnavailable>());
        expect(app.mcp, isA<McpWiringFailed>());
        expect(app.jobs, isNull);
        expect(app.automations, isA<AutomationsUnavailable>());
      },
    );
  });

  group('the data layer is real persistence, not a cache', () {
    test('a fact written through MemoryService survives a rebuild', () async {
      final NoirComposition first = await open();
      final MemoryOpened memory = first.memory as MemoryOpened;
      memory.service.add(
        'the deploy box is in Frankfurt',
        key: 'deploy.box',
        tags: <String>['infra'],
      );
      await memory.store.flush();
      await first.dispose();

      // A brand new graph over the same directory: nothing carried over in
      // memory, so the row can only have come off disk.
      final NoirComposition second = await open();
      addTearDown(second.dispose);
      final MemoryOpened reopened = second.memory as MemoryOpened;

      final List<MemoryEntry> live = reopened.service.list();
      expect(live, hasLength(1));
      expect(live.single.content, 'the deploy box is in Frankfurt');
      expect(live.single.key, 'deploy.box');
      expect(live.single.provenance.origin, MemoryOrigin.userExplicit);
      expect(live.single.revision, 1);

      // And the durable record carries the provenance, so a fact the assistant
      // proposed never becomes indistinguishable from one the user asked for.
      final DataOpened data = second.data as DataOpened;
      final data_memory.MemoryEntry? record = await data.layer.memories.find(
        live.single.id,
      );
      expect(record, isNotNull);
      expect(record!.provenanceOrigin, MemoryOrigin.userExplicit.name);
      expect(record.value, 'the deploy box is in Frankfurt');
    });

    test('the conversation is written to the durable transcript', () async {
      final NoirComposition first = await open();
      first.conversation.submitUserMessage('first run question');
      final String assistantId = first.conversation.beginAssistantMessage();
      first.conversation.appendAssistantDelta(assistantId, 'first run answer');
      first.conversation.stopActiveStream();
      await first.journal!.flush();
      expect(first.journal!.persistedMessages, 2);
      await first.dispose();

      // A brand new graph over the same directory replays the transcript into
      // its own fresh controller.
      final NoirComposition second = await open();
      addTearDown(second.dispose);
      final List<ConversationMessage> replayed = second.conversation.messages;
      expect(replayed, hasLength(2));
      expect(replayed.first.role, MessageRole.user);
      expect(replayed.first.text, 'first run question');
      expect(replayed.last.role, MessageRole.assistant);
      expect(replayed.last.text, 'first run answer');
      // And the durable record is the transcript of record, holding the
      // messages exactly as they were produced.
      final ConversationSnapshot? stored = await (second.data as DataOpened)
          .layer
          .conversations
          .find(kCurrentConversationId);
      expect(stored, isNotNull);
      expect(stored!.messages, hasLength(2));
      expect(stored.messages.first.text, 'first run question');
      expect(stored.messages.last.text, 'first run answer');
    });

    test(
      'a record written without provenance is not shown as a memory fact',
      () async {
        final NoirComposition app = await open();
        final DataOpened data = app.data as DataOpened;
        // Written straight through the repository, with no lib/memory origin.
        await data.layer.memories.upsert(
          data.layer.memories.newMemory(
            id: 'hand-written',
            key: 'notes',
            value: 'written by another subsystem',
          ),
        );
        addTearDown(app.dispose);

        final MemoryOpened memory = app.memory as MemoryOpened;
        await memory.store.reload();
        expect(memory.service.list(), isEmpty);
        // It is still readable through the repository it was written to.
        expect(await data.layer.memories.find('hand-written'), isNotNull);
      },
    );
  });

  group('nothing is invented when a dependency is missing', () {
    test(
      'no provider configured means no endpoint, key, model or price',
      () async {
        final NoirComposition app = await open();
        addTearDown(app.dispose);

        final ProviderNotConfigured absent =
            app.provider as ProviderNotConfigured;
        expect(absent.reason, contains('No provider is configured'));
        // No default endpoint anywhere in the graph.
        expect(app.catalog, isA<CatalogIdle>());

        // warmUp must not paper over it with a cached or built-in catalog.
        await app.warmUp();
        final CatalogUnavailable catalog = app.catalog as CatalogUnavailable;
        expect(catalog.reason, absent.reason);

        // No budget to report against, because there is nothing to spend on.
        expect(await app.costPlan(), isNull);
        expect(app.usage.pricing.hasPricingFor('anything'), isFalse);
        expect(app.usage.hasReportedUsage, isFalse);
      },
    );

    test(
      'the assistant reports the real reason instead of inventing a reply',
      () async {
        final NoirComposition app = await open();
        addTearDown(app.dispose);

        final replies = app.assistantReplies!;
        await expectLater(
          replies('hello'),
          emitsThrough(
            emitsError(
              isA<AssistantUnavailable>().having(
                (AssistantUnavailable error) => error.reason,
                'reason',
                contains('No provider is configured'),
              ),
            ),
          ),
        );
        // Nothing was written to the conversation, because nothing was generated.
        expect(app.conversation.messages, isEmpty);
      },
    );

    test('the usage dashboard starts empty rather than zeroed', () async {
      final NoirComposition app = await open();
      addTearDown(app.dispose);

      final UsageSnapshot snapshot = await app
          .usageStates()
          .firstWhere((UsageState state) => state is UsageAvailable)
          .then((UsageState state) => (state as UsageAvailable).snapshot);
      expect(snapshot.tokensUsed, isNull);
      expect(snapshot.costUsd, isNull);
      expect(snapshot.activeModel, isNull);
      expect(snapshot.capturedAt, isNotNull);
    });

    test('the prompt service ships no template', () async {
      final NoirComposition app = await open();
      addTearDown(app.dispose);
      expect(app.prompts.names(), isEmpty);
      expect(
        () => app.prompts.compose('anything'),
        throwsA(isA<PromptValidationException>()),
      );
    });
  });

  group('a configured provider drives the real runtime', () {
    /// Writes the provider record and its secret the way the app's own data
    /// layer requires, then rebuilds the graph over the same directory.
    Future<NoirComposition> withProvider(
      FakeTransport transport, {
      String baseUrl = 'https://gateway.invalid/v1',
    }) async {
      {
        final NoirComposition setup = await open();
        final DataOpened data = setup.data as DataOpened;
        await data.layer.settings.upsert(
          ProviderSettings(
            id: 'primary',
            displayName: 'Primary gateway',
            baseUrl: baseUrl,
            defaultModel: 'vendor/alpha',
            fallbackModels: const <String>['vendor/beta', 'vendor/gone'],
            funded: false,
            rpmCap: 20,
            dailyCap: 50,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );
        await data.layer.settings.setSecret('primary', 'sk-test-key-value');
        await setup.dispose();
      }
      return open(transport: transport);
    }

    test('the catalog read binds real prices and a real route', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest request) => jsonResponse(<String, dynamic>{
          'data': <Object?>[
            <String, dynamic>{
              'id': 'vendor/alpha',
              'context_length': 8192,
              'pricing': <String, dynamic>{
                'prompt': '0.000001',
                'completion': '0.000002',
              },
            },
            <String, dynamic>{'id': 'vendor/beta'},
            // No id: the parser must reject it rather than invent one.
            <String, dynamic>{'name': 'nameless'},
          ],
        }),
      ]);
      final NoirComposition app = await withProvider(transport);
      addTearDown(app.dispose);

      final ProviderReady ready = app.provider as ProviderReady;
      expect(ready.settings.id, 'primary');
      expect(ready.auth.baseUrl, 'https://gateway.invalid/v1');
      expect(ready.auth.hasCredentials, isTrue);
      // The key is only ever inside the auth config, and it describes itself
      // without it.
      expect(ready.auth.describe(), isNot(contains('sk-test-key-value')));
      expect(ready.router.executor, isNotNull);

      await app.warmUp();
      final CatalogReady catalog = app.catalog as CatalogReady;
      expect(catalog.catalog.rejectedEntries, 1);
      expect(
        catalog.route.model?.id,
        'vendor/alpha',
        reason: 'the default model survived in the live catalog',
      );
      // Prices came from the same read that produced the catalog.
      expect(app.usage.pricing.hasPricingFor('vendor/alpha'), isTrue);
    });

    test('the cost plan uses the A9 caps and only live model ids', () async {
      final FakeTransport transport = FakeTransport(<FakeHandler>[
        (ProviderRequest request) => jsonResponse(<String, dynamic>{
          'data': <Object?>[
            <String, dynamic>{'id': 'vendor/alpha'},
            <String, dynamic>{'id': 'vendor/beta'},
          ],
        }),
      ]);
      final NoirComposition app = await withProvider(transport);
      addTearDown(app.dispose);
      await app.warmUp();

      final CostPlan plan = (await app.costPlan())!;
      expect(plan.funded, isFalse);
      expect(plan.dailyCap, 50, reason: 'the user\'s own record says 50');
      expect(plan.rpmCap, OPENROUTER_FREE_RPM_CAP);
      expect(plan.usedToday, 0);
      expect(plan.remainingToday, 50);
      // 'vendor/gone' is not in the catalog, so it is not offered as a
      // fallback. The chain is made of ids the provider really served.
      expect(plan.fallbackModelIds, <String>['vendor/beta']);
      for (final String id in plan.fallbackModelIds) {
        expect(id, isNot(contains('free-model')));
      }
    });

    test(
      'a provider that cannot be read never leaves a model selected',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest request) => rawResponse(
            'nope',
            status: 401,
            headers: <String, String>{'content-type': 'text/plain'},
          ),
        ]);
        final NoirComposition app = await withProvider(transport);
        addTearDown(app.dispose);

        await app.warmUp();
        final CatalogUnavailable catalog = app.catalog as CatalogUnavailable;
        expect(catalog.reason, contains('auth'));
        expect(app.usage.pricing.hasPricingFor('vendor/alpha'), isFalse);

        // And the assistant refuses, with the provider's own reason.
        await expectLater(
          app.assistantReplies!('hi'),
          emitsError(isA<AssistantUnavailable>()),
        );
      },
    );

    test(
      'a streamed reply records the provider-reported usage durably',
      () async {
        final FakeTransport transport = FakeTransport(<FakeHandler>[
          (ProviderRequest request) => jsonResponse(<String, dynamic>{
            'data': <Object?>[
              <String, dynamic>{
                'id': 'vendor/alpha',
                'pricing': <String, dynamic>{
                  'prompt': '0.000001',
                  'completion': '0.000002',
                },
              },
            ],
          }),
          (ProviderRequest request) => sseResponse(<String>[
            '{"id":"c1","model":"vendor/alpha",'
                '"choices":[{"index":0,"delta":{"content":"Hel"}}]}',
            '{"id":"c1","model":"vendor/alpha",'
                '"choices":[{"index":0,"delta":{"content":"lo"}}],'
                '"usage":{"prompt_tokens":11,"completion_tokens":2}}',
          ]),
        ]);
        final NoirComposition app = await withProvider(transport);
        addTearDown(app.dispose);
        await app.warmUp();

        final List<String> deltas = await app.assistantReplies!('hi').toList();
        expect(deltas.join(''), 'Hello');
        await app.usage.flush();

        // Tokens came from a real provider usage block and were persisted.
        final summary = await app.usage.summary();
        expect(summary.totalTokens, 13);
        expect(summary.requests, 1);
        final DataOpened data = app.data as DataOpened;
        final List<data_usage.UsageRecord> stored = await data.layer.usage
            .readAll();
        expect(stored, hasLength(1));
        expect(stored.single.provider, 'primary');
        expect(stored.single.model, 'vendor/alpha');
        expect(stored.single.totalTokens, 13);
        expect(stored.single.costUsd, isNotNull);
      },
    );
  });

  group('the policy gate is still in front of the screen', () {
    late NativeBridge bridge;

    setUp(() {
      platform.install(<String, Future<Object?> Function(MethodCall call)>{
        kMethodServiceStatus: (MethodCall call) async =>
            _connectedStatus(nodeCount: _dump().length),
        kMethodGetNodes: (MethodCall call) async => <String, dynamic>{
          'nodes': _dump(),
          'nodeCount': _dump().length,
        },
        kMethodPolicyGate: (MethodCall call) async => <String, dynamic>{
          'allowed': true,
          'message': 'ok',
        },
        kMethodDispatchGesture: (MethodCall call) async => <String, dynamic>{
          'executed': true,
        },
      });
      bridge = NativeBridge();
    });

    tearDown(() async {
      await bridge.dispose();
    });

    test('a run nobody confirmed never reaches the platform', () async {
      final NoirComposition app = await open(
        bridge: bridge,
        // Short enough that the unanswered request expires inside the test.
        consentTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(app.dispose);

      final List<NoirUiEvent> seen = <NoirUiEvent>[];
      final StreamSubscription<NoirUiEvent> events = app.taskRun.events.listen(
        seen.add,
      );
      addTearDown(events.cancel);

      final RuntimeResult? result = await app.runAutomation(
        const AutomationRequest(action: 'tap', input: 'Send message'),
      );

      expect(result, isNotNull);
      expect(result!.blocked, isTrue);
      expect(seen.whereType<ConfirmationRequired>(), isNotEmpty);
      expect(
        platform.methods,
        isNot(contains(kMethodDispatchGesture)),
        reason: 'no confirmation, no gesture',
      );
      expect(app.taskRun.state, TaskState.failed);
    });

    test('an explicit refusal is a refusal, and spends no approval', () async {
      final NoirComposition app = await open(bridge: bridge);
      addTearDown(app.dispose);

      final Future<RuntimeResult?> run = app.runAutomation(
        const AutomationRequest(action: 'tap', input: 'Send message'),
      );
      final PendingConfirmation confirmation = await app.confirmations.first;
      expect(confirmation.action, 'tap');
      expect(confirmation.riskLevel, greaterThanOrEqualTo(0));
      confirmation.answer(false);

      final RuntimeResult? result = await run;
      expect(result!.blocked, isTrue);
      expect(platform.methods, isNot(contains(kMethodDispatchGesture)));
    });

    test(
      'a confirmed run dispatches exactly once, through the Kotlin gate',
      () async {
        final NoirComposition app = await open(bridge: bridge);
        addTearDown(app.dispose);

        // 'read_screen' classifies as STANDARD, so the policy asks for a
        // confirmation but not for a biometric, and this build can satisfy it.
        final Future<RuntimeResult?> run = app.runAutomation(
          const AutomationRequest(action: 'read_screen', input: 'Send message'),
        );
        final PendingConfirmation confirmation = await app.confirmations.first;
        expect(confirmation.action, 'read_screen');
        expect(confirmation.riskLevel, 1);
        expect(confirmation.needsBiometric, isFalse);
        expect(confirmation.canBeApproved, isTrue);
        confirmation.answer(true);

        final RuntimeResult? result = await run;
        expect(result!.blocked, isFalse);

        final List<MethodCall> dispatches = platform.received
            .where((MethodCall call) => call.method == kMethodDispatchGesture)
            .toList();
        expect(dispatches, hasLength(1));
        // The platform is still the one that re-verifies: the request carries the
        // proposal and the gate request id, and the Dart engine is what answered.
        final Map<Object?, Object?> payload =
            dispatches.single.arguments as Map<Object?, Object?>;
        expect(payload['confirmed'], isTrue);
        expect(
          (payload['proposal'] as Map<Object?, Object?>)['action'],
          'read_screen',
        );
        expect(payload['gateRequestId'], isNotNull);

        // The approval was single-use.
        expect(app.gate.approvedActions, isEmpty);
      },
    );

    test(
      'MCP tool calls are refused without a server and without consent',
      () async {
        final NoirComposition app = await open(bridge: bridge);
        addTearDown(app.dispose);

        final McpComposition mcp = (app.mcp as McpWired).composition;
        expect(await mcp.configuredServers(), isEmpty);

        final McpToolOutcome outcome = await mcp.callTool(
          'anything',
          'delete_note',
          <String, dynamic>{},
        );
        expect(outcome, isA<McpToolRefused>());
        expect((outcome as McpToolRefused).code, kMcpServerNotConfigured);
      },
    );

    test(
      'the gate the platform calls back into is the pipeline\'s engine',
      () async {
        final NoirComposition app = await open(bridge: bridge);
        addTearDown(app.dispose);

        // The bridge answers `policyGate` with the engine the app is running, not
        // with a second copy of the rules, so the two halves cannot disagree.
        final Map<String, dynamic> request = <String, dynamic>{
          'proposal': <String, dynamic>{'action': 'delete_everything'},
        };

        // Without a confirmation the platform's call is refused, even though the
        // risk classifier scored it HIGH_RISK on the Dart side.
        final NativeGateVerdict unconfirmed = await app.bridge.evaluateGate(
          request,
        );
        expect(unconfirmed.allowed, isFalse);
        expect(unconfirmed.riskLevel, 3);
        expect(unconfirmed.needsBiometric, isTrue);
        expect(unconfirmed.message, kCodeConfirmationRequired);

        // With one, the same engine allows it and flags the biometric.
        final NativeGateVerdict verdict = await app.bridge.evaluateGate(
          <String, dynamic>{...request, 'confirmed': true},
        );
        expect(verdict.allowed, isTrue);
        expect(verdict.riskLevel, 3);
        expect(verdict.needsBiometric, isTrue);
        // The flag was set on the app's own engine, by that engine's own rules.
        expect(app.policy.requireBiometric, isTrue);
      },
    );

    test(
      'an action the policy wants a biometric for cannot be approved here',
      () async {
        final NoirComposition app = await open(bridge: bridge);
        addTearDown(app.dispose);

        // 'delete' classifies as HIGH_RISK, so the PolicyEngine asks for a
        // biometric. This build cannot perform one.
        final Future<RuntimeResult?> run = app.runAutomation(
          const AutomationRequest(action: 'delete', input: 'Send message'),
        );
        final PendingConfirmation confirmation = await app.confirmations.first;
        expect(confirmation.riskLevel, 3);
        expect(confirmation.needsBiometric, isTrue);
        expect(confirmation.canBeApproved, isFalse);
        confirmation.answer(true);

        final RuntimeResult? result = await run;
        expect(result!.blocked, isTrue);
        expect(app.gate.approvedActions, isEmpty);
        expect(platform.methods, isNot(contains(kMethodDispatchGesture)));
      },
    );
  });

  group('the undo window is a real control, not a picture of one', () {
    // `UndoToast` used to render a permanently disabled button captioned
    // "Disabled: undo is not wired to an action executor yet." The runtime
    // could cancel a window all along, but nothing could reach the executor
    // that ran the action, and `CountdownUndoWindow` published its event from
    // the window's *ending*, so the toast appeared after the countdown it
    // belonged to was over and its `reversible` flag described the ending
    // rather than the action.
    //
    // What is asserted here, against the real bridge, the real PolicyEngine and
    // the real ConsentGate:
    //
    //   * a navigation the user confirmed is announced while its window is still
    //     open, as reversible, and pressing Undo dispatches one compensating
    //     gesture — once, and only after a fresh confirmation;
    //   * an action this build cannot reverse is announced as irreversible, so
    //     the control is not offered and the press is refused with a reason;
    //   * nothing about the compensation is decided here: the screen has to
    //     change for the compensation to have anything to aim at.
    late NativeBridge bridge;

    setUp(() {
      platform.install(<String, Future<Object?> Function(MethodCall call)>{
        kMethodServiceStatus: (MethodCall call) async =>
            _connectedStatus(nodeCount: _undoDump().length),
        kMethodGetNodes: (MethodCall call) async => <String, dynamic>{
          'nodes': _undoDump(),
          'nodeCount': _undoDump().length,
        },
        kMethodPolicyGate: (MethodCall call) async => <String, dynamic>{
          'allowed': true,
          'message': 'ok',
        },
        kMethodDispatchGesture: (MethodCall call) async => <String, dynamic>{
          'executed': true,
        },
      });
      bridge = NativeBridge();
    });

    tearDown(() async {
      await bridge.dispose();
    });

    /// Every gesture the platform was actually asked to dispatch.
    List<MethodCall> dispatches() => platform.received
        .where((MethodCall call) => call.method == kMethodDispatchGesture)
        .toList();

    /// Records what the graph announces.
    ///
    /// It deliberately does NOT end the countdown. The window now publishes
    /// when it opens and stays live until the user presses Undo or the clock
    /// runs out, so a helper that cancelled on the announcement would destroy
    /// the very record the press is supposed to act on. Tests that never press
    /// call [settle] to close the window instead.
    List<ActionCompletedWithUndoWindow> announcements(NoirComposition app) {
      final List<ActionCompletedWithUndoWindow> announced =
          <ActionCompletedWithUndoWindow>[];
      final StreamSubscription<NoirUiEvent> subscription = app.taskRun.events
          .listen((NoirUiEvent event) {
            if (event is! ActionCompletedWithUndoWindow) return;
            announced.add(event);
          });
      addTearDown(subscription.cancel);
      return announced;
    }

    /// Starts [request] and answers its gate, without waiting for the run.
    ///
    /// The run does not finish until its undo window ends, so a helper that
    /// awaited it would deadlock against the press the test has not made yet.
    /// The returned future is the run itself; [settle] or a press ends it.
    Future<Future<RuntimeResult?>> launch(
      NoirComposition app,
      AutomationRequest request,
    ) async {
      final Future<RuntimeResult?> run = app.runAutomation(request);
      final PendingConfirmation confirmation = await app.confirmations.first;
      expect(confirmation.action, request.action);
      confirmation.answer(true);
      return run;
    }

    test('a confirmed navigation can be undone once, through the gate', () async {
      final NoirComposition app = await open(bridge: bridge);
      addTearDown(app.dispose);
      final List<ActionCompletedWithUndoWindow> announced = announcements(app);

      final Future<RuntimeResult?> run = await launch(
        app,
        const AutomationRequest(action: 'navigate', input: 'Send message'),
      );
      while (announced.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(dispatches(), hasLength(1));

      expect(
        announced,
        hasLength(1),
        reason: 'the completed action announced its window once',
      );
      final ActionCompletedWithUndoWindow window = announced.single;
      expect(
        window.reversible,
        isTrue,
        reason: 'a navigation has an inverse this build can dispatch',
      );
      expect(window.actionDescription, contains('navigate'));
      expect(window.actionId, isNotEmpty);

      // The press itself. It is a new gated action, so the gate is asked again
      // rather than the original approval being reused: that approval was
      // single-use and covered one dispatch.
      final Future<UndoResult> undo = app.undo(window.actionId);
      final PendingConfirmation compensating = await app.confirmations.first;
      expect(compensating.action, 'navigate_back');
      compensating.answer(true);

      expect(await undo, isA<UndoPerformed>());
      expect((await run)!.blocked, isFalse);
      final List<MethodCall> sent = dispatches();
      expect(sent, hasLength(2), reason: 'the action and its compensation');
      final Map<Object?, Object?> payload =
          sent.last.arguments as Map<Object?, Object?>;
      expect(
        (payload['proposal'] as Map<Object?, Object?>)['action'],
        'navigate_back',
      );
      expect(payload['confirmed'], isTrue);
      expect(app.gate.approvedActions, isEmpty);

      // The compensation announced its own window, and it is not reversible:
      // this build names no inverse for going back, so there is no undo of the
      // undo to offer.
      expect(announced, hasLength(2));
      expect(announced.last.reversible, isFalse);
    });

    test('a second press on the same action does nothing', () async {
      final NoirComposition app = await open(bridge: bridge);
      addTearDown(app.dispose);
      final List<ActionCompletedWithUndoWindow> announced = announcements(app);

      final Future<RuntimeResult?> run = await launch(
        app,
        const AutomationRequest(action: 'navigate', input: 'Send message'),
      );
      while (announced.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final ActionCompletedWithUndoWindow window = announced.single;
      final Future<UndoResult> undo = app.undo(window.actionId);
      (await app.confirmations.first).answer(true);
      expect(await undo, isA<UndoPerformed>());
      await run;

      final UndoResult again = await app.undo(window.actionId);

      expect(again, isA<UndoRefused>());
      expect((again as UndoRefused).reason, kUndoNoLiveWindow);
      expect(
        dispatches(),
        hasLength(2),
        reason: 'the spent window holds nothing to compensate',
      );
    });

    test('an action with no inverse is offered no undo at all', () async {
      final NoirComposition app = await open(bridge: bridge);
      addTearDown(app.dispose);
      final List<ActionCompletedWithUndoWindow> announced = announcements(app);

      // `read_screen` is STANDARD, so it does get a window — a tap cannot be
      // untapped, so that window is announced as irreversible.
      // The press happens while the window is still live, which is the point:
      // a window this build cannot reverse is refused for that reason, not
      // because its clock happened to run out first.
      final Future<RuntimeResult?> run = await launch(
        app,
        const AutomationRequest(action: 'read_screen', input: 'Send message'),
      );
      while (announced.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(announced.single.reversible, isFalse);

      final UndoResult refused = await app.undo(announced.single.actionId);
      expect((await run)!.blocked, isFalse);

      expect(refused, isA<UndoRefused>());
      expect((refused as UndoRefused).reason, kUndoNotCompensatable);
      expect(dispatches(), hasLength(1), reason: 'nothing was compensated');
    });

    test('an undo nobody confirms dispatches nothing', () async {
      final NoirComposition app = await open(
        bridge: bridge,
        // Short enough that the unanswered request expires inside the test.
        consentTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(app.dispose);
      final List<ActionCompletedWithUndoWindow> announced = announcements(app);

      final Future<RuntimeResult?> run = await launch(
        app,
        const AutomationRequest(action: 'navigate', input: 'Send message'),
      );
      while (announced.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // The press, and no answer: the compensating run waits out the gate's own
      // bound and is refused, because silence is not consent.
      final Future<UndoResult> refused = app.undo(
        announced.single.actionId,
      );
      expect(await refused, isA<UndoRefused>());
      await run;

      expect((await refused as UndoRefused).reason, kUndoNotApproved);
      expect(dispatches(), hasLength(1));
    });

    test('a compensation with nothing to aim at reports the real reason', () async {
      // The same graph over a dump with no back affordance: the compensating
      // run plans against the real screen, finds no node it can aim at, and the
      // executor's own block code is what the user is told.
      platform.install(<String, Future<Object?> Function(MethodCall call)>{
        kMethodServiceStatus: (MethodCall call) async =>
            _connectedStatus(nodeCount: _dump().length),
        kMethodGetNodes: (MethodCall call) async => <String, dynamic>{
          'nodes': _dump(),
          'nodeCount': _dump().length,
        },
        kMethodPolicyGate: (MethodCall call) async => <String, dynamic>{
          'allowed': true,
          'message': 'ok',
        },
        kMethodDispatchGesture: (MethodCall call) async => <String, dynamic>{
          'executed': true,
        },
      });
      final NoirComposition app = await open(bridge: bridge);
      addTearDown(app.dispose);
      final List<ActionCompletedWithUndoWindow> announced = announcements(app);

      final Future<RuntimeResult?> run = await launch(
        app,
        const AutomationRequest(action: 'navigate', input: 'Send message'),
      );
      while (announced.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final Future<UndoResult> undo = app.undo(announced.single.actionId);
      (await app.confirmations.first).answer(true);

      final UndoResult refused = await undo;
      expect((await run)!.blocked, isFalse);
      expect(refused, isA<UndoRefused>());
      expect((refused as UndoRefused).reason, kCodeMalformedGestureTarget);
    });
  });

  group('nothing in the new code is a stub', () {
    test(
      'no placeholder markers in the composition root or its wiring',
      () async {
        final List<String> sources = <String>[
          'lib/core/composition_root.dart',
          'lib/core/agent_wiring.dart',
          'lib/core/automation_wiring.dart',
          'lib/data/automation_repository.dart',
          'lib/data/memory_store_bridge.dart',
          'lib/data/usage_store_bridge.dart',
          'lib/ui/operations_sheet.dart',
          'lib/main.dart',
        ];
        for (final String path in sources) {
          final String source = File(path).readAsStringSync();
          for (final String marker in <String>[
            'TODO',
            'FIXME',
            'UnimplementedError',
            'UnsupportedError',
            'throw Unimp',
          ]) {
            expect(
              source.contains(marker),
              isFalse,
              reason: '$path contains "$marker"',
            );
          }
        }
      },
    );
  });
}
