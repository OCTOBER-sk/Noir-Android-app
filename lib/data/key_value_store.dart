// lib/data/key_value_store.dart — the storage contract used by every repository.
//
// A store is a collection-keyed map of JSON payloads with four hard guarantees:
// atomic writes (temp file + rename, never a half-written record), explicit
// schema versioning with forward-only migrations, corruption recovery that keeps
// the bad bytes, and serialized read-modify-write so concurrent updates to one
// key cannot be lost.
//
// Backends only supply the primitive file operations; all of the behaviour above
// lives in [KeyValueStoreBase] so the real file store and the deterministic
// in-memory double cannot drift apart.

import 'dart:async';
import 'dart:convert';

import 'data_errors.dart';
import 'schema.dart';

/// A record as it exists in storage: its schema version, when it was written and
/// the payload itself.
class StoredRecord {
  const StoredRecord({
    required this.schemaVersion,
    required this.writtenAt,
    required this.payload,
  });

  final int schemaVersion;
  final DateTime writtenAt;

  /// A fresh, mutable copy: callers can hand this to a mutator without the
  /// store observing the change.
  final Map<String, Object?> payload;
}

/// Why the store had to step in while reading a record.
enum StoreRecoveryReason {
  /// The primary bytes were unreadable; a good backup was used instead.
  corruptPrimary,

  /// The primary was gone; a good backup was used instead.
  missingPrimary,

  /// The record could not be read and no good copy exists. The bytes are kept.
  unrecoverable,
}

/// One entry of the store's recovery log.
class StoreRecovery {
  const StoreRecovery({
    required this.collection,
    required this.id,
    required this.reason,
    required this.quarantineId,
    required this.detail,
  });

  final String collection;
  final String id;
  final StoreRecoveryReason reason;

  /// Where the unreadable bytes were preserved, when there were any.
  final String? quarantineId;
  final String detail;

  @override
  String toString() =>
      'StoreRecovery($collection/$id, $reason, quarantine: $quarantineId, '
      '$detail)';
}

/// The storage contract every backend implements.
abstract interface class KeyValueStore {
  SchemaCatalog get catalog;

  /// Recovery events observed by this store instance, oldest first.
  List<StoreRecovery> get recoveries;

  /// Whether records survive a process restart. The in-memory double says no.
  bool get isDurable;

  /// The record as stored, or null when it does not exist.
  Future<StoredRecord?> readRecord(String collection, String id);

  /// The payload as stored, or null when it does not exist.
  Future<Map<String, Object?>?> read(String collection, String id);

  /// Writes [payload] at the collection's current schema version.
  Future<void> write(
    String collection,
    String id,
    Map<String, Object?> payload,
  );

  /// Writes [payload] stamped with an explicit [schemaVersion].
  ///
  /// Used to seed or import records written by an older build; the migration
  /// chain then runs on read. Refuses versions this build does not know.
  Future<void> writeAtVersion(
    String collection,
    String id,
    int schemaVersion,
    Map<String, Object?> payload,
  );

  /// Applies [mutate] to the stored payload inside the store's write queue and
  /// persists the result. The callback receives null for a missing record and may
  /// be asynchronous, which is how a record and a secret it references are
  /// written in one critical section.
  ///
  /// Returning null from the callback deletes the record. Concurrent calls for
  /// the same key are serialized, so read-modify-write is atomic and a throwing
  /// callback leaves the record exactly as it was.
  Future<StoredRecord?> mutateRecord(
    String collection,
    String id,
    FutureOr<Map<String, Object?>?> Function(Map<String, Object?>? current)
    mutate,
  );

  /// Removes the record. Deleting a record that does not exist is a no-op.
  Future<void> delete(String collection, String id);

  /// Whether the store holds a record, even if it cannot currently be read.
  Future<bool> exists(String collection, String id);

  /// The ids in [collection], sorted lexicographically.
  Future<List<String>> listIds(String collection);
}

/// Fault injection for tests and for rehearsing disk failures in production.
abstract interface class FaultInjectableStore implements KeyValueStore {
  /// Fail the next write before anything is staged.
  void failNextWrite([Object? error]);

  /// Fail the next write after it was staged but before it became visible.
  void failNextSwap([Object? error]);

  /// Fail the next delete before anything is removed.
  void failNextDelete([Object? error]);

  void clearFaults();
}

/// Low-level access to the raw bytes behind a record.
///
/// Used for repair tooling and for tests that need to prove what is actually on
/// disk (determinism, quarantine contents, "the failed migration changed
/// nothing"). It bypasses every schema check on purpose.
abstract interface class RawStoreAccess {
  /// The stored envelope text for a record, or null.
  Future<String?> rawEnvelope(String collection, String id);

  /// Replaces the stored bytes for a record *without* touching its backup and
  /// without any validation, modelling damage that came from outside the store:
  /// a truncated file, a bad sync, a half-flushed write from an older build.
  ///
  /// This deliberately throws away the bytes that were there, which is why it is
  /// not a write path: it exists so corruption, quarantine and recovery can be
  /// exercised against real files.
  Future<void> damagePrimary(String collection, String id, String contents);

  /// Publishes [contents] as the record, keeping the usual atomic write path.
  /// Used by repair tooling to install a hand-recovered record.
  Future<void> writeRawEnvelope(String collection, String id, String contents);

  /// The newest quarantine id holding a copy of this record's bad bytes.
  Future<String?> quarantineIdFor(String collection, String id);

  /// The preserved bytes for a quarantine id, or null.
  Future<String?> quarantinedContents(String quarantineId);

  /// Every quarantine id this backend knows about, sorted.
  Future<List<String>> quarantinedKeys();
}

/// The longest id a record may have.
const int maxRecordIdLength = 120;

final RegExp _recordIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$');

/// Validates [id] and returns the storage key for it.
///
/// Ids become path segments on disk, so anything that could escape the
/// collection directory, collide with a backup/temp file, or confuse a listing
/// is refused here rather than sanitised: a rewritten key would silently
/// orphan the record the caller asked for.
String storageKey(String collection, String id) {
  if (id.isEmpty) {
    throw StorageKeyError(id, 'an id must not be empty');
  }
  if (id.length > maxRecordIdLength) {
    throw StorageKeyError(
      id,
      'an id must be at most $maxRecordIdLength characters, got ${id.length}',
    );
  }
  if (!_recordIdPattern.hasMatch(id)) {
    throw StorageKeyError(
      id,
      'an id must match ${_recordIdPattern.pattern} (letters, digits, dot, '
      'underscore and dash only)',
    );
  }
  if (id.contains('__')) {
    throw StorageKeyError(
      id,
      'an id must not contain "__", which is reserved for store side files',
    );
  }
  if (!CollectionSchema.collectionNamePattern.hasMatch(collection)) {
    throw StorageKeyError(
      collection,
      'a collection name must match '
      '${CollectionSchema.collectionNamePattern.pattern}',
    );
  }
  return '$collection/$id';
}

/// The id used for a [storageKey]'s quarantine copy. Flat, file-name safe and
/// impossible to confuse with a record id (ids never contain `~` or `#`).
String quarantineIdFor(String key, int index) =>
    '${key.replaceAll('/', '~')}#$index';

final RegExp _quarantineIdPattern = RegExp(
  r'^[a-z][a-z0-9_]{0,63}~[A-Za-z0-9][A-Za-z0-9._-]{0,119}#[0-9]{1,9}$',
);

/// Throws unless [id] is a quarantine id produced by [quarantineIdFor].
String checkedQuarantineId(String id) {
  if (!_quarantineIdPattern.hasMatch(id)) {
    throw StorageKeyError(id, 'not a quarantine id');
  }
  return id;
}

/// Shared implementation of [KeyValueStore].
///
/// Backends implement the primitive operations below; versioning, migration,
/// corruption recovery, atomicity and the write queue are handled here so that
/// every backend behaves identically.
abstract class KeyValueStoreBase
    implements KeyValueStore, FaultInjectableStore, RawStoreAccess {
  KeyValueStoreBase({required this.catalog, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  @override
  final SchemaCatalog catalog;

  final DateTime Function() _clock;
  final List<StoreRecovery> _recoveries = <StoreRecovery>[];
  final StoreFaults _faults = StoreFaults();
  Future<void> _writeQueue = Future<void>.value();

  @override
  List<StoreRecovery> get recoveries =>
      List<StoreRecovery>.unmodifiable(_recoveries);

  /// The clock used to stamp writes. Injected so tests are deterministic.
  DateTime get now => _clock().toUtc();

  // ---------------------------------------------------------------------
  // Primitives supplied by a backend.
  // ---------------------------------------------------------------------

  /// The current bytes for [key], or null.
  String? readPrimary(String key);

  /// The previous good bytes for [key], or null.
  String? readBackup(String key);

  /// Publishes [contents] for [key] atomically: stage it, then swap it in, and
  /// rotate the previous bytes to the backup. Calls [throwIfSwapFault]
  /// between staging and swapping.
  void writePrimaryAtomically(String key, String contents);

  /// Publishes [contents] over the primary bytes of [key] without rotating the
  /// backup. Models external damage; see [RawStoreAccess.damagePrimary].
  void damagePrimaryBytes(String key, String contents);

  /// Removes the primary and the backup for [key].
  void removeRecordFiles(String key);

  /// Every record id in [collection], sorted.
  List<String> listRecordIds(String collection);

  /// The index to use for the next quarantine copy of [key].
  int nextQuarantineIndex(String key);

  /// Copies (or moves) the primary bytes of [key] into quarantine and returns
  /// the quarantine id.
  String quarantinePrimary(String key, {required bool move});

  /// The newest quarantine id for [key], or null.
  String? findQuarantineId(String key);

  /// The preserved bytes of a quarantine id, or null.
  String? readQuarantine(String id);

  /// Every quarantine id, sorted.
  List<String> listQuarantineIds();

  // ---------------------------------------------------------------------
  // Fault injection.
  // ---------------------------------------------------------------------

  @override
  void failNextWrite([Object? error]) => _faults.failNextWrite(error);

  @override
  void failNextSwap([Object? error]) => _faults.failNextSwap(error);

  @override
  void failNextDelete([Object? error]) => _faults.failNextDelete(error);

  @override
  void clearFaults() => _faults.clear();

  /// Called by a backend between staging a write and publishing it.
  void throwIfSwapFault() => _faults.throwIfSwap();

  // ---------------------------------------------------------------------
  // KeyValueStore.
  // ---------------------------------------------------------------------

  @override
  Future<StoredRecord?> readRecord(String collection, String id) {
    return _serialized<StoredRecord?>(() => _readRecordLocked(collection, id));
  }

  @override
  Future<Map<String, Object?>?> read(String collection, String id) async {
    final record = await readRecord(collection, id);
    return record?.payload;
  }

  @override
  Future<void> write(
    String collection,
    String id,
    Map<String, Object?> payload,
  ) async {
    final schema = catalog.require(collection);
    await writeAtVersion(collection, id, schema.currentVersion, payload);
  }

  @override
  Future<void> writeAtVersion(
    String collection,
    String id,
    int schemaVersion,
    Map<String, Object?> payload,
  ) {
    return _serialized<void>(() {
      final schema = catalog.require(collection);
      final key = storageKey(collection, id);
      if (schemaVersion < 1) {
        throw InvalidSchemaVersionError(
          collection: collection,
          requestedVersion: schemaVersion,
          currentVersion: schema.currentVersion,
        );
      }
      if (schemaVersion > schema.currentVersion) {
        throw SchemaVersionTooNewError(
          collection: collection,
          onDiskVersion: schemaVersion,
          supportedVersion: schema.currentVersion,
        );
      }
      _faults.throwIfWrite();
      final writtenAt = now;
      writePrimaryAtomically(
        key,
        encodeEnvelope(
          schemaVersion: schemaVersion,
          writtenAt: writtenAt,
          payload: payload,
        ),
      );
    });
  }

  @override
  Future<StoredRecord?> mutateRecord(
    String collection,
    String id,
    FutureOr<Map<String, Object?>?> Function(Map<String, Object?>? current)
    mutate,
  ) {
    return _serialized<StoredRecord?>(() async {
      final schema = catalog.require(collection);
      final key = storageKey(collection, id);
      final current = _readRecordLocked(collection, id);
      final next = await mutate(
        current == null ? null : Map<String, Object?>.of(current.payload),
      );
      if (next == null) {
        _faults.throwIfDelete();
        removeRecordFiles(key);
        return null;
      }
      _faults.throwIfWrite();
      final writtenAt = now;
      writePrimaryAtomically(
        key,
        encodeEnvelope(
          schemaVersion: schema.currentVersion,
          writtenAt: writtenAt,
          payload: next,
        ),
      );
      return StoredRecord(
        schemaVersion: schema.currentVersion,
        writtenAt: writtenAt,
        payload: next,
      );
    });
  }

  @override
  Future<void> delete(String collection, String id) {
    return _serialized<void>(() {
      catalog.require(collection);
      final key = storageKey(collection, id);
      _faults.throwIfDelete();
      removeRecordFiles(key);
    });
  }

  @override
  Future<bool> exists(String collection, String id) async {
    catalog.require(collection);
    final key = storageKey(collection, id);
    return readPrimary(key) != null || readBackup(key) != null;
  }

  @override
  Future<List<String>> listIds(String collection) async {
    catalog.require(collection);
    return listRecordIds(collection);
  }

  // ---------------------------------------------------------------------
  // RawStoreAccess.
  // ---------------------------------------------------------------------

  @override
  Future<String?> rawEnvelope(String collection, String id) async {
    catalog.require(collection);
    return readPrimary(storageKey(collection, id));
  }

  @override
  Future<void> writeRawEnvelope(String collection, String id, String contents) {
    return _serialized<void>(() {
      catalog.require(collection);
      final key = storageKey(collection, id);
      _faults.throwIfWrite();
      writePrimaryAtomically(key, contents);
    });
  }

  @override
  Future<void> damagePrimary(String collection, String id, String contents) {
    return _serialized<void>(() {
      catalog.require(collection);
      final key = storageKey(collection, id);
      _faults.throwIfWrite();
      damagePrimaryBytes(key, contents);
    });
  }

  @override
  Future<String?> quarantineIdFor(String collection, String id) async {
    catalog.require(collection);
    return findQuarantineId(storageKey(collection, id));
  }

  @override
  Future<String?> quarantinedContents(String quarantineId) async =>
      readQuarantine(checkedQuarantineId(quarantineId));

  @override
  Future<List<String>> quarantinedKeys() async => listQuarantineIds();

  // ---------------------------------------------------------------------
  // Envelope encoding.
  // ---------------------------------------------------------------------

  /// Encodes a versioned envelope. Deterministic: the same payload, version and
  /// clock always produce the same bytes.
  String encodeEnvelope({
    required int schemaVersion,
    required DateTime writtenAt,
    required Map<String, Object?> payload,
  }) {
    try {
      return jsonEncode(<String, Object?>{
        'schemaVersion': schemaVersion,
        'writtenAt': writtenAt.toUtc().toIso8601String(),
        'payload': payload,
      });
    } catch (error) {
      throw StorageEncodeError(
        'payload for schema version $schemaVersion cannot be encoded as JSON',
        cause: error,
      );
    }
  }

  StoredRecord decodeEnvelope(String contents) {
    final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } catch (error) {
      throw StorageDecodeError('stored bytes are not valid JSON', cause: error);
    }
    if (decoded is! Map) {
      throw StorageDecodeError(
        'stored bytes are a ${decoded.runtimeType}, not a JSON object',
      );
    }
    final envelope = Map<String, Object?>.from(decoded);
    final version = envelope['schemaVersion'];
    if (version is! int) {
      throw StorageDecodeError(
        'envelope field "schemaVersion" is ${version.runtimeType}, not an int',
      );
    }
    final writtenAtRaw = envelope['writtenAt'];
    if (writtenAtRaw is! String) {
      throw StorageDecodeError(
        'envelope field "writtenAt" is ${writtenAtRaw.runtimeType}, not a '
        'timestamp string',
      );
    }
    final DateTime writtenAt;
    try {
      writtenAt = DateTime.parse(writtenAtRaw);
    } catch (error) {
      throw StorageDecodeError(
        'envelope field "writtenAt" is not a valid timestamp: $writtenAtRaw',
        cause: error,
      );
    }
    final payload = envelope['payload'];
    if (payload is! Map) {
      throw StorageDecodeError(
        'envelope field "payload" is ${payload.runtimeType}, not a JSON object',
      );
    }
    return StoredRecord(
      schemaVersion: version,
      writtenAt: writtenAt,
      payload: Map<String, Object?>.from(payload),
    );
  }

  // ---------------------------------------------------------------------
  // Internals.
  // ---------------------------------------------------------------------

  StoredRecord? _readRecordLocked(String collection, String id) {
    final schema = catalog.require(collection);
    final key = storageKey(collection, id);
    final String? primary;
    try {
      primary = readPrimary(key);
    } on StorageDecodeError catch (error) {
      // The bytes are unreadable before they are even parsed (invalid UTF-8, a
      // truncated multi-byte sequence). Same handling as a broken envelope.
      return _recoverFromBackup(collection, id, key, error);
    }
    if (primary == null) {
      final backup = readBackup(key);
      if (backup == null) {
        return null;
      }
      final recovered = _readAndMigrate(
        schema,
        key,
        backup,
        persistUpgrade: false,
      );
      _recoveries.add(
        StoreRecovery(
          collection: collection,
          id: id,
          reason: StoreRecoveryReason.missingPrimary,
          quarantineId: null,
          detail: 'primary bytes were missing; the backup copy was used',
        ),
      );
      return recovered;
    }
    try {
      return _readAndMigrate(schema, key, primary, persistUpgrade: true);
    } on StorageDecodeError catch (error) {
      return _recoverFromBackup(collection, id, key, error);
    }
  }

  StoredRecord _recoverFromBackup(
    String collection,
    String id,
    String key,
    StorageDecodeError primaryError,
  ) {
    String? backup;
    StorageDecodeError? backupReadError;
    try {
      backup = readBackup(key);
    } on StorageDecodeError catch (error) {
      backupReadError = error;
    }
    if (backup == null) {
      final quarantineId = quarantinePrimary(key, move: false);
      _recoveries.add(
        StoreRecovery(
          collection: collection,
          id: id,
          reason: StoreRecoveryReason.unrecoverable,
          quarantineId: quarantineId,
          detail: backupReadError == null
              ? 'no backup exists; ${primaryError.message}'
              : 'no readable backup exists; ${backupReadError.message}',
        ),
      );
      throw CorruptRecordError(
        collection: collection,
        id: id,
        quarantineId: quarantineId,
        detail: primaryError.message,
        cause: primaryError,
      );
    }
    final StoredRecord recovered;
    try {
      recovered = _readAndMigrate(
        catalog.require(collection),
        key,
        backup,
        persistUpgrade: false,
      );
    } on StorageDecodeError catch (backupError) {
      final quarantineId = quarantinePrimary(key, move: false);
      _recoveries.add(
        StoreRecovery(
          collection: collection,
          id: id,
          reason: StoreRecoveryReason.unrecoverable,
          quarantineId: quarantineId,
          detail: 'the backup is corrupt too: ${backupError.message}',
        ),
      );
      throw CorruptRecordError(
        collection: collection,
        id: id,
        quarantineId: quarantineId,
        detail: backupError.message,
        cause: backupError,
      );
    }
    // Preserve the bad bytes, then heal the record from the good backup.
    final quarantineId = quarantinePrimary(key, move: true);
    writePrimaryAtomically(
      key,
      encodeEnvelope(
        schemaVersion: recovered.schemaVersion,
        writtenAt: recovered.writtenAt,
        payload: recovered.payload,
      ),
    );
    _recoveries.add(
      StoreRecovery(
        collection: collection,
        id: id,
        reason: StoreRecoveryReason.corruptPrimary,
        quarantineId: quarantineId,
        detail: 'primary bytes were replaced from the backup copy',
      ),
    );
    return recovered;
  }

  StoredRecord _readAndMigrate(
    CollectionSchema schema,
    String key,
    String contents, {
    required bool persistUpgrade,
  }) {
    final record = decodeEnvelope(contents);
    if (record.schemaVersion == schema.currentVersion) {
      return record;
    }
    final migrated = schema.migrate(record.schemaVersion, record.payload);
    final upgraded = StoredRecord(
      schemaVersion: schema.currentVersion,
      writtenAt: now,
      payload: migrated,
    );
    if (persistUpgrade) {
      writePrimaryAtomically(
        key,
        encodeEnvelope(
          schemaVersion: upgraded.schemaVersion,
          writtenAt: upgraded.writtenAt,
          payload: upgraded.payload,
        ),
      );
    }
    return upgraded;
  }

  Future<T> _serialized<T>(FutureOr<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

/// One-shot faults used to rehearse write failures.
class StoreFaults {
  Object? _writeError;
  Object? _swapError;
  Object? _deleteError;

  void failNextWrite([Object? error]) {
    _writeError = error ?? StateError('injected write failure');
  }

  void failNextSwap([Object? error]) {
    _swapError = error ?? StateError('injected swap failure');
  }

  void failNextDelete([Object? error]) {
    _deleteError = error ?? StateError('injected delete failure');
  }

  void clear() {
    _writeError = null;
    _swapError = null;
    _deleteError = null;
  }

  void throwIfWrite() {
    final error = _writeError;
    _writeError = null;
    if (error != null) {
      throw error;
    }
  }

  void throwIfSwap() {
    final error = _swapError;
    _swapError = null;
    if (error != null) {
      throw error;
    }
  }

  void throwIfDelete() {
    final error = _deleteError;
    _deleteError = null;
    if (error != null) {
      throw error;
    }
  }
}
