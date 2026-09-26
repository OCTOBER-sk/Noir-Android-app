// lib/data/conversation_repository.dart — durable conversation state.
//
// A conversation is stored as one record holding its whole message list, so
// restoring it is a single read and cannot produce a half-restored thread.
// Appending is a serialized read-modify-write inside the store, which is what
// makes concurrent appends safe.

import '../core/conversation_models.dart';
import 'codecs.dart';
import 'collection_repository.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'pagination.dart';
import 'records.dart';

class ConversationRepository
    extends CollectionRepository<ConversationSnapshot> {
  ConversationRepository({
    required super.store,
    super.codec = const ConversationSnapshotCodec(),
    super.clock,
    super.maxPageLimit,
  }) : super(collection: NoirCollections.conversations);

  /// A new, empty conversation with timestamps taken from the repository clock.
  ConversationSnapshot newSnapshot({
    required String id,
    String title = 'New conversation',
    bool pinned = false,
    List<ConversationMessage> messages = const <ConversationMessage>[],
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final stamp = now;
    return ConversationSnapshot(
      id: id,
      title: title,
      pinned: pinned,
      createdAt: createdAt ?? stamp,
      updatedAt: updatedAt ?? stamp,
      messages: messages,
    );
  }

  /// Appends [message], creating the conversation if it does not exist yet.
  ///
  /// Runs as one serialized read-modify-write, so two appends racing on the
  /// same conversation both land.
  Future<ConversationSnapshot> appendMessage(
    String conversationId,
    ConversationMessage message,
  ) async {
    final record = await store.mutateRecord(collection, conversationId, (
      current,
    ) {
      final existing = current == null
          ? null
          : codec.decode(conversationId, current);
      final base =
          existing ??
          newSnapshot(id: conversationId, createdAt: now, updatedAt: now);
      return codec.encode(
        base.copyWith(
          messages: <ConversationMessage>[...base.messages, message],
          updatedAt: now,
        ),
      );
    });
    return codec.decode(conversationId, record!.payload);
  }

  /// Replaces the title, failing loudly when the conversation does not exist.
  Future<ConversationSnapshot> rename(String id, String title) =>
      update(id, (current) => current.copyWith(title: title, updatedAt: now));

  /// Drops every message, keeping the conversation itself.
  Future<ConversationSnapshot> clearMessages(String id) => update(
    id,
    (current) => current.copyWith(
      messages: const <ConversationMessage>[],
      updatedAt: now,
    ),
  );

  /// Pins or unpins a conversation.
  Future<ConversationSnapshot> setPinned(String id, {required bool pinned}) =>
      update(id, (current) => current.copyWith(pinned: pinned, updatedAt: now));

  /// A page of conversations, pinned first and then most recently updated.
  Future<Page<ConversationSnapshot>> listRecent({
    PageRequest? page,
    int? limit,
    int? offset,
    void Function(String id, Object error)? onUnreadable,
  }) {
    final request = PageRequest.validated(
      offset: offset ?? page?.offset ?? 0,
      limit: limit ?? page?.limit ?? defaultPageLimit,
      maxLimit: maxPageLimit,
    );
    return pageOrdered(request, compareRecentFirst, onUnreadable: onUnreadable);
  }

  /// Pinned first, then newest [ConversationSnapshot.updatedAt], then id.
  static int compareRecentFirst(
    ConversationSnapshot a,
    ConversationSnapshot b,
  ) {
    if (a.pinned != b.pinned) {
      return a.pinned ? -1 : 1;
    }
    final byUpdate = b.updatedAt.compareTo(a.updatedAt);
    if (byUpdate != 0) {
      return byUpdate;
    }
    return a.id.compareTo(b.id);
  }

  /// A JSON-friendly view of one conversation, including its id.
  ///
  /// Contains no secrets: conversations are plain text, and the export is built
  /// from the same codec the store uses.
  Future<Map<String, Object?>> export(String id) async {
    final snapshot = await find(id);
    if (snapshot == null) {
      throw RecordNotFoundError(collection: collection, id: id);
    }
    return <String, Object?>{'id': snapshot.id, ...codec.encode(snapshot)};
  }
}
