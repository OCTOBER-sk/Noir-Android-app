// lib/memory/memory_service.dart
// A2 — Memory ("Save as Fact") service layer.
//
// The service is a thin, deterministic layer over an injected [MemoryStore]:
// it never calls DateTime.now() (a [Clock] is injected) and it never seeds
// sample data. Ordering is fully specified so callers get stable results.
import '../core/clock.dart';
import 'memory_models.dart';

export 'memory_models.dart';

const Object _unsetTtl = Object();

class MemoryService {
  /// Creates a service over [store].
  ///
  /// [maxEntries] bounds how many rows the store is allowed to hold; when the
  /// store already holds more, the service trims it immediately, preferring
  /// expired rows and then the oldest, so the bound holds for injected stores
  /// as well as for ones this service filled.
  MemoryService({
    required this.store,
    Clock? clock,
    this.maxEntries = 500,
    this.defaultRetention,
    int sequence = 0,
  }) : clock = clock ?? const SystemClock(),
       _sequence = sequence {
    if (maxEntries <= 0) {
      throw const MemoryValidationException('INVALID_MAX_ENTRIES');
    }
    _enforceCapacity();
  }

  final MemoryStore store;
  final Clock clock;

  /// Upper bound on rows held in the store.
  final int maxEntries;

  /// Applied to entries added without an explicit [MemoryService.add] ttl.
  final Duration? defaultRetention;

  int _sequence;

  /// Ids dropped by the most recent capacity enforcement, oldest first.
  final List<String> lastEvictions = <String>[];

  /// Number of live (non-expired) entries.
  int get size => _live().length;

  /// Live entries, oldest first; ties broken by id so the order is stable.
  /// The result is a snapshot the caller owns; mutating it never reaches the
  /// store.
  List<MemoryEntry> list({bool includeExpired = false}) {
    final List<MemoryEntry> all = _sorted(store.readAll());
    if (includeExpired) {
      return all;
    }
    final DateTime now = clock.now();
    return all.where((MemoryEntry e) => !e.isExpiredAt(now)).toList();
  }

  /// The live entry with [id], or null when unknown or expired.
  MemoryEntry? get(String id) {
    final MemoryEntry? entry = _raw(id);
    if (entry == null) {
      return null;
    }
    return entry.isExpiredAt(clock.now()) ? null : entry;
  }

  bool contains(String id) => get(id) != null;

  /// Stores a fact. The caller is the one deciding to remember it — nothing
  /// here infers or auto-saves.
  ///
  /// Pass `ttl: null` to keep the entry forever even when [defaultRetention]
  /// is set; omit [ttl] entirely to inherit [defaultRetention].
  MemoryEntry add(
    String content, {
    String? sourceId,
    MemoryOrigin origin = MemoryOrigin.userExplicit,
    List<String> tags = const <String>[],
    String? key,
    Object? ttl = _unsetTtl,
    String? id,
  }) {
    final String body = content.trim();
    if (body.isEmpty) {
      throw const MemoryValidationException('EMPTY_CONTENT');
    }
    if (sourceId != null && sourceId.trim().isEmpty) {
      throw const MemoryValidationException('EMPTY_SOURCE_ID');
    }
    if (key != null && key.trim().isEmpty) {
      throw const MemoryValidationException('EMPTY_KEY');
    }
    if (id != null && id.trim().isEmpty) {
      throw const MemoryValidationException('EMPTY_ID');
    }

    final String entryId = id?.trim() ?? _nextId();
    if (_raw(entryId) != null) {
      throw MemoryValidationException('DUPLICATE_ID', entryId);
    }

    final DateTime now = clock.now();
    final Duration? effectiveTtl = _resolveTtl(ttl);
    store.write(
      MemoryEntry(
        id: entryId,
        content: body,
        key: key?.trim(),
        tags: _normalizeTags(tags),
        provenance: MemoryProvenance(
          origin: origin,
          sourceId: sourceId?.trim() ?? 'user',
          recordedAt: now,
        ),
        createdAt: now,
        updatedAt: now,
        expiresAt: effectiveTtl == null ? null : now.add(effectiveTtl),
      ),
    );
    _enforceCapacity(protect: entryId);
    return _raw(entryId) ?? (throw StateError('entry $entryId vanished'));
  }

  /// Edits a live entry. Provenance and [MemoryEntry.createdAt] survive the
  /// edit; [MemoryEntry.updatedAt] and the revision move forward.
  MemoryEntry update(
    String id, {
    String? content,
    List<String>? tags,
    String? key,
    Object? ttl = _unsetTtl,
    bool clearExpiry = false,
  }) {
    final MemoryEntry? existing = _raw(id);
    if (existing == null) {
      throw MemoryValidationException('UNKNOWN_ID', id);
    }
    if (clearExpiry && ttl != _unsetTtl && ttl != null) {
      throw const MemoryValidationException('CONFLICTING_EXPIRY');
    }

    final DateTime now = clock.now();
    final MemoryEntry updated = existing.copyWith(
      content: content == null ? null : _requireContent(content),
      tags: tags == null ? null : _normalizeTags(tags),
      key: key == null ? null : _requireKey(key),
      updatedAt: now,
      expiresAt: clearExpiry
          ? null
          : (ttl == _unsetTtl ? null : now.add(_requireTtl(ttl))),
      clearExpiry: clearExpiry,
      revision: existing.revision + 1,
    );
    store.write(updated);
    _enforceCapacity(protect: id);
    return updated;
  }

  /// Removes a row regardless of expiry. Returns false for an unknown id.
  bool delete(String id) {
    if (_raw(id) == null) {
      return false;
    }
    store.remove(id);
    return true;
  }

  /// Drops every expired row. Returns the ids removed, oldest first.
  List<String> purgeExpired() {
    final DateTime now = clock.now();
    final List<MemoryEntry> expired = _sorted(
      store.readAll(),
    ).where((MemoryEntry e) => e.isExpiredAt(now)).toList();
    for (final MemoryEntry entry in expired) {
      store.remove(entry.id);
    }
    return expired.map((MemoryEntry e) => e.id).toList();
  }

  /// Case-insensitive token search. Every query token must appear somewhere in
  /// the entry's content, key or tags. Results are ordered by descending
  /// relevance, then newest first, then id.
  ///
  /// Relevance is explainable on purpose: a token matched in a tag is worth 3,
  /// in the key 2 and in the content 1, plus 2 when the whole query appears
  /// verbatim in the content. Equal scores fall back to recency then id, so
  /// the ordering never depends on iteration order.
  List<MemorySearchResult> search(
    String query, {
    MemoryOrigin? origin,
    String? tag,
    bool includeExpired = false,
  }) {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const MemoryValidationException('EMPTY_QUERY');
    }
    final Set<String> tokens = trimmed
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((String t) => t.isNotEmpty)
        .toSet();
    final String? tagFilter = tag?.trim().toLowerCase();
    final DateTime now = clock.now();

    final List<MemorySearchResult> hits = <MemorySearchResult>[];
    for (final MemoryEntry entry in _sorted(store.readAll())) {
      if (!includeExpired && entry.isExpiredAt(now)) {
        continue;
      }
      if (origin != null && entry.provenance.origin != origin) {
        continue;
      }
      if (tagFilter != null &&
          !entry.tags.any((String t) => t.toLowerCase() == tagFilter)) {
        continue;
      }
      final String content = entry.content.toLowerCase();
      final String key = (entry.key ?? '').toLowerCase();
      final List<String> tags = entry.tags
          .map((String t) => t.toLowerCase())
          .toList();
      int score = 0;
      bool allPresent = true;
      for (final String token in tokens) {
        if (tags.any((String t) => t.contains(token))) {
          score += 3;
        } else if (key.contains(token)) {
          score += 2;
        } else if (content.contains(token)) {
          score += 1;
        } else {
          allPresent = false;
          break;
        }
      }
      if (allPresent && score > 0) {
        if (content.contains(trimmed.toLowerCase())) {
          score += 2;
        }
        hits.add(MemorySearchResult(entry: entry, relevance: score));
      }
    }

    hits.sort((MemorySearchResult a, MemorySearchResult b) {
      final int byScore = b.relevance.compareTo(a.relevance);
      if (byScore != 0) {
        return byScore;
      }
      final int byAge = b.entry.createdAt.compareTo(a.entry.createdAt);
      if (byAge != 0) {
        return byAge;
      }
      return a.entry.id.compareTo(b.entry.id);
    });
    return hits;
  }

  void clear() => store.clear();

  // --- internals ---------------------------------------------------------

  MemoryEntry? _raw(String id) {
    for (final MemoryEntry entry in store.readAll()) {
      if (entry.id == id) {
        return entry;
      }
    }
    return null;
  }

  List<MemoryEntry> _live() {
    final DateTime now = clock.now();
    return store
        .readAll()
        .where((MemoryEntry e) => !e.isExpiredAt(now))
        .toList(growable: false);
  }

  /// Oldest first, ties broken by id — the single ordering used everywhere.
  List<MemoryEntry> _sorted(List<MemoryEntry> entries) {
    final List<MemoryEntry> copy = List<MemoryEntry>.of(entries);
    copy.sort((MemoryEntry a, MemoryEntry b) {
      final int byAge = a.createdAt.compareTo(b.createdAt);
      return byAge != 0 ? byAge : a.id.compareTo(b.id);
    });
    return copy;
  }

  String _nextId() {
    while (true) {
      _sequence += 1;
      final String candidate = 'mem-${_sequence.toString().padLeft(4, '0')}';
      if (_raw(candidate) == null) {
        return candidate;
      }
    }
  }

  Duration? _resolveTtl(Object? ttl) {
    if (identical(ttl, _unsetTtl)) {
      return defaultRetention;
    }
    if (ttl == null) {
      return null;
    }
    return _requireTtl(ttl);
  }

  Duration _requireTtl(Object? ttl) {
    if (ttl is! Duration) {
      throw const MemoryValidationException('INVALID_TTL');
    }
    if (ttl <= Duration.zero) {
      throw MemoryValidationException('INVALID_TTL', ttl.inSeconds.toString());
    }
    return ttl;
  }

  String _requireContent(String content) {
    final String body = content.trim();
    if (body.isEmpty) {
      throw const MemoryValidationException('EMPTY_CONTENT');
    }
    return body;
  }

  String _requireKey(String key) {
    final String body = key.trim();
    if (body.isEmpty) {
      throw const MemoryValidationException('EMPTY_KEY');
    }
    return body;
  }

  List<String> _normalizeTags(List<String> tags) {
    final List<String> out = <String>[];
    for (final String tag in tags) {
      final String value = tag.trim();
      if (value.isEmpty) {
        continue;
      }
      if (!out.contains(value)) {
        out.add(value);
      }
    }
    return List<String>.unmodifiable(out);
  }

  /// Keeps the store at or below [maxEntries] rows. Expired rows go first,
  /// then the oldest — so a bounded store never prefers deleting live data it
  /// cannot afford to lose, and the choice is reproducible. [protect] is never
  /// chosen, so the entry an add or update just wrote always survives.
  void _enforceCapacity({String? protect}) {
    lastEvictions.clear();
    List<MemoryEntry> rows = _sorted(
      store.readAll(),
    ).where((MemoryEntry e) => e.id != protect).toList();
    final DateTime now = clock.now();
    while (rows.length + (protect == null ? 0 : 1) > maxEntries) {
      MemoryEntry? victim;
      for (final MemoryEntry entry in rows) {
        if (entry.isExpiredAt(now)) {
          victim = entry;
          break;
        }
      }
      final MemoryEntry chosen = victim ?? rows.first;
      store.remove(chosen.id);
      lastEvictions.add(chosen.id);
      rows = rows.where((MemoryEntry e) => e.id != chosen.id).toList();
    }
  }
}
