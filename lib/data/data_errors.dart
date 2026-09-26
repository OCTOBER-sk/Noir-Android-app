// lib/data/data_errors.dart — the closed error hierarchy of the data layer.
//
// Every failure mode of the persistence layer is an explicit, typed error.
// Nothing in lib/data/ fails silently, and no failure discards bytes.
library;

/// Base class for every error raised by lib/data/.
sealed class DataStoreException implements Exception {
  const DataStoreException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    final suffix = cause == null ? '' : ' (cause: $cause)';
    return '$runtimeType: $message$suffix';
  }
}

/// An id or collection name is not usable as a storage key.
final class StorageKeyError extends DataStoreException {
  const StorageKeyError(this.key, String reason)
    : super('storage key "$key" rejected: $reason');

  /// The offending id (or collection name).
  final String key;
}

/// Operation on a collection that has no registered schema.
final class UnknownCollectionError extends DataStoreException {
  const UnknownCollectionError(this.collection)
    : super('no schema registered for collection "$collection"');

  final String collection;
}

/// A schema version outside the supported range was requested.
final class InvalidSchemaVersionError extends DataStoreException {
  const InvalidSchemaVersionError({
    required this.collection,
    required this.requestedVersion,
    required this.currentVersion,
  }) : super(
         'collection "$collection" cannot be written at schema version '
         '$requestedVersion (supported: 1..$currentVersion)',
       );

  final String collection;
  final int requestedVersion;
  final int currentVersion;
}

/// Data on disk was written by a newer version of the app.
final class SchemaVersionTooNewError extends DataStoreException {
  const SchemaVersionTooNewError({
    required this.collection,
    required this.onDiskVersion,
    required this.supportedVersion,
  }) : super(
         'collection "$collection" holds schema version $onDiskVersion but '
         'this build only understands up to $supportedVersion',
       );

  final String collection;
  final int onDiskVersion;
  final int supportedVersion;
}

/// There is no registered migration step between two schema versions.
final class MissingMigrationError extends DataStoreException {
  const MissingMigrationError({
    required this.collection,
    required this.fromVersion,
    required this.toVersion,
  }) : super(
         'collection "$collection" has no migration from schema version '
         '$fromVersion to $toVersion',
       );

  final String collection;
  final int fromVersion;
  final int toVersion;
}

/// A registered migration step threw. The stored record is left untouched.
final class MigrationFailedError extends DataStoreException {
  const MigrationFailedError({
    required this.collection,
    required this.fromVersion,
    required this.toVersion,
    required Object failure,
  }) : super(
         'migration $fromVersion -> $toVersion for collection "$collection" '
         'failed; the stored record was not modified',
         cause: failure,
       );

  final String collection;
  final int fromVersion;
  final int toVersion;

  /// The original error thrown by the migration callback.
  Object get failure => cause!;
}

/// A [CollectionSchema] was registered with an impossible migration chain.
final class SchemaRegistrationError extends DataStoreException {
  const SchemaRegistrationError(super.message);
}

/// A payload could not be turned into JSON.
final class StorageEncodeError extends DataStoreException {
  const StorageEncodeError(super.message, {super.cause});
}

/// A stored envelope could not be read back. Treated as corruption.
final class StorageDecodeError extends DataStoreException {
  const StorageDecodeError(super.message, {super.cause});
}

/// A stored record is unreadable and no good copy exists. The bytes are kept.
final class CorruptRecordError extends DataStoreException {
  const CorruptRecordError({
    required this.collection,
    required this.id,
    required this.quarantineId,
    required String detail,
    super.cause,
  }) : super(
         'record "$collection/$id" is corrupt ($detail); bytes preserved as '
         'quarantine "$quarantineId"',
       );

  final String collection;
  final String id;

  /// Where the unreadable bytes were preserved for manual repair.
  final String quarantineId;
}

/// A stored record has the right envelope but the wrong shape for its codec.
final class MalformedRecordError extends DataStoreException {
  const MalformedRecordError({
    required this.collection,
    required this.id,
    required this.field,
    required String detail,
    super.cause,
  }) : super(
         'record "$collection/$id" has an invalid "$field" ($detail); the '
         'stored bytes were left untouched',
       );

  final String collection;
  final String id;
  final String field;
}

/// The filesystem refused an operation. Never swallowed.
final class StorageIoError extends DataStoreException {
  const StorageIoError({
    required this.path,
    required this.operation,
    required super.cause,
  }) : super('filesystem $operation failed for "$path"');

  final String path;
  final String operation;
}

/// A value handed to the data layer is not usable, with no more specific error
/// to blame.
final class InvalidDataError extends DataStoreException {
  const InvalidDataError(super.message, {super.cause});
}

/// A page request is outside the supported range.
final class InvalidPageRequestError extends DataStoreException {
  const InvalidPageRequestError(super.message);
}

/// A repository update targeted a record that does not exist.
final class RecordNotFoundError extends DataStoreException {
  const RecordNotFoundError({required this.collection, required this.id})
    : super('no record "$collection/$id"');

  final String collection;
  final String id;
}

/// A secret reference was requested that the secret store does not hold.
final class SecretNotFoundError extends DataStoreException {
  const SecretNotFoundError(this.ref) : super('no secret for reference "$ref"');

  final String ref;
}

/// A scheduled job description is not usable.
final class InvalidScheduleError extends DataStoreException {
  const InvalidScheduleError(super.message);
}
