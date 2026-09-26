// lib/data/collection_repository.dart — the CRUD shape every Noir collection has.
//
// Repositories add their own behaviour (search, aggregation, scheduling) on top
// of these primitives. What they all share is: id-ordered listing with paging, a
// total count, an atomic update that never clobbers a concurrent write, and
// errors that name the record that could not be read.

import 'codecs.dart';
import 'data_errors.dart';
import 'key_value_store.dart';
import 'pagination.dart';
import 'records.dart';

/// CRUD over one collection of [T].
abstract class CollectionRepository<T extends DataRecord> {
  CollectionRepository({
    required this.collection,
    required this.store,
    required this.codec,
    int maxPageLimit = defaultMaxPageLimit,
    DateTime Function()? clock,
  }) : maxPageLimit = PageRequest.validated(maxLimit: maxPageLimit).limit,
       _clock = clock ?? DateTime.now;

  /// The collection this repository owns.
  final String collection;

  final KeyValueStore store;
  final RecordCodec<T> codec;
  final int maxPageLimit;
  final DateTime Function() _clock;

  /// The clock used to stamp new records.
  DateTime get now => _clock().toUtc();

  /// The id of the record stored under [id], or null.
  Future<T?> find(String id) async {
    final payload = await store.read(collection, id);
    if (payload == null) {
      return null;
    }
    return codec.decode(id, payload);
  }

  /// Every record id in this collection, sorted.
  Future<List<String>> ids() => store.listIds(collection);

  /// A single page of records in id order.
  ///
  /// A record that cannot be decoded is an error, not a row to skip. Pass
  /// [onUnreadable] to handle them explicitly: the record is then left out of
  /// [Page.items] but still counted in [Page.total] and reported to the handler,
  /// so it is never dropped quietly.
  Future<Page<T>> page(
    PageRequest request, {
    void Function(String id, Object error)? onUnreadable,
  }) async {
    final validated = PageRequest.validated(
      offset: request.offset,
      limit: request.limit,
      maxLimit: maxPageLimit,
    );
    final all = await ids();
    if (validated.limit == 0) {
      return Page<T>(
        items: const <Never>[],
        offset: validated.offset,
        limit: validated.limit,
        total: all.length,
      );
    }
    // Paging by id avoids reading records that are not on the page.
    final window = all.skip(validated.offset).take(validated.limit).toList();
    final items = <T>[];
    for (final id in window) {
      final record = await _readOrReport(id, onUnreadable);
      if (record != null) {
        items.add(record);
      }
    }
    return Page<T>(
      items: items,
      offset: validated.offset,
      limit: validated.limit,
      total: all.length,
    );
  }

  Future<T?> _readOrReport(
    String id,
    void Function(String id, Object error)? onUnreadable,
  ) async {
    if (onUnreadable == null) {
      return find(id);
    }
    try {
      return await find(id);
    } on DataStoreException catch (error) {
      onUnreadable(id, error);
      return null;
    }
  }

  /// A page of every record ordered by [compare] instead of by id.
  ///
  /// Reads every record to sort it, so keep it for collections that stay small
  /// (conversations, prompts, memories, jobs) rather than for usage records.
  Future<Page<T>> pageOrdered(
    PageRequest request,
    int Function(T a, T b) compare, {
    void Function(String id, Object error)? onUnreadable,
  }) async {
    final validated = PageRequest.validated(
      offset: request.offset,
      limit: request.limit,
      maxLimit: maxPageLimit,
    );
    final all = await readAll(onUnreadable: onUnreadable);
    // Counted before the read so an unreadable record is still in the total.
    final total = onUnreadable == null ? all.length : (await ids()).length;
    if (validated.limit == 0) {
      return Page<T>(
        items: const <Never>[],
        offset: validated.offset,
        limit: validated.limit,
        total: total,
      );
    }
    final ordered = all.toList()..sort(compare);
    return pageOf<T>(ordered, validated, total: total);
  }

  /// Every record in the collection, in id order.
  Future<List<T>> readAll({
    void Function(String id, Object error)? onUnreadable,
  }) async {
    final records = <T>[];
    for (final id in await ids()) {
      final record = await _readOrReport(id, onUnreadable);
      if (record != null) {
        records.add(record);
      }
    }
    return List<T>.unmodifiable(records);
  }

  /// How many records the collection holds.
  Future<int> count() async => (await ids()).length;

  /// Whether a record exists under [id].
  Future<bool> exists(String id) => store.exists(collection, id);

  /// Creates or replaces a record and returns it as stored.
  Future<T> upsert(T record) async {
    await store.write(collection, record.id, codec.encode(record));
    return record;
  }

  /// Deletes a record. Deleting one that does not exist is a no-op.
  Future<void> delete(String id) => store.delete(collection, id);

  /// Deletes every record in the collection.
  Future<int> deleteAll() async {
    var removed = 0;
    for (final id in await ids()) {
      await store.delete(collection, id);
      removed++;
    }
    return removed;
  }

  /// Applies [mutate] to the stored record and persists the result inside the
  /// store's write queue, so a concurrent update cannot be lost.
  ///
  /// Throws [RecordNotFoundError] when the record does not exist and [mutate]
  /// returns null.
  Future<T> update(String id, T? Function(T current) mutate) async {
    final stored = await store.mutateRecord(collection, id, (current) {
      if (current == null) {
        throw RecordNotFoundError(collection: collection, id: id);
      }
      final next = mutate(codec.decode(id, current));
      return next == null ? null : codec.encode(next);
    });
    if (stored == null) {
      throw RecordNotFoundError(collection: collection, id: id);
    }
    return codec.decode(id, stored.payload);
  }

  /// Like [update], but creates the record when it is missing: [mutate] is
  /// called with null and must return a record.
  Future<T> updateOrCreate(String id, T Function(T? current) mutate) async {
    final stored = await store.mutateRecord(
      collection,
      id,
      (current) => codec.encode(
        mutate(current == null ? null : codec.decode(id, current)),
      ),
    );
    if (stored == null) {
      throw RecordNotFoundError(collection: collection, id: id);
    }
    return codec.decode(id, stored.payload);
  }
}
