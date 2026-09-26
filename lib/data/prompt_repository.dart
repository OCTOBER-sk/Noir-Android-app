// lib/data/prompt_repository.dart — saved prompts.
//
// Prompts are small, user-authored and frequently read in full, so search reads
// the collection and filters in memory. That is a deliberate trade: it keeps
// search honest (every field participates) at the cost of scaling linearly with
// the number of prompts, which is capped by [PromptRepository.maxPageLimit] and
// the fact that a phone holds tens, not millions, of them.

import 'codecs.dart';
import 'collection_repository.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'pagination.dart';
import 'records.dart';

/// A stored prompt.
class SavedPrompt extends DataRecord {
  SavedPrompt({
    required super.id,
    required this.title,
    required this.body,
    required List<String> tags,
    required this.favourite,
    required super.createdAt,
    required super.updatedAt,
  }) : tags = normaliseTags(tags) {
    if (title.trim().isEmpty) {
      throw const InvalidDataError('a prompt needs a title');
    }
    if (body.trim().isEmpty) {
      throw const InvalidDataError('a prompt needs a body');
    }
  }

  final String title;
  final String body;
  final List<String> tags;
  final bool favourite;

  /// The body split on whitespace, for a cheap size estimate.
  int get wordCount =>
      body.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).length;

  /// Lower-cased, trimmed, de-duplicated tags, sorted for a stable store.
  static List<String> normaliseTags(List<String> tags) {
    final seen = <String, String>{};
    for (final tag in tags) {
      final trimmed = tag.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.length > maxTagLength) {
        throw InvalidDataError(
          'a tag must be at most $maxTagLength characters, got '
          '${trimmed.length}',
        );
      }
      final key = trimmed.toLowerCase();
      // The first spelling wins, so "Work" and "work" do not both survive.
      seen.putIfAbsent(key, () => trimmed);
    }
    return List<String>.unmodifiable(seen.values.toList()..sort());
  }

  SavedPrompt copyWith({
    String? title,
    String? body,
    List<String>? tags,
    bool? favourite,
    DateTime? updatedAt,
  }) {
    return SavedPrompt(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
      tags: tags ?? this.tags,
      favourite: favourite ?? this.favourite,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Whether any of [query]'s terms appear in the title, body or a tag.
  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return true;
    }
    if (title.toLowerCase().contains(needle)) {
      return true;
    }
    if (body.toLowerCase().contains(needle)) {
      return true;
    }
    return tags.any((tag) => tag.toLowerCase().contains(needle));
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'body': body,
    'tags': List<String>.of(tags),
    'favourite': favourite,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  @override
  String toString() =>
      'SavedPrompt($id, "$title", ${body.length} chars, '
      'tags: ${tags.join(',')}, favourite: $favourite)';
}

/// The longest tag a prompt may carry.
const int maxTagLength = 32;

class SavedPromptCodec extends RecordCodec<SavedPrompt> {
  const SavedPromptCodec();

  @override
  Map<String, Object?> encode(SavedPrompt record) => record.toJson();

  @override
  SavedPrompt decode(String id, Map<String, Object?> json) {
    const collection = NoirCollections.prompts;
    final title = requireString(json, 'title', collection, id);
    final body = requireString(json, 'body', collection, id);
    final tags = requireStringList(json, 'tags', collection, id);
    final favourite = optionalBool(json, 'favourite', collection, id);
    final createdAt = requireTimestamp(json, 'createdAt', collection, id);
    final updatedAt = requireTimestamp(json, 'updatedAt', collection, id);
    try {
      return SavedPrompt(
        id: id,
        title: title,
        body: body,
        tags: tags,
        favourite: favourite,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
    } on InvalidDataError catch (error) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: error.message.contains('title') ? 'title' : 'body',
        detail: error.message,
        cause: error,
      );
    }
  }
}

class PromptRepository extends CollectionRepository<SavedPrompt> {
  PromptRepository({
    required super.store,
    super.codec = const SavedPromptCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.prompts);

  /// Creates or replaces a prompt, keeping the original [SavedPrompt.createdAt].
  @override
  Future<SavedPrompt> upsert(SavedPrompt record) async {
    final stored = await store.mutateRecord(collection, record.id, (current) {
      final createdAt = current == null
          ? record.createdAt
          : codec.decode(record.id, current).createdAt;
      return codec.encode(
        SavedPrompt(
          id: record.id,
          title: record.title,
          body: record.body,
          tags: record.tags,
          favourite: record.favourite,
          createdAt: createdAt,
          updatedAt: record.updatedAt,
        ),
      );
    });
    return codec.decode(record.id, stored!.payload);
  }

  /// A prompt that starts from the repository clock.
  SavedPrompt newPrompt({
    required String id,
    required String title,
    required String body,
    List<String> tags = const <String>[],
    bool favourite = false,
  }) {
    final stamp = now;
    return SavedPrompt(
      id: id,
      title: title,
      body: body,
      tags: tags,
      favourite: favourite,
      createdAt: stamp,
      updatedAt: stamp,
    );
  }

  /// Marks or unmarks a favourite.
  Future<SavedPrompt> setFavourite(String id, {required bool favourite}) =>
      update(
        id,
        (current) => current.copyWith(favourite: favourite, updatedAt: now),
      );

  /// Favourites first, then most recently updated, then id.
  static int compareByRecency(SavedPrompt a, SavedPrompt b) {
    if (a.favourite != b.favourite) {
      return a.favourite ? -1 : 1;
    }
    final byUpdate = b.updatedAt.compareTo(a.updatedAt);
    return byUpdate != 0 ? byUpdate : a.id.compareTo(b.id);
  }

  /// A page of prompts, favourites first.
  Future<Page<SavedPrompt>> listByRecency({
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

  /// Searches title, body and tags, optionally narrowed to favourites or a tag.
  Future<Page<SavedPrompt>> search(
    String query, {
    PageRequest? page,
    int? limit,
    int? offset,
    bool favouritesOnly = false,
    String? tag,
  }) async {
    final request = PageRequest.validated(
      offset: offset ?? page?.offset ?? 0,
      limit: limit ?? page?.limit ?? defaultPageLimit,
      maxLimit: maxPageLimit,
    );
    final needleTag = tag?.trim().toLowerCase() ?? '';
    final matches = <SavedPrompt>[];
    for (final prompt in await readAll()) {
      if (favouritesOnly && !prompt.favourite) {
        continue;
      }
      if (needleTag.isNotEmpty &&
          !prompt.tags.any(
            (candidate) => candidate.toLowerCase() == needleTag,
          )) {
        continue;
      }
      if (prompt.matches(query)) {
        matches.add(prompt);
      }
    }
    matches.sort(compareByRecency);
    return pageOf<SavedPrompt>(matches, request, total: matches.length);
  }
}
