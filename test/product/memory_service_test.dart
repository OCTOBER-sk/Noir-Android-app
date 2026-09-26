// Product subsystem 1 — Memory (A2 "Save as Fact").
//
// Scope note: this exercises the real MemoryService against real injected
// stores (the in-memory store shipped in lib/ and a recording store defined
// here). No disk or platform persistence is claimed — lib/data is untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/core/clock.dart';
import 'package:noir_android_app/memory/memory_service.dart';

/// Test double: in-memory store that records every call so the tests can prove
/// MemoryService reaches the store through the injected interface only.
class RecordingMemoryStore implements MemoryStore {
  final Map<String, MemoryEntry> rows = <String, MemoryEntry>{};
  final List<String> calls = <String>[];

  @override
  List<MemoryEntry> readAll() {
    calls.add('readAll');
    return List<MemoryEntry>.of(rows.values);
  }

  @override
  void write(MemoryEntry entry) {
    calls.add('write:${entry.id}');
    rows[entry.id] = entry;
  }

  @override
  void remove(String id) {
    calls.add('remove:$id');
    rows.remove(id);
  }

  @override
  void clear() {
    calls.add('clear');
    rows.clear();
  }
}

void main() {
  late FakeClock clock;

  setUp(() => clock = FakeClock(DateTime.utc(2026, 3, 1, 9)));

  group('MemoryService — store injection and empty start', () {
    test('a fresh service holds no sample data and injects its store', () {
      final store = InMemoryMemoryStore();
      final service = MemoryService(store: store, clock: clock);

      expect(service.store, same(store));
      expect(service.list(), isEmpty);
      expect(service.search('anything'), isEmpty);
      expect(service.size, 0);
    });

    test('every mutation is routed through the injected MemoryStore', () {
      final store = RecordingMemoryStore();
      final service = MemoryService(store: store, clock: clock);

      final entry = service.add(
        'dark roast is the default order',
        sourceId: 'msg-1',
      );
      service.update(entry.id, content: 'light roast is the default order');
      service.delete(entry.id);

      expect(
        store.calls.where((String c) => !c.startsWith('readAll')).toList(),
        <String>[
          'write:${entry.id}',
          'write:${entry.id}',
          'remove:${entry.id}',
        ],
      );
      expect(
        store.calls.where((String c) => c == 'readAll'),
        isNotEmpty,
        reason: 'the store is the only source of truth, so it is read back',
      );
      expect(store.rows, isEmpty);
    });
  });

  group('MemoryService — add and provenance', () {
    test('add records content, provenance and both timestamps', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);

      final entry = service.add(
        'office wifi password rotates monthly',
        sourceId: 'conv-7#msg-3',
        origin: MemoryOrigin.userExplicit,
        tags: <String>['wifi', 'secrets-adjacent'],
        key: 'wifi.password',
      );

      expect(entry.id, 'mem-0001');
      expect(entry.content, 'office wifi password rotates monthly');
      expect(entry.key, 'wifi.password');
      expect(entry.tags, <String>['wifi', 'secrets-adjacent']);
      expect(entry.provenance.origin, MemoryOrigin.userExplicit);
      expect(entry.provenance.sourceId, 'conv-7#msg-3');
      expect(entry.provenance.recordedAt, DateTime.utc(2026, 3, 1, 9));
      expect(entry.createdAt, DateTime.utc(2026, 3, 1, 9));
      expect(entry.updatedAt, DateTime.utc(2026, 3, 1, 9));
      expect(entry.revision, 1);
      expect(entry.expiresAt, isNull);
    });

    test('add trims content and rejects blank content', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);

      expect(service.add('   dark mode is on   ').content, 'dark mode is on');
      expect(
        () => service.add('   '),
        throwsA(isA<MemoryValidationException>()),
      );
      expect(() => service.add(''), throwsA(isA<MemoryValidationException>()));
      expect(service.size, 1, reason: 'only the one valid add persisted');
    });

    test(
      'add rejects a duplicate id and keeps ids sequential and deterministic',
      () {
        final service = MemoryService(
          store: InMemoryMemoryStore(),
          clock: clock,
        );

        final first = service.add('first fact', id: 'mem-0001');
        expect(first.id, 'mem-0001');

        expect(
          () => service.add('clashing fact', id: 'mem-0001'),
          throwsA(isA<MemoryValidationException>()),
        );

        final second = service.add('second fact');
        final third = service.add('third fact');
        expect(<String>[second.id, third.id], <String>['mem-0002', 'mem-0003']);
      },
    );

    test('add rejects provenance that names no source', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);

      expect(
        () => service.add('orphan fact', sourceId: '  '),
        throwsA(isA<MemoryValidationException>()),
      );
      expect(service.size, 0);
    });
  });

  group('MemoryService — update and delete', () {
    test('update keeps createdAt, moves updatedAt and bumps the revision', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      final entry = service.add('meeting is at 9');

      clock.advance(const Duration(hours: 2));
      final updated = service.update(entry.id, content: 'meeting is at 10');

      expect(updated.content, 'meeting is at 10');
      expect(updated.createdAt, DateTime.utc(2026, 3, 1, 9));
      expect(updated.updatedAt, DateTime.utc(2026, 3, 1, 11));
      expect(updated.revision, 2);
      expect(service.get('mem-0001'), same(updated));
    });

    test('update without a content change still stamps updatedAt', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      final entry = service.add('standup notes are in the shared drive');

      clock.advance(const Duration(minutes: 30));
      final updated = service.update(entry.id);

      expect(updated.content, 'standup notes are in the shared drive');
      expect(updated.updatedAt, DateTime.utc(2026, 3, 1, 9, 30));
      expect(updated.revision, 2);
    });

    test('update can attach and clear an expiry', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      final entry = service.add('temporary parking spot');

      final expiring = service.update(entry.id, ttl: const Duration(hours: 2));
      expect(expiring.expiresAt, DateTime.utc(2026, 3, 1, 11));

      final cleared = service.update(entry.id, clearExpiry: true);
      expect(cleared.expiresAt, isNull);
    });

    test('update of an unknown id fails loudly and leaves the store alone', () {
      final store = RecordingMemoryStore();
      final service = MemoryService(store: store, clock: clock);
      service.add('only fact');

      expect(
        () => service.update('mem-404', content: 'nope'),
        throwsA(isA<MemoryValidationException>()),
      );
      expect(service.size, 1);
      expect(store.calls.where((String c) => c == 'write:mem-404'), isEmpty);
    });

    test('delete reports whether a live entry was removed', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      final entry = service.add('delete me');

      expect(service.delete(entry.id), isTrue);
      expect(service.delete(entry.id), isFalse);
      expect(service.get(entry.id), isNull);
      expect(service.size, 0);
    });

    test('delete of a non-existent id is false, not an exception', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);

      expect(service.delete('mem-999'), isFalse);
    });
  });

  group('MemoryService — search', () {
    test(
      'search is case-insensitive, token-based and ordered deterministically',
      () {
        final service = MemoryService(
          store: InMemoryMemoryStore(),
          clock: clock,
        );
        service.add(
          'coffee grinder burrs need replacing',
          tags: <String>['kitchen'],
        );
        clock.advance(const Duration(minutes: 1));
        service.add(
          'coffee grinder is a Baratza Encore',
          tags: <String>['kitchen'],
        );
        clock.advance(const Duration(minutes: 1));
        service.add('tea kettle descaling reminder', tags: <String>['kitchen']);
        clock.advance(const Duration(minutes: 1));
        service.add('coffee grinder burrs AND the encore both matter');

        final hits = service.search('coffee grinder');

        expect(hits.map((MemorySearchResult r) => r.entry.id), <String>[
          'mem-0004',
          'mem-0002',
          'mem-0001',
        ], reason: 'equal scores fall back to newest first');
        expect(hits.map((MemorySearchResult r) => r.relevance).toSet(), <int>{
          4,
        }, reason: 'same tokens plus the same phrase, so the scores tie');
        expect(hits.first.entry.content, contains('AND the encore'));
        expect(
          service
              .search('COFFEE   Grinder')
              .map((MemorySearchResult r) => r.entry.id),
          hits.map((MemorySearchResult r) => r.entry.id),
          reason: 'case and repeated whitespace do not change the answer',
        );
      },
    );

    test('a tag or key match outranks a passing mention in the body', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('mentions coffee once', tags: <String>['coffee']);
      service.add('coffee is the topic', key: 'coffee.preference');
      service.add('coffee grinder burrs');

      final hits = service.search('coffee');

      expect(hits.map((MemorySearchResult r) => r.entry.id), <String>[
        'mem-0001',
        'mem-0002',
        'mem-0003',
      ]);
      expect(hits.map((MemorySearchResult r) => r.relevance), <int>[
        5,
        4,
        3,
      ], reason: 'tag 3 + phrase, key 2 + phrase, content 1 + phrase');
    });

    test('search requires every query token to match', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('coffee grinder burrs');
      clock.advance(const Duration(minutes: 1));
      service.add('coffee grinder is clean');

      expect(
        service
            .search('coffee grinder')
            .map((MemorySearchResult r) => r.entry.id),
        <String>['mem-0002', 'mem-0001'],
        reason: 'both tokens match both entries, so the newer one leads',
      );
      expect(service.search('coffee kettle'), isEmpty);
    });

    test('search filters by origin and tag', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add(
        'user asked to remember the wifi',
        origin: MemoryOrigin.userExplicit,
        tags: <String>['wifi'],
      );
      service.add(
        'wifi was mentioned in passing',
        origin: MemoryOrigin.assistantProposal,
        tags: <String>['wifi', 'unverified'],
      );

      final explicit = service.search(
        'wifi',
        origin: MemoryOrigin.userExplicit,
      );
      expect(explicit.map((MemorySearchResult r) => r.entry.id), <String>[
        'mem-0001',
      ]);

      final tagged = service.search('wifi', tag: 'unverified');
      expect(tagged.map((MemorySearchResult r) => r.entry.id), <String>[
        'mem-0002',
      ]);
    });

    test('search matches the key and tags, not just the content', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('value lives in a nested field', key: 'deploy.hetzner.box');
      service.add('unrelated sentence', tags: <String>['gym']);

      expect(
        service.search('hetzner').map((MemorySearchResult r) => r.entry.id),
        <String>['mem-0001'],
      );
      expect(
        service.search('gym').map((MemorySearchResult r) => r.entry.id),
        <String>['mem-0002'],
      );
    });

    test('a blank query is a validation error, never a full dump', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('a fact');

      expect(
        () => service.search('   '),
        throwsA(isA<MemoryValidationException>()),
      );
    });
  });

  group('MemoryService — retention and expiry', () {
    test('a ttl becomes an absolute expiresAt stamped from the clock', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);

      final entry = service.add('pass expires', ttl: const Duration(days: 7));

      expect(entry.expiresAt, DateTime.utc(2026, 3, 8, 9));
    });

    test('the service default retention applies when no ttl is given', () {
      final service = MemoryService(
        store: InMemoryMemoryStore(),
        clock: clock,
        defaultRetention: const Duration(days: 30),
      );

      final entry = service.add('expires by default');
      expect(entry.expiresAt, DateTime.utc(2026, 3, 31, 9));
    });

    test('explicit null ttl means keep forever', () {
      final service = MemoryService(
        store: InMemoryMemoryStore(),
        clock: clock,
        defaultRetention: const Duration(days: 30),
      );

      final entry = service.add('keep forever', ttl: null);
      expect(entry.expiresAt, isNull);
    });

    test('a non-positive ttl is rejected', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);

      expect(
        () => service.add('bad ttl', ttl: Duration.zero),
        throwsA(isA<MemoryValidationException>()),
      );
      expect(
        () => service.add('bad ttl', ttl: const Duration(seconds: -1)),
        throwsA(isA<MemoryValidationException>()),
      );
    });

    test('expired entries are hidden from search and list by default', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      final keeper = service.add(
        'expires tomorrow',
        ttl: const Duration(days: 1),
      );
      clock.advance(const Duration(minutes: 1));
      final goner = service.add(
        'expires in an hour',
        ttl: const Duration(hours: 1),
      );

      clock.advance(const Duration(hours: 2));

      expect(
        service.search('expires').map((MemorySearchResult r) => r.entry.id),
        <String>[keeper.id],
      );
      expect(service.list().map((MemoryEntry e) => e.id), <String>[keeper.id]);
      expect(service.size, 1, reason: 'size counts live entries only');
      expect(
        service.list(includeExpired: true).map((MemoryEntry e) => e.id),
        <String>[keeper.id, goner.id],
        reason: 'the expired view keeps the same oldest-first order',
      );
      expect(
        service
            .search('expires', includeExpired: true)
            .map((MemorySearchResult r) => r.entry.id),
        <String>[goner.id, keeper.id],
        reason: 'search still scores before ordering',
      );
    });

    test('expiry is inclusive of the exact expiry instant', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('boundary', ttl: const Duration(hours: 1));

      clock.advance(const Duration(hours: 1) - const Duration(seconds: 1));
      expect(service.size, 1);

      clock.advance(const Duration(seconds: 1));
      expect(service.size, 0);
    });

    test('purgeExpired drops only the expired rows from the store', () {
      final store = RecordingMemoryStore();
      final service = MemoryService(store: store, clock: clock);
      service.add('short lived', ttl: const Duration(minutes: 5));
      service.add('long lived', ttl: const Duration(days: 5));

      clock.advance(const Duration(minutes: 6));
      final purged = service.purgeExpired();

      expect(purged, <String>['mem-0001']);
      expect(store.rows.keys, <String>['mem-0002']);
      expect(service.size, 1);
    });

    test('isExpiredAt answers for a given instant', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      final entry = service.add('check me', ttl: const Duration(days: 1));

      expect(entry.isExpiredAt(DateTime.utc(2026, 3, 1, 9)), isFalse);
      expect(entry.isExpiredAt(DateTime.utc(2026, 3, 2, 8, 59, 59)), isFalse);
      expect(entry.isExpiredAt(DateTime.utc(2026, 3, 2, 9)), isTrue);
    });
  });

  group('MemoryService — bounded capacity', () {
    test('add beyond maxEntries evicts the oldest entry deterministically', () {
      final service = MemoryService(
        store: InMemoryMemoryStore(),
        clock: clock,
        maxEntries: 3,
      );

      for (final String fact in <String>['one', 'two', 'three', 'four']) {
        clock.advance(const Duration(minutes: 1));
        service.add(fact);
      }

      expect(service.list().map((MemoryEntry e) => e.content), <String>[
        'two',
        'three',
        'four',
      ]);
      expect(service.size, 3);
    });

    test('an expired entry is evicted before a live one', () {
      final service = MemoryService(
        store: InMemoryMemoryStore(),
        clock: clock,
        maxEntries: 2,
      );
      service.add('live old', ttl: const Duration(days: 5));
      clock.advance(const Duration(days: 1));
      service.add('already stale', ttl: const Duration(hours: 1));
      clock.advance(const Duration(hours: 1));
      service.add('live new');

      expect(service.list().map((MemoryEntry e) => e.content), <String>[
        'live old',
        'live new',
      ]);
      expect(service.lastEvictions, <String>['mem-0002']);
      expect(service.get('mem-0002'), isNull);
    });

    test('evictions are reported with the id that was dropped', () {
      final service = MemoryService(
        store: InMemoryMemoryStore(),
        clock: clock,
        maxEntries: 2,
      );
      service.add('one');
      service.add('two');
      service.add('three');

      expect(service.lastEvictions, <String>['mem-0001']);
    });

    test('a non-positive maxEntries is rejected', () {
      expect(
        () => MemoryService(
          store: InMemoryMemoryStore(),
          clock: clock,
          maxEntries: 0,
        ),
        throwsA(isA<MemoryValidationException>()),
      );
    });

    test(
      'an over-capacity injected store is trimmed as the service starts',
      () {
        final seeder = MemoryService(
          store: RecordingMemoryStore(),
          clock: clock,
          maxEntries: 5,
        );
        final store = seeder.store as RecordingMemoryStore;
        seeder.add('one');
        seeder.add('two');
        seeder.add('three');
        expect(store.rows, hasLength(3));

        final trimmed = MemoryService(
          store: store,
          clock: clock,
          maxEntries: 2,
        );

        expect(trimmed.size, 2);
        expect(trimmed.list().map((MemoryEntry e) => e.content), <String>[
          'two',
          'three',
        ]);
        expect(trimmed.lastEvictions, <String>['mem-0001']);
        expect(store.rows.keys, <String>['mem-0002', 'mem-0003']);
      },
    );
  });

  group('MemoryService — deterministic ordering', () {
    test('list is oldest first', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('b', id: 'mem-0002');
      clock.advance(const Duration(minutes: 1));
      service.add('a', id: 'mem-0001');
      clock.advance(const Duration(minutes: 1));
      service.add('c', id: 'mem-0003');

      expect(service.list().map((MemoryEntry e) => e.id), <String>[
        'mem-0002',
        'mem-0001',
        'mem-0003',
      ]);
    });

    test('same-instant entries are ordered by id, not by insertion luck', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('b', id: 'mem-0002');
      service.add('a', id: 'mem-0001');
      service.add('c', id: 'mem-0003');

      expect(service.list().map((MemoryEntry e) => e.id), <String>[
        'mem-0001',
        'mem-0002',
        'mem-0003',
      ]);
    });

    test('repeated identical operations produce identical orderings', () {
      List<String> run() {
        final clock = FakeClock(DateTime.utc(2026, 3, 1, 9));
        final service = MemoryService(
          store: InMemoryMemoryStore(),
          clock: clock,
        );
        for (final String fact in <String>['alpha', 'beta', 'gamma', 'delta']) {
          service.add(fact, tags: <String>['shared']);
          clock.advance(const Duration(minutes: 1));
        }
        return service
            .search('alpha beta gamma delta shared')
            .map((MemorySearchResult r) => r.entry.id)
            .toList();
      }

      expect(run(), run());
    });

    test('list and search never hand out the live store collection', () {
      final service = MemoryService(store: InMemoryMemoryStore(), clock: clock);
      service.add('immutable snapshot');

      final first = service.list();
      first.clear();

      expect(service.size, 1);
    });
  });
}
