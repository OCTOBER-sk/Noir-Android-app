// Shared behavioural contract for every KeyValueStore implementation.
//
// The real JSON file store and the deterministic in-memory double run the exact
// same expectations; anything that passes here is a property of the storage
// contract, not of one backend. Nothing here is asserted by a comment.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

typedef StoreFactory =
    KeyValueStore Function(SchemaCatalog catalog, DateTime Function() clock);

const String widgetCollection = 'widgets';
const String gadgetCollection = 'gadgets';
const String gizmoCollection = 'gizmos';
const String orphanCollection = 'orphans';

final DateTime fixedClockTime = DateTime.utc(2026, 3, 4, 5, 6, 7);

/// v1 gadget records stored `name`; v2 renamed the field to `displayName`.
Map<String, Object?> migrateGadgetV1ToV2(Map<String, Object?> payload) {
  final migrated = <String, Object?>{
    ...payload,
    'displayName': payload['name'],
    'migratedFrom': 1,
  };
  migrated.remove('name');
  return migrated;
}

/// A migration that always fails, used to prove failures are loud and inert.
Map<String, Object?> migrateGizmoV1ToV2ThatThrows(
  Map<String, Object?> payload,
) {
  throw StateError('boom: migration refused to run');
}

SchemaCatalog buildContractCatalog() {
  return SchemaCatalog()
    ..register(CollectionSchema(name: widgetCollection, currentVersion: 1))
    ..register(
      CollectionSchema(
        name: gadgetCollection,
        currentVersion: 2,
        migrations: [
          SchemaMigration(
            fromVersion: 1,
            toVersion: 2,
            description: 'gadgets: rename name -> displayName',
            migrate: migrateGadgetV1ToV2,
          ),
        ],
      ),
    )
    ..register(
      CollectionSchema(
        name: gizmoCollection,
        currentVersion: 2,
        migrations: [
          SchemaMigration(
            fromVersion: 1,
            toVersion: 2,
            description: 'gizmos: migration that always throws',
            migrate: migrateGizmoV1ToV2ThatThrows,
          ),
        ],
      ),
    )
    ..register(CollectionSchema(name: orphanCollection, currentVersion: 2));
}

void keyValueStoreContract({
  required String name,
  required StoreFactory create,
}) {
  group('KeyValueStore contract — $name', () {
    late KeyValueStore store;
    late FaultInjectableStore faults;
    late RawStoreAccess raw;

    setUp(() {
      store = create(buildContractCatalog(), () => fixedClockTime);
      faults = store as FaultInjectableStore;
      raw = store as RawStoreAccess;
    });

    tearDown(() {
      faults.clearFaults();
    });

    group('empty state', () {
      test(
        'reads nothing, lists nothing and reports no keys before any write',
        () async {
          expect(await store.read(widgetCollection, 'missing'), isNull);
          expect(await store.readRecord(widgetCollection, 'missing'), isNull);
          expect(await store.exists(widgetCollection, 'missing'), isFalse);
          expect(await store.listIds(widgetCollection), isEmpty);
          expect(store.recoveries, isEmpty);
        },
      );

      test('an empty payload round-trips as an empty map', () async {
        await store.write(widgetCollection, 'empty', <String, Object?>{});

        expect(
          await store.read(widgetCollection, 'empty'),
          <String, Object?>{},
        );
        expect(await store.exists(widgetCollection, 'empty'), isTrue);
      });
    });

    group('read and write', () {
      test('returns exactly the payload that was written', () async {
        final payload = <String, Object?>{
          'title': 'Noir',
          'count': 7,
          'ratio': 0.5,
          'enabled': true,
          'missing': null,
          'tags': <Object?>['a', 'b'],
          'nested': <String, Object?>{
            'inner': <String, Object?>{'deep': 'value'},
          },
        };

        await store.write(widgetCollection, 'w1', payload);

        expect(await store.read(widgetCollection, 'w1'), payload);
      });

      test('a read hands back a defensive copy', () async {
        await store.write(widgetCollection, 'w1', <String, Object?>{
          'nested': <String, Object?>{'deep': 'value'},
        });

        final first = (await store.read(widgetCollection, 'w1'))!;
        (first['nested'] as Map<String, Object?>)['deep'] = 'tampered';
        first['injected'] = true;
        final second = (await store.read(widgetCollection, 'w1'))!;

        expect((second['nested'] as Map<String, Object?>)['deep'], 'value');
        expect(second.containsKey('injected'), isFalse);
      });

      test(
        'a second write replaces the payload instead of merging it',
        () async {
          await store.write(widgetCollection, 'w1', <String, Object?>{
            'a': 1,
            'b': 2,
          });
          await store.write(widgetCollection, 'w1', <String, Object?>{'b': 3});

          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'b': 3,
          });
        },
      );

      test('the newest value wins when a key is written repeatedly', () async {
        for (var i = 0; i < 25; i++) {
          await store.write(widgetCollection, 'w1', <String, Object?>{'i': i});
        }

        expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
          'i': 24,
        });
      });

      test('collections are isolated from one another', () async {
        await store.write(widgetCollection, 'shared', <String, Object?>{
          'w': 1,
        });
        await store.write(gadgetCollection, 'shared', <String, Object?>{
          'g': 2,
        });

        expect(await store.read(widgetCollection, 'shared'), <String, Object?>{
          'w': 1,
        });
        expect(await store.read(gadgetCollection, 'shared'), <String, Object?>{
          'g': 2,
        });
        expect(await store.listIds(widgetCollection), <String>['shared']);
        expect(await store.listIds(gadgetCollection), <String>['shared']);
      });

      test(
        'unicode, newlines and empty strings survive a round trip',
        () async {
          final text = 'héllo — 日本語\n\ttab "\\" quote 😀';

          await store.write(widgetCollection, 'w1', <String, Object?>{
            'text': text,
          });

          expect((await store.read(widgetCollection, 'w1'))!['text'], text);
        },
      );

      test('a payload that cannot be encoded is rejected explicitly', () async {
        await expectLater(
          store.write(widgetCollection, 'bad', <String, Object?>{
            'o': Object(),
          }),
          throwsA(isA<StorageEncodeError>()),
        );
        expect(await store.exists(widgetCollection, 'bad'), isFalse);
        expect(await raw.rawEnvelope(widgetCollection, 'bad'), isNull);
      });
    });

    group('listing', () {
      test('ids come back sorted lexicographically', () async {
        for (final id in <String>['b', 'a10', 'a2', 'a']) {
          await store.write(widgetCollection, id, <String, Object?>{'id': id});
        }

        expect(await store.listIds(widgetCollection), <String>[
          'a',
          'a10',
          'a2',
          'b',
        ]);
      });

      test('only the requested collection is listed', () async {
        await store.write(
          widgetCollection,
          'only-widgets',
          <String, Object?>{},
        );

        expect(await store.listIds(gadgetCollection), isEmpty);
        expect(await store.listIds(widgetCollection), <String>['only-widgets']);
      });

      test('listing an unregistered collection fails loudly', () async {
        await expectLater(
          store.listIds('nope'),
          throwsA(isA<UnknownCollectionError>()),
        );
      });
    });

    group('delete', () {
      test('delete removes the record and is idempotent', () async {
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
        await store.write(widgetCollection, 'w2', <String, Object?>{'a': 2});

        await store.delete(widgetCollection, 'w1');
        await store.delete(widgetCollection, 'w1');
        await store.delete(widgetCollection, 'never-existed');

        expect(await store.read(widgetCollection, 'w1'), isNull);
        expect(await store.exists(widgetCollection, 'w1'), isFalse);
        expect(await store.read(widgetCollection, 'w2'), <String, Object?>{
          'a': 2,
        });
      });

      test('a deleted key does not come back from a stale backup', () async {
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 2});

        await store.delete(widgetCollection, 'w1');

        expect(await store.read(widgetCollection, 'w1'), isNull);
        expect(await raw.rawEnvelope(widgetCollection, 'w1'), isNull);
      });
    });

    group('schema versioning', () {
      test('a write stamps the current schema version and clock', () async {
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});

        final record = (await store.readRecord(widgetCollection, 'w1'))!;
        expect(record.schemaVersion, 1);
        expect(record.writtenAt, fixedClockTime);
        expect(record.payload, <String, Object?>{'a': 1});
      });

      test(
        'reading a legacy record migrates it and persists the upgrade',
        () async {
          await store.writeAtVersion(
            gadgetCollection,
            'g1',
            1,
            <String, Object?>{'name': 'legacy', 'extra': true},
          );

          final record = (await store.readRecord(gadgetCollection, 'g1'))!;

          expect(record.schemaVersion, 2);
          expect(record.payload, <String, Object?>{
            'displayName': 'legacy',
            'extra': true,
            'migratedFrom': 1,
          });
          final again = (await store.readRecord(gadgetCollection, 'g1'))!;
          expect(again.schemaVersion, 2, reason: 'the upgrade must be durable');
        },
      );

      test(
        'a record written at an unsupported future version is refused',
        () async {
          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});

          await expectLater(
            store.writeAtVersion(widgetCollection, 'w1', 99, <String, Object?>{
              'a': 2,
            }),
            throwsA(isA<SchemaVersionTooNewError>()),
          );
          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'a': 1,
          }, reason: 'a refused write must not damage the record');
        },
      );

      test('a version below 1 is refused', () async {
        await expectLater(
          store.writeAtVersion(widgetCollection, 'w1', 0, <String, Object?>{}),
          throwsA(isA<InvalidSchemaVersionError>()),
        );
      });

      test('a failing migration surfaces as MigrationFailedError and changes '
          'nothing on disk', () async {
        await store.writeAtVersion(gizmoCollection, 'gz1', 1, <String, Object?>{
          'name': 'fragile',
        });
        final before = await raw.rawEnvelope(gizmoCollection, 'gz1');

        await expectLater(
          store.read(gizmoCollection, 'gz1'),
          throwsA(isA<MigrationFailedError>()),
        );
        await expectLater(
          store.readRecord(gizmoCollection, 'gz1'),
          throwsA(isA<MigrationFailedError>()),
        );
        expect(await raw.rawEnvelope(gizmoCollection, 'gz1'), before);
      });

      test(
        'a version with no migration path to current fails loudly',
        () async {
          await store.writeAtVersion(
            orphanCollection,
            'o1',
            1,
            <String, Object?>{'stuck': true},
          );
          final before = await raw.rawEnvelope(orphanCollection, 'o1');

          await expectLater(
            store.read(orphanCollection, 'o1'),
            throwsA(isA<MissingMigrationError>()),
          );
          expect(await raw.rawEnvelope(orphanCollection, 'o1'), before);
        },
      );
    });

    group('atomic writes', () {
      test(
        'a failure before the swap leaves the previous payload readable',
        () async {
          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
          faults.failNextWrite(StateError('disk full'));

          await expectLater(
            store.write(widgetCollection, 'w1', <String, Object?>{'a': 2}),
            throwsA(isA<StateError>()),
          );

          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'a': 1,
          });
        },
      );

      test(
        'a failure between the temp write and the swap is never observable',
        () async {
          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
          faults.failNextSwap();

          await expectLater(
            store.write(widgetCollection, 'w1', <String, Object?>{'a': 2}),
            throwsA(isA<StateError>()),
          );

          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'a': 1,
          });
          expect(await store.listIds(widgetCollection), <String>['w1']);

          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 3});
          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'a': 3,
          });
          expect(await store.listIds(widgetCollection), <String>['w1']);
        },
      );

      test(
        'a first write interrupted before the swap leaves no record',
        () async {
          faults.failNextSwap();

          await expectLater(
            store.write(widgetCollection, 'w1', <String, Object?>{'a': 1}),
            throwsA(isA<StateError>()),
          );

          expect(await store.exists(widgetCollection, 'w1'), isFalse);
          expect(await store.read(widgetCollection, 'w1'), isNull);
        },
      );

      test('a failed delete leaves the record readable', () async {
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
        faults.failNextDelete(StateError('locked'));

        await expectLater(
          store.delete(widgetCollection, 'w1'),
          throwsA(isA<StateError>()),
        );

        expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
          'a': 1,
        });
      });

      test('clearing faults restores normal operation', () async {
        faults.failNextWrite(StateError('down'));
        await expectLater(
          store.write(widgetCollection, 'w1', <String, Object?>{}),
          throwsA(isA<StateError>()),
        );

        faults.clearFaults();
        await store.write(widgetCollection, 'w1', <String, Object?>{
          'ok': true,
        });

        expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
          'ok': true,
        });
      });
    });

    group('corruption and recovery', () {
      test(
        'a truncated primary is quarantined and the backup is recovered',
        () async {
          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 2});
          await raw.damagePrimary(widgetCollection, 'w1', '{"payload": {"a":');

          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'a': 1,
          });
          expect(store.recoveries, hasLength(1));
          final recovery = store.recoveries.single;
          expect(recovery.collection, widgetCollection);
          expect(recovery.id, 'w1');
          expect(recovery.reason, StoreRecoveryReason.corruptPrimary);
          expect(recovery.quarantineId, isNotNull);
          expect(
            await raw.quarantinedContents(recovery.quarantineId!),
            '{"payload": {"a":',
            reason: 'the corrupt bytes must be kept, never dropped',
          );
          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'a': 1,
          }, reason: 'the store heals itself after a recovery');
        },
      );

      test(
        'a primary that is valid JSON but not an envelope is corruption',
        () async {
          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
          await store.write(widgetCollection, 'w1', <String, Object?>{'a': 2});
          await raw.damagePrimary(widgetCollection, 'w1', '[1, 2, 3]');

          expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
            'a': 1,
          }, reason: 'a non-envelope primary is corruption, not data');
          expect(store.recoveries.last.quarantineId, isNotNull);
        },
      );

      test('an envelope missing its payload field is corruption', () async {
        await raw.damagePrimary(
          widgetCollection,
          'hollow',
          '{"schemaVersion":1,"writtenAt":"2026-01-01T00:00:00.000Z"}',
        );

        await expectLater(
          store.read(widgetCollection, 'hollow'),
          throwsA(isA<CorruptRecordError>()),
        );
      });

      test('an envelope with an unparseable timestamp is corruption', () async {
        await raw.damagePrimary(
          widgetCollection,
          'stamped',
          '{"schemaVersion":1,"writtenAt":"not-a-time","payload":{}}',
        );

        await expectLater(
          store.read(widgetCollection, 'stamped'),
          throwsA(isA<CorruptRecordError>()),
        );
      });

      test(
        'unrecoverable corruption throws, keeps the bytes and stays loud',
        () async {
          await raw.damagePrimary(
            widgetCollection,
            'lonely',
            'not json at all',
          );

          await expectLater(
            store.read(widgetCollection, 'lonely'),
            throwsA(isA<CorruptRecordError>()),
          );
          await expectLater(
            store.read(widgetCollection, 'lonely'),
            throwsA(isA<CorruptRecordError>()),
          );

          final quarantineId = await raw.quarantineIdFor(
            widgetCollection,
            'lonely',
          );
          expect(quarantineId, isNotNull);
          expect(
            await raw.quarantinedContents(quarantineId!),
            'not json at all',
          );
          expect(
            await raw.rawEnvelope(widgetCollection, 'lonely'),
            'not json at all',
            reason: 'the original bytes stay in place for manual repair',
          );
          expect(await store.exists(widgetCollection, 'lonely'), isTrue);
          expect(
            store.recoveries.last.reason,
            StoreRecoveryReason.unrecoverable,
          );
        },
      );

      test('a corrupt record can be repaired by writing over it', () async {
        await raw.damagePrimary(widgetCollection, 'fixme', 'garbage');
        await expectLater(
          store.read(widgetCollection, 'fixme'),
          throwsA(isA<CorruptRecordError>()),
        );

        await store.write(widgetCollection, 'fixme', <String, Object?>{
          'repaired': true,
        });

        expect(await store.read(widgetCollection, 'fixme'), <String, Object?>{
          'repaired': true,
        });
        expect(
          store.recoveries.map((r) => r.reason),
          contains(StoreRecoveryReason.unrecoverable),
        );
      });
    });

    group('atomic read-modify-write', () {
      test('concurrent increments on one key all land', () async {
        await store.write(widgetCollection, 'counter', <String, Object?>{
          'n': 0,
        });

        await Future.wait<void>(<Future<void>>[
          for (var i = 0; i < 40; i++)
            store.mutateRecord(widgetCollection, 'counter', (current) {
              final value = (current!['n']! as int) + 1;
              return <String, Object?>{'n': value};
            }),
        ]);

        expect((await store.read(widgetCollection, 'counter'))!['n'], 40);
      });

      test(
        'mutateRecord sees null for a missing key and can create it',
        () async {
          Map<String, Object?>? seen;
          int calls = 0;

          final created = await store.mutateRecord(widgetCollection, 'fresh', (
            current,
          ) {
            calls++;
            seen = current;
            return <String, Object?>{'created': true};
          });

          expect(seen, isNull);
          expect(calls, 1);
          expect(created!.payload, <String, Object?>{'created': true});
          expect(created.schemaVersion, 1);
        },
      );

      test('mutateRecord returning null deletes the record', () async {
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});

        final result = await store.mutateRecord(
          widgetCollection,
          'w1',
          (current) => null,
        );

        expect(result, isNull);
        expect(await store.exists(widgetCollection, 'w1'), isFalse);
      });
    });

    group('input validation', () {
      test('an empty id is rejected', () async {
        await expectLater(
          store.read(widgetCollection, ''),
          throwsA(isA<StorageKeyError>()),
        );
        await expectLater(
          store.write(widgetCollection, '', <String, Object?>{}),
          throwsA(isA<StorageKeyError>()),
        );
      });

      test('an id that tries to escape the collection is rejected', () async {
        for (final id in <String>[
          '../escape',
          'nested/id',
          r'..\escape',
          '.',
          '..',
          'a__tmp',
          'a__bak',
          'has space',
          'tab\tinside',
          'star*',
        ]) {
          await expectLater(
            store.write(widgetCollection, id, <String, Object?>{}),
            throwsA(isA<StorageKeyError>()),
            reason: 'id "$id" must be refused',
          );
        }
      });

      test('an id with dots is a normal id, not a side file', () async {
        await store.write(widgetCollection, 'a.bak.json', <String, Object?>{
          'a': 1,
        });
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 2});
        await raw.damagePrimary(widgetCollection, 'w1', 'broken');

        expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
          'a': 1,
        });
        expect(await store.listIds(widgetCollection), <String>[
          'a.bak.json',
          'w1',
        ]);
        expect(
          await store.read(widgetCollection, 'a.bak.json'),
          <String, Object?>{'a': 1},
        );
      });

      test('an id longer than the limit is rejected', () async {
        await expectLater(
          store.write(widgetCollection, 'a' * 121, <String, Object?>{}),
          throwsA(isA<StorageKeyError>()),
        );
      });

      test(
        'an unregistered collection is rejected on every operation',
        () async {
          await expectLater(
            store.read('nope', 'w1'),
            throwsA(isA<UnknownCollectionError>()),
          );
          await expectLater(
            store.write('nope', 'w1', <String, Object?>{}),
            throwsA(isA<UnknownCollectionError>()),
          );
          await expectLater(
            store.delete('nope', 'w1'),
            throwsA(isA<UnknownCollectionError>()),
          );
        },
      );
    });
  });
}
