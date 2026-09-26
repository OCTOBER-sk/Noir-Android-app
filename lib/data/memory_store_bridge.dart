// lib/data/memory_store_bridge.dart — the seam between the two memory systems.
//
// `lib/memory` and `lib/data` each have a type called MemoryEntry, and they
// are not interchangeable:
//
//   * `lib/memory/memory_models.dart` models a *remembered fact*: free text,
//     provenance ("the user asked for this" vs "the assistant proposed it"),
//     an expiry and a revision counter. Its [MemoryStore] is synchronous,
//     because a save is a single in-process call.
//   * `lib/data/memory_repository.dart` models a *durable keyed record* under
//     the schema/migrations/quarantine machinery of the rest of the data layer.
//     Its reads and writes are asynchronous, because they go to disk.
//
// Wiring MemoryService to a real device means putting one behind the other, and
// this file is that adapter. It is deliberately the only place the two
// vocabularies meet.
//
// Two things it does NOT do:
//
//   * It does not fall back to a volatile store. If the repository cannot be
//     read, [open] reports the failure and the composition root surfaces it as
//     an explicit state. Silently degrading to an in-memory store would make
//     "I saved that" true for the length of one process and false after a
//     restart, which is the same lie as never saving it at all.
//   * It does not guess at a translation. A `lib/memory` entry with no key
//     becomes the record key [factScopeKey] and a record with
//     [MemoryScope.global]; both are named constants rather than values picked
//     per entry, so what the store holds is always explainable.
import 'dart:async';

import '../memory/memory_models.dart' as memory;
import 'memory_repository.dart';

export '../memory/memory_models.dart' show MemoryOrigin;
export 'memory_repository.dart' show MemoryScope;

/// The record [key] a `lib/memory` entry is filed under when it has none.
///
/// `MemoryEntry.key` is optional in `lib/memory` and mandatory in `lib/data`,
/// so an unkeyed fact has to land somewhere. One constant, always the same, is
/// the only translation that does not invent a per-entry name.
const String factScopeKey = 'fact';

/// Raised when the durable memory store cannot be read at startup.
class MemoryStoreUnavailable implements Exception {
  const MemoryStoreUnavailable(this.reason);

  /// What actually failed, in the repository's own words.
  final String reason;

  @override
  String toString() => 'MemoryStoreUnavailable($reason)';
}

/// A [memory.MemoryStore] whose rows live in a [MemoryRepository].
///
/// The interface is synchronous and the repository is not, so the store keeps
/// an authoritative in-memory mirror of the collection and writes through to
/// disk. [open] populates that mirror from the real collection, which is why
/// the constructor cannot be used directly: a store built without [open] would
/// answer `readAll` with an empty list, and a caller could not tell that apart
/// from a user who has never saved anything.
///
/// Writes are queued, not dropped, and [flush] waits for the queue. A write that
/// fails is recorded in [pendingFailures] and re-thrown to whoever awaits
/// [flush] rather than being swallowed.
class PersistedMemoryStore implements memory.MemoryStore {
  PersistedMemoryStore._(this._memories, this._rows, this._writes);

  /// Reads the whole memory collection and returns a store over it.
  ///
  /// Throws [MemoryStoreUnavailable] when the collection cannot be read. That
  /// is deliberately fatal for the caller: a memory service that cannot reach
  /// its own store must not be handed one that pretends to be empty.
  static Future<PersistedMemoryStore> open(MemoryRepository memories) async {
    List<MemoryEntry> records;
    try {
      records = await memories.readAll();
    } on Object catch (error) {
      throw MemoryStoreUnavailable('$error');
    }
    final Map<String, memory.MemoryEntry> rows = <String, memory.MemoryEntry>{
      for (final MemoryEntry record in records)
        if (!_isForeign(record)) record.id: _toMemory(record),
    };
    return PersistedMemoryStore._(memories, rows, <Future<void>>[]);
  }

  final MemoryRepository _memories;

  /// The mirror. Authoritative for reads; the repository is authoritative on
  /// disk, and [reload] is how the two are re-synchronised.
  final Map<String, memory.MemoryEntry> _rows;

  /// Serialises the write-behind queue: one record in flight at a time, so two
  /// edits to the same id cannot reorder on disk.
  Future<void> _tail = Future<void>.value();
  final List<Future<void>> _writes;

  /// Failures from queued writes, oldest first. A write that could not reach
  /// the disk is reported here and re-thrown to whoever awaits [flush]; it is
  /// never dropped silently.
  final List<Object> pendingFailures = <Object>[];

  /// Ids whose write is still queued.
  int get pendingWriteCount => _writes.length;

  /// Reads the collection again and replaces the mirror with what is on disk.
  ///
  /// A row that vanished underneath the service is removed rather than kept,
  /// so the mirror cannot report a fact the store no longer holds.
  Future<void> reload() async {
    final List<MemoryEntry> records = await _memories.readAll();
    final Map<String, memory.MemoryEntry> fresh = <String, memory.MemoryEntry>{
      for (final MemoryEntry record in records)
        if (!_isForeign(record)) record.id: _toMemory(record),
    };
    _rows
      ..clear()
      ..addAll(fresh);
  }

  @override
  List<memory.MemoryEntry> readAll() =>
      List<memory.MemoryEntry>.unmodifiable(_rows.values);

  @override
  void write(memory.MemoryEntry entry) {
    _rows[entry.id] = entry;
    _enqueue(() => _memories.upsert(_toRecord(entry)));
  }

  @override
  void remove(String id) {
    _rows.remove(id);
    _enqueue(() => _memories.delete(id));
  }

  @override
  void clear() {
    _rows.clear();
    _enqueue(() => _memories.deleteAll());
  }

  /// Waits for every queued write, re-throwing the first failure.
  ///
  /// The queue is drained completely before anything is thrown, so one failed
  /// write cannot strand the ones behind it.
  Future<void> flush() async {
    while (_writes.isNotEmpty) {
      await _writes.removeAt(0);
    }
    if (pendingFailures.isNotEmpty) {
      final List<Object> failures = List<Object>.of(pendingFailures);
      pendingFailures.clear();
      throw failures.first;
    }
  }

  void _enqueue(Future<Object?> Function() operation) {
    final Completer<void> done = Completer<void>();
    _writes.add(done.future);
    _tail = _tail.then((_) async {
      try {
        await operation();
      } on Object catch (error) {
        pendingFailures.add(error);
      }
      if (!done.isCompleted) done.complete();
    });
  }

  /// Whether a record in the collection came from somewhere other than
  /// [PersistedMemoryStore].
  ///
  /// The memories collection is a shared table: records written directly
  /// through [MemoryRepository] have no `lib/memory` provenance, and there is
  /// no honest way to read a `lib/memory` entry out of one. Hiding them from
  /// [memory.MemoryService.list] would be better than inventing a provenance
  /// for them, so they are excluded from the service's view and remain
  /// readable through the repository.
  static bool _isForeign(MemoryEntry record) => record.provenanceOrigin == null;

  /// `lib/data` record -> `lib/memory` entry.
  static memory.MemoryEntry _toMemory(MemoryEntry record) {
    final DateTime recordedAt =
        record.provenanceRecordedAt ?? record.createdAt.toUtc();
    return memory.MemoryEntry(
      id: record.id,
      content: record.value,
      key: record.key == factScopeKey ? null : record.key,
      tags: List<String>.of(record.tags),
      provenance: memory.MemoryProvenance(
        origin: _originFrom(record.provenanceOrigin),
        sourceId: record.provenanceSourceId ?? 'user',
        recordedAt: recordedAt,
        note: record.provenanceNote,
      ),
      createdAt: record.createdAt.toUtc(),
      updatedAt: record.updatedAt.toUtc(),
      expiresAt: record.expiresAt?.toUtc(),
      revision: record.revision ?? 1,
    );
  }

  /// `lib/memory` entry -> `lib/data` record.
  static MemoryEntry _toRecord(memory.MemoryEntry entry) {
    return MemoryEntry(
      id: entry.id,
      key: entry.key ?? factScopeKey,
      value: entry.content,
      scope: MemoryScope.global,
      tags: List<String>.of(entry.tags),
      pinned: false,
      createdAt: entry.createdAt.toUtc(),
      updatedAt: entry.updatedAt.toUtc(),
      provenanceOrigin: entry.provenance.origin.name,
      provenanceSourceId: entry.provenance.sourceId,
      provenanceRecordedAt: entry.provenance.recordedAt.toUtc(),
      provenanceNote: entry.provenance.note,
      revision: entry.revision,
      expiresAt: entry.expiresAt?.toUtc(),
    );
  }

  /// A stored origin name that no longer exists in this build degrades to
  /// [MemoryOrigin.import] rather than throwing: the fact itself is still
  /// valid, and losing it because a rename happened would be worse than
  /// recording the weaker claim that it was imported.
  static memory.MemoryOrigin _originFrom(String? name) {
    for (final memory.MemoryOrigin origin in memory.MemoryOrigin.values) {
      if (origin.name == name) return origin;
    }
    return memory.MemoryOrigin.import;
  }
}
