// lib/data/memory_repository.dart — durable memory entries.
//
// A memory is a small keyed fact the agent is allowed to keep. Ids identify
// records; [MemoryEntry.key] is the fact's own name, so a caller can ask "what do
// I know about the user's timezone" without knowing an id.

import 'codecs.dart';
import 'collection_repository.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'pagination.dart';
import 'records.dart';

/// How widely a memory applies.
enum MemoryScope {
  /// Applies to every conversation.
  global,

  /// Applies to the conversation it was written in.
  conversation,
}

/// The persisted name of a [MemoryScope] value.
String memoryScopeName(MemoryScope scope) => scope.name;

class MemoryEntry extends DataRecord {
  MemoryEntry({
    required super.id,
    required this.key,
    required this.value,
    required this.scope,
    required List<String> tags,
    required this.pinned,
    required super.createdAt,
    required super.updatedAt,
    this.lastUsedAt,
  }) : tags = List<String>.unmodifiable(tags) {
    if (key.trim().isEmpty) {
      throw const InvalidDataError('a memory needs a key');
    }
    if (value.trim().isEmpty) {
      throw const InvalidDataError('a memory needs a value');
    }
    for (final tag in tags) {
      if (tag.trim().length > maxMemoryTagLength) {
        throw InvalidDataError(
          'a memory tag must be at most $maxMemoryTagLength characters',
        );
      }
    }
  }

  final String key;
  final String value;
  final MemoryScope scope;
  final List<String> tags;
  final bool pinned;
  final DateTime? lastUsedAt;

  /// The scope as it is stored, for display.
  String get scopeName => memoryScopeName(scope);

  MemoryEntry copyWith({
    String? key,
    String? value,
    MemoryScope? scope,
    List<String>? tags,
    bool? pinned,
    DateTime? updatedAt,
    DateTime? lastUsedAt,
  }) {
    return MemoryEntry(
      id: id,
      key: key ?? this.key,
      value: value ?? this.value,
      scope: scope ?? this.scope,
      tags: tags ?? this.tags,
      pinned: pinned ?? this.pinned,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    );
  }

  /// Whether [query] appears in the key, the value or a tag.
  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return true;
    }
    if (key.toLowerCase().contains(needle)) {
      return true;
    }
    if (value.toLowerCase().contains(needle)) {
      return true;
    }
    return tags.any((tag) => tag.toLowerCase().contains(needle));
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'value': value,
    'scope': scopeName,
    'tags': List<String>.of(tags),
    'pinned': pinned,
    'lastUsedAt': lastUsedAt?.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  @override
  String toString() =>
      'MemoryEntry($id, $key = $value, $scopeName, '
      'pinned: $pinned)';
}

const int maxMemoryTagLength = 32;

class MemoryEntryCodec extends RecordCodec<MemoryEntry> {
  const MemoryEntryCodec();

  @override
  Map<String, Object?> encode(MemoryEntry record) => record.toJson();

  @override
  MemoryEntry decode(String id, Map<String, Object?> json) {
    const collection = NoirCollections.memories;
    final key = requireString(json, 'key', collection, id);
    final value = requireString(json, 'value', collection, id);
    final scopeName = requireString(json, 'scope', collection, id);
    final scope = MemoryScope.values.where((s) => s.name == scopeName);
    if (scope.isEmpty) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'scope',
        detail: 'unknown scope "$scopeName"',
      );
    }
    final tags = requireStringList(json, 'tags', collection, id);
    final pinned = optionalBool(json, 'pinned', collection, id);
    final lastUsedAt = json['lastUsedAt'] == null
        ? null
        : requireTimestamp(json, 'lastUsedAt', collection, id);
    final createdAt = requireTimestamp(json, 'createdAt', collection, id);
    final updatedAt = requireTimestamp(json, 'updatedAt', collection, id);
    try {
      return MemoryEntry(
        id: id,
        key: key,
        value: value,
        scope: scope.single,
        tags: tags,
        pinned: pinned,
        createdAt: createdAt,
        updatedAt: updatedAt,
        lastUsedAt: lastUsedAt,
      );
    } on InvalidDataError catch (error) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: error.message.contains('key') ? 'key' : 'value',
        detail: error.message,
        cause: error,
      );
    }
  }
}

class MemoryRepository extends CollectionRepository<MemoryEntry> {
  MemoryRepository({
    required super.store,
    super.codec = const MemoryEntryCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.memories);

  /// A memory that starts from the repository clock.
  MemoryEntry newMemory({
    required String id,
    required String key,
    required String value,
    MemoryScope scope = MemoryScope.global,
    List<String> tags = const <String>[],
    bool pinned = false,
  }) {
    final stamp = now;
    return MemoryEntry(
      id: id,
      key: key,
      value: value,
      scope: scope,
      tags: tags,
      pinned: pinned,
      createdAt: stamp,
      updatedAt: stamp,
    );
  }

  /// Every memory filed under [key], in id order.
  Future<List<MemoryEntry>> findByKey(String key) async {
    final matches = <MemoryEntry>[];
    for (final memory in await readAll()) {
      if (memory.key == key) {
        matches.add(memory);
      }
    }
    return List<MemoryEntry>.unmodifiable(matches);
  }

  /// Records that a memory was just used, which moves it to the front of any
  /// recency listing and is persisted.
  Future<MemoryEntry> touch(String id, {DateTime? at}) => update(
    id,
    (current) => current.copyWith(
      lastUsedAt: (at ?? now).toUtc(),
      updatedAt: (at ?? now).toUtc(),
    ),
  );

  /// Pinned first, then most recently updated, then id.
  static int compareByRecency(MemoryEntry a, MemoryEntry b) {
    if (a.pinned != b.pinned) {
      return a.pinned ? -1 : 1;
    }
    final byUpdate = b.updatedAt.compareTo(a.updatedAt);
    return byUpdate != 0 ? byUpdate : a.id.compareTo(b.id);
  }

  /// A page of memories, pinned first.
  Future<Page<MemoryEntry>> listByRecency({
    PageRequest? page,
    int? limit,
    int? offset,
  }) {
    final request = PageRequest.validated(
      offset: offset ?? page?.offset ?? 0,
      limit: limit ?? page?.limit ?? defaultPageLimit,
      maxLimit: maxPageLimit,
    );
    return pageOrdered(request, compareByRecency);
  }

  /// Searches key, value and tags, optionally narrowed by scope or pin state.
  Future<Page<MemoryEntry>> search(
    String query, {
    PageRequest? page,
    int? limit,
    int? offset,
    MemoryScope? scope,
    bool pinnedOnly = false,
  }) async {
    final request = PageRequest.validated(
      offset: offset ?? page?.offset ?? 0,
      limit: limit ?? page?.limit ?? defaultPageLimit,
      maxLimit: maxPageLimit,
    );
    final matches = <MemoryEntry>[];
    for (final memory in await readAll()) {
      if (scope != null && memory.scope != scope) {
        continue;
      }
      if (pinnedOnly && !memory.pinned) {
        continue;
      }
      if (memory.matches(query)) {
        matches.add(memory);
      }
    }
    matches.sort(compareByRecency);
    return pageOf<MemoryEntry>(matches, request, total: matches.length);
  }

  /// Removes a memory. Kept as a named operation so "forget" reads clearly at
  /// the call site and cannot be confused with "delete the collection".
  Future<void> forget(String id) => delete(id);
}
