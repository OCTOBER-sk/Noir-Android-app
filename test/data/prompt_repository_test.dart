// Saved prompts: CRUD, search, tags, favourites and paging.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/noir_schema.dart';

void main() {
  late Directory root;
  late KeyValueStore store;
  late PromptRepository prompts;
  var tick = 0;

  SavedPrompt prompt({
    required String id,
    String title = 'Untitled',
    String body = 'do the thing',
    List<String> tags = const <String>[],
    bool favourite = false,
    DateTime? updatedAt,
  }) {
    final stamp = DateTime.utc(2026, 4, 1).add(Duration(minutes: tick++));
    return SavedPrompt(
      id: id,
      title: title,
      body: body,
      tags: tags,
      favourite: favourite,
      createdAt: stamp,
      updatedAt: updatedAt ?? stamp,
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_prompts_');
    store = JsonFileKeyValueStore(
      root: root,
      catalog: buildNoirCatalog(),
      clock: () => DateTime.utc(2026, 4, 1, 12),
    );
    prompts = PromptRepository(
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
    expect(await prompts.readAll(), isEmpty);
    expect(await prompts.count(), isZero);
    expect((await prompts.search('anything')).items, isEmpty);
  });

  test('a prompt round-trips with tags and the favourite flag', () async {
    await prompts.upsert(
      prompt(
        id: 'p1',
        title: 'Summarise',
        body: 'Summarise the following in one line:',
        tags: const <String>['work', 'summary'],
        favourite: true,
      ),
    );

    final loaded = (await prompts.find('p1'))!;

    expect(loaded.title, 'Summarise');
    expect(loaded.body, 'Summarise the following in one line:');
    expect(loaded.tags, <String>['summary', 'work']);
    expect(loaded.favourite, isTrue);
    expect(loaded.wordCount, 6);
  });

  test('duplicate tags are collapsed and blank tags dropped', () async {
    final saved = await prompts.upsert(
      prompt(id: 'p1', tags: const <String>['a', 'a', '  ', 'b', 'A']),
    );

    expect((await prompts.find('p1'))!.tags, <String>[
      'a',
      'b',
    ], reason: 'tags are trimmed, sorted and de-duplicated case-insensitively');
    expect(saved.tags, hasLength(2));
  });

  test('a prompt with a blank title or body is rejected', () async {
    expect(
      () => prompt(id: 'p1', title: '   '),
      throwsA(isA<InvalidDataError>()),
    );
    expect(
      () => prompt(id: 'p2', body: '\n\t'),
      throwsA(isA<InvalidDataError>()),
    );
    expect(await prompts.count(), isZero);
  });

  test('tags longer than the limit are rejected', () async {
    expect(
      () =>
          prompt(id: 'p1', tags: <String>[List<String>.filled(40, 'x').join()]),
      throwsA(isA<InvalidDataError>()),
    );
  });

  test('search matches title, body and tags, case-insensitively', () async {
    await prompts.upsert(prompt(id: 'a', title: 'Translate', body: 'deepl'));
    await prompts.upsert(
      prompt(id: 'b', title: 'Cook', body: 'TRADITIONAL soup'),
    );
    await prompts.upsert(
      prompt(
        id: 'c',
        title: 'Other',
        body: 'nothing',
        tags: const <String>['Translate'],
      ),
    );
    await prompts.upsert(prompt(id: 'd', title: 'Unrelated', body: 'nope'));

    final found = await prompts.search('translate');

    expect(found.items.map((p) => p.id).toSet(), <String>{
      'a',
      'c',
    }, reason: 'a title match and a tag match, not a body match');
    expect(found.total, 2);
    expect((await prompts.search('soup')).items.map((p) => p.id), <String>[
      'b',
    ], reason: 'the body is matched case-insensitively too');
  });

  test('search with a blank query returns everything', () async {
    await prompts.upsert(prompt(id: 'a'));
    await prompts.upsert(prompt(id: 'b'));

    expect((await prompts.search('   ')).total, 2);
  });

  test('search can be restricted to favourites or to a tag', () async {
    await prompts.upsert(
      prompt(id: 'a', favourite: true, tags: const <String>['work']),
    );
    await prompts.upsert(prompt(id: 'b', tags: const <String>['work']));
    await prompts.upsert(prompt(id: 'c', tags: const <String>['play']));

    expect(
      (await prompts.search('', favouritesOnly: true)).items.map((p) => p.id),
      <String>['a'],
    );
    expect(
      (await prompts.search('', tag: 'work')).items.map((p) => p.id).toSet(),
      <String>{'a', 'b'},
    );
    expect((await prompts.search('', tag: 'missing')).items, isEmpty);
  });

  test('favourites are listed first, then most recently updated', () async {
    await prompts.upsert(
      prompt(id: 'old', updatedAt: DateTime.utc(2026, 1, 1)),
    );
    await prompts.upsert(
      prompt(id: 'new', updatedAt: DateTime.utc(2026, 6, 1)),
    );
    await prompts.upsert(
      prompt(id: 'star', favourite: true, updatedAt: DateTime.utc(2020)),
    );

    final page = await prompts.listByRecency(limit: 10);

    expect(page.items.map((p) => p.id), <String>['star', 'new', 'old']);
  });

  test('search results are paged with a real total', () async {
    for (var i = 0; i < 7; i++) {
      await prompts.upsert(prompt(id: 'p$i', title: 'Find me $i'));
    }

    final first = await prompts.search('find me', limit: 3);

    expect(first.items, hasLength(3));
    expect(first.total, 7);
    expect(first.hasMore, isTrue);
    final second = await prompts.search('find me', page: first.nextPage);
    expect(second.offset, 3);
    expect(second.items, hasLength(3));
    final third = await prompts.search('find me', page: second.nextPage);
    expect(third.items, hasLength(1));
    expect(third.hasMore, isFalse);
    expect(third.nextPage, isNull);
  });

  test('paging through search never repeats or drops a prompt', () async {
    for (var i = 0; i < 11; i++) {
      await prompts.upsert(prompt(id: 'p$i', title: 'Find me $i'));
    }

    final seen = <String>[];
    var request = PageRequest(limit: 4);
    while (true) {
      final page = await prompts.search('find me', page: request);
      seen.addAll(page.items.map((p) => p.id));
      final next = page.nextPage;
      if (next == null) {
        break;
      }
      request = next;
    }

    expect(seen, hasLength(11));
    expect(seen.toSet(), hasLength(11));
  });

  test('setting a favourite is persisted', () async {
    await prompts.upsert(prompt(id: 'p1'));

    final starred = await prompts.setFavourite('p1', favourite: true);

    expect(starred.favourite, isTrue);
    expect((await prompts.find('p1'))!.favourite, isTrue);
  });

  test(
    'setting a favourite on a missing prompt is an explicit error',
    () async {
      await expectLater(
        prompts.setFavourite('nope', favourite: true),
        throwsA(isA<RecordNotFoundError>()),
      );
    },
  );

  test('a duplicate save replaces the prompt and keeps createdAt', () async {
    final first = await prompts.upsert(prompt(id: 'p1', title: 'First'));
    final second = await prompts.upsert(
      SavedPrompt(
        id: 'p1',
        title: 'Second',
        body: 'new body',
        tags: const <String>[],
        favourite: false,
        createdAt: DateTime.utc(2000),
        updatedAt: DateTime.utc(2030),
      ),
    );

    expect(second.title, 'Second');
    expect(
      second.createdAt,
      first.createdAt,
      reason: 'createdAt is decided by the first save',
    );
    expect((await prompts.find('p1'))!.body, 'new body');
  });

  test('a malformed record fails loudly and keeps its bytes', () async {
    await store.write(NoirCollections.prompts, 'broken', <String, Object?>{
      'title': 'ok',
      'body': <Object?>[],
      'tags': <Object?>[],
      'favourite': false,
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
    });
    final before = await (store as RawStoreAccess).rawEnvelope(
      NoirCollections.prompts,
      'broken',
    );

    await expectLater(
      prompts.find('broken'),
      throwsA(
        isA<MalformedRecordError>().having((e) => e.field, 'field', 'body'),
      ),
    );
    expect(
      await (store as RawStoreAccess).rawEnvelope(
        NoirCollections.prompts,
        'broken',
      ),
      before,
    );
  });

  test('a prompt survives a restart', () async {
    await prompts.upsert(
      prompt(id: 'p1', title: 'Durable', tags: const <String>['x']),
    );

    final reopened = PromptRepository(
      store: JsonFileKeyValueStore(root: root, catalog: buildNoirCatalog()),
    );

    final loaded = (await reopened.find('p1'))!;
    expect(loaded.title, 'Durable');
    expect(loaded.tags, <String>['x']);
  });

  test('deleting removes the prompt', () async {
    await prompts.upsert(prompt(id: 'p1'));

    await prompts.delete('p1');

    expect(await prompts.exists('p1'), isFalse);
    expect(await prompts.count(), isZero);
  });
}
