// MCP server configuration: what is persisted, what is redacted, and where a
// bearer token is allowed to exist at all.
//
// The rule under test is the same one provider settings follow, and it is the
// reason this collection exists: an MCPAdapter is only ever built for a server
// the user actually configured, and the token for that server is a *reference*,
// never a value. The tests also check the validation that keeps a saved record
// usable — a server with an empty allowlist or an endpoint that is not a URL is
// refused at write time instead of becoming a record that looks configured and can
// never act.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/noir_schema.dart';

const String mcpToken = 'mcp-bearer-TOKEN-abcdef0123456789';

void main() {
  late Directory root;
  late Directory secretRoot;
  late SecretStore secrets;
  late KeyValueStore store;
  late McpServerRepository mcp;

  final DateTime stamp = DateTime.utc(2026, 3, 4, 5, 6, 7);

  McpServerRepository open() => McpServerRepository(
    store: JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(secrets: secrets),
      clock: () => stamp,
    ),
    secrets: secrets,
    clock: () => stamp,
  );

  McpServerSettings notesServer({
    String id = 'notes',
    List<String> allowedTools = const <String>['read_note', 'delete_note'],
    List<String> backgroundSafeTools = const <String>['read_note'],
  }) => McpServerSettings(
    id: id,
    displayName: 'Notes',
    endpoint: 'https://mcp.example.test/notes',
    transportKind: 'http',
    allowedTools: allowedTools,
    backgroundSafeTools: backgroundSafeTools,
    createdAt: stamp,
    updatedAt: stamp,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_mcp_servers_');
    secretRoot = Directory.systemTemp.createTempSync('noir_mcp_secrets_');
    secrets = FileSecretStore(root: secretRoot);
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(secrets: secrets),
      clock: () => stamp,
    );
    mcp = McpServerRepository(
      store: store,
      secrets: secrets,
      clock: () => stamp,
    );
  });

  tearDown(() {
    for (final Directory dir in <Directory>[root, secretRoot]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  group('the configuration is only ever what the user entered', () {
    test('a fresh repository is empty', () async {
      expect(await mcp.readAll(), isEmpty);
      expect(await mcp.count(), isZero);
      expect(await mcp.find('notes'), isNull);
    });

    test('a saved server comes back with every field intact', () async {
      await mcp.upsert(notesServer());

      final loaded = (await mcp.find('notes'))!;

      expect(loaded.displayName, 'Notes');
      expect(loaded.endpoint, 'https://mcp.example.test/notes');
      expect(loaded.transportKind, 'http');
      expect(loaded.allowedTools, <String>['read_note', 'delete_note']);
      expect(loaded.backgroundSafeTools, <String>['read_note']);
      expect(loaded.vouchesForBackground('read_note'), isTrue);
      expect(loaded.vouchesForBackground('delete_note'), isFalse);
      expect(loaded.isStdio, isFalse);
      expect(loaded.httpEndpoint, Uri.parse('https://mcp.example.test/notes'));
      expect(loaded.hasSecret, isFalse);
    });

    test('a stdio server keeps its executable and has no URL', () async {
      await mcp.upsert(
        mcp.newServer(
          id: 'local',
          displayName: 'Local server',
          endpoint: '/usr/local/bin/noir-mcp',
          transportKind: 'stdio',
          allowedTools: const <String>['read_note'],
          backgroundSafeTools: const <String>[],
        ),
      );

      final loaded = (await mcp.find('local'))!;

      expect(loaded.transportKind, 'stdio');
      expect(loaded.isStdio, isTrue);
      expect(loaded.httpEndpoint, isNull);
      expect(loaded.allowedTools, <String>['read_note']);
    });

    test('a saved server survives a restart', () async {
      await mcp.upsert(notesServer());
      await mcp.setToken('notes', mcpToken);

      final reopened = open();
      final loaded = (await reopened.find('notes'))!;

      expect(loaded.allowedTools, <String>['read_note', 'delete_note']);
      expect(loaded.backgroundSafeTools, <String>['read_note']);
      expect(loaded.hasSecret, isTrue);
      expect(await reopened.resolveToken('notes'), mcpToken);
    });

    test('newServer stamps from the repository clock', () async {
      final created = mcp.newServer(
        id: 'notes',
        displayName: 'Notes',
        endpoint: 'https://mcp.example.test/notes',
        allowedTools: const <String>['read_note'],
        backgroundSafeTools: const <String>['read_note'],
      );

      expect(created.createdAt, stamp);
      expect(created.updatedAt, stamp);
      expect(created.toString(), contains('tools: 1 (1 declared read-only)'));
    });
  });

  group('the bearer token is a reference, never a value', () {
    test(
      'a token is filed in the secret store and only a ref is persisted',
      () async {
        await mcp.upsert(notesServer());
        final saved = await mcp.setToken('notes', mcpToken);

        expect(saved.hasSecret, isTrue);
        expect(saved.secretRef, mcpServerSecretRef('notes'));
        expect(saved.secretValue, isNull);
        expect(await secrets.read(mcpServerSecretRef('notes')), mcpToken);
        expect(await mcp.resolveToken('notes'), mcpToken);

        final raw = await (store as RawStoreAccess).rawEnvelope(
          NoirCollections.mcpServers,
          'notes',
        );
        expect(raw, contains(mcpServerSecretRef('notes')));
        expect(
          raw,
          isNot(contains(mcpToken)),
          reason: 'the value is not in the record',
        );
        expect(
          await mcp.recordsLeakingTokens(<String>[mcpToken]),
          isEmpty,
          reason: 'no stored envelope holds the token',
        );
      },
    );

    test('the redacted form replaces the ref and reports presence', () async {
      await mcp.upsert(notesServer());
      await mcp.setToken('notes', mcpToken);

      final json = (await mcp.find('notes'))!.toRedactedJson();

      expect(json['secretRef'], redactedSecretPlaceholder);
      expect(json['secretConfigured'], isTrue);
      expect(json.toString(), isNot(contains(mcpToken)));
    });

    test('an export of the collection carries no token', () async {
      await mcp.upsert(notesServer());
      await mcp.setToken('notes', mcpToken);

      final exported = await mcp.exportRedacted();

      expect(exported, hasLength(1));
      expect(exported.single['endpoint'], 'https://mcp.example.test/notes');
      expect(exported.single.toString(), isNot(contains(mcpToken)));
    });

    test('clearing a token removes both the ref and the value', () async {
      await mcp.upsert(notesServer());
      await mcp.setToken('notes', mcpToken);

      final cleared = await mcp.clearToken('notes');

      expect(cleared.hasSecret, isFalse);
      expect(cleared.secretRef, isNull);
      expect(await secrets.has(mcpServerSecretRef('notes')), isFalse);
      expect(await mcp.resolveToken('notes'), isNull);
    });

    test('deleting a server deletes its token', () async {
      await mcp.upsert(notesServer());
      await mcp.setToken('notes', mcpToken);

      await mcp.delete('notes');

      expect(await mcp.exists('notes'), isFalse);
      expect(await secrets.has(mcpServerSecretRef('notes')), isFalse);
    });

    test('a record that claims a missing token fails loudly', () async {
      await mcp.upsert(notesServer().copyWith(secretRef: 'ghost-token-ref'));

      await expectLater(
        mcp.resolveToken('notes'),
        throwsA(isA<SecretNotFoundError>()),
      );
    });

    test('an unknown server has no token to resolve', () async {
      await expectLater(
        mcp.resolveToken('nope'),
        throwsA(isA<RecordNotFoundError>()),
      );
      await expectLater(
        mcp.setToken('nope', mcpToken),
        throwsA(isA<RecordNotFoundError>()),
      );
      await expectLater(
        mcp.clearToken('nope'),
        throwsA(isA<RecordNotFoundError>()),
      );
    });

    test('an empty token is refused rather than stored', () async {
      await mcp.upsert(notesServer());

      await expectLater(
        mcp.setToken('notes', ''),
        throwsA(isA<InvalidDataError>()),
      );
      expect((await mcp.find('notes'))!.hasSecret, isFalse);
    });

    test('a record that leaks the token is found by the scan', () async {
      await mcp.upsert(notesServer());
      // Damage a stored record the way a hand-edited file or an older build
      // would: the plaintext lands in the record itself.
      final raw = store as RawStoreAccess;
      final envelope = (await raw.rawEnvelope(
        NoirCollections.mcpServers,
        'notes',
      ))!;
      await raw.damagePrimary(
        NoirCollections.mcpServers,
        'notes',
        envelope.replaceFirst(
          '"allowedTools"',
          '"token":"$mcpToken","allowedTools"',
        ),
      );

      expect(await mcp.recordsLeakingTokens(<String>[mcpToken]), <String>[
        'notes',
      ]);
    });
  });

  group('a saved record is one the app can actually use', () {
    test('an empty allowlist is refused', () {
      expect(
        () => notesServer(allowedTools: const <String>[]),
        throwsA(
          isA<InvalidDataError>().having(
            (e) => e.message,
            'message',
            contains('at least one allowed tool'),
          ),
        ),
      );
    });

    test('an endpoint that is not http(s) is refused', () {
      expect(
        () => McpServerSettings(
          id: 'notes',
          displayName: 'Notes',
          endpoint: 'ftp://mcp.example.test/notes',
          transportKind: 'http',
          allowedTools: const <String>['read_note'],
          backgroundSafeTools: const <String>[],
          createdAt: stamp,
          updatedAt: stamp,
        ),
        throwsA(
          isA<InvalidDataError>().having(
            (e) => e.message,
            'message',
            contains('not an http(s) MCP endpoint'),
          ),
        ),
      );
    });

    test('an unknown transport kind is refused', () {
      expect(
        () => McpServerSettings(
          id: 'notes',
          displayName: 'Notes',
          endpoint: 'https://mcp.example.test/notes',
          transportKind: 'carrier-pigeon',
          allowedTools: const <String>['read_note'],
          backgroundSafeTools: const <String>[],
          createdAt: stamp,
          updatedAt: stamp,
        ),
        throwsA(isA<InvalidDataError>()),
      );
    });

    test('a tool name that is not a tool name is refused', () {
      expect(
        () => notesServer(allowedTools: const <String>['read note']),
        throwsA(
          isA<InvalidDataError>().having(
            (e) => e.message,
            'message',
            contains('not a usable MCP tool name'),
          ),
        ),
      );
      expect(
        () => notesServer(allowedTools: const <String>['../etc/passwd']),
        throwsA(isA<InvalidDataError>()),
      );
    });

    test('a duplicated tool on the allowlist is refused', () {
      expect(
        () =>
            notesServer(allowedTools: const <String>['read_note', 'read_note']),
        throwsA(
          isA<InvalidDataError>().having(
            (e) => e.message,
            'message',
            contains('listed twice'),
          ),
        ),
      );
    });

    test(
      'a background-safe declaration for a tool that is not allowed is refused',
      () {
        expect(
          () => notesServer(
            allowedTools: const <String>['read_note'],
            backgroundSafeTools: const <String>['delete_everything'],
          ),
          throwsA(
            isA<InvalidDataError>().having(
              (e) => e.message,
              'message',
              contains('is not on the allowlist'),
            ),
          ),
        );
      },
    );

    test('a background-safe tool declared twice is refused', () {
      expect(
        () => notesServer(
          allowedTools: const <String>['read_note'],
          backgroundSafeTools: const <String>['read_note', 'read_note'],
        ),
        throwsA(
          isA<InvalidDataError>().having(
            (e) => e.message,
            'message',
            contains('declared background safe twice'),
          ),
        ),
      );
    });

    test('a display name is required', () {
      expect(
        () => McpServerSettings(
          id: 'notes',
          displayName: '   ',
          endpoint: 'https://mcp.example.test/notes',
          transportKind: 'http',
          allowedTools: const <String>['read_note'],
          backgroundSafeTools: const <String>[],
          createdAt: stamp,
          updatedAt: stamp,
        ),
        throwsA(isA<InvalidDataError>()),
      );
    });

    test('a stdio server needs an executable', () {
      expect(
        () => McpServerSettings(
          id: 'local',
          displayName: 'Local',
          endpoint: '  ',
          transportKind: 'stdio',
          allowedTools: const <String>['read_note'],
          backgroundSafeTools: const <String>[],
          createdAt: stamp,
          updatedAt: stamp,
        ),
        throwsA(isA<InvalidDataError>()),
      );
    });

    test(
      'a record whose stored fields are malformed is named, not defaulted',
      () async {
        await store
            .write(NoirCollections.mcpServers, 'broken', <String, Object?>{
              'displayName': 'Broken',
              'endpoint': 'https://mcp.example.test/x',
              'transportKind': 'http',
              'allowedTools': 'read_note',
              'backgroundSafeTools': <String>[],
              'createdAt': stamp.toIso8601String(),
              'updatedAt': stamp.toIso8601String(),
            });

        await expectLater(
          mcp.find('broken'),
          throwsA(
            isA<MalformedRecordError>()
                .having(
                  (e) => e.collection,
                  'collection',
                  NoirCollections.mcpServers,
                )
                .having((e) => e.id, 'id', 'broken')
                .having((e) => e.field, 'field', 'allowedTools'),
          ),
        );
      },
    );

    test('a stored endpoint that is not http(s) is refused on read', () async {
      await store.write(NoirCollections.mcpServers, 'bad', <String, Object?>{
        'displayName': 'Bad',
        'endpoint': 'not a url',
        'transportKind': 'http',
        'allowedTools': <String>['read_note'],
        'backgroundSafeTools': <String>[],
        'createdAt': stamp.toIso8601String(),
        'updatedAt': stamp.toIso8601String(),
      });

      await expectLater(
        mcp.find('bad'),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.message,
            'message',
            contains('not an http(s) MCP endpoint'),
          ),
        ),
      );
    });
  });
}
