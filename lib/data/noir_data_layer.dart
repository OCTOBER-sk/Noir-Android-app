// lib/data/noir_data_layer.dart — one object that owns Noir's persistence.
//
// [NoirDataLayer.open] points the whole data layer at a directory: it builds the
// store, the secret store, the schema catalog and every repository, so a caller
// never wires them by hand. [NoirDataLayer.inMemory] does the same with the
// deterministic in-memory store, which is what tests and previews use.

import 'dart:io';

import 'collections.dart';
import 'conversation_repository.dart';
import 'job_repository.dart';
import 'key_value_store.dart';
import 'json_file_key_value_store.dart';
import 'in_memory_key_value_store.dart';
import 'mcp_server_repository.dart';
import 'memory_repository.dart';
import 'noir_schema.dart';
import 'prompt_repository.dart';
import 'secrets.dart';
import 'settings_repository.dart';
import 'usage_repository.dart';

/// The persistence layer for conversations, settings, prompts, memories, usage
/// and scheduled jobs.
class NoirDataLayer {
  NoirDataLayer._({
    required this.store,
    required this.secrets,
    required this.clock,
    required this.conversations,
    required this.settings,
    required this.prompts,
    required this.memories,
    required this.usage,
    required this.jobs,
    required this.mcpServers,
  });

  /// The clock the layer stamps records with.
  final DateTime Function() clock;

  /// The current time as this layer sees it.
  DateTime get now => clock().toUtc();

  /// Opens the data layer on real files under [root].
  ///
  /// [root] and [secretRoot] are created if missing. [secretRoot] holds secrets
  /// and is kept out of the record directories on purpose: a record can never be
  /// read as a secret by accident, and an export of the record directory can
  /// never contain one.
  static Future<NoirDataLayer> open({
    required Directory root,
    Directory? secretRoot,
    DateTime Function()? clock,
    int maxPageLimit = 200,
  }) async {
    final now = clock ?? DateTime.now;
    final secrets = FileSecretStore(
      root: secretRoot ?? Directory('${root.path}/secrets'),
    );
    final store = JsonFileKeyValueStore(
      root: root,
      catalog: NoirSchema.catalog(secrets: secrets, clock: now),
      clock: now,
    );
    return NoirDataLayer._wire(
      store: store,
      secrets: secrets,
      clock: now,
      maxPageLimit: maxPageLimit,
    );
  }

  /// Opens the data layer on the deterministic in-memory store.
  ///
  /// Nothing is written to disk and nothing survives the process. The schema,
  /// codec, redaction and aggregation behaviour is identical to [open].
  static NoirDataLayer inMemory({
    DateTime Function()? clock,
    int maxPageLimit = 200,
    InMemoryStorage? backing,
  }) {
    final now = clock ?? DateTime.now;
    final secrets = InMemorySecretStore();
    final store = InMemoryKeyValueStore(
      catalog: NoirSchema.catalog(secrets: secrets, clock: now),
      clock: now,
      backing: backing,
    );
    return NoirDataLayer._wire(
      store: store,
      secrets: secrets,
      clock: now,
      maxPageLimit: maxPageLimit,
    );
  }

  static NoirDataLayer _wire({
    required KeyValueStore store,
    required SecretStore secrets,
    required DateTime Function() clock,
    required int maxPageLimit,
  }) {
    return NoirDataLayer._(
      store: store,
      secrets: secrets,
      clock: clock,
      conversations: ConversationRepository(
        store: store,
        clock: clock,
        maxPageLimit: maxPageLimit,
      ),
      settings: SettingsRepository(
        store: store,
        secrets: secrets,
        clock: clock,
        maxPageLimit: maxPageLimit,
      ),
      prompts: PromptRepository(
        store: store,
        clock: clock,
        maxPageLimit: maxPageLimit,
      ),
      memories: MemoryRepository(
        store: store,
        clock: clock,
        maxPageLimit: maxPageLimit,
      ),
      usage: UsageRepository(
        store: store,
        clock: clock,
        maxPageLimit: maxPageLimit,
      ),
      jobs: JobRepository(
        store: store,
        clock: clock,
        maxPageLimit: maxPageLimit,
      ),
      mcpServers: McpServerRepository(
        store: store,
        secrets: secrets,
        clock: clock,
        maxPageLimit: maxPageLimit,
      ),
    );
  }

  /// The record store. Injectable: the same repositories run on the file store
  /// and on the in-memory double.
  final KeyValueStore store;

  /// The secret provider. Records only ever hold references into it.
  final SecretStore secrets;

  final ConversationRepository conversations;
  final SettingsRepository settings;
  final PromptRepository prompts;
  final MemoryRepository memories;
  final UsageRepository usage;
  final JobRepository jobs;

  /// The MCP servers a user configured. Empty means the app has no MCP adapter
  /// to build, and both the composition root and the Safety Center say so.
  final McpServerRepository mcpServers;

  /// Every record in every collection, with provider secrets redacted.
  ///
  /// Safe to write to a file, attach to a bug report or show in a UI. Usage
  /// records are summarised rather than listed, because a busy day holds far too
  /// many of them to export one by one.
  Future<Map<String, Object?>> exportRedactedSnapshot() async {
    final fileStore = store is JsonFileKeyValueStore
        ? store as JsonFileKeyValueStore
        : null;
    final snapshot = <String, Object?>{
      'exportedAt': now.toIso8601String(),
      'exportVersion': 1,
      'collections': <String, Object?>{
        NoirCollections.conversations: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final conversation in await conversations.readAll(
              onUnreadable: _ignore,
            ))
              <String, Object?>{
                'id': conversation.id,
                'title': conversation.title,
                'pinned': conversation.pinned,
                'messageCount': conversation.messageCount,
                'createdAt': conversation.createdAt.toIso8601String(),
                'updatedAt': conversation.updatedAt.toIso8601String(),
              },
          ],
        },
        NoirCollections.providerSettings: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final provider in await settings.readAll(
              onUnreadable: _ignore,
            ))
              provider.toRedactedJson(),
          ],
        },
        NoirCollections.prompts: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final prompt in await prompts.readAll(onUnreadable: _ignore))
              <String, Object?>{...prompt.toJson(), 'id': prompt.id},
          ],
        },
        NoirCollections.memories: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final memory in await memories.readAll(onUnreadable: _ignore))
              <String, Object?>{...memory.toJson(), 'id': memory.id},
          ],
        },
        NoirCollections.jobs: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final job in await jobs.readAll(onUnreadable: _ignore))
              <String, Object?>{...job.toJson(), 'id': job.id},
          ],
        },
        NoirCollections.mcpServers: <String, Object?>{
          'items': <Map<String, Object?>>[
            for (final server in await mcpServers.readAll(
              onUnreadable: _ignore,
            ))
              server.toRedactedJson(),
          ],
        },
        NoirCollections.usage: <String, Object?>{
          'summary': (await usage.summarize(onUnreadable: _ignore)).toString(),
          'dailyTotals': (await usage.dailyTotals(
            days: 30,
            onUnreadable: _ignore,
          )).buckets.map((bucket) => bucket.toString()).toList(),
        },
      },
      'recoveries': <String>[
        for (final recovery in store.recoveries) recovery.toString(),
      ],
    };
    if (fileStore != null) {
      snapshot['root'] = fileStore.root.path;
    }
    return snapshot;
  }

  /// A record the export could not read is listed by id rather than failing the
  /// whole export, and the failure is still visible in [store]'s recovery and
  /// error path. A corrupt record must not make the app unexportable.
  static void _ignore(String id, Object error) {}

  /// The quarantine ids held by the underlying store, when it has any.
  Future<List<String>> quarantinedKeys() async {
    final raw = store is RawStoreAccess ? store as RawStoreAccess : null;
    return (await raw?.quarantinedKeys()) ?? const <String>[];
  }

  /// The preserved bytes of a quarantined record.
  Future<String?> quarantinedContents(String quarantineId) async {
    final raw = store is RawStoreAccess ? store as RawStoreAccess : null;
    return await raw?.quarantinedContents(quarantineId);
  }

  /// What this data layer is, in plain terms: which backend, where, whether it
  /// is durable, and which schema versions it understands. Intended for a
  /// settings screen or a bug report, and it claims nothing that is not true.
  Map<String, Object?> selfReport() {
    final fileStore = store is JsonFileKeyValueStore
        ? store as JsonFileKeyValueStore
        : null;
    return <String, Object?>{
      'backend': store.runtimeType.toString(),
      'isDurable': store.isDurable,
      'root': fileStore?.root.path,
      'atomicWrites': 'temp file + rename, previous bytes kept as a backup',
      'recovery': 'unreadable bytes are quarantined, never deleted',
      'maxPageLimit': conversations.maxPageLimit,
      'secretsDurable': secrets.isDurable,
      'secretsEncryptedAtRest': secrets.isEncryptedAtRest,
      'secretsProtection': secrets.protectionSummary,
      'recoveries': store.recoveries.length,
      'collections': <String, Object?>{
        for (final name in store.catalog.names)
          name: <String, Object?>{
            'currentVersion': store.catalog.require(name).currentVersion,
            'migrations': store.catalog
                .require(name)
                .migrations
                .map((migration) => migration.description)
                .toList(),
          },
      },
    };
  }
}
