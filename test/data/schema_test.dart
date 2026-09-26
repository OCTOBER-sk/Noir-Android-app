// Schema versions, migration chains and the catalog that wires them together.
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

Map<String, Object?> addOne(Map<String, Object?> payload) => <String, Object?>{
  ...payload,
  'step': (payload['step'] as int? ?? 0) + 1,
};

Map<String, Object?> rename(Map<String, Object?> payload) => <String, Object?>{
  'renamed': payload['old'],
};

Map<String, Object?> explode(Map<String, Object?> payload) =>
    throw const FormatException('migration is broken');

Map<String, Object?> throwDomainError(Map<String, Object?> payload) =>
    throw const InvalidPageRequestError('nope');

void main() {
  group('CollectionSchema registration', () {
    test('a schema with no migrations is valid', () {
      final schema = CollectionSchema(name: 'things', currentVersion: 1);

      expect(schema.currentVersion, 1);
      expect(schema.migrations, isEmpty);
      expect(schema.toString(), 'CollectionSchema(things, v1, 0 step(s))');
    });

    test('a duplicate step is rejected', () {
      expect(
        () => CollectionSchema(
          name: 'things',
          currentVersion: 3,
          migrations: [
            SchemaMigration(
              fromVersion: 1,
              toVersion: 2,
              description: 'a',
              migrate: addOne,
            ),
            SchemaMigration(
              fromVersion: 1,
              toVersion: 2,
              description: 'b',
              migrate: addOne,
            ),
          ],
        ),
        throwsA(isA<SchemaRegistrationError>()),
      );
    });

    test('a step that skips a version is rejected', () {
      expect(
        () => CollectionSchema(
          name: 'things',
          currentVersion: 3,
          migrations: [
            SchemaMigration(
              fromVersion: 1,
              toVersion: 3,
              description: 'a',
              migrate: addOne,
            ),
          ],
        ),
        throwsA(isA<SchemaRegistrationError>()),
      );
    });

    test('a step that runs past the current version is rejected', () {
      expect(
        () => CollectionSchema(
          name: 'things',
          currentVersion: 2,
          migrations: [
            SchemaMigration(
              fromVersion: 2,
              toVersion: 3,
              description: 'a',
              migrate: addOne,
            ),
          ],
        ),
        throwsA(isA<SchemaRegistrationError>()),
      );
    });

    test('a step from version 0 is rejected', () {
      expect(
        () => CollectionSchema(
          name: 'things',
          currentVersion: 2,
          migrations: [
            SchemaMigration(
              fromVersion: 0,
              toVersion: 1,
              description: 'a',
              migrate: addOne,
            ),
          ],
        ),
        throwsA(isA<SchemaRegistrationError>()),
      );
    });

    test('a collection name that is not a safe path segment is rejected', () {
      for (final name in <String>[
        '',
        'Upper',
        'has space',
        '../escape',
        'a/b',
      ]) {
        expect(
          () => CollectionSchema(name: name, currentVersion: 1),
          throwsA(isA<SchemaRegistrationError>()),
          reason: 'name "$name" must be refused',
        );
      }
    });

    test('a collection must start at version 1', () {
      expect(
        () => CollectionSchema(name: 'things', currentVersion: 0),
        throwsA(isA<SchemaRegistrationError>()),
      );
    });
  });

  group('CollectionSchema.pathFrom', () {
    final schema = CollectionSchema(
      name: 'things',
      currentVersion: 3,
      migrations: [
        SchemaMigration(
          fromVersion: 2,
          toVersion: 3,
          description: 'rename',
          migrate: rename,
        ),
        SchemaMigration(
          fromVersion: 1,
          toVersion: 2,
          description: 'bump',
          migrate: addOne,
        ),
      ],
    );

    test('the current version needs no steps', () {
      expect(schema.pathFrom(3), isEmpty);
    });

    test('older versions get the steps in order, whatever order they were '
        'registered in', () {
      final steps = schema.pathFrom(1);

      expect(steps, hasLength(2));
      expect(steps[0].description, 'bump');
      expect(steps[1].description, 'rename');
    });

    test('a newer version on disk is refused', () {
      expect(
        () => schema.pathFrom(4),
        throwsA(
          isA<SchemaVersionTooNewError>()
              .having((e) => e.onDiskVersion, 'onDiskVersion', 4)
              .having((e) => e.supportedVersion, 'supportedVersion', 3),
        ),
      );
    });

    test('a version below 1 is refused', () {
      expect(
        () => schema.pathFrom(0),
        throwsA(isA<InvalidSchemaVersionError>()),
      );
    });

    test('a gap in the chain is refused instead of guessed at', () {
      final gapped = CollectionSchema(
        name: 'things',
        currentVersion: 3,
        migrations: [
          SchemaMigration(
            fromVersion: 2,
            toVersion: 3,
            description: 'rename',
            migrate: rename,
          ),
        ],
      );

      expect(gapped.pathFrom(3), isEmpty);
      expect(
        () => gapped.pathFrom(1),
        throwsA(
          isA<MissingMigrationError>()
              .having((e) => e.fromVersion, 'fromVersion', 1)
              .having((e) => e.toVersion, 'toVersion', 3),
        ),
      );
    });
  });

  group('CollectionSchema.migrate', () {
    final schema = CollectionSchema(
      name: 'things',
      currentVersion: 3,
      migrations: [
        SchemaMigration(
          fromVersion: 1,
          toVersion: 2,
          description: 'bump',
          migrate: addOne,
        ),
        SchemaMigration(
          fromVersion: 2,
          toVersion: 3,
          description: 'rename',
          migrate: rename,
        ),
      ],
    );

    test('every step runs, in order, on the previous result', () {
      expect(
        schema.migrate(1, <String, Object?>{'old': 'x', 'step': 0}),
        <String, Object?>{'renamed': 'x'},
      );
    });

    test('a record already at the current version is untouched', () {
      final payload = <String, Object?>{'anything': true};

      expect(identical(schema.migrate(3, payload), payload), isTrue);
    });

    test('a failing step is reported with the original error attached', () {
      final broken = CollectionSchema(
        name: 'things',
        currentVersion: 2,
        migrations: [
          SchemaMigration(
            fromVersion: 1,
            toVersion: 2,
            description: 'explode',
            migrate: explode,
          ),
        ],
      );

      expect(
        () => broken.migrate(1, <String, Object?>{}),
        throwsA(
          isA<MigrationFailedError>()
              .having((e) => e.fromVersion, 'fromVersion', 1)
              .having((e) => e.toVersion, 'toVersion', 2)
              .having((e) => e.failure, 'failure', isA<FormatException>()),
        ),
      );
    });

    test('a data layer error from a step is not re-wrapped', () {
      final broken = CollectionSchema(
        name: 'things',
        currentVersion: 2,
        migrations: [
          SchemaMigration(
            fromVersion: 1,
            toVersion: 2,
            description: 'domain error',
            migrate: throwDomainError,
          ),
        ],
      );

      expect(
        () => broken.migrate(1, <String, Object?>{}),
        throwsA(isA<InvalidPageRequestError>()),
      );
    });

    test('a migration cannot mutate the payload it was given', () {
      final original = <String, Object?>{'n': 1};

      schema.migrate(1, original);

      expect(original, <String, Object?>{'n': 1});
    });
  });

  group('SchemaCatalog', () {
    test('an unregistered collection is an explicit error', () {
      final catalog = SchemaCatalog();

      expect(catalog.contains('nope'), isFalse);
      expect(catalog.find('nope'), isNull);
      expect(
        () => catalog.require('nope'),
        throwsA(isA<UnknownCollectionError>()),
      );
    });

    test('registration replaces an earlier registration of the same name', () {
      final catalog = SchemaCatalog()
        ..register(CollectionSchema(name: 'things', currentVersion: 1))
        ..register(CollectionSchema(name: 'things', currentVersion: 7));

      expect(catalog.require('things').currentVersion, 7);
      expect(catalog.names, <String>['things']);
    });

    test('the exposed view cannot be mutated', () {
      final catalog = SchemaCatalog()
        ..register(CollectionSchema(name: 'things', currentVersion: 1));

      expect(
        () => catalog.all['other'] = CollectionSchema(
          name: 'other',
          currentVersion: 1,
        ),
        throwsUnsupportedError,
      );
      expect(() => catalog.names.add('x'), throwsUnsupportedError);
    });
  });

  group('StorageFaults', () {
    test('each injected fault fires exactly once', () {
      final faults = StoreFaults();
      faults
        ..failNextWrite()
        ..failNextSwap()
        ..failNextDelete();

      expect(faults.throwIfWrite, throwsStateError);
      expect(faults.throwIfWrite, returnsNormally);
      expect(faults.throwIfSwap, throwsStateError);
      expect(faults.throwIfSwap, returnsNormally);
      expect(faults.throwIfDelete, throwsStateError);
      expect(faults.throwIfDelete, returnsNormally);
    });

    test('a custom error object is thrown as given', () {
      final faults = StoreFaults()..failNextWrite(ArgumentError('nope'));

      expect(faults.throwIfWrite, throwsArgumentError);
    });

    test('clearing drops pending faults', () {
      final faults = StoreFaults()
        ..failNextWrite()
        ..clear();

      expect(faults.throwIfWrite, returnsNormally);
    });
  });
}
