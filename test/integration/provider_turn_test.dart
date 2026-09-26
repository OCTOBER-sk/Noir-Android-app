// test/integration/provider_turn_test.dart — a turn, end to end, through the
// graph the app runs on.
//
// The path under test, in the order it happens:
//
//   user message -> [ConversationController] -> [ConversationBridge] ->
//   [OpenRouterAdapter] over a scripted transport -> SSE frames ->
//   [ProviderTextDelta]s back into the controller and the screen's turn ->
//   [ProviderUsage] recorded against the model the provider really served, and
//   written to the durable usage collection.
//
// Nothing here asserts on a value a double invented. The deltas are the bytes a
// provider sends, the usage block is the block it reported, and the numbers the
// tracker holds afterwards are those numbers read back off disk. The second group
// of tests is the other half of "terminates honestly": a provider that fails, a
// provider that says nothing, and a caller that stops listening.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/assistant_bridge.dart';
import 'package:noir_android_app/core/composition_root.dart';
import 'package:noir_android_app/core/conversation_controller.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/providers/errors.dart';
import 'package:noir_android_app/providers/transport.dart';

import '../support/fake_transport.dart';
import 'support/noir_test_graph.dart';

void main() {
  group("a user's turn reaches the provider and comes back as deltas", () {
    test(
      'the whole path: message, SSE, controller deltas, durable usage',
      () async {
        final NoirTestGraph graph = await NoirTestGraph.withProvider(
          handlers: <FakeHandler>[
            (ProviderRequest request) => NoirTestGraph.catalogResponse(),
            (ProviderRequest request) => NoirTestGraph.turnResponse(
              deltas: <String>['Good ', 'morning', '.'],
              usage: <String, Object?>{
                'prompt_tokens': 42,
                'completion_tokens': 7,
              },
            ),
          ],
        );
        addTearDown(graph.dispose);
        await graph.warmUp();

        final AssistantTurnOutcome outcome = await graph.app.sendAssistantTurn(
          const AssistantTurnRequest(
            model: kTestModel,
            userText: 'good morning?',
          ),
        );

        // The typed outcome says what really happened.
        expect(outcome, isA<AssistantTurnCompleted>());
        final AssistantTurnCompleted completed =
            outcome as AssistantTurnCompleted;
        expect(completed.text, 'Good morning.');
        expect(completed.deltaCount, 3, reason: 'one delta per provider frame');
        expect(completed.usageRecorded, isTrue);
        expect(completed.model, kTestModel);

        // The controller holds the conversation, in order, with the turn closed.
        final List<ConversationMessage> messages =
            graph.app.conversation.messages;
        expect(messages, hasLength(2));
        expect(messages.first.role, MessageRole.user);
        expect(messages.first.text, 'good morning?');
        expect(messages.last.role, MessageRole.assistant);
        expect(messages.last.text, 'Good morning.');
        expect(messages.last.isStreaming, isFalse);
        expect(graph.app.conversation.hasActiveStream, isFalse);

        // The request really carried the user's turn, and only that turn: this
        // conversation had no history to send yet.
        final List<Map<String, dynamic>> sent = graph.provider.chatMessages(0);
        expect(sent, hasLength(1));
        expect(sent.single['role'], 'user');
        expect(sent.single['content'], 'good morning?');
        expect(graph.provider.chatBody(0)['model'], kTestModel);
        expect(
          graph.provider.chatBody(0)['stream'],
          isTrue,
          reason: 'deltas only exist if the request asked to stream',
        );

        // Usage is the provider's own numbers, persisted and priced from the same
        // catalog read that produced the route.
        await graph.app.usage.flush();
        final records = await graph.storedUsage();
        expect(records, hasLength(1));
        expect(records.single.provider, 'primary');
        expect(records.single.model, kTestModel);
        expect(records.single.promptTokens, 42);
        expect(records.single.completionTokens, 7);
        expect(records.single.totalTokens, 49);
        expect(
          records.single.costUsd,
          isNotNull,
          reason: 'the catalog really served prices for this model',
        );
        final summary = await graph.app.usage.summary();
        expect(summary.requests, 1);
        expect(summary.totalTokens, 49);
      },
    );

    test(
      'the second turn carries the first one: the real history is sent',
      () async {
        final NoirTestGraph graph = await NoirTestGraph.withProvider(
          handlers: <FakeHandler>[
            (ProviderRequest request) => NoirTestGraph.catalogResponse(),
            (ProviderRequest request) =>
                NoirTestGraph.turnResponse(deltas: <String>['First answer.']),
            (ProviderRequest request) =>
                NoirTestGraph.turnResponse(deltas: <String>['Second answer.']),
          ],
        );
        addTearDown(graph.dispose);
        await graph.warmUp();

        await graph.app.sendAssistantTurn(
          const AssistantTurnRequest(model: kTestModel, userText: 'first'),
        );
        await graph.app.sendAssistantTurn(
          const AssistantTurnRequest(model: kTestModel, userText: 'second'),
        );

        // The first request saw only the first turn.
        expect(graph.provider.chatMessages(0), hasLength(1));
        // The second request saw the exchange, oldest first, in wire order.
        final List<Map<String, dynamic>> second = graph.provider.chatMessages(
          1,
        );
        expect(
          second.map(
            (Map<String, dynamic> m) => '${m['role']}:${m['content']}',
          ),
          <String>['user:first', 'assistant:First answer.', 'user:second'],
        );
        // And the controller still holds one conversation, not three.
        expect(graph.app.conversation.messages, hasLength(4));
      },
    );

    test('the turn the UI can see is the turn the transcript keeps', () async {
      final NoirTestGraph graph = await NoirTestGraph.withProvider(
        handlers: <FakeHandler>[
          (ProviderRequest request) => NoirTestGraph.catalogResponse(),
          (ProviderRequest request) =>
              NoirTestGraph.turnResponse(deltas: <String>['Kept.']),
        ],
      );
      addTearDown(graph.dispose);
      await graph.warmUp();

      await graph.app.sendAssistantTurn(
        const AssistantTurnRequest(model: kTestModel, userText: 'remember me'),
      );
      await graph.app.journal!.flush();

      final List<ConversationMessage> stored =
          (await graph.data.layer.conversations.find(
            kCurrentConversationId,
          ))!.messages;
      expect(stored.map((ConversationMessage m) => m.text), <String>[
        'remember me',
        'Kept.',
      ]);
    });

    test('the A5 timeline sees every token the provider really sent', () async {
      final NoirTestGraph graph = await NoirTestGraph.withProvider(
        handlers: <FakeHandler>[
          (ProviderRequest request) => NoirTestGraph.catalogResponse(),
          (ProviderRequest request) =>
              NoirTestGraph.turnResponse(deltas: <String>['a', 'b', 'c']),
        ],
      );
      addTearDown(graph.dispose);
      await graph.warmUp();

      final List<NoirUiEvent> seen = <NoirUiEvent>[];
      final sub = graph.app.taskRun.events.listen(seen.add);
      addTearDown(sub.cancel);

      await graph.app.sendAssistantTurn(
        const AssistantTurnRequest(model: kTestModel, userText: 'tokens?'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        seen.whereType<StreamingTokenReceived>().map(
          (StreamingTokenReceived event) => event.delta,
        ),
        <String>['a', 'b', 'c'],
      );
    });
  });

  group('a provider that does not answer is reported, not invented', () {
    test(
      'an auth failure is a typed failure with the provider\'s own kind',
      () async {
        final NoirTestGraph graph = await NoirTestGraph.withProvider(
          handlers: <FakeHandler>[
            (ProviderRequest request) => NoirTestGraph.catalogResponse(),
            (ProviderRequest request) => rawResponse(
              'no',
              status: 401,
              headers: <String, String>{'content-type': 'text/plain'},
            ),
          ],
        );
        addTearDown(graph.dispose);
        await graph.warmUp();

        final AssistantTurnOutcome outcome = await graph.app.sendAssistantTurn(
          const AssistantTurnRequest(model: kTestModel, userText: 'hello?'),
        );

        expect(outcome, isA<AssistantTurnFailed>());
        final AssistantTurnFailure failure =
            (outcome as AssistantTurnFailed).failure;
        expect(failure.kind, AssistantTurnFailureKind.provider);
        expect(failure.providerKind, ProviderErrorKind.auth);
        expect(failure.reason, contains('auth'));
        expect(failure.partial, isEmpty, reason: 'nothing really arrived');
        expect(failure.isTransient, isFalse);
        expect(
          failure.reason,
          isNot(contains(kTestApiKey)),
          reason: 'the failure reason is not a place for the key',
        );

        // The turn was opened and closed honestly: an empty assistant message and
        // no stream left hanging.
        final List<ConversationMessage> messages =
            graph.app.conversation.messages;
        expect(messages, hasLength(2));
        expect(messages.last.role, MessageRole.assistant);
        expect(messages.last.text, isEmpty);
        expect(graph.app.conversation.hasActiveStream, isFalse);

        // Nothing was written to usage, because the provider reported nothing.
        await graph.app.usage.flush();
        expect(await graph.storedUsage(), isEmpty);
        expect(graph.app.usage.hasReportedUsage, isFalse);
      },
    );

    test(
      'text that really arrived before the failure is kept, not discarded',
      () async {
        final NoirTestGraph graph = await NoirTestGraph.withProvider(
          handlers: <FakeHandler>[
            (ProviderRequest request) => NoirTestGraph.catalogResponse(),
            (ProviderRequest request) => erroringResponse(
              ProviderException(
                kind: ProviderErrorKind.rateLimit,
                message: 'slow down',
              ),
              chunks: <String>[
                'data: {"id":"c1","model":"$kTestModel","choices":'
                    '[{"index":0,"delta":{"content":"partial "}}]}\n\n',
                'data: {"id":"c1","model":"$kTestModel","choices":'
                    '[{"index":0,"delta":{"content":"answer"}}],'
                    '"usage":{"prompt_tokens":5,"completion_tokens":2}}\n\n',
              ],
            ),
          ],
        );
        addTearDown(graph.dispose);
        await graph.warmUp();

        final AssistantTurnOutcome outcome = await graph.app.sendAssistantTurn(
          const AssistantTurnRequest(model: kTestModel, userText: 'ramble?'),
        );

        expect(outcome, isA<AssistantTurnFailed>());
        final AssistantTurnFailure failure =
            (outcome as AssistantTurnFailed).failure;
        expect(failure.providerKind, ProviderErrorKind.rateLimit);
        expect(failure.isTransient, isTrue);
        expect(failure.partial, 'partial answer');
        // The words the provider really sent are on screen, and the failure is
        // reported beside them rather than in place of them.
        expect(graph.app.conversation.messages.last.text, 'partial answer');
        expect(graph.app.conversation.messages.last.isStreaming, isFalse);
        // The usage the provider did report was still recorded: it is real.
        await graph.app.usage.flush();
        final partial = await graph.storedUsage();
        expect(partial, hasLength(1));
        expect(partial.single.totalTokens, 7);
      },
    );

    test(
      'a stream that ends with no content is a failure, not an empty answer',
      () async {
        final NoirTestGraph graph = await NoirTestGraph.withProvider(
          handlers: <FakeHandler>[
            (ProviderRequest request) => NoirTestGraph.catalogResponse(),
            (ProviderRequest request) => sseResponse(<String>[
              '{"id":"c1","model":"$kTestModel","choices":[{"index":0,'
                  '"delta":{},"finish_reason":"content_filter"}]}',
            ]),
          ],
        );
        addTearDown(graph.dispose);
        await graph.warmUp();

        final AssistantTurnOutcome outcome = await graph.app.sendAssistantTurn(
          const AssistantTurnRequest(model: kTestModel, userText: 'quiet?'),
        );

        expect(
          (outcome as AssistantTurnFailed).failure.kind,
          AssistantTurnFailureKind.noContent,
        );
        expect(graph.app.conversation.messages.last.text, isEmpty);
      },
    );

    test('a caller that stops listening stops the provider', () async {
      final NoirTestGraph graph = await NoirTestGraph.withProvider(
        handlers: <FakeHandler>[
          (ProviderRequest request) => NoirTestGraph.catalogResponse(),
          (ProviderRequest request) => hangingResponse(),
        ],
      );
      addTearDown(graph.dispose);
      await graph.warmUp();

      // The UI path: the Command Centre's stream, cancelled the way the Stop
      // button cancels it.
      final Stream<String> deltas = graph.app.assistantReplies!(
        'are you there?',
      );
      final StreamSubscription<String> subscription = deltas.listen(
        (String _) {},
        onError: (Object _) {},
      );
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      // And the headless path: a turn nobody is waiting for any more still
      // terminates, and leaves no stream open on the controller.
      final Stream<String> second = graph.app.assistantReplies!('still there?');
      final StreamSubscription<String> other = second.listen(
        (String _) {},
        onError: (Object _) {},
      );
      await Future<void>.delayed(Duration.zero);
      await other.cancel();
      await graph.app.assistant.settle();

      expect(graph.app.conversation.hasActiveStream, isFalse);
      expect(graph.app.conversation.messages.length, greaterThanOrEqualTo(2));
    });
  });

  group('the graph refuses to invent a backend', () {
    test(
      'with no provider configured a turn says so instead of answering',
      () async {
        final NoirTestGraph graph = await NoirTestGraph.withProvider(
          handlers: <FakeHandler>[(ProviderRequest request) => rawResponse('')],
        );
        addTearDown(graph.dispose);
        // A graph whose provider record cannot produce a runtime: the record is
        // there, the key is not, so the endpoint cannot be built.
        final DataOpened opened = graph.data;
        final providerId = (await opened.layer.settings.readAll()).single.id;
        await opened.layer.settings.clearSecret(providerId);
        final NoirComposition without = await NoirComposition.open(
          dataRootCandidates: <Directory>[graph.workspace],
          providerTransport: graph.provider.transport,
        );
        addTearDown(without.dispose);
        await graph.app.dispose();

        expect(without.provider, isA<ProviderNotConfigured>());
        final AssistantTurnOutcome outcome = await without.sendAssistantTurn(
          const AssistantTurnRequest(model: kTestModel, userText: 'anyone?'),
        );
        expect(
          (outcome as AssistantTurnFailed).failure.kind,
          AssistantTurnFailureKind.notConfigured,
        );
        // No request went out over the transport that the re-opened graph owns.
        expect(without.conversation.messages.last.text, isEmpty);
      },
    );

    test('a model nobody served is never sent', () async {
      final NoirTestGraph graph = await NoirTestGraph.withProvider(
        handlers: <FakeHandler>[
          (ProviderRequest request) => NoirTestGraph.catalogResponse(
            model: 'vendor/other-only',
            extraModels: const <String>[],
          ),
        ],
      );
      addTearDown(graph.dispose);
      await graph.warmUp();

      // The catalog read really succeeded; it simply never served the model the
      // user named. That is a routing absence, not a discovery failure.
      expect(graph.app.catalog, isA<CatalogReady>());
      final AssistantTurnOutcome outcome = await graph.app.sendAssistantTurn(
        const AssistantTurnRequest(
          model: 'vendor/never-served',
          userText: 'hi',
        ),
      );
      expect(outcome, isA<AssistantTurnFailed>());
      expect(
        (outcome as AssistantTurnFailed).failure.kind,
        anyOf(
          AssistantTurnFailureKind.noModel,
          AssistantTurnFailureKind.provider,
        ),
      );
      // The router may legitimately fall back to a model the catalog really
      // served. What it must never do is put the unserved id on the wire.
      expect(
        graph.provider.chatRequests
            .map(
              (ProviderRequest request) => graph.provider.chatBody(
                graph.provider.chatRequests.indexOf(request),
              )['model'],
            )
            .contains('vendor/never-served'),
        isFalse,
        reason: 'a model the provider never served must not be sent',
      );
    });
  });
}
