// lib/data/records.dart — the records the data layer persists.
//
// A record is immutable, has an id (which is also its storage key) and
// timestamps. Records know how to describe themselves as JSON and how to build a
// copy with fields replaced; the codecs below turn that into strict,
// loss-validated storage payloads.

import '../core/conversation_models.dart';
import 'collections.dart';
import 'data_errors.dart';

/// Base class for every persisted record.
abstract class DataRecord {
  const DataRecord({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The storage key for this record, and its id within the collection.
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// A persisted [ConversationMessage].
///
/// The wire format is a plain map, so a conversation written by one build is
/// readable by the next. Role names are the [MessageRole] names, and every field
/// is required: a half-written message is an error, not a default.
class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.isStreaming,
  });

  factory StoredMessage.fromMessage(ConversationMessage message) =>
      StoredMessage(
        id: message.id,
        role: message.role,
        text: message.text,
        isStreaming: message.isStreaming,
      );

  /// Reads the v2 message format. [recordId] names the record in any error, and
  /// [field] prefixes the field name when this is a nested entry.
  factory StoredMessage.fromJson(
    String recordId,
    Map<String, Object?> json, {
    String collection = NoirCollections.conversations,
    String field = '',
  }) {
    String qualify(String key) => field.isEmpty ? key : '$field.$key';

    String requireString(String key) {
      final value = json[key];
      if (value is! String) {
        throw MalformedRecordError(
          collection: collection,
          id: recordId,
          field: qualify(key),
          detail: 'expected a string, got ${value.runtimeType}',
        );
      }
      return value;
    }

    // Validated in field order so the error always names the first bad field.
    final messageId = requireString('id');
    final roleName = requireString('role');
    final role = MessageRole.values.where((value) => value.name == roleName);
    if (role.isEmpty) {
      throw MalformedRecordError(
        collection: collection,
        id: recordId,
        field: qualify('role'),
        detail: 'unknown role "$roleName"',
      );
    }
    final text = requireString('text');
    final isStreaming = json['isStreaming'];
    if (isStreaming is! bool) {
      throw MalformedRecordError(
        collection: collection,
        id: recordId,
        field: qualify('isStreaming'),
        detail: 'expected a bool, got ${isStreaming.runtimeType}',
      );
    }
    return StoredMessage(
      id: messageId,
      role: role.single,
      text: text,
      isStreaming: isStreaming,
    );
  }

  final String id;
  final MessageRole role;
  final String text;
  final bool isStreaming;

  ConversationMessage toMessage() => ConversationMessage(
    id: id,
    role: role,
    text: text,
    isStreaming: isStreaming,
  );

  StoredMessage copyWith({
    String? id,
    MessageRole? role,
    String? text,
    bool? isStreaming,
  }) {
    return StoredMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      text: text ?? this.text,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'role': role.name,
    'text': text,
    'isStreaming': isStreaming,
  };

  @override
  bool operator ==(Object other) =>
      other is StoredMessage &&
      other.id == id &&
      other.role == role &&
      other.text == text &&
      other.isStreaming == isStreaming;

  @override
  int get hashCode => Object.hash(id, role, text, isStreaming);

  @override
  String toString() =>
      'StoredMessage($id, ${role.name}, streaming: $isStreaming, '
      '${text.length} chars)';
}

/// A stored message list, tolerant of the field renames older builds used.
List<StoredMessage> storedMessagesFromJson(
  Map<String, Object?> json, {
  required String collection,
  required String id,
  String field = 'messages',
}) {
  final raw = json[field];
  if (raw is! List) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: field,
      detail: 'expected a list, got ${raw.runtimeType}',
    );
  }
  final messages = <StoredMessage>[];
  for (var index = 0; index < raw.length; index++) {
    final entry = raw[index];
    if (entry is! Map) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: '$field[$index]',
        detail: 'expected an object, got ${entry.runtimeType}',
      );
    }
    messages.add(
      StoredMessage.fromJson(
        id,
        Map<String, Object?>.from(entry),
        collection: collection,
        field: '$field[$index]',
      ),
    );
  }
  return List<StoredMessage>.unmodifiable(messages);
}

/// A whole conversation: its messages plus the state the UI needs to restore it.
class ConversationSnapshot extends DataRecord {
  ConversationSnapshot({
    required super.id,
    required this.title,
    required this.pinned,
    required super.createdAt,
    required super.updatedAt,
    required List<ConversationMessage> messages,
  }) : messages = List<ConversationMessage>.unmodifiable(messages);

  /// Builds a snapshot from a controller-style message list.
  factory ConversationSnapshot.fromMessages({
    required String id,
    String title = '',
    bool pinned = false,
    required List<ConversationMessage> messages,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    return ConversationSnapshot(
      id: id,
      title: title,
      pinned: pinned,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
    );
  }

  final String title;
  final bool pinned;
  final List<ConversationMessage> messages;

  int get messageCount => messages.length;

  /// The last message in the conversation, if any.
  ConversationMessage? get lastMessage =>
      messages.isEmpty ? null : messages.last;

  ConversationSnapshot copyWith({
    String? title,
    bool? pinned,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ConversationMessage>? messages,
  }) {
    return ConversationSnapshot(
      id: id,
      title: title ?? this.title,
      pinned: pinned ?? this.pinned,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'pinned': pinned,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'messages': <Map<String, Object?>>[
      for (final message in messages)
        StoredMessage.fromMessage(message).toJson(),
    ],
  };

  @override
  String toString() =>
      'ConversationSnapshot($id, "$title", ${messages.length} message(s), '
      'pinned: $pinned)';
}
