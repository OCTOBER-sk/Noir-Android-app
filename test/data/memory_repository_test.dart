// Memories: the durable, user-visible notes the agent is allowed to keep.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/noir_schema.dart';

void main() {
  late Directory root;
  late KeyValueStore store;
  late MemoryRepository memories;
  var tick = 0;

  MemoryEntry entry({
    required String id,
    String key = 'note',
    String value = 'a remembered fact',
    MemoryScope scope = MemoryScope.global,
    List<String> tags = const <String>[],
    bool pinned = false,
    DateTime? updatedAt,
  }) {
    final stamp = DateTime.utc(2026, 4, 1).add(Duration(minutes: tick++));
    return MemoryEntry(
      id: id,
      key: key,
      value: value,
      scope: scope,
      tags: tags,
      pinned: pinned,
      createdAt: stamp,
      updatedAt: updatedAt ?? stamp,
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_memories_');
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(),
      clock: () => DateTime.utc(2026, 4, 1, 12),
    );
    memories = MemoryRepository(
      store: store,
      clock: () => DateTime.utc(2026, 4, 1, 12),
    );
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('a fresh repository is empty', () async {
    expect(await memories.readAll(), isEmpty);
    expect(await memories.count(), isZero);
    expect(await memories.findByKey('note'), isEmpty);
  });

  test('a memory round-trips with scope, tags and pin state', () async {
    await memories.upsert(
      entry(
        id: 'm1',
        key: 'user.timezone',
        value: 'Europe/Berlin',
        scope: MemoryScope.conversation,
        tags: const <String>['profile'],
        pinned: true,
      ),
    );

    final loaded = (await memories.find('m1'))!;

    expect(loaded.key, 'user.timezone');
    expect(loaded.value, 'Europe/Berlin');
    expect(loaded.scope, MemoryScope.conversation);
    expect(loaded.tags, <String>['profile']);
    expect(loaded.pinned, isTrue);
    expect(loaded.scopeName, 'conversation');
  });

  test('a blank key or value is rejected', () async {
    expect(() => entry(id: 'm1', key: '  '), throwsA(isA<InvalidDataError>()));
    expect(
      () => entry(id: 'm2', value: '\n'),
      throwsA(isA<InvalidDataError>()),
    );
    expect(await memories.count(), isZero);
  });

  test('upserting by key keeps one record per key', () async {
    await memories.upsert(entry(id: 'first', key: 'user.name', value: 'Ada'));
    await memories.upsert(
      entry(id: 'second', key: 'user.name', value: 'Grace'),
    );

    final all = await memories.readAll();

    expect(all, hasLength(2), reason: 'the id decides identity, not the key');
    expect(await memories.findByKey('user.name'), hasLength(2));
  });

  test('a search matches key, value and tags', () async {
    await memories.upsert(
      entry(
        id: 'm1',
        key: 'user.name',
        value: 'Ada',
        tags: const <String>['profile'],
      ),
    );
    await memories.upsert(entry(id: 'm2', key: 'user.lang', value: 'ENGLISH'));
    await memories.upsert(entry(id: 'm3', key: 'other', value: 'nothing'));

    expect(
      (await memories.search('user.name')).items.map((m) => m.id),
      <String>['m1'],
    );
    expect((await memories.search('english')).items.map((m) => m.id), <String>[
      'm2',
    ]);
    expect((await memories.search('profile')).items.map((m) => m.id), <String>[
      'm1',
    ]);
  });

  test('search can be narrowed by scope and pin state', () async {
    await memories.upsert(entry(id: 'g', scope: MemoryScope.global));
    await memories.upsert(entry(id: 'c', scope: MemoryScope.conversation));
    await memories.upsert(entry(id: 'p', pinned: true));

    expect(
      (await memories.search(
        '',
        scope: MemoryScope.conversation,
      )).items.map((m) => m.id),
      <String>['c'],
    );
    expect(
      (await memories.search('', pinnedOnly: true)).items.map((m) => m.id),
      <String>['p'],
    );
  });

  test('pinned memories are listed first, then most recently used', () async {
    await memories.upsert(
      entry(id: 'old', updatedAt: DateTime.utc(2026, 1, 1)),
    );
    await memories.upsert(
      entry(id: 'new', updatedAt: DateTime.utc(2026, 6, 1)),
    );
    await memories.upsert(
      entry(id: 'star', pinned: true, updatedAt: DateTime.utc(2020)),
    );

    final page = await memories.listByRecency(limit: 10);

    expect(page.items.map((m) => m.id), <String>['star', 'new', 'old']);
  });

  test('touching a memory moves it to the front and is persisted', () async {
    await memories.upsert(entry(id: 'm1', updatedAt: DateTime.utc(2020, 1, 1)));
    await memories.upsert(entry(id: 'm2', updatedAt: DateTime.utc(2026, 6, 1)));

    final touched = await memories.touch('m1', at: DateTime.utc(2027, 1, 1));

    expect(touched.updatedAt, DateTime.utc(2027, 1, 1));
    expect(touched.lastUsedAt, DateTime.utc(2027, 1, 1));
    final page = await memories.listByRecency(limit: 10);
    expect(page.items.map((m) => m.id), <String>['m1', 'm2']);
    expect((await memories.find('m1'))!.lastUsedAt, DateTime.utc(2027, 1, 1));
  });

  test('touching a memory that does not exist is an explicit error', () async {
    await expectLater(
      memories.touch('nope'),
      throwsA(isA<RecordNotFoundError>()),
    );
  });

  test('an unknown scope name in a stored record is malformed', () async {
    await store.write(NoirCollections.memories, 'm1', <String, Object?>{
      'key': 'k',
      'value': 'v',
      'scope': 'galaxy',
      'tags': <Object?>[],
      'pinned': false,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
    });

    await expectLater(
      memories.find('m1'),
      throwsA(
        isA<MalformedRecordError>().having((e) => e.field, 'field', 'scope'),
      ),
    );
  });

  test('a negative pinned value is malformed, not false', () async {
    await store.write(NoirCollections.memories, 'm1', <String, Object?>{
      'key': 'k',
      'value': 'v',
      'scope': 'global',
      'tags': <Object?>[],
      'pinned': -1,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
    });

    await expectLater(
      memories.find('m1'),
      throwsA(
        isA<MalformedRecordError>().having((e) => e.field, 'field', 'pinned'),
      ),
    );
  });

  test('a memory survives a restart', () async {
    await memories.upsert(
      entry(
        id: 'm1',
        key: 'user.name',
        value: 'Ada',
        tags: const <String>['x'],
      ),
    );

    final reopened = MemoryRepository(
      store: JsonFileKeyValueStore(root: root, catalog: buildNoirCatalog()),
    );

    final loaded = (await reopened.find('m1'))!;
    expect(loaded.value, 'Ada');
    expect(loaded.tags, <String>['x']);
    expect(loaded.scope, MemoryScope.global);
  });

  test('forgetting removes a memory', () async {
    await memories.upsert(entry(id: 'm1'));
    await memories.upsert(entry(id: 'm2'));

    await memories.forget('m1');

    expect(await memories.exists('m1'), isFalse);
    expect(await memories.count(), 1);
  });
}
