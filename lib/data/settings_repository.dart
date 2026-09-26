// lib/data/settings_repository.dart — provider settings with a secret boundary.
//
// The repository is the only place that can turn a reference into a value, and it
// only does so when a caller asks for the secret explicitly. Everything that
// leaves this repository for a log, a UI or an export goes through
// [ProviderSettings.toRedactedJson].

import 'collection_repository.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'key_value_store.dart';
import 'provider_settings.dart';
import 'secrets.dart';

class SettingsRepository extends CollectionRepository<ProviderSettings> {
  SettingsRepository({
    required super.store,
    required this.secrets,
    super.codec = const ProviderSettingsCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.providerSettings);

  /// The secret provider. The data layer never reaches past this.
  final SecretStore secrets;

  /// Files a secret for [providerId] and records the reference in the provider.
  ///
  /// The value never passes through the record, an error message or a log line.
  /// Both writes happen inside one serialized read-modify-write, so the record
  /// can never end up pointing at a secret that was not written.
  Future<ProviderSettings> setSecret(String providerId, String value) async {
    if (value.isEmpty) {
      throw const InvalidDataError('a secret value must not be empty');
    }
    final ref = providerSecretRef(providerId);
    final record = await store.mutateRecord(collection, providerId, (
      current,
    ) async {
      if (current == null) {
        throw RecordNotFoundError(collection: collection, id: providerId);
      }
      // Value first: if the write fails, the record keeps its old reference
      // instead of pointing at a secret that is not there.
      await secrets.write(ref, value);
      return codec.encode(
        codec
            .decode(providerId, current)
            .copyWith(secretRef: ref, secretUpdatedAt: now, updatedAt: now),
      );
    });
    return codec.decode(providerId, record!.payload);
  }

  /// Removes the secret from the store and the reference from the record, in one
  /// critical section.
  Future<ProviderSettings> clearSecret(String providerId) async {
    final ref = providerSecretRef(providerId);
    final record = await store.mutateRecord(collection, providerId, (
      current,
    ) async {
      if (current == null) {
        throw RecordNotFoundError(collection: collection, id: providerId);
      }
      await secrets.delete(ref);
      return codec.encode(
        codec
            .decode(providerId, current)
            .copyWith(
              clearSecretRef: true,
              clearSecretUpdatedAt: true,
              updatedAt: now,
            ),
      );
    });
    return codec.decode(providerId, record!.payload);
  }

  /// The plaintext secret for a provider. The one deliberate exit from the
  /// boundary, called by the provider adapter that needs to authenticate.
  ///
  /// Throws [RecordNotFoundError] for an unknown provider and
  /// [SecretNotFoundError] when the record claims a secret the store does not
  /// have, because silently treating that as "no key" would look like an
  /// authentication failure much later.
  Future<String?> resolveSecret(String providerId) async {
    final settings = await find(providerId);
    if (settings == null) {
      throw RecordNotFoundError(collection: collection, id: providerId);
    }
    if (!settings.hasSecret) {
      return null;
    }
    final value = await secrets.read(settings.secretRef!);
    if (value == null) {
      throw SecretNotFoundError(settings.secretRef!);
    }
    return value;
  }

  @override
  Future<void> delete(String id) async {
    // The record goes first: a secret left behind is unreferenced and harmless,
    // a record pointing at a deleted secret would break authentication later.
    await super.delete(id);
    await secrets.delete(providerSecretRef(id));
  }

  /// A JSON-friendly snapshot for an export or a bug report.
  ///
  /// Every provider is redacted, so the result is safe to share.
  Future<Map<String, Object?>> exportRedactedSnapshot() async {
    final providers = await readAll();
    return <String, Object?>{
      'exportVersion': 1,
      'exportedAt': now.toIso8601String(),
      'providers': <Map<String, Object?>>[
        for (final provider in providers) provider.toRedactedJson(),
      ],
    };
  }

  /// The ids of records whose stored bytes contain any of [values].
  ///
  /// A safety net for "no record ever holds a secret": a plain scan of the stored
  /// envelopes, not of the decoded records, so a field the codec ignores is still
  /// caught.
  Future<List<String>> recordsLeakingSecrets(Iterable<String> values) async {
    final secrets = values.where((value) => value.isNotEmpty).toList();
    if (secrets.isEmpty) {
      return const <String>[];
    }
    final raw = store as RawStoreAccess;
    final leaking = <String>[];
    for (final id in await ids()) {
      final bytes = await raw.rawEnvelope(collection, id);
      if (bytes == null) {
        continue;
      }
      if (secrets.any(bytes.contains)) {
        leaking.add(id);
      }
    }
    leaking.sort();
    return List<String>.unmodifiable(leaking);
  }
}
