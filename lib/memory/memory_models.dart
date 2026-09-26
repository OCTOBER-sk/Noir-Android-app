// lib/memory/memory_models.dart
// A2 — Memory ("Save as Fact") data model and the injectable store seam.
//
// Nothing in this file seeds sample data: a brand new store is empty and a
// brand new service returns nothing. Persistence lives behind [MemoryStore] so
// the service can be driven by a test double.

/// Where a fact came from. The origin travels with the entry forever so a fact
/// that was inferred by the assistant is never confused with one the user asked
/// to save.
enum MemoryOrigin {
  /// The user explicitly asked to remember this.
  userExplicit,

  /// The assistant proposed it; the caller decides whether to persist it.
  assistantProposal,

  /// Extracted from a tool result.
  toolResult,

  /// Imported by the user from outside the app.
  import,
}

/// Immutable provenance record attached to every memory entry.
class MemoryProvenance {
  const MemoryProvenance({
    required this.origin,
    required this.sourceId,
    required this.recordedAt,
    this.note,
  });

  final MemoryOrigin origin;

  /// Stable identifier of the originating item (message id, tool call id...).
  final String sourceId;

  final DateTime recordedAt;

  final String? note;

  MemoryProvenance copyWith({
    MemoryOrigin? origin,
    String? sourceId,
    DateTime? recordedAt,
    String? note,
  }) {
    return MemoryProvenance(
      origin: origin ?? this.origin,
      sourceId: sourceId ?? this.sourceId,
      recordedAt: recordedAt ?? this.recordedAt,
      note: note ?? this.note,
    );
  }

  @override
  String toString() =>
      'MemoryProvenance(${origin.name}, source: $sourceId, at: $recordedAt)';
}

/// A single remembered fact. Entries are immutable; edits go through
/// `MemoryService.update` which produces a new revision.
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.content,
    required this.provenance,
    required this.createdAt,
    required this.updatedAt,
    this.key,
    this.tags = const <String>[],
    this.expiresAt,
    this.revision = 1,
  });

  final String id;

  /// The remembered text, already trimmed.
  final String content;

  /// Optional namespace key, e.g. `deploy.hetzner.box`.
  final String? key;

  final List<String> tags;
  final MemoryProvenance provenance;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Absolute expiry instant, or null when the entry never expires.
  final DateTime? expiresAt;

  /// Bumped on every update; starts at 1.
  final int revision;

  bool get hasExpiry => expiresAt != null;

  /// Expiry is inclusive: at [expiresAt] the entry is already dead.
  bool isExpiredAt(DateTime instant) {
    final DateTime? expiry = expiresAt;
    if (expiry == null) {
      return false;
    }
    return !instant.toUtc().isBefore(expiry);
  }

  /// Everything a query can match against.
  String get searchableText =>
      <String>[content, key ?? '', ...tags].join(' ').toLowerCase();

  MemoryEntry copyWith({
    String? content,
    String? key,
    List<String>? tags,
    MemoryProvenance? provenance,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? expiresAt,
    bool clearExpiry = false,
    int? revision,
  }) {
    return MemoryEntry(
      id: id,
      content: content ?? this.content,
      key: key ?? this.key,
      tags: tags ?? this.tags,
      provenance: provenance ?? this.provenance,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      expiresAt: clearExpiry ? null : (expiresAt ?? this.expiresAt),
      revision: revision ?? this.revision,
    );
  }

  @override
  String toString() => 'MemoryEntry($id, rev: $revision, content: $content)';
}

/// A scored search hit. [relevance] is a plain token-overlap count so ordering
/// is fully explainable and deterministic.
class MemorySearchResult {
  const MemorySearchResult({required this.entry, required this.relevance});

  final MemoryEntry entry;
  final int relevance;

  @override
  String toString() => 'MemorySearchResult(${entry.id}, score: $relevance)';
}

/// Raised for every rejected input or unknown id. Callers get a machine
/// readable [code] instead of having to parse a message.
class MemoryValidationException implements Exception {
  const MemoryValidationException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() =>
      'MemoryValidationException($code${detail == null ? '' : ': $detail'})';
}

/// Persistence seam. The service only ever talks to this interface.
abstract interface class MemoryStore {
  /// Every row currently held, in whatever order the store prefers. The
  /// service re-orders, so implementations need not sort.
  List<MemoryEntry> readAll();

  /// Insert or replace one row.
  void write(MemoryEntry entry);

  void remove(String id);

  void clear();
}

/// In-memory [MemoryStore]. Ships in lib/ so the app has a working store
/// before lib/data persistence exists; tests also use it as the in-memory test
/// store. Starts empty — never seeded.
class InMemoryMemoryStore implements MemoryStore {
  InMemoryMemoryStore([Iterable<MemoryEntry> seed = const <MemoryEntry>[]]) {
    for (final MemoryEntry entry in seed) {
      rows[entry.id] = entry;
    }
  }

  final Map<String, MemoryEntry> rows = <String, MemoryEntry>{};

  @override
  List<MemoryEntry> readAll() => List<MemoryEntry>.of(rows.values);

  @override
  void write(MemoryEntry entry) {
    rows[entry.id] = entry;
  }

  @override
  void remove(String id) {
    rows.remove(id);
  }

  @override
  void clear() => rows.clear();
}
