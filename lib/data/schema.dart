// lib/data/schema.dart — per-collection schema versions and migration steps.
//
// A collection is a logical table of JSON records (conversations, settings,
// prompts, memories, usage records, jobs). Every record carries the schema
// version of the writer that produced it; reads migrate forward, and anything
// newer than this build is refused rather than guessed at.

import 'data_errors.dart';

/// Upgrades a stored payload by exactly one schema version.
typedef PayloadMigration =
    Map<String, Object?> Function(Map<String, Object?> payload);

/// One forward step in a collection's schema history.
class SchemaMigration {
  const SchemaMigration({
    required this.fromVersion,
    required this.toVersion,
    required this.description,
    required this.migrate,
  });

  final int fromVersion;
  final int toVersion;

  /// Human-readable summary; shown in [MissingMigrationError] diagnostics and
  /// in the data layer's self-report.
  final String description;
  final PayloadMigration migrate;

  @override
  String toString() =>
      'SchemaMigration($fromVersion -> $toVersion: $description)';
}

/// The schema of a single collection: current version plus the steps that reach
/// it from older versions.
class CollectionSchema {
  /// Declares a collection and its schema history.
  ///
  /// The chain is validated eagerly: a gap, a duplicate step, a step that skips
  /// a version or a step that runs past [currentVersion] is a
  /// [SchemaRegistrationError] at registration time, not a surprise on read.
  factory CollectionSchema({
    required String name,
    required int currentVersion,
    List<SchemaMigration> migrations = const <SchemaMigration>[],
  }) {
    if (!collectionNamePattern.hasMatch(name)) {
      throw SchemaRegistrationError(
        'collection name "$name" must match ${collectionNamePattern.pattern}',
      );
    }
    if (currentVersion < 1) {
      throw SchemaRegistrationError(
        'collection "$name" must start at schema version 1',
      );
    }
    return CollectionSchema._(
      name: name,
      currentVersion: currentVersion,
      migrations: List<SchemaMigration>.unmodifiable(
        _validate(name, currentVersion, migrations),
      ),
    );
  }

  const CollectionSchema._({
    required this.name,
    required this.currentVersion,
    required this.migrations,
  });
  static final RegExp collectionNamePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  final String name;
  final int currentVersion;
  final List<SchemaMigration> migrations;

  static List<SchemaMigration> _validate(
    String name,
    int currentVersion,
    List<SchemaMigration> migrations,
  ) {
    final sorted = List<SchemaMigration>.of(migrations)
      ..sort((a, b) => a.fromVersion.compareTo(b.fromVersion));
    final seen = <int>{};
    for (final migration in sorted) {
      if (migration.fromVersion < 1) {
        throw SchemaRegistrationError(
          'collection "$name" declares a migration from version '
          '${migration.fromVersion}; versions start at 1',
        );
      }
      if (migration.toVersion != migration.fromVersion + 1) {
        throw SchemaRegistrationError(
          'collection "$name" declares a ${migration.fromVersion} -> '
          '${migration.toVersion} step; steps must advance exactly one version',
        );
      }
      if (migration.toVersion > currentVersion) {
        throw SchemaRegistrationError(
          'collection "$name" is at version $currentVersion but declares a step '
          'reaching ${migration.toVersion}',
        );
      }
      if (!seen.add(migration.fromVersion)) {
        throw SchemaRegistrationError(
          'collection "$name" declares two steps from version '
          '${migration.fromVersion}',
        );
      }
    }
    return sorted;
  }

  /// The ordered steps that lift a record from [onDiskVersion] to
  /// [currentVersion].
  ///
  /// Throws [MissingMigrationError] when the chain has a gap and
  /// [SchemaVersionTooNewError] when the data is from a newer build.
  List<SchemaMigration> pathFrom(int onDiskVersion) {
    if (onDiskVersion > currentVersion) {
      throw SchemaVersionTooNewError(
        collection: name,
        onDiskVersion: onDiskVersion,
        supportedVersion: currentVersion,
      );
    }
    if (onDiskVersion < 1) {
      throw InvalidSchemaVersionError(
        collection: name,
        requestedVersion: onDiskVersion,
        currentVersion: currentVersion,
      );
    }
    if (onDiskVersion == currentVersion) {
      return const <SchemaMigration>[];
    }
    final steps = <SchemaMigration>[];
    var cursor = onDiskVersion;
    while (cursor < currentVersion) {
      final step = migrations
          .where((migration) => migration.fromVersion == cursor)
          .toList();
      if (step.isEmpty) {
        throw MissingMigrationError(
          collection: name,
          fromVersion: cursor,
          toVersion: currentVersion,
        );
      }
      steps.add(step.single);
      cursor = step.single.toVersion;
    }
    return List<SchemaMigration>.unmodifiable(steps);
  }

  /// Applies every step needed to bring [onDiskVersion] up to date.
  ///
  /// Any throw from a step surfaces as [MigrationFailedError] with the original
  /// error attached; the caller is expected to leave the stored bytes alone.
  Map<String, Object?> migrate(
    int onDiskVersion,
    Map<String, Object?> payload,
  ) {
    var current = onDiskVersion;
    var data = payload;
    for (final step in pathFrom(onDiskVersion)) {
      try {
        data = step.migrate(data);
      } on DataStoreException {
        rethrow;
      } catch (error) {
        throw MigrationFailedError(
          collection: name,
          fromVersion: current,
          toVersion: step.toVersion,
          failure: error,
        );
      }
      current = step.toVersion;
    }
    return data;
  }

  @override
  String toString() =>
      'CollectionSchema($name, v$currentVersion, ${migrations.length} step(s))';
}

/// The set of collections this build understands.
class SchemaCatalog {
  final Map<String, CollectionSchema> _schemas = <String, CollectionSchema>{};

  /// Registers [schema], replacing any previous registration of the same name.
  void register(CollectionSchema schema) {
    _schemas[schema.name] = schema;
  }

  bool contains(String name) => _schemas.containsKey(name);

  CollectionSchema? find(String name) => _schemas[name];

  /// Throws [UnknownCollectionError] when [name] is not registered.
  CollectionSchema require(String name) {
    final schema = _schemas[name];
    if (schema == null) {
      throw UnknownCollectionError(name);
    }
    return schema;
  }

  List<String> get names => List<String>.unmodifiable(_schemas.keys);

  Map<String, CollectionSchema> get all =>
      Map<String, CollectionSchema>.unmodifiable(_schemas);
}
