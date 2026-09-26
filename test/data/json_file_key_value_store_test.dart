// The real on-disk JSON store: atomic temp+rename writes, per-key backups,
// quarantine of corrupt bytes, and durability across process restarts.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/key_value_store_contract.dart';

void main() {
  late Directory root;

  KeyValueStore createOver(Directory directory) => JsonFileKeyValueStore(
    root: directory,
    catalog: buildContractCatalog(),
    clock: () => fixedClockTime,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('noir_json_store_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  keyValueStoreContract(
    name: 'JsonFileKeyValueStore',
    create: (catalog, clock) =>
        JsonFileKeyValueStore(root: root, catalog: catalog, clock: clock),
  );

  group('file layout', () {
    test('the root directory is created on open', () {
      final nested = Directory('${root.path}/deep/nested/store');

      JsonFileKeyValueStore(root: nested, catalog: buildContractCatalog());

      expect(nested.existsSync(), isTrue);
      expect(Directory('${nested.path}/widgets').existsSync(), isTrue);
      expect(Directory('${nested.path}/quarantine').existsSync(), isTrue);
    });

    test(
      'a record lives at <collection>/<id>.json and holds a JSON envelope',
      () async {
        final store = createOver(root);

        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});

        final file = File('${root.path}/widgets/w1.json');
        expect(file.existsSync(), isTrue);
        expect(
          file.readAsStringSync(),
          '{"schemaVersion":1,"writtenAt":"2026-03-04T05:06:07.000Z",'
          '"payload":{"a":1}}',
        );
      },
    );

    test('a stale temp file is never visible as data', () async {
      final store = createOver(root);
      await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
      File('${root.path}/widgets/w1__tmp7.json').writeAsStringSync('{"a":');

      expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
        'a': 1,
      });
      expect(await store.listIds(widgetCollection), <String>['w1']);

      await store.write(widgetCollection, 'w2', <String, Object?>{'a': 2});
      expect(await store.listIds(widgetCollection), <String>['w1', 'w2']);
    });

    test(
      'an interrupted first write leaves only a temp file, not a record',
      () async {
        final store = createOver(root);
        (store as FaultInjectableStore).failNextSwap();

        await expectLater(
          store.write(widgetCollection, 'w1', <String, Object?>{'a': 1}),
          throwsA(isA<StateError>()),
        );

        expect(File('${root.path}/widgets/w1.json').existsSync(), isFalse);
        expect(
          Directory(
            '${root.path}/widgets',
          ).listSync().where((e) => e.path.endsWith('__tmp1.json')),
          hasLength(1),
        );
      },
    );
  });

  group('durability', () {
    test('a second store instance reads what the first one wrote', () async {
      final first = createOver(root);
      await first.write(widgetCollection, 'w1', <String, Object?>{
        'title': 'durable',
        'items': <Object?>[1, 2, 3],
      });
      await first.delete(gadgetCollection, 'none');

      final second = createOver(root);

      expect(await second.read(widgetCollection, 'w1'), <String, Object?>{
        'title': 'durable',
        'items': <Object?>[1, 2, 3],
      });
      expect(
        (await second.readRecord(widgetCollection, 'w1'))!.schemaVersion,
        1,
      );
    });

    test('a backup file is what recovery falls back to', () async {
      final store = createOver(root);
      await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
      await store.write(widgetCollection, 'w1', <String, Object?>{'a': 2});

      expect(File('${root.path}/widgets/w1.json').existsSync(), isTrue);
      expect(File('${root.path}/widgets/w1__bak.json').existsSync(), isTrue);
      expect(
        File('${root.path}/widgets/w1__bak.json').readAsStringSync(),
        contains('{"a":1}'),
      );
    });

    test('deleting a record removes the primary and the backup file', () async {
      final store = createOver(root);
      await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
      await store.write(widgetCollection, 'w1', <String, Object?>{'a': 2});

      await store.delete(widgetCollection, 'w1');

      expect(File('${root.path}/widgets/w1.json').existsSync(), isFalse);
      expect(File('${root.path}/widgets/w1__bak.json').existsSync(), isFalse);
    });
  });

  group('migration from a legacy file on disk', () {
    test(
      'a hand-written v1 envelope is migrated and rewritten as v2',
      () async {
        Directory('${root.path}/gadgets').createSync(recursive: true);
        File('${root.path}/gadgets/legacy.json').writeAsStringSync(
          '{"schemaVersion":1,"writtenAt":"2025-01-01T00:00:00.000Z",'
          '"payload":{"name":"from-disk"}}',
        );

        final store = createOver(root);
        final record = (await store.readRecord(gadgetCollection, 'legacy'))!;

        expect(record.schemaVersion, 2);
        expect(record.payload['displayName'], 'from-disk');
        expect(
          File('${root.path}/gadgets/legacy.json').readAsStringSync(),
          contains('"schemaVersion":2'),
        );
      },
    );

    test(
      'a file written by a newer app version is refused, not rewritten',
      () async {
        Directory('${root.path}/widgets').createSync(recursive: true);
        File('${root.path}/widgets/future.json').writeAsStringSync(
          '{"schemaVersion":7,"writtenAt":"2030-01-01T00:00:00.000Z",'
          '"payload":{"a":1}}',
        );

        final store = createOver(root);

        await expectLater(
          store.read(widgetCollection, 'future'),
          throwsA(isA<SchemaVersionTooNewError>()),
        );
        expect(
          File('${root.path}/widgets/future.json').readAsStringSync(),
          contains('"schemaVersion":7'),
        );
      },
    );
  });

  group('corrupt files', () {
    test(
      'a corrupt primary is copied into quarantine and kept in place',
      () async {
        final store = createOver(root);
        await (store as RawStoreAccess).damagePrimary(
          widgetCollection,
          'broken',
          '{"schemaVersion":1,',
        );

        await expectLater(
          store.read(widgetCollection, 'broken'),
          throwsA(isA<CorruptRecordError>()),
        );

        final quarantined = Directory(
          '${root.path}/quarantine',
        ).listSync().map((e) => e.path).toList();
        expect(quarantined, hasLength(1));
        expect(quarantined.single, contains('widgets~broken#1'));
        expect(
          File(quarantined.single).readAsStringSync(),
          '{"schemaVersion":1,',
        );
        expect(
          File('${root.path}/widgets/broken.json').readAsStringSync(),
          '{"schemaVersion":1,',
        );
      },
    );

    test('quarantine files are never listed as live records', () async {
      final store = createOver(root);
      await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
      await store.write(widgetCollection, 'broken', <String, Object?>{'a': 1});
      await store.write(widgetCollection, 'broken', <String, Object?>{'a': 2});
      await (store as RawStoreAccess).damagePrimary(
        widgetCollection,
        'broken',
        'nope',
      );

      expect(await store.read(widgetCollection, 'broken'), <String, Object?>{
        'a': 1,
      }, reason: 'the healthy backup is served after recovery');
      expect(
        Directory('${root.path}/quarantine').listSync().map((e) => e.path),
        everyElement(contains('broken#')),
        reason: 'quarantine lives outside the collection directories',
      );
      expect(await store.listIds(widgetCollection), <String>[
        'broken',
        'w1',
      ], reason: 'the recovered record is a normal record again');
    });

    test(
      'bytes that are not valid UTF-8 are corruption, not an io error',
      () async {
        final store = createOver(root);
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 1});
        await store.write(widgetCollection, 'w1', <String, Object?>{'a': 2});
        File(
          '${root.path}/widgets/w1.json',
        ).writeAsBytesSync(<int>[0xC3, 0x28, 0xA0, 0xA1, 0xFF]);

        expect(await store.read(widgetCollection, 'w1'), <String, Object?>{
          'a': 1,
        });
        expect(
          store.recoveries.last.reason,
          StoreRecoveryReason.corruptPrimary,
        );
      },
    );

    test('invalid UTF-8 with no backup fails as corruption', () async {
      final store = createOver(root);
      File('${root.path}/widgets/w1.json').writeAsBytesSync(<int>[0xFF, 0xFE]);

      await expectLater(
        store.read(widgetCollection, 'w1'),
        throwsA(isA<CorruptRecordError>()),
      );
    });

    test('an empty file is corruption, not an empty record', () async {
      final store = createOver(root);
      File('${root.path}/widgets/void.json').writeAsStringSync('');

      await expectLater(
        store.read(widgetCollection, 'void'),
        throwsA(isA<CorruptRecordError>()),
      );
    });
  });

  group('io failures', () {
    test(
      'a filesystem failure surfaces as a StorageIoError, never as silence',
      () async {
        final store = createOver(root);
        // Something else already owns the record's path.
        Directory('${root.path}/widgets/w1.json').createSync();

        await expectLater(
          store.write(widgetCollection, 'w1', <String, Object?>{'a': 1}),
          throwsA(isA<StorageIoError>()),
        );
        expect(await store.read(widgetCollection, 'w1'), isNull);
      },
    );

    test('a directory sitting on a record path is not a record', () async {
      final store = createOver(root);
      Directory('${root.path}/widgets/shadow.json').createSync();

      expect(await store.exists(widgetCollection, 'shadow'), isFalse);
      expect(await store.read(widgetCollection, 'shadow'), isNull);
      expect(await store.listIds(widgetCollection), isEmpty);
    });
  });
}
