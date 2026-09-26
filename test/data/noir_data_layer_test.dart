// The whole data layer against real files: open it, use it, close the process,
// open it again, and check that everything came back — conversations, settings,
// prompts, memories, usage, jobs and the configured MCP servers — with no
// secret in the exported snapshot.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_models.dart';
import 'package:noir_android_app/data/data.dart';

const String secretValue = 'sk-or-v1-INTEGRATION-SECRET-9999';
const String mcpToken = 'mcp-bearer-INTEGRATION-TOKEN-4242';

void main() {
  late Directory root;
  var tick = 0;
  DateTime clock() =>
      DateTime.utc(2026, 6, 1, 8).add(Duration(milliseconds: tick++));

  Future<NoirDataLayer> open() => NoirDataLayer.open(
    root: root,
    secretRoot: Directory('${root.path}/private'),
    clock: clock,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_layer_');
    tick = 0;
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('opening creates the directory layout it needs', () async {
    final layer = await open();

    expect(Directory(root.path).existsSync(), isTrue);
    expect(Directory('${root.path}/private').existsSync(), isTrue);
    for (final name in layer.store.catalog.names) {
      expect(
        Directory('${root.path}/$name').existsSync(),
        isTrue,
        reason: 'collection "$name" needs a directory',
      );
    }
    expect(
      layer.store.catalog.names,
      containsAll(<String>[
        NoirCollections.conversations,
        NoirCollections.providerSettings,
        NoirCollections.prompts,
        NoirCollections.memories,
        NoirCollections.usage,
        NoirCollections.jobs,
      ]),
    );
  });

  test('a fresh layer is empty everywhere', () async {
    final layer = await open();

    expect(await layer.conversations.count(), isZero);
    expect(await layer.settings.count(), isZero);
    expect(await layer.prompts.count(), isZero);
    expect(await layer.memories.count(), isZero);
    expect(await layer.usage.count(), isZero);
    expect(await layer.jobs.count(), isZero);
    expect(layer.store.recoveries, isEmpty);
    expect(await layer.quarantinedKeys(), isEmpty);
  });

  test(
    'everything written through one session is there after a restart',
    () async {
      final first = await open();

      await first.conversations.appendMessage(
        'c1',
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'keep me',
        ),
      );
      await first.settings.upsert(
        ProviderSettings(
          id: 'openrouter',
          displayName: 'OpenRouter',
          baseUrl: 'https://openrouter.ai/api/v1',
          defaultModel: 'noir-engine/pro-v2:free',
          fallbackModels: const <String>[],
          funded: false,
          rpmCap: 20,
          dailyCap: 50,
          createdAt: clock(),
          updatedAt: clock(),
        ),
      );
      await first.settings.setSecret('openrouter', secretValue);
      await first.prompts.upsert(
        first.prompts.newPrompt(
          id: 'p1',
          title: 'Summarise',
          body: 'in one line',
        ),
      );
      await first.memories.upsert(
        first.memories.newMemory(id: 'm1', key: 'user.name', value: 'Ada'),
      );
      await first.usage.record(
        provider: 'openrouter',
        model: 'noir-engine/pro-v2:free',
        promptTokens: 120,
        completionTokens: 80,
        funded: false,
      );
      await first.jobs.upsert(
        first.jobs.newJob(
          id: 'j1',
          name: 'Nightly',
          prompt: 'run the check',
          schedule: JobSchedule.daily(hour: 3, minute: 0),
        ),
      );
      await first.jobs.markCompleted('j1', at: DateTime.utc(2026, 6, 2, 3));

      // A new layer over the same directory: this is the "app restarted" case.
      final second = await open();

      expect(
        (await second.conversations.find('c1'))!.messages.single.text,
        'keep me',
      );
      expect((await second.settings.find('openrouter'))!.hasSecret, isTrue);
      expect(await second.settings.resolveSecret('openrouter'), secretValue);
      expect((await second.prompts.find('p1'))!.title, 'Summarise');
      expect((await second.memories.find('m1'))!.value, 'Ada');
      expect((await second.usage.summarize()).totalTokens, 200);
      expect((await second.jobs.find('j1'))!.runCount, 1);
      expect(
        (await second.jobs.find('j1'))!.nextRunAt,
        DateTime.utc(2026, 6, 3, 3),
      );
    },
  );

  test('the whole-app export carries no secret and stays valid JSON', () async {
    final layer = await open();
    await layer.settings.upsert(
      ProviderSettings(
        id: 'openrouter',
        displayName: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        defaultModel: 'noir-engine/pro-v2:free',
        fallbackModels: const <String>['a:free'],
        funded: true,
        rpmCap: 20,
        dailyCap: 1000,
        createdAt: clock(),
        updatedAt: clock(),
      ),
    );
    await layer.settings.setSecret('openrouter', secretValue);
    await layer.conversations.appendMessage(
      'c1',
      const ConversationMessage(
        id: 'user-1',
        role: MessageRole.user,
        text: 'private conversation',
      ),
    );
    await layer.prompts.upsert(
      layer.prompts.newPrompt(id: 'p1', title: 'P', body: 'b'),
    );
    await layer.memories.upsert(
      layer.memories.newMemory(id: 'm1', key: 'k', value: 'v'),
    );
    await layer.jobs.upsert(
      layer.jobs.newJob(
        id: 'j1',
        name: 'J',
        prompt: 'p',
        schedule: JobSchedule.interval(intervalMinutes: 30),
      ),
    );
    // A configured MCP server, credentialed: the whole-app export claims to hold
    // every record in every collection, so a backup that dropped the MCP
    // configuration would restore an app with no MCP capability at all and no
    // record of which servers were configured. The token is what proves the
    // collection belongs in the export without leaking through it.
    await layer.mcpServers.upsert(
      layer.mcpServers.newServer(
        id: 'notes',
        displayName: 'Notes',
        endpoint: 'https://mcp.example.test/notes',
        allowedTools: const <String>['read_note'],
        backgroundSafeTools: const <String>['read_note'],
      ),
    );
    await layer.mcpServers.setToken('notes', mcpToken);

    final export = await layer.exportRedactedSnapshot();
    final text = jsonEncode(export);

    expect(text, isNot(contains(secretValue)));
    expect(text, isNot(contains(mcpToken)));
    expect(jsonDecode(text), isA<Map<String, Object?>>());
    expect(export['exportVersion'], 1);
    expect(export['collections'], isA<Map<String, Object?>>());
    final collections = export['collections']! as Map<String, Object?>;
    expect(collections.keys.toSet(), <String>{
      NoirCollections.conversations,
      NoirCollections.providerSettings,
      NoirCollections.prompts,
      NoirCollections.memories,
      NoirCollections.jobs,
      NoirCollections.mcpServers,
      NoirCollections.usage,
    });
    final providers =
        collections[NoirCollections.providerSettings]! as Map<String, Object?>;
    final provider =
        (providers['items']! as List<Object?>).single! as Map<String, Object?>;
    expect(provider['secretConfigured'], isTrue);
    expect(provider['secretRef'], redactedSecretPlaceholder);
    // The server's endpoint and allowlist are the configuration a restore needs;
    // the bearer token is not, and is not there.
    final servers =
        collections[NoirCollections.mcpServers]! as Map<String, Object?>;
    final server =
        (servers['items']! as List<Object?>).single! as Map<String, Object?>;
    expect(server['endpoint'], 'https://mcp.example.test/notes');
    expect(server['allowedTools'], <String>['read_note']);
    expect(server['secretConfigured'], isTrue);
    expect(server['secretRef'], redactedSecretPlaceholder);
    expect(
      await layer.settings.recordsLeakingSecrets(<String>[secretValue]),
      isEmpty,
    );
    expect(
      await layer.mcpServers.recordsLeakingTokens(<String>[mcpToken]),
      isEmpty,
    );
  });

  test('a corrupt record is reported by the layer, not swallowed', () async {
    final layer = await open();
    await layer.conversations.appendMessage(
      'c1',
      const ConversationMessage(
        id: 'user-1',
        role: MessageRole.user,
        text: 'x',
      ),
    );
    File(
      '${root.path}/${NoirCollections.conversations}/c1.json',
    ).writeAsStringSync('{"schemaVersion":1,"writtenAt":');

    await expectLater(
      layer.conversations.find('c1'),
      throwsA(isA<CorruptRecordError>().having((e) => e.id, 'id', 'c1')),
      reason: 'no backup existed, so there is nothing to fall back to',
    );
    expect(layer.store.recoveries, isNotEmpty);
    expect(
      layer.store.recoveries.last.reason,
      StoreRecoveryReason.unrecoverable,
    );
    expect(await layer.quarantinedKeys(), isNotEmpty);
    expect(
      await layer.quarantinedContents(
        layer.store.recoveries.last.quarantineId!,
      ),
      '{"schemaVersion":1,"writtenAt":',
    );
  });

  test(
    'a corrupt record with a backup is recovered and the layer heals',
    () async {
      final layer = await open();
      await layer.conversations.appendMessage(
        'c1',
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'first',
        ),
      );
      await layer.conversations.appendMessage(
        'c1',
        const ConversationMessage(
          id: 'user-2',
          role: MessageRole.user,
          text: 'second',
        ),
      );
      File(
        '${root.path}/${NoirCollections.conversations}/c1.json',
      ).writeAsStringSync('nonsense');

      final recovered = await layer.conversations.find('c1');

      expect(recovered!.messages.map((m) => m.text), <String>['first']);
      expect(
        layer.store.recoveries.last.reason,
        StoreRecoveryReason.corruptPrimary,
      );
      expect(
        await layer.conversations.find('c1'),
        isNotNull,
        reason: 'a second read must find a healthy record',
      );
    },
  );

  test(
    'a self-report names the backend, the collections and the limits',
    () async {
      final layer = await open();

      final report = layer.selfReport();

      expect(report['backend'], 'JsonFileKeyValueStore');
      expect(report['root'], root.path);
      expect(report['isDurable'], isTrue);
      expect(report['secretsDurable'], isTrue);
      expect(report['secretsEncryptedAtRest'], isFalse);
      expect(report['atomicWrites'], contains('temp file + rename'));
      expect(report['maxPageLimit'], isA<int>());
      expect(report['collections'], isA<Map<String, Object?>>());
      final collections = report['collections']! as Map<String, Object?>;
      expect(collections[NoirCollections.conversations], <String, Object?>{
        'currentVersion': NoirSchema.conversationsVersion,
        'migrations': hasLength(1),
      });
    },
  );

  test(
    'an in-memory layer behaves like a file-backed one for a session',
    () async {
      final layer = NoirDataLayer.inMemory(clock: clock);

      await layer.conversations.appendMessage(
        'c1',
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'ephemeral',
        ),
      );
      await layer.usage.record(
        provider: 'openrouter',
        model: 'm:free',
        promptTokens: 5,
        completionTokens: 5,
        funded: false,
      );

      expect((await layer.conversations.find('c1'))!.messages, hasLength(1));
      expect((await layer.usage.summarize()).totalTokens, 10);
      expect(layer.selfReport()['isDurable'], isFalse);
      expect(layer.selfReport()['backend'], 'InMemoryKeyValueStore');
    },
  );

  test('opening twice over the same directory sees the same data', () async {
    final first = await open();
    await first.prompts.upsert(
      first.prompts.newPrompt(id: 'p1', title: 'Shared', body: 'b'),
    );

    final second = await open();

    expect((await second.prompts.find('p1'))!.title, 'Shared');
  });

  test('a data layer can be injected into repositories built by hand', () async {
    // The repositories take a store, so a test (or a preview) can hand them the
    // in-memory double instead of the filesystem.
    final store = InMemoryKeyValueStore(
      catalog: NoirSchema.catalog(clock: clock),
      clock: clock,
    );
    final repository = ConversationRepository(store: store, clock: clock);

    await repository.appendMessage(
      'c1',
      const ConversationMessage(
        id: 'user-1',
        role: MessageRole.user,
        text: 'injected',
      ),
    );

    expect((await repository.find('c1'))!.messages.single.text, 'injected');
  });
}
