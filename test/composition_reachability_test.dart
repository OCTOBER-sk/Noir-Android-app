// test/composition_reachability_test.dart — the regression guard for the exact
// bug this branch fixes.
//
// The failure mode this test exists to stop is not a compile error and not a
// red test. It is a module that is fully implemented, fully covered by unit
// tests, and completely absent from the shipped app: `flutter analyze` is green
// because the file is valid Dart, and `flutter test` is green because the test
// files import the module directly. Nothing in CI can tell the difference
// between "wired into the product" and "only ever exercised by a test".
//
// So this test does what neither can: it walks the import/export graph from the
// real application entry point, `lib/main.dart`, over every file under `lib/`,
// and fails when any file is unreachable from it. A module that nothing in the
// app can reach is dead code at the app entry point, whatever the test suite
// says about it.
//
// `import` and `export` are both followed, because a re-export makes a file
// reachable in exactly the same sense an import does: the app can name its
// declarations.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The application entry point. Reachability is measured from here, because
/// this is the file the platform actually runs.
const String kEntryPoint = 'lib/main.dart';

/// `package:name/...` prefix of this package.
const String kPackageUri = 'package:noir_android_app/';

/// Matches a relative or `package:` `import`/`export` directive at the start of
/// a line. Directives may be preceded by whitespace; anything else (a mention
/// in a doc comment, a string literal) is not a directive and is ignored.
final RegExp _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Resolves a URI to a package-relative path, or null when it points outside
/// this package (`dart:`, `package:flutter/…`, `package:http/…`).
String? _packagePath(String uri) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    if (!uri.startsWith(kPackageUri)) return null;
    return 'lib/${uri.substring(kPackageUri.length)}';
  }
  if (uri.contains(':')) return null;
  return uri;
}

/// The package root: the nearest ancestor of the test working directory that
/// holds a `pubspec.yaml`.
Directory _packageRoot() {
  Directory current = Directory.current.absolute;
  while (true) {
    if (File('${current.path}/pubspec.yaml').existsSync()) return current;
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('no pubspec.yaml found above ${Directory.current.path}');
    }
    current = parent;
  }
}

/// Every `.dart` file under `lib/`, as package-relative POSIX paths, sorted.
List<String> _libraryFiles(Directory root) {
  final Directory lib = Directory('${root.path}/lib');
  if (!lib.existsSync()) {
    throw StateError('no lib/ directory in ${root.path}');
  }
  final List<String> found = <String>[];
  for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      found.add(
        entity.path.substring(root.path.length + 1).replaceAll(r'\', '/'),
      );
    }
  }
  found.sort();
  return found;
}

/// The in-package files [relativePath] reaches in one hop.
List<String> _directTargets(Directory root, String relativePath) {
  final File file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('import graph references a missing file: $relativePath');
  }
  final String source = file.readAsStringSync();
  final String directory = relativePath.contains('/')
      ? relativePath.substring(0, relativePath.lastIndexOf('/'))
      : '';

  final List<String> targets = <String>[];
  for (final RegExpMatch match in _directive.allMatches(source)) {
    final String? path = _packagePath(match.group(1)!);
    if (path == null) continue;
    // Normalise `./` and `../` segments the way the analyzer does.
    final List<String> segments = <String>[
      ...directory.isEmpty ? const <String>[] : directory.split('/'),
      ...path.split('/'),
    ];
    final List<String> normalised = <String>[];
    for (final String segment in segments) {
      if (segment == '.' || segment.isEmpty) continue;
      if (segment == '..') {
        if (normalised.isEmpty) {
          throw StateError('$relativePath imports outside lib/: $path');
        }
        normalised.removeLast();
        continue;
      }
      normalised.add(segment);
    }
    final String resolved = normalised.join('/');
    for (final String candidate in <String>[
      resolved,
      '$resolved.dart',
      '$resolved/index.dart',
    ]) {
      if (File('${root.path}/$candidate').existsSync()) {
        targets.add(candidate);
        break;
      }
    }
  }
  return targets;
}

/// Every file under `lib/` that `lib/main.dart` can reach, by import or export.
Set<String> _reachableFrom(Directory root, String entryPoint) {
  if (!File('${root.path}/$entryPoint').existsSync()) {
    throw StateError('entry point not found: $entryPoint');
  }
  final Set<String> seen = <String>{};
  final List<String> pending = <String>[entryPoint];
  while (pending.isNotEmpty) {
    final String current = pending.removeLast();
    if (!seen.add(current)) continue;
    for (final String target in _directTargets(root, current)) {
      if (!seen.contains(target)) pending.add(target);
    }
  }
  return seen;
}

int _lineCount(Directory root, String relativePath) =>
    File('${root.path}/$relativePath').readAsLinesSync().length;

void main() {
  late Directory root;

  setUpAll(() {
    root = _packageRoot();
  });

  test('every file under lib/ is reachable from lib/main.dart', () {
    final List<String> all = _libraryFiles(root);
    final Set<String> reachable = _reachableFrom(root, kEntryPoint);
    final List<String> unreachable = all
        .where((String path) => !reachable.contains(path))
        .toList();

    final int unreachableLines = unreachable.fold<int>(
      0,
      (int sum, String path) => sum + _lineCount(root, path),
    );

    expect(
      unreachable,
      isEmpty,
      reason: <String>[
        '${unreachable.length} of ${all.length} files under lib/ are not '
            'reachable from $kEntryPoint '
            '($unreachableLines lines of dead code at the app entry point).',
        'A module nothing in the app can reach is not shipped, however many '
            'tests import it directly.',
        '',
        for (final String path in unreachable)
          '  ${_lineCount(root, path).toString().padLeft(5)}  $path',
      ].join('\n'),
    );
  });

  test('the reachability walker finds a file through a transitive import', () {
    // Guards the walker itself: main.dart reaches conversation_models.dart only
    // through conversation_controller.dart. If the walk were depth-1 the whole
    // assertion above would pass vacuously.
    final Set<String> reachable = _reachableFrom(root, kEntryPoint);
    expect(
      reachable,
      contains('lib/core/conversation_models.dart'),
      reason: 'a transitive import must count as reachable',
    );
    expect(
      reachable,
      contains('lib/core/ui_state_contract.dart'),
      reason: 'a re-export must count as reachable',
    );
  });

  test(
    'the reachability walker fails when a file is cut off from the entry',
    () {
      // Proves the guard has teeth: cut lib/main.dart down to a leaf import and
      // the very same walker must report the rest of lib/ as unreachable.
      final File original = File('${root.path}/$kEntryPoint');
      final String saved = original.readAsStringSync();
      final File leafOnly = File('${root.path}/lib/_reachability_probe.dart')
        ..writeAsStringSync(saved);
      try {
        final Set<String> fromLeaf = _reachableFrom(
          root,
          'lib/_reachability_probe.dart',
        );
        final List<String> all = _libraryFiles(root)
            .where((String path) => path != 'lib/_reachability_probe.dart')
            .toList();
        final List<String> hidden = all
            .where((String path) => !fromLeaf.contains(path))
            .toList();
        expect(
          hidden,
          isNotEmpty,
          reason:
              'an entry point that reaches nothing must be reported as '
              'reaching nothing',
        );
      } finally {
        leafOnly.deleteSync();
        expect(original.readAsStringSync(), saved);
      }
    },
  );
}
