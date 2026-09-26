// Provider settings: what is persisted, what is redacted, and where a plaintext
// secret is allowed to exist at all.
//
// The rule under test: a record holds a *reference*, never a value. The only way
// to get a value back is to ask the secret store for it by reference. Logs and
// exports get the redacted form, and the tests check the whole surface for the
// literal secret string.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/noir_schema.dart';

const String secretValue = 'sk-or-v1-SUPERSECRET-0123456789';

void main() {
  late Directory root;
  late Directory secretRoot;
  late SecretStore secrets;
  late KeyValueStore store;
  late SettingsRepository settings;

  SettingsRepository makeRepository(
    KeyValueStore target,
    SecretStore secretStore,
  ) => SettingsRepository(
    store: target,
    secrets: secretStore,
    clock: () => DateTime.utc(2026, 2, 3, 4, 5, 6),
  );

  ProviderSettings openRouter({
    bool funded = false,
    String? id = 'openrouter',
  }) {
    return ProviderSettings(
      id: id!,
      displayName: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      defaultModel: 'noir-engine/pro-v2:free',
      fallbackModels: const <String>['thinkingmachines/inkling:free'],
      funded: funded,
      rpmCap: 20,
      dailyCap: funded ? 1000 : 50,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_settings_');
    secretRoot = Directory.systemTemp.createTempSync('noir_secrets_');
    secrets = FileSecretStore(root: secretRoot);
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(secrets: secrets),
      clock: () => DateTime.utc(2026, 2, 3, 4, 5, 6),
    );
    settings = makeRepository(store, secrets);
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
    if (secretRoot.existsSync()) {
      secretRoot.deleteSync(recursive: true);
    }
  });

  group('CRUD', () {
    test('a fresh repository is empty', () async {
      expect(await settings.readAll(), isEmpty);
      expect(await settings.count(), isZero);
      expect(await settings.find('nope'), isNull);
    });

    test('a saved provider comes back with every field intact', () async {
      await settings.upsert(openRouter());

      final loaded = (await settings.find('openrouter'))!;

      expect(loaded.displayName, 'OpenRouter');
      expect(loaded.baseUrl, 'https://openrouter.ai/api/v1');
      expect(loaded.defaultModel, 'noir-engine/pro-v2:free');
      expect(loaded.fallbackModels, <String>['thinkingmachines/inkling:free']);
      expect(loaded.funded, isFalse);
      expect(loaded.rpmCap, 20);
      expect(loaded.dailyCap, 50);
      expect(loaded.hasSecret, isFalse);
    });

    test('a provider survives a restart', () async {
      await settings.upsert(openRouter(funded: true));
      await settings.setSecret('openrouter', secretValue);

      final reopened = makeRepository(
        JsonFileKeyValueStore(
          root: root,
          catalog: buildNoirCatalog(secrets: secrets),
        ),
        secrets,
      );
      final loaded = (await reopened.find('openrouter'))!;

      expect(loaded.funded, isTrue);
      expect(loaded.dailyCap, 1000);
      expect(loaded.hasSecret, isTrue);
      expect(await reopened.resolveSecret('openrouter'), secretValue);
    });

    test('deleting a provider also deletes its secret', () async {
      await settings.upsert(openRouter());
      await settings.setSecret('openrouter', secretValue);

      await settings.delete('openrouter');

      expect(await settings.exists('openrouter'), isFalse);
      expect(await secrets.has('openrouter-api-key'), isFalse);
      expect(await secrets.read('openrouter-api-key'), isNull);
    });

    test('deleting a provider that never had a secret is fine', () async {
      await settings.upsert(openRouter());

      await settings.delete('openrouter');

      expect(await settings.count(), isZero);
    });

    test('providers are listed and paged in id order', () async {
      await settings.upsert(openRouter(id: 'b-provider'));
      await settings.upsert(openRouter(id: 'a-provider'));
      await settings.upsert(openRouter(id: 'c-provider'));

      expect(await settings.ids(), <String>[
        'a-provider',
        'b-provider',
        'c-provider',
      ]);
      final page = await settings.page(PageRequest(limit: 2));
      expect(page.items.map((s) => s.id), <String>['a-provider', 'b-provider']);
      expect(page.total, 3);
      expect(page.hasMore, isTrue);
    });

    test('an invalid provider is rejected before it is stored', () async {
      expect(
        () => openRouter().copyWith(baseUrl: 'not a url'),
        throwsA(isA<InvalidDataError>()),
      );
      expect(
        () => openRouter().copyWith(rpmCap: -1),
        throwsA(isA<InvalidDataError>()),
      );
      expect(
        () => openRouter().copyWith(displayName: '  '),
        throwsA(isA<InvalidDataError>()),
      );
      expect(await settings.count(), isZero);
    });

    test(
      'updating a provider that does not exist is an explicit error',
      () async {
        await expectLater(
          settings.update('nope', (current) => current.copyWith(funded: true)),
          throwsA(isA<RecordNotFoundError>()),
        );
      },
    );

    test('an update is applied and persisted', () async {
      await settings.upsert(openRouter());

      final updated = await settings.update(
        'openrouter',
        (current) => current.copyWith(funded: true, dailyCap: 1000),
      );

      expect(updated.funded, isTrue);
      expect((await settings.find('openrouter'))!.dailyCap, 1000);
    });
  });

  group('the secret boundary', () {
    test('the stored record holds a reference, never the value', () async {
      await settings.upsert(openRouter());

      final stored = await settings.setSecret('openrouter', secretValue);

      expect(stored.hasSecret, isTrue);
      expect(stored.secretRef, 'openrouter-api-key');
      final raw = await (store as RawStoreAccess).rawEnvelope(
        NoirCollections.providerSettings,
        'openrouter',
      );
      expect(raw, isNotNull);
      expect(raw, isNot(contains(secretValue)));
      expect(raw, contains('openrouter-api-key'));
    });

    test(
      'the value comes back only when it is asked for by reference',
      () async {
        await settings.upsert(openRouter());
        await settings.setSecret('openrouter', secretValue);

        expect(await settings.resolveSecret('openrouter'), secretValue);
        expect(await settings.find('openrouter'), isNotNull);
        expect(
          (await settings.find('openrouter'))!.secretValue,
          isNull,
          reason: 'a loaded record must not carry the value',
        );
      },
    );

    test('a provider without a secret resolves to null', () async {
      await settings.upsert(openRouter());

      expect(await settings.resolveSecret('openrouter'), isNull);
    });

    test(
      'resolving a secret for a provider that does not exist is an error',
      () async {
        await expectLater(
          settings.resolveSecret('nope'),
          throwsA(isA<RecordNotFoundError>()),
        );
      },
    );

    test(
      'a provider whose secret vanished is reported, not silently empty',
      () async {
        await settings.upsert(openRouter());
        await settings.setSecret('openrouter', secretValue);
        await secrets.delete('openrouter-api-key');

        await expectLater(
          settings.resolveSecret('openrouter'),
          throwsA(isA<SecretNotFoundError>()),
        );
        expect((await settings.find('openrouter'))!.hasSecret, isTrue);
      },
    );

    test(
      'setting a secret on a missing provider is an explicit error',
      () async {
        await expectLater(
          settings.setSecret('nope', secretValue),
          throwsA(isA<RecordNotFoundError>()),
        );
      },
    );

    test('setting a secret replaces the old one', () async {
      await settings.upsert(openRouter());
      await settings.setSecret('openrouter', 'first-value');
      await settings.setSecret('openrouter', secretValue);

      expect(await settings.resolveSecret('openrouter'), secretValue);
      expect(await secrets.has('openrouter-api-key'), isTrue);
    });

    test('clearing a secret empties the store and the record', () async {
      await settings.upsert(openRouter());
      await settings.setSecret('openrouter', secretValue);

      final cleared = await settings.clearSecret('openrouter');

      expect(cleared.hasSecret, isFalse);
      expect(cleared.secretRef, isNull);
      expect(await secrets.has('openrouter-api-key'), isFalse);
      expect(await secrets.listRefs(), isEmpty);
    });

    test('two providers keep separate secrets', () async {
      await settings.upsert(openRouter(id: 'openrouter'));
      await settings.upsert(openRouter(id: 'ollama'));
      await settings.setSecret('openrouter', secretValue);
      await settings.setSecret('ollama', 'local-no-key');

      expect(await settings.resolveSecret('openrouter'), secretValue);
      expect(await settings.resolveSecret('ollama'), 'local-no-key');
      final rawOpenRouter = await (store as RawStoreAccess).rawEnvelope(
        NoirCollections.providerSettings,
        'openrouter',
      );
      final rawOllama = await (store as RawStoreAccess).rawEnvelope(
        NoirCollections.providerSettings,
        'ollama',
      );
      expect(rawOpenRouter, isNot(contains('local-no-key')));
      expect(rawOllama, isNot(contains(secretValue)));
    });

    test('no record in the store leaks a known secret', () async {
      await settings.upsert(openRouter());
      await settings.setSecret('openrouter', secretValue);

      expect(
        await settings.recordsLeakingSecrets(<String>[secretValue]),
        isEmpty,
      );
    });

    test(
      'a record that somehow holds a secret is reported by the leak check',
      () async {
        await store
            .write(NoirCollections.providerSettings, 'leaky', <String, Object?>{
              'displayName': 'Leaky',
              'baseUrl': 'https://example.invalid/v1',
              'defaultModel': 'm',
              'fallbackModels': <Object?>[],
              'funded': false,
              'rpmCap': 20,
              'dailyCap': 50,
              'apiKey': secretValue,
              'createdAt': '2026-01-01T00:00:00.000Z',
              'updatedAt': '2026-01-01T00:00:00.000Z',
            });

        expect(
          await settings.recordsLeakingSecrets(<String>[secretValue]),
          <String>['leaky'],
        );
      },
    );
  });

  group('redaction', () {
    test('the export carries no secret value anywhere', () async {
      await settings.upsert(openRouter());
      await settings.setSecret('openrouter', secretValue);

      final export = await settings.exportRedactedSnapshot();
      final text = _json(export);

      expect(text, isNot(contains(secretValue)));
      expect(text, contains(redactedSecretPlaceholder));
      final providers = export['providers']! as List<Object?>;
      expect(providers, hasLength(1));
      final provider = providers.single! as Map<String, Object?>;
      expect(provider['secretConfigured'], isTrue);
      expect(provider['secretRef'], redactedSecretPlaceholder);
      expect(provider['secretUpdatedAt'], isA<String>());
      expect(provider['displayName'], 'OpenRouter');
    });

    test('the export still says which providers have no secret', () async {
      await settings.upsert(openRouter());

      final export = await settings.exportRedactedSnapshot();
      final provider =
          (export['providers']! as List<Object?>).single!
              as Map<String, Object?>;

      expect(provider['secretConfigured'], isFalse);
      expect(provider.containsKey('secretUpdatedAt'), isFalse);
    });

    test('a redacted record is a full record, not a summary', () async {
      final redacted = openRouter(funded: true).toRedactedJson();

      expect(redacted['displayName'], 'OpenRouter');
      expect(redacted['baseUrl'], 'https://openrouter.ai/api/v1');
      expect(redacted['defaultModel'], 'noir-engine/pro-v2:free');
      expect(redacted['fallbackModels'], <String>[
        'thinkingmachines/inkling:free',
      ]);
      expect(redacted['funded'], isTrue);
      expect(redacted['rpmCap'], 20);
      expect(redacted['dailyCap'], 1000);
    });

    test('toString never prints a secret', () async {
      await settings.upsert(openRouter());
      final withSecret = await settings.setSecret('openrouter', secretValue);

      expect(withSecret.toString(), isNot(contains(secretValue)));
      expect(withSecret.toString(), contains('openrouter'));
      expect(
        withSecret.toString(),
        contains('secret(openrouter-api-key, configured)'),
      );
    });

    test('a log line is scrubbed of every known secret', () {
      final line = 'calling $secretValue and $secretValue again, plus nothing';

      final scrubbed = redactSecretsIn(line, <String>[secretValue, '']);

      expect(scrubbed, isNot(contains(secretValue)));
      expect(
        scrubbed,
        'calling $redactedSecretPlaceholder and $redactedSecretPlaceholder '
        'again, plus nothing',
      );
    });

    test('redaction over-matches rather than leaking a substring', () {
      final scrubbed = redactSecretsIn('ab and abc', <String>['ab']);

      expect(scrubbed, isNot(contains('ab')));
      expect(
        scrubbed,
        '$redactedSecretPlaceholder and $redactedSecretPlaceholder'
        'c',
      );
    });

    test('describeSecret reports presence only', () {
      expect(
        describeSecret('ref-1', present: true),
        'secret(ref-1, configured)',
      );
      expect(describeSecret('ref-1', present: false), 'secret(ref-1, absent)');
      expect(describeSecret('ref-1', present: true), isNot(contains('sk-')));
    });
  });

  group('migrating a v1 record that held a plaintext key', () {
    Future<void> seedLegacyRecord() async {
      await store.writeAtVersion(
        NoirCollections.providerSettings,
        'openrouter',
        1,
        <String, Object?>{
          'id': 'openrouter',
          'name': 'OpenRouter',
          'baseUrl': 'https://openrouter.ai/api/v1',
          'defaultModel': 'noir-engine/pro-v2:free',
          'fallbackModels': <Object?>['thinkingmachines/inkling:free'],
          'funded': false,
          'rpmCap': 20,
          'dailyCap': 50,
          'apiKey': secretValue,
          'createdAt': '2025-12-01T00:00:00.000Z',
          'updatedAt': '2025-12-01T00:00:00.000Z',
        },
      );
    }

    test('reading it moves the key behind the secret store', () async {
      await seedLegacyRecord();

      final loaded = (await settings.find('openrouter'))!;

      expect(loaded.displayName, 'OpenRouter');
      expect(loaded.hasSecret, isTrue);
      expect(loaded.secretRef, isNotNull);
      expect(await settings.resolveSecret('openrouter'), secretValue);
    });

    test('the upgraded record no longer holds the plaintext', () async {
      await seedLegacyRecord();

      await settings.find('openrouter');

      final raw = await (store as RawStoreAccess).rawEnvelope(
        NoirCollections.providerSettings,
        'openrouter',
      );
      expect(raw, isNot(contains(secretValue)));
      expect(raw, isNot(contains('apiKey')));
      final record = (await store.readRecord(
        NoirCollections.providerSettings,
        'openrouter',
      ))!;
      expect(record.schemaVersion, 2);
      expect(
        await settings.recordsLeakingSecrets(<String>[secretValue]),
        isEmpty,
      );
    });

    test('the v1 name field becomes displayName', () async {
      await seedLegacyRecord();

      expect((await settings.find('openrouter'))!.displayName, 'OpenRouter');
    });

    test('a v1 record with no key still migrates, with no secret', () async {
      await store.writeAtVersion(
        NoirCollections.providerSettings,
        'keyless',
        1,
        <String, Object?>{
          'name': 'Local',
          'baseUrl': 'http://127.0.0.1:11434/v1',
          'defaultModel': 'llama3',
          'fallbackModels': <Object?>[],
          'funded': false,
          'rpmCap': 60,
          'dailyCap': 100000,
          'createdAt': '2025-12-01T00:00:00.000Z',
          'updatedAt': '2025-12-01T00:00:00.000Z',
        },
      );

      final loaded = (await settings.find('keyless'))!;

      expect(loaded.hasSecret, isFalse);
      expect(loaded.baseUrl, 'http://127.0.0.1:11434/v1');
      expect(await settings.resolveSecret('keyless'), isNull);
    });

    test(
      'without a secret store the migration refuses to touch the record',
      () async {
        await store.writeAtVersion(
          NoirCollections.providerSettings,
          'openrouter',
          1,
          <String, Object?>{
            'name': 'OpenRouter',
            'baseUrl': 'https://openrouter.ai/api/v1',
            'defaultModel': 'm',
            'fallbackModels': <Object?>[],
            'funded': false,
            'rpmCap': 20,
            'dailyCap': 50,
            'apiKey': secretValue,
            'createdAt': '2025-12-01T00:00:00.000Z',
            'updatedAt': '2025-12-01T00:00:00.000Z',
          },
        );
        final noSecrets = JsonFileKeyValueStore(
          root: root,
          catalog: buildNoirCatalog(),
          clock: () => DateTime.utc(2026, 2, 3),
        );
        final before = await (noSecrets as RawStoreAccess).rawEnvelope(
          NoirCollections.providerSettings,
          'openrouter',
        );

        await expectLater(
          noSecrets.read(NoirCollections.providerSettings, 'openrouter'),
          throwsA(isA<MigrationFailedError>()),
        );
        expect(
          await (noSecrets as RawStoreAccess).rawEnvelope(
            NoirCollections.providerSettings,
            'openrouter',
          ),
          before,
          reason: 'a refused migration must not rewrite the record',
        );
      },
    );
  });

  group('malformed records', () {
    Future<void> seedBroken(String field, Object? value) async {
      await store
          .write(NoirCollections.providerSettings, 'broken', <String, Object?>{
            'displayName': 'OpenRouter',
            'baseUrl': 'https://openrouter.ai/api/v1',
            'defaultModel': 'm',
            'fallbackModels': <Object?>[],
            'funded': false,
            'rpmCap': 20,
            'dailyCap': 50,
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
            field: value,
          });
    }

    test('a wrong type names the field', () async {
      await seedBroken('rpmCap', 'twenty');

      await expectLater(
        settings.find('broken'),
        throwsA(
          isA<MalformedRecordError>()
              .having((e) => e.field, 'field', 'rpmCap')
              .having(
                (e) => e.collection,
                'collection',
                NoirCollections.providerSettings,
              ),
        ),
      );
    });

    test('a baseUrl that is not a URL names the field', () async {
      await seedBroken('baseUrl', 'openrouter dot ai');

      await expectLater(
        settings.find('broken'),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'baseUrl',
          ),
        ),
      );
    });

    test('a negative cap names the field', () async {
      await seedBroken('dailyCap', -5);

      await expectLater(
        settings.find('broken'),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'dailyCap',
          ),
        ),
      );
    });

    test('a non-string display name names the field', () async {
      await seedBroken('displayName', 7);

      await expectLater(
        settings.find('broken'),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'displayName',
          ),
        ),
      );
    });

    test('fallback models must be a list of strings', () async {
      await seedBroken('fallbackModels', <Object?>[1, 2]);

      await expectLater(
        settings.find('broken'),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'fallbackModels[0]',
          ),
        ),
      );
    });

    test('an unknown secret field from a newer build is ignored', () async {
      await seedBroken('secretFutureField', true);

      expect((await settings.find('broken'))!.displayName, 'OpenRouter');
    });
  });

  group('secret stores', () {
    test('the in-memory store says it is neither durable nor encrypted', () {
      final store = InMemorySecretStore();

      expect(store.isDurable, isFalse);
      expect(store.isEncryptedAtRest, isFalse);
      expect(store.protectionSummary, contains('lost when the process exits'));
    });

    test('the file store is durable and admits it is not encrypted', () {
      final store = FileSecretStore(root: secretRoot);

      expect(store.isDurable, isTrue);
      expect(store.isEncryptedAtRest, isFalse);
      expect(store.protectionSummary, contains('not encrypted at rest'));
    });

    test('the file store keeps a value across instances', () async {
      await FileSecretStore(root: secretRoot).write('ref-1', secretValue);

      final reopened = FileSecretStore(root: secretRoot);

      expect(await reopened.read('ref-1'), secretValue);
      expect(await reopened.has('ref-1'), isTrue);
      expect(await reopened.listRefs(), <String>['ref-1']);
    });

    test(
      'the in-memory store forgets a value when the instance is dropped',
      () async {
        await InMemorySecretStore().write('ref-1', secretValue);

        expect(await InMemorySecretStore().read('ref-1'), isNull);
        expect(await InMemorySecretStore().has('ref-1'), isFalse);
      },
    );

    test('a deleted ref is gone from both stores', () async {
      final memory = InMemorySecretStore();
      final file = FileSecretStore(root: secretRoot);
      await memory.write('ref-1', secretValue);
      await file.write('ref-1', secretValue);

      await memory.delete('ref-1');
      await file.delete('ref-1');
      await file.delete('ref-1');

      expect(await memory.has('ref-1'), isFalse);
      expect(await file.has('ref-1'), isFalse);
      expect(await file.listRefs(), isEmpty);
    });

    test('an empty value is rejected by both stores', () async {
      await expectLater(
        InMemorySecretStore().write('ref-1', ''),
        throwsA(isA<InvalidDataError>()),
      );
      await expectLater(
        FileSecretStore(root: secretRoot).write('ref-1', ''),
        throwsA(isA<InvalidDataError>()),
      );
    });

    test('a reference that could escape the directory is rejected', () async {
      for (final ref in <String>[
        '',
        '../escape',
        'nested/ref',
        'has space',
        'a__b',
        'r' * 200,
      ]) {
        await expectLater(
          FileSecretStore(root: secretRoot).write(ref, secretValue),
          throwsA(isA<StorageKeyError>()),
          reason: 'ref "$ref" must be refused',
        );
        await expectLater(
          InMemorySecretStore().write(ref, secretValue),
          throwsA(isA<StorageKeyError>()),
          reason: 'ref "$ref" must be refused',
        );
      }
    });

    test('a dot in a reference is fine', () async {
      final memory = InMemorySecretStore();

      await memory.write('provider.api-key', secretValue);

      expect(await memory.read('provider.api-key'), secretValue);
      expect(memory.refs, <String>['provider.api-key']);
    });

    test(
      'the file store reports unreadable bytes without leaking them',
      () async {
        File(
          '${secretRoot.path}/ref-1.secret',
        ).writeAsBytesSync(<int>[0xFF, 0xFE]);

        await expectLater(
          FileSecretStore(root: secretRoot).read('ref-1'),
          throwsA(
            isA<SecretNotFoundError>().having(
              (e) => e.toString(),
              'message',
              isNot(contains('0xFF')),
            ),
          ),
        );
      },
    );
  });
}

String _json(Object? value) => jsonEncode(value);
