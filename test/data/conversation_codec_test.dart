// Serialization of Noir records: what is written, what is read back, and what
// counts as malformed. Nothing here depends on a backend, so it is tested
// against the codec directly and again through the repositories.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_models.dart';
import 'package:noir_android_app/data/data.dart';

void main() {
  final at = DateTime.utc(2026, 5, 6, 7, 8, 9);

  group('StoredMessage', () {
    test('round-trips every field of a ConversationMessage', () {
      const original = ConversationMessage(
        id: 'assistant-1',
        role: MessageRole.assistant,
        text: 'héllo\nworld',
        isStreaming: true,
      );

      final stored = StoredMessage.fromMessage(original);
      final restored = stored.toMessage();

      expect(restored.id, original.id);
      expect(restored.role, original.role);
      expect(restored.text, original.text);
      expect(restored.isStreaming, original.isStreaming);
      expect(restored.content, original.content);
    });

    test(
      'an empty streamed message keeps its empty text and streaming flag',
      () {
        const original = ConversationMessage(
          id: 'assistant-9',
          role: MessageRole.assistant,
        );

        final restored = StoredMessage.fromMessage(original).toMessage();

        expect(restored.text, isEmpty);
        expect(restored.isStreaming, isFalse);
      },
    );

    test('an unknown role name is malformed, not a silent default', () {
      expect(
        () => StoredMessage.fromJson('m1', <String, Object?>{
          'id': 'm1',
          'role': 'system',
          'text': 'hi',
          'isStreaming': false,
        }),
        throwsA(
          isA<MalformedRecordError>().having((e) => e.field, 'field', 'role'),
        ),
      );
    });

    test('a missing required field is malformed', () {
      expect(
        () => StoredMessage.fromJson('m1', <String, Object?>{'role': 'user'}),
        throwsA(
          isA<MalformedRecordError>().having((e) => e.field, 'field', 'id'),
        ),
      );
    });

    test('a text field of the wrong type is malformed', () {
      expect(
        () => StoredMessage.fromJson('m1', <String, Object?>{
          'id': 'm1',
          'role': 'user',
          'text': 12,
          'isStreaming': false,
        }),
        throwsA(
          isA<MalformedRecordError>().having((e) => e.field, 'field', 'text'),
        ),
      );
    });

    test('an isStreaming field of the wrong type is malformed', () {
      expect(
        () => StoredMessage.fromJson('m1', <String, Object?>{
          'id': 'm1',
          'role': 'user',
          'text': 'hi',
          'isStreaming': 'yes',
        }),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'isStreaming',
          ),
        ),
      );
    });

    test('unknown extra fields are ignored so a newer build can add them', () {
      final message = StoredMessage.fromJson('m1', <String, Object?>{
        'id': 'm1',
        'role': 'user',
        'text': 'hi',
        'isStreaming': false,
        'futureField': <Object?>[1, 2],
      });

      expect(message.toJson(), <String, Object?>{
        'id': 'm1',
        'role': 'user',
        'text': 'hi',
        'isStreaming': false,
      });
    });
  });

  group('ConversationSnapshot codec', () {
    final snapshot = ConversationSnapshot(
      id: 'c1',
      title: 'Trip planning',
      pinned: true,
      createdAt: at,
      updatedAt: at.add(const Duration(minutes: 5)),
      messages: const <ConversationMessage>[
        ConversationMessage(id: 'user-1', role: MessageRole.user, text: 'hi'),
        ConversationMessage(
          id: 'assistant-1',
          role: MessageRole.assistant,
          text: 'hello',
        ),
      ],
    );

    test('a round trip is lossless', () {
      final encoded = ConversationSnapshotCodec().encode(snapshot);
      final decoded = ConversationSnapshotCodec().decode('c1', encoded);

      expect(decoded.id, 'c1');
      expect(decoded.title, 'Trip planning');
      expect(decoded.pinned, isTrue);
      expect(decoded.createdAt, at);
      expect(decoded.updatedAt, at.add(const Duration(minutes: 5)));
      expect(decoded.messages, hasLength(2));
      expect(decoded.messages[0].text, 'hi');
      expect(decoded.messages[0].role, MessageRole.user);
      expect(decoded.messages[1].text, 'hello');
      expect(decoded.messages[1].role, MessageRole.assistant);
      expect(decoded.messages[1].isStreaming, isFalse);
    });

    test('the id is the storage key, not a duplicated field', () {
      final encoded = ConversationSnapshotCodec().encode(snapshot);

      expect(encoded.containsKey('id'), isFalse);
      expect(encoded.containsKey('createdAt'), isTrue);
      expect(encoded.containsKey('updatedAt'), isTrue);
    });

    test('timestamps are stored as UTC ISO-8601 strings', () {
      final local = DateTime(2026, 5, 6, 9, 8, 9);
      final encoded = ConversationSnapshotCodec().encode(
        ConversationSnapshot(
          id: 'c1',
          title: 'local time',
          pinned: false,
          createdAt: local,
          updatedAt: local,
          messages: const <ConversationMessage>[],
        ),
      );

      expect(encoded['createdAt'], '2026-05-06T09:08:09.000Z');
    });

    test('a non-UTC timestamp comes back as the same instant', () {
      final local = DateTime(2026, 5, 6, 9, 8, 9);
      final snapshot = ConversationSnapshot(
        id: 'c1',
        title: 'x',
        pinned: false,
        createdAt: local,
        updatedAt: local,
        messages: const <ConversationMessage>[],
      );

      final decoded = ConversationSnapshotCodec().decode(
        'c1',
        ConversationSnapshotCodec().encode(snapshot),
      );

      expect(decoded.createdAt.toUtc(), local.toUtc());
    });

    test('a messages field that is not a list is malformed', () {
      expect(
        () => ConversationSnapshotCodec().decode('c1', <String, Object?>{
          'title': 'x',
          'pinned': false,
          'createdAt': at.toIso8601String(),
          'updatedAt': at.toIso8601String(),
          'messages': 'not a list',
        }),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'messages',
          ),
        ),
      );
    });

    test('a message entry that is not an object is malformed', () {
      expect(
        () => ConversationSnapshotCodec().decode('c1', <String, Object?>{
          'title': 'x',
          'pinned': false,
          'createdAt': at.toIso8601String(),
          'updatedAt': at.toIso8601String(),
          'messages': <Object?>['not an object'],
        }),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'messages[0]',
          ),
        ),
      );
    });

    test('a bad timestamp is malformed and names the field', () {
      expect(
        () => ConversationSnapshotCodec().decode('c1', <String, Object?>{
          'title': 'x',
          'pinned': false,
          'createdAt': 'yesterday',
          'updatedAt': at.toIso8601String(),
          'messages': <Object?>[],
        }),
        throwsA(
          isA<MalformedRecordError>().having(
            (e) => e.field,
            'field',
            'createdAt',
          ),
        ),
      );
    });

    test('a missing title is malformed, never an empty string', () {
      expect(
        () => ConversationSnapshotCodec().decode('c1', <String, Object?>{
          'pinned': false,
          'createdAt': at.toIso8601String(),
          'updatedAt': at.toIso8601String(),
          'messages': <Object?>[],
        }),
        throwsA(
          isA<MalformedRecordError>().having((e) => e.field, 'field', 'title'),
        ),
      );
    });

    test('a pinned field of the wrong type is malformed', () {
      expect(
        () => ConversationSnapshotCodec().decode('c1', <String, Object?>{
          'title': 'x',
          'pinned': 1,
          'createdAt': at.toIso8601String(),
          'updatedAt': at.toIso8601String(),
          'messages': <Object?>[],
        }),
        throwsA(
          isA<MalformedRecordError>().having((e) => e.field, 'field', 'pinned'),
        ),
      );
    });

    test(
      'copyWith can change the title and pin state without touching ids',
      () {
        final updated = snapshot.copyWith(title: 'Renamed', pinned: false);

        expect(updated.title, 'Renamed');
        expect(updated.pinned, isFalse);
        expect(updated.id, snapshot.id);
        expect(updated.createdAt, snapshot.createdAt);
        expect(updated.messages, snapshot.messages);
      },
    );

    test('the returned message list cannot be mutated by a caller', () {
      final decoded = ConversationSnapshotCodec().decode(
        'c1',
        ConversationSnapshotCodec().encode(snapshot),
      );

      expect(
        () => decoded.messages.add(
          const ConversationMessage(id: 'x', role: MessageRole.user),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
