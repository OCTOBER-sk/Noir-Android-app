// Conversation persistence: what a conversation looks like after a restart, what
// happens with an empty collection, with a malformed record, and with a record
// written by the v1 schema.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/conversation_models.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/message_expectations.dart';
import 'support/noir_schema.dart';

void main() {
  late Directory root;
  late KeyValueStore store;
  late ConversationRepository conversations;
  var tick = 0;

  ConversationRepository makeRepository(KeyValueStore target) =>
      ConversationRepository(
        store: target,
        codec: const ConversationSnapshotCodec(),
        clock: () => DateTime.utc(2026, 7, 8).add(Duration(seconds: tick++)),
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_conversations_');
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(),
      clock: () => DateTime.utc(2026, 7, 8, 9),
    );
    conversations = makeRepository(store);
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('empty state', () {
    test('a fresh collection lists nothing and finds nothing', () async {
      expect(await conversations.readAll(), isEmpty);
      expect(await conversations.count(), isZero);
      expect(await conversations.find('missing'), isNull);
      expect(await conversations.exists('missing'), isFalse);
      expect(
        (await conversations.page(PageRequest(limit: 10))).isEmpty,
        isTrue,
      );
    });

    test('a conversation with no messages round-trips', () async {
      await conversations.upsert(
        conversations.newSnapshot(id: 'c-empty', title: 'Nothing yet'),
      );

      final loaded = (await conversations.find('c-empty'))!;

      expect(loaded.messages, isEmpty);
      expect(loaded.messageCount, 0);
      expect(loaded.lastMessage, isNull);
      expect(loaded.title, 'Nothing yet');
    });
  });

  group('lossless restore', () {
    test('every message field survives a save and load cycle', () async {
      final messages = <ConversationMessage>[
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'héllo — 日本語 😀\nsecond line',
        ),
        const ConversationMessage(
          id: 'assistant-1',
          role: MessageRole.assistant,
          text: 'partial answer',
          isStreaming: true,
        ),
        const ConversationMessage(
          id: 'assistant-2',
          role: MessageRole.assistant,
        ),
      ];
      await conversations.upsert(
        conversations.newSnapshot(
          id: 'c1',
          title: 'Trip',
          messages: messages,
          pinned: true,
        ),
      );

      final loaded = (await conversations.find('c1'))!;

      expectMessagesMatch(loaded.messages, messages, reason: 'after a reload');
      expect(loaded.pinned, isTrue);
      expect(loaded.title, 'Trip');
      expect(loaded.messages[1].isStreaming, isTrue);
      expect(loaded.messages[2].text, isEmpty);
    });

    test('message order is preserved exactly', () async {
      final messages = <ConversationMessage>[
        for (var i = 0; i < 25; i++)
          ConversationMessage(
            id: 'user-$i',
            role: i.isEven ? MessageRole.user : MessageRole.assistant,
            text: 'message $i',
          ),
      ];
      await conversations.upsert(
        conversations.newSnapshot(id: 'c1', messages: messages),
      );

      final loaded = (await conversations.find('c1'))!;

      expect(
        loaded.messages.map((m) => m.id).toList(),
        messages.map((m) => m.id).toList(),
      );
    });

    test('a conversation survives a restart on real files', () async {
      final messages = <ConversationMessage>[
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'durable?',
        ),
      ];
      await conversations.upsert(
        conversations.newSnapshot(
          id: 'c1',
          title: 'Durable',
          messages: messages,
        ),
      );

      final reopened = makeRepository(
        JsonFileKeyValueStore(
          root: root,
          catalog: buildNoirCatalog(),
          clock: () => DateTime.utc(2026, 7, 8, 10),
        ),
      );
      final loaded = (await reopened.find('c1'))!;

      expect(loaded.title, 'Durable');
      expectMessagesMatch(loaded.messages, messages, reason: 'after a restart');
    });

    test('an export is readable JSON that carries every message', () async {
      await conversations.upsert(
        conversations.newSnapshot(
          id: 'c1',
          title: 'Exported',
          messages: const <ConversationMessage>[
            ConversationMessage(
              id: 'user-1',
              role: MessageRole.user,
              text: 'q',
            ),
          ],
        ),
      );

      final exported = await conversations.export('c1');

      expect(exported['id'], 'c1');
      expect((exported['messages']! as List<Object?>).single, <String, Object?>{
        'id': 'user-1',
        'role': 'user',
        'text': 'q',
        'isStreaming': false,
      });
    });
  });

  group('appending', () {
    test('a message appended to a missing conversation creates it', () async {
      final created = await conversations.appendMessage(
        'c-new',
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'hi',
        ),
      );

      expect(created.messageCount, 1);
      final loaded = (await conversations.find('c-new'))!;
      expect(loaded.messages.single.text, 'hi');
      expect(loaded.title, 'New conversation');
    });

    test('appending keeps prior messages and stamps updatedAt', () async {
      final created = await conversations.appendMessage(
        'c1',
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'one',
        ),
      );
      final second = await conversations.appendMessage(
        'c1',
        const ConversationMessage(
          id: 'assistant-1',
          role: MessageRole.assistant,
          text: 'two',
        ),
      );

      expect(second.messages, hasLength(2));
      expect(second.messages.first.id, 'user-1');
      expect(
        second.updatedAt.isBefore(created.updatedAt),
        isFalse,
        reason: 'updatedAt must not move backwards',
      );
      expect((await conversations.find('c1'))!.messages, hasLength(2));
    });

    test('concurrent appends all land, none is lost', () async {
      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < 20; i++)
          conversations.appendMessage(
            'c1',
            ConversationMessage(
              id: 'user-$i',
              role: MessageRole.user,
              text: 'm$i',
            ),
          ),
      ]);

      final loaded = (await conversations.find('c1'))!;
      expect(loaded.messages, hasLength(20));
      expect(
        loaded.messages.map((m) => m.id).toSet(),
        hasLength(20),
        reason: 'every appended id must be present exactly once',
      );
    });

    test(
      'clearing messages leaves an empty but existing conversation',
      () async {
        await conversations.upsert(
          conversations.newSnapshot(
            id: 'c1',
            messages: const <ConversationMessage>[
              ConversationMessage(
                id: 'user-1',
                role: MessageRole.user,
                text: 'x',
              ),
            ],
          ),
        );

        final cleared = await conversations.clearMessages('c1');

        expect(cleared.messages, isEmpty);
        expect((await conversations.find('c1'))!.messages, isEmpty);
        expect(await conversations.exists('c1'), isTrue);
      },
    );

    test('a title is only replaced when asked for', () async {
      await conversations.upsert(
        conversations.newSnapshot(id: 'c1', title: 'Keep me'),
      );

      await conversations.appendMessage(
        'c1',
        const ConversationMessage(
          id: 'user-1',
          role: MessageRole.user,
          text: 'x',
        ),
      );
      final afterAppend = (await conversations.find('c1'))!;
      expect(afterAppend.title, 'Keep me');

      await conversations.rename('c1', 'Renamed');
      expect((await conversations.find('c1'))!.title, 'Renamed');
    });

    test(
      'renaming or clearing a missing conversation is an explicit error',
      () async {
        await expectLater(
          conversations.rename('nope', 'x'),
          throwsA(isA<RecordNotFoundError>()),
        );
        await expectLater(
          conversations.clearMessages('nope'),
          throwsA(isA<RecordNotFoundError>()),
        );
      },
    );
  });

  group('listing and limits', () {
    test('conversations are listed newest first', () async {
      for (var i = 0; i < 5; i++) {
        tick = i;
        await conversations.upsert(
          conversations.newSnapshot(
            id: 'c$i',
            title: 'conversation $i',
            createdAt: DateTime.utc(2026, 1, 1 + i),
            updatedAt: DateTime.utc(2026, 1, 1 + i),
          ),
        );
      }

      final page = await conversations.listRecent(limit: 3);

      expect(page.items.map((c) => c.id), <String>['c4', 'c3', 'c2']);
      expect(page.total, 5);
      expect(page.hasMore, isTrue);
      expect(page.nextPage!.offset, 3);
    });

    test('pinned conversations come first, then newest', () async {
      for (var i = 0; i < 3; i++) {
        await conversations.upsert(
          conversations.newSnapshot(
            id: 'c$i',
            createdAt: DateTime.utc(2026, 1, 1 + i),
            updatedAt: DateTime.utc(2026, 1, 1 + i),
          ),
        );
      }
      await conversations.upsert(
        conversations.newSnapshot(
          id: 'pinned-old',
          title: 'pinned',
          pinned: true,
          createdAt: DateTime.utc(2025, 1, 1),
          updatedAt: DateTime.utc(2025, 1, 1),
        ),
      );

      final page = await conversations.listRecent(limit: 10);

      expect(page.items.first.id, 'pinned-old');
      expect(page.items.map((c) => c.id).skip(1), <String>['c2', 'c1', 'c0']);
    });

    test('paging walks the whole list exactly once', () async {
      for (var i = 0; i < 7; i++) {
        tick = i;
        await conversations.upsert(
          conversations.newSnapshot(
            id: 'c$i',
            createdAt: DateTime.utc(2026, 1, 1 + i),
            updatedAt: DateTime.utc(2026, 1, 1 + i),
          ),
        );
      }

      final seen = <String>[];
      var request = PageRequest(limit: 3);
      while (true) {
        final page = await conversations.listRecent(page: request);
        seen.addAll(page.items.map((c) => c.id));
        final next = page.nextPage;
        if (next == null) {
          break;
        }
        request = next;
      }

      expect(seen, hasLength(7));
      expect(seen.toSet(), hasLength(7));
    });

    test('a zero limit returns an empty page but the real total', () async {
      await conversations.upsert(conversations.newSnapshot(id: 'c1'));

      final page = await conversations.listRecent(limit: 0);

      expect(page.items, isEmpty);
      expect(page.total, 1);
    });

    test('a limit above the maximum is capped', () async {
      final repository = ConversationRepository(
        store: store,
        codec: const ConversationSnapshotCodec(),
        maxPageLimit: 2,
      );

      final page = await repository.listRecent(limit: 100);

      expect(page.limit, 2);
    });

    test('a negative offset or limit is rejected', () async {
      expect(
        () => PageRequest.validated(offset: -1),
        throwsA(isA<InvalidPageRequestError>()),
      );
      expect(
        () => PageRequest.validated(limit: -5),
        throwsA(isA<InvalidPageRequestError>()),
      );
      await expectLater(
        () => conversations.listRecent(page: PageRequest.validated(offset: -1)),
        throwsA(isA<InvalidPageRequestError>()),
      );
    });

    test('an offset past the end is an empty page, not an error', () async {
      await conversations.upsert(conversations.newSnapshot(id: 'c1'));

      final page = await conversations.listRecent(
        page: PageRequest(offset: 50),
      );

      expect(page.items, isEmpty);
      expect(page.total, 1);
      expect(page.hasMore, isFalse);
    });
  });

  group('malformed and legacy records', () {
    test(
      'a record with a bad message field fails loudly and keeps its bytes',
      () async {
        await store.write(
          NoirCollections.conversations,
          'c1',
          <String, Object?>{
            'title': 'Broken',
            'pinned': false,
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
            'messages': <Object?>[
              <String, Object?>{'id': 'm1'},
            ],
          },
        );
        final before = await (store as RawStoreAccess).rawEnvelope(
          NoirCollections.conversations,
          'c1',
        );

        await expectLater(
          conversations.find('c1'),
          throwsA(
            isA<MalformedRecordError>()
                .having(
                  (e) => e.collection,
                  'collection',
                  NoirCollections.conversations,
                )
                .having((e) => e.id, 'id', 'c1'),
          ),
        );
        expect(
          await (store as RawStoreAccess).rawEnvelope(
            NoirCollections.conversations,
            'c1',
          ),
          before,
          reason: 'a shape error must not rewrite or delete anything',
        );
      },
    );

    test('a listing refuses to hide a malformed record by default', () async {
      await conversations.upsert(conversations.newSnapshot(id: 'good-1'));
      await store
          .write(NoirCollections.conversations, 'broken', <String, Object?>{
            'title': 42,
            'pinned': false,
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
            'messages': <Object?>[],
          });

      await expectLater(
        conversations.listRecent(limit: 10),
        throwsA(
          isA<MalformedRecordError>().having((e) => e.id, 'id', 'broken'),
        ),
      );
      expect(await conversations.count(), 2);
      expect(await conversations.ids(), contains('broken'));
    });

    test(
      'a listing that is told to skip unreadable records reports them',
      () async {
        await conversations.upsert(conversations.newSnapshot(id: 'good-1'));
        await store
            .write(NoirCollections.conversations, 'broken', <String, Object?>{
              'title': 42,
              'pinned': false,
              'createdAt': '2026-01-01T00:00:00.000Z',
              'updatedAt': '2026-01-01T00:00:00.000Z',
              'messages': <Object?>[],
            });
        final reported = <String>[];

        final page = await conversations.listRecent(
          limit: 10,
          onUnreadable: (id, error) => reported.add(id),
        );

        expect(page.items.map((c) => c.id), <String>['good-1']);
        expect(page.total, 2, reason: 'the broken record still exists on disk');
        expect(reported, <String>['broken']);
        await expectLater(
          conversations.find('broken'),
          throwsA(isA<MalformedRecordError>()),
        );
      },
    );

    test('a v1 record with body instead of text is migrated on read', () async {
      await store.writeAtVersion(
        NoirCollections.conversations,
        'legacy',
        1,
        <String, Object?>{
          'title': 'Old',
          'createdAt': '2025-05-05T10:00:00.000Z',
          'updatedAt': '2025-05-05T10:30:00.000Z',
          'messages': <Object?>[
            <String, Object?>{
              'id': 'user-1',
              'role': 'user',
              'body': 'legacy text',
            },
            <String, Object?>{
              'id': 'assistant-1',
              'role': 'assistant',
              'body': 'legacy reply',
              'streaming': true,
            },
          ],
        },
      );

      final loaded = (await conversations.find('legacy'))!;

      expect(loaded.title, 'Old');
      expect(loaded.pinned, isFalse);
      expect(loaded.createdAt, DateTime.utc(2025, 5, 5, 10));
      expect(loaded.messages, hasLength(2));
      expect(loaded.messages[0].text, 'legacy text');
      expect(loaded.messages[1].isStreaming, isTrue);
      final record = (await store.readRecord(
        NoirCollections.conversations,
        'legacy',
      ))!;
      expect(record.schemaVersion, 2, reason: 'the migration must be durable');
      expect(record.payload['messages'], isA<List<Object?>>());
    });

    test('a migrated conversation can be appended to without losing the old '
        'messages', () async {
      await store.writeAtVersion(
        NoirCollections.conversations,
        'legacy',
        1,
        <String, Object?>{
          'title': 'Old',
          'createdAt': '2025-05-05T10:00:00.000Z',
          'updatedAt': '2025-05-05T10:30:00.000Z',
          'messages': <Object?>[
            <String, Object?>{'id': 'user-1', 'role': 'user', 'body': 'old'},
          ],
        },
      );

      final appended = await conversations.appendMessage(
        'legacy',
        const ConversationMessage(
          id: 'user-2',
          role: MessageRole.user,
          text: 'new',
        ),
      );

      expect(appended.messages.map((m) => m.id), <String>['user-1', 'user-2']);
      expect(appended.messages.first.text, 'old');
      final record = (await store.readRecord(
        NoirCollections.conversations,
        'legacy',
      ))!;
      expect(record.schemaVersion, 2);
    });

    test(
      'a v1 record without a pinned flag is still readable after upgrade',
      () async {
        await store.writeAtVersion(
          NoirCollections.conversations,
          'legacy',
          1,
          <String, Object?>{
            'title': 'No pin field',
            'createdAt': '2025-05-05T10:00:00.000Z',
            'updatedAt': '2025-05-05T10:00:00.000Z',
            'messages': <Object?>[],
          },
        );

        expect((await conversations.find('legacy'))!.pinned, isFalse);
      },
    );
  });

  group('deletion', () {
    test('deleting a conversation removes it and its count', () async {
      await conversations.upsert(conversations.newSnapshot(id: 'c1'));
      await conversations.upsert(conversations.newSnapshot(id: 'c2'));

      await conversations.delete('c1');

      expect(await conversations.exists('c1'), isFalse);
      expect(await conversations.count(), 1);
      await conversations.delete('c1');
      expect(await conversations.count(), 1);
    });

    test('deleting everything empties the collection', () async {
      for (var i = 0; i < 4; i++) {
        await conversations.upsert(conversations.newSnapshot(id: 'c$i'));
      }

      expect(await conversations.deleteAll(), 4);
      expect(await conversations.count(), isZero);
    });
  });
}
