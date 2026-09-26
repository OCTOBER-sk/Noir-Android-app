// lib/data/codecs.dart — strict, hand-written JSON codecs.
//
// There is no code generation here on purpose: a codec is the place where a
// stored record is validated, and each field gets a named error so a corrupt or
// hand-edited file says which field is wrong. Decoding never invents a default
// for a field that must be there, and unknown fields are ignored so a newer
// build can add them.

import '../core/conversation_models.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'records.dart';

/// Reads a required string field.
String requireString(
  Map<String, Object?> json,
  String key,
  String collection,
  String id,
) {
  final value = json[key];
  if (value is! String) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'expected a string, got ${value.runtimeType}',
    );
  }
  return value;
}

/// Reads an optional string field, defaulting to null.
String? optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    return null;
  }
  return value;
}

/// Reads a required bool field.
bool requireBool(
  Map<String, Object?> json,
  String key,
  String collection,
  String id,
) {
  final value = json[key];
  if (value is! bool) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'expected a bool, got ${value.runtimeType}',
    );
  }
  return value;
}

/// Reads a bool field that older schema versions did not have.
///
/// Absent means [defaultValue]; present but not a bool is an error, because a
/// silently dropped flag is how a record loses state.
bool optionalBool(
  Map<String, Object?> json,
  String key,
  String collection,
  String id, {
  bool defaultValue = false,
}) {
  final value = json[key];
  if (value == null) {
    return defaultValue;
  }
  if (value is! bool) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'expected a bool, got ${value.runtimeType}',
    );
  }
  return value;
}

/// Reads a required non-negative int field.
int requireInt(
  Map<String, Object?> json,
  String key,
  String collection,
  String id,
) {
  final value = json[key];
  if (value is! int) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'expected an int, got ${value.runtimeType}',
    );
  }
  if (value < 0) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'expected a non-negative int, got $value',
    );
  }
  return value;
}

/// Reads a required ISO-8601 timestamp field.
DateTime requireTimestamp(
  Map<String, Object?> json,
  String key,
  String collection,
  String id,
) {
  final value = json[key];
  if (value is! String) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'expected an ISO-8601 timestamp string, got ${value.runtimeType}',
    );
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'not a valid ISO-8601 timestamp: "$value"',
    );
  }
  return parsed.toUtc();
}

/// Reads a list of strings, rejecting anything that is not a list of strings.
List<String> requireStringList(
  Map<String, Object?> json,
  String key,
  String collection,
  String id,
) {
  final value = json[key];
  if (value is! List) {
    throw MalformedRecordError(
      collection: collection,
      id: id,
      field: key,
      detail: 'expected a list, got ${value.runtimeType}',
    );
  }
  final items = <String>[];
  for (var index = 0; index < value.length; index++) {
    final entry = value[index];
    if (entry is! String) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: '$key[$index]',
        detail: 'expected a string, got ${entry.runtimeType}',
      );
    }
    items.add(entry);
  }
  return items;
}

/// Turns a record into a stored payload.
abstract class RecordCodec<T extends DataRecord> {
  const RecordCodec();

  Map<String, Object?> encode(T record);

  /// Decodes a payload. Implementations throw [MalformedRecordError] with the
  /// offending field name rather than substituting defaults.
  T decode(String id, Map<String, Object?> json);
}

/// Conversations: schema version 2.
///
/// v1 stored message text under `body`, and had no `pinned` flag.
class ConversationSnapshotCodec extends RecordCodec<ConversationSnapshot> {
  const ConversationSnapshotCodec();

  @override
  Map<String, Object?> encode(ConversationSnapshot record) => record.toJson();

  @override
  ConversationSnapshot decode(String id, Map<String, Object?> json) {
    final collection = NoirCollections.conversations;
    final title = requireString(json, 'title', collection, id);
    final pinned = optionalBool(json, 'pinned', collection, id);
    final createdAt = requireTimestamp(json, 'createdAt', collection, id);
    final updatedAt = requireTimestamp(json, 'updatedAt', collection, id);
    final messages = storedMessagesFromJson(
      json,
      collection: collection,
      id: id,
    );
    return ConversationSnapshot(
      id: id,
      title: title,
      pinned: pinned,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: <ConversationMessage>[
        for (final message in messages) message.toMessage(),
      ],
    );
  }
}
