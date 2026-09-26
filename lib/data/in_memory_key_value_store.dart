// lib/data/in_memory_key_value_store.dart — the deterministic test double.
//
// It is not a stub: the envelopes are encoded to exactly the same JSON strings
// the file store writes, and all versioning, migration, quarantine and atomicity
// logic runs in the shared base class. A test that passes here passes against
// real files, and the backing map can be shared between instances to rehearse a
// process restart.

import 'key_value_store.dart';

/// The bytes behind an [InMemoryKeyValueStore]. Share one instance to model two
/// store objects looking at the same storage.
class InMemoryStorage {
  InMemoryStorage();

  /// Current bytes per storage key.
  final Map<String, String> primary = <String, String>{};

  /// Previous good bytes per storage key.
  final Map<String, String> backup = <String, String>{};

  /// Bytes written by an interrupted write, i.e. the equivalent of a stray
  /// `*.tmp` file. Never visible to readers.
  final Map<String, String> pending = <String, String>{};

  /// Preserved bad bytes per quarantine id.
  final Map<String, String> quarantine = <String, String>{};

  /// Every byte string this storage has ever been asked to hold.
  final List<String> writeLog = <String>[];
}

/// A [KeyValueStore] that keeps versioned JSON envelopes in memory.
class InMemoryKeyValueStore extends KeyValueStoreBase {
  InMemoryKeyValueStore({
    required super.catalog,
    super.clock,
    InMemoryStorage? backing,
  }) : backing = backing ?? InMemoryStorage() {
    if (backing != null) {
      _sharedBacking = true;
    }
  }

  /// The bytes this store reads and writes. Exposed so a test can model a
  /// restart with a second instance.
  final InMemoryStorage backing;

  @override
  bool get isDurable =>
      // Only when a caller deliberately shares the backing map with a later
      // instance, which is how a test models a restart.
      _sharedBacking;

  bool _sharedBacking = false;

  @override
  String? readPrimary(String key) => backing.primary[key];

  @override
  String? readBackup(String key) => backing.backup[key];

  @override
  void writePrimaryAtomically(String key, String contents) {
    backing.writeLog.add(contents);
    // Stage first, exactly like a temp file being written and flushed.
    backing.pending[key] = contents;
    throwIfSwapFault();
    final previous = backing.primary[key];
    if (previous != null) {
      backing.backup[key] = previous;
    }
    backing.primary[key] = backing.pending.remove(key)!;
  }

  @override
  void damagePrimaryBytes(String key, String contents) {
    backing.writeLog.add(contents);
    backing.primary[key] = contents;
    backing.pending.remove(key);
  }

  @override
  void removeRecordFiles(String key) {
    backing.primary.remove(key);
    backing.backup.remove(key);
    backing.pending.remove(key);
  }

  @override
  List<String> listRecordIds(String collection) {
    final prefix = '$collection/';
    final ids =
        backing.primary.keys
            .where((key) => key.startsWith(prefix))
            .map((key) => key.substring(prefix.length))
            .toList()
          ..sort();
    return ids;
  }

  @override
  int nextQuarantineIndex(String key) {
    var index = 1;
    while (backing.quarantine.containsKey(quarantineIdFor(key, index))) {
      index++;
    }
    return index;
  }

  @override
  String quarantinePrimary(String key, {required bool move}) {
    final id = quarantineIdFor(key, nextQuarantineIndex(key));
    final contents = backing.primary[key];
    if (contents == null) {
      return id;
    }
    backing.quarantine[id] = contents;
    if (move) {
      backing.primary.remove(key);
      backing.pending.remove(key);
    }
    return id;
  }

  @override
  String? findQuarantineId(String key) {
    for (var index = 64; index >= 1; index--) {
      final id = quarantineIdFor(key, index);
      if (backing.quarantine.containsKey(id)) {
        return id;
      }
    }
    return null;
  }

  @override
  String? readQuarantine(String id) => backing.quarantine[id];

  @override
  List<String> listQuarantineIds() => backing.quarantine.keys.toList()..sort();
}
