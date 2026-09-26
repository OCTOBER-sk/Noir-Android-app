// lib/data/mcp_server_repository.dart — the MCP servers a user has configured
// (R2/B2).
//
// The repository is the only way the composition root learns that an MCP server
// exists. It holds the record, and it holds the secret boundary for the bearer
// token: [setToken] files the value and the reference in one serialized
// read-modify-write, so a record can never point at a token that was not
// written, and [resolveToken] is the single place a token becomes readable —
// called by the transport factory, never by a screen or a log line.
import 'collection_repository.dart';
import 'collections.dart';
import 'mcp_server_settings.dart';
import 'data_errors.dart';
import 'key_value_store.dart';
import 'secrets.dart';

class McpServerRepository extends CollectionRepository<McpServerSettings> {
  McpServerRepository({
    required super.store,
    required this.secrets,
    super.codec = const McpServerSettingsCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.mcpServers);

  /// The secret provider. The data layer never reaches past this.
  final SecretStore secrets;

  /// A record that starts from the repository clock.
  McpServerSettings newServer({
    required String id,
    required String displayName,
    required String endpoint,
    String transportKind = 'http',
    List<String> allowedTools = const <String>[],
    List<String> backgroundSafeTools = const <String>[],
  }) {
    final stamp = now;
    return McpServerSettings(
      id: id,
      displayName: displayName,
      endpoint: endpoint,
      transportKind: transportKind,
      allowedTools: allowedTools,
      backgroundSafeTools: backgroundSafeTools,
      createdAt: stamp,
      updatedAt: stamp,
    );
  }

  /// Files [token] for the server [id] and records the reference.
  ///
  /// The value never passes through the record, an error message or a log line.
  /// Both writes happen inside one serialized read-modify-write, so a failure
  /// leaves the record pointing at the token that is actually stored.
  Future<McpServerSettings> setToken(String id, String token) async {
    if (token.isEmpty) {
      throw const InvalidDataError('a token value must not be empty');
    }
    final ref = mcpServerSecretRef(id);
    final record = await store.mutateRecord(collection, id, (current) async {
      if (current == null) {
        throw RecordNotFoundError(collection: collection, id: id);
      }
      // Value first: if the write fails, the record keeps its old reference
      // instead of pointing at a token that is not there.
      await secrets.write(ref, token);
      return codec
          .decode(id, current)
          .copyWith(secretRef: ref, secretUpdatedAt: now, updatedAt: now)
          .toJson();
    });
    return codec.decode(id, record!.payload);
  }

  /// Removes the token from the store and the reference from the record, in one
  /// critical section.
  Future<McpServerSettings> clearToken(String id) async {
    final ref = mcpServerSecretRef(id);
    final record = await store.mutateRecord(collection, id, (current) async {
      if (current == null) {
        throw RecordNotFoundError(collection: collection, id: id);
      }
      await secrets.delete(ref);
      return codec
          .decode(id, current)
          .copyWith(
            clearSecretRef: true,
            clearSecretUpdatedAt: true,
            updatedAt: now,
          )
          .toJson();
    });
    return codec.decode(id, record!.payload);
  }

  /// The bearer token for [id], or null when the server has none.
  ///
  /// Throws [RecordNotFoundError] for an unknown server and
  /// [SecretNotFoundError] when the record claims a token the store does not
  /// have, because treating that as "no credentials" would surface much later
  /// as an authentication failure the user cannot explain.
  Future<String?> resolveToken(String id) async {
    final settings = await find(id);
    if (settings == null) {
      throw RecordNotFoundError(collection: collection, id: id);
    }
    if (!settings.hasSecret) return null;
    final value = await secrets.read(settings.secretRef!);
    if (value == null) {
      throw SecretNotFoundError(settings.secretRef!);
    }
    return value;
  }

  @override
  Future<void> delete(String id) async {
    // The record goes first: a token left behind is unreferenced and harmless,
    // a record pointing at a deleted token would break the next connection.
    await super.delete(id);
    await secrets.delete(mcpServerSecretRef(id));
  }

  /// Every configured server, redacted. Safe to export or show.
  ///
  /// [onUnreadable] is passed straight through, so a record that cannot be
  /// decoded is reported by the caller rather than quietly missing.
  Future<List<Map<String, Object?>>> exportRedacted({
    void Function(String id, Object error)? onUnreadable,
  }) async {
    return <Map<String, Object?>>[
      for (final server in await readAll(onUnreadable: onUnreadable))
        server.toRedactedJson(),
    ];
  }

  /// The ids of records whose stored bytes contain any of [values].
  ///
  /// The same safety net the provider settings carry: a record must never hold
  /// the token it points at, and this scans the stored envelopes rather than the
  /// decoded records so a field the codec ignores is still caught.
  Future<List<String>> recordsLeakingTokens(Iterable<String> values) async {
    final tokens = values.where((value) => value.isNotEmpty).toList();
    if (tokens.isEmpty) return const <String>[];
    final raw = store as RawStoreAccess;
    final leaking = <String>[];
    for (final id in await ids()) {
      final bytes = await raw.rawEnvelope(collection, id);
      if (bytes == null) continue;
      if (tokens.any(bytes.contains)) leaking.add(id);
    }
    leaking.sort();
    return List<String>.unmodifiable(leaking);
  }
}
