// lib/data/noir_schema.dart — the schema catalog Noir actually ships with.
//
// One place declares every collection, its current version and every migration
// that reaches it. Registering a collection that no repository uses is a bug
// this file cannot catch, so it stays deliberately short: a new collection
// means a new line here and a new schema version if the shape changed.

import 'collections.dart';
import 'data_errors.dart';
import 'schema.dart';
import 'secrets.dart';

/// Collection schema versions and the migrations between them.
abstract final class NoirSchema {
  /// Conversations are at v2: v1 stored message text as `body` and had no
  /// `pinned` flag.
  static const int conversationsVersion = 2;

  /// Provider settings are at v2: v1 stored the API key in plaintext inside the
  /// record, v2 stores only a reference into the secret store.
  static const int providerSettingsVersion = 2;

  static const int promptsVersion = 1;
  static const int memoriesVersion = 1;
  static const int usageVersion = 1;
  static const int jobsVersion = 1;

  /// MCP server records are at v1: the first shape already keeps the bearer
  /// token behind a secret reference, so there is no plaintext migration to do.
  static const int mcpServersVersion = 1;

  /// Builds the catalog. [secrets] is required for the provider-settings
  /// migration: it is the boundary that moves a v1 plaintext key out of the
  /// record and behind the secret provider.
  static SchemaCatalog catalog({
    SecretStore? secrets,
    DateTime Function()? clock,
  }) {
    final catalog = SchemaCatalog();
    catalog.register(
      CollectionSchema(
        name: NoirCollections.conversations,
        currentVersion: conversationsVersion,
        migrations: <SchemaMigration>[
          SchemaMigration(
            fromVersion: 1,
            toVersion: 2,
            description:
                'conversations: message "body" -> "text", '
                '"streaming" -> "isStreaming", add "pinned"',
            migrate: migrateConversationV1ToV2,
          ),
        ],
      ),
    );
    catalog.register(
      CollectionSchema(
        name: NoirCollections.providerSettings,
        currentVersion: providerSettingsVersion,
        migrations: <SchemaMigration>[
          SchemaMigration(
            fromVersion: 1,
            toVersion: 2,
            description:
                'provider settings: move the plaintext "apiKey" into '
                'the secret store and keep only a reference',
            migrate: secrets == null
                ? refuseSecretMigration
                : migrateProviderSettingsV1ToV2(secrets, clock ?? DateTime.now),
          ),
        ],
      ),
    );
    catalog.register(
      CollectionSchema(
        name: NoirCollections.prompts,
        currentVersion: promptsVersion,
      ),
    );
    catalog.register(
      CollectionSchema(
        name: NoirCollections.memories,
        currentVersion: memoriesVersion,
      ),
    );
    catalog.register(
      CollectionSchema(
        name: NoirCollections.usage,
        currentVersion: usageVersion,
      ),
    );
    catalog.register(
      CollectionSchema(name: NoirCollections.jobs, currentVersion: jobsVersion),
    );
    catalog.register(
      CollectionSchema(
        name: NoirCollections.mcpServers,
        currentVersion: mcpServersVersion,
      ),
    );
    return catalog;
  }

  /// v1 -> v2 for conversations.
  static Map<String, Object?> migrateConversationV1ToV2(
    Map<String, Object?> payload,
  ) {
    final raw = payload['messages'];
    final migrated = <String, Object?>{
      ...payload,
      'pinned': payload['pinned'] ?? false,
    };
    if (raw is List) {
      migrated['messages'] = <Object?>[
        for (final entry in raw) _migrateMessage(entry),
      ];
    }
    return migrated;
  }

  static Object? _migrateMessage(Object? entry) {
    if (entry is! Map) {
      // Left untouched on purpose: the codec will name the exact bad entry
      // instead of the migration guessing what it meant.
      return entry;
    }
    final message = Map<String, Object?>.from(entry);
    final body = message['body'];
    message.remove('body');
    message['text'] = body ?? message['text'] ?? '';
    message['isStreaming'] =
        message['isStreaming'] ?? message['streaming'] ?? false;
    message.remove('streaming');
    return message;
  }

  /// v1 -> v2 for provider settings.
  ///
  /// The v1 format kept the API key in the record itself. Moving it into the
  /// secret store is the whole point of the step: after the migration the record
  /// holds a reference, never the secret.
  static PayloadMigration migrateProviderSettingsV1ToV2(
    SecretStore secrets,
    DateTime Function() clock,
  ) {
    return (Map<String, Object?> payload) {
      final migrated = Map<String, Object?>.of(payload);
      // v1 named the label "name" and duplicated the id; v2 takes the label from
      // "displayName" and keeps the id in the storage key only.
      migrated.remove('name');
      migrated.remove('id');
      if (migrated['displayName'] == null && payload['name'] != null) {
        migrated['displayName'] = payload['name'];
      }
      migrated.remove('apiKey');
      final plaintext = payload['apiKey'];
      if (plaintext is String && plaintext.isNotEmpty) {
        final ref = _legacySecretRef(payload);
        secrets.write(ref, plaintext);
        migrated['secretRef'] = ref;
        migrated['secretUpdatedAt'] = clock().toUtc().toIso8601String();
      }
      return migrated;
    };
  }

  /// The reference a migrated v1 record's secret is filed under.
  static String _legacySecretRef(Map<String, Object?> payload) {
    final id = payload['id'];
    final name = payload['name'];
    final basis = (id ?? name ?? 'provider').toString();
    final sanitised = basis.replaceAll(RegExp('[^A-Za-z0-9._-]'), '-');
    return 'migrated-$sanitised';
  }

  /// Used when a build tries to migrate v1 settings without a secret store to
  /// migrate into. Failing loudly is the only safe option: the alternative is
  /// dropping the key or leaving it in the clear.
  static Map<String, Object?> refuseSecretMigration(
    Map<String, Object?> payload,
  ) {
    throw const MigrationFailedError(
      collection: NoirCollections.providerSettings,
      fromVersion: 1,
      toVersion: 2,
      failure: _NoSecretStoreFailure(),
    );
  }
}

class _NoSecretStoreFailure implements Exception {
  const _NoSecretStoreFailure();

  @override
  String toString() =>
      'provider settings from schema v1 hold a plaintext API key, but this '
      'build has no secret store to migrate it into. Refusing to read the '
      'record rather than leaving the key in the clear.';
}
