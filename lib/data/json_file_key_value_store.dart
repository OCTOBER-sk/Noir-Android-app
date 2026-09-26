// lib/data/json_file_key_value_store.dart — the real on-disk store.
//
// Layout under [root]:
//   <collection>/<id>.json          current bytes
//   <collection>/<id>__bak.json      previous good bytes
//   <collection>/<id>__tmp<n>.json   a write in flight, never read
//   quarantine/<collection>~<id>#<n>.json   preserved bad bytes
//
// A write is staged in a temp file, flushed, and only then renamed over the
// primary, after the previous bytes have been rotated to the backup. A crash at
// any point leaves either the old record or the new one readable, never a
// half-written file.

import 'dart:convert';
import 'dart:io';

import 'data_errors.dart';
import 'key_value_store.dart';
import 'schema.dart';

const String _jsonSuffix = '.json';
const String _backupMarker = '__bak';
const String _tempMarker = '__tmp';

/// A [KeyValueStore] backed by one JSON file per record.
class JsonFileKeyValueStore extends KeyValueStoreBase {
  /// Creates the store and its directories. [root] is created when missing.
  JsonFileKeyValueStore({
    required this.root,
    super.clock,
    SchemaCatalog? catalog,
  }) : super(catalog: catalog ?? SchemaCatalog()) {
    _prepareRoot();
  }

  /// The directory holding the store's files.
  final Directory root;

  @override
  bool get isDurable => true;

  static const String _quarantineDir = 'quarantine';

  Directory get _quarantineRoot => Directory('${root.path}/$_quarantineDir');

  void _prepareRoot() {
    try {
      root.createSync(recursive: true);
      _quarantineRoot.createSync(recursive: true);
      for (final name in catalog.names) {
        Directory('${root.path}/$name').createSync(recursive: true);
      }
    } on FileSystemException catch (error) {
      throw StorageIoError(path: root.path, operation: 'create', cause: error);
    }
  }

  // ---------------------------------------------------------------------
  // Paths.
  // ---------------------------------------------------------------------

  String _fileName(String key) {
    final separator = key.lastIndexOf('/');
    return key.substring(separator + 1);
  }

  String _dirPath(String key) {
    final separator = key.lastIndexOf('/');
    return '${root.path}/${key.substring(0, separator)}';
  }

  File _primaryFile(String key) =>
      File('${_dirPath(key)}/${_fileName(key)}$_jsonSuffix');

  File _backupFile(String key) =>
      File('${_dirPath(key)}/${_fileName(key)}$_backupMarker$_jsonSuffix');

  File _tempFile(String key, int index) =>
      File('${_dirPath(key)}/${_fileName(key)}$_tempMarker$index$_jsonSuffix');

  File _quarantineFile(String id) =>
      File('${_quarantineRoot.path}/$id$_jsonSuffix');

  // ---------------------------------------------------------------------
  // Primitives.
  // ---------------------------------------------------------------------

  @override
  String? readPrimary(String key) => _readFile(_primaryFile(key), 'read');

  @override
  String? readBackup(String key) => _readFile(_backupFile(key), 'read backup');

  String? _readFile(File file, String operation) {
    try {
      if (!file.existsSync()) {
        return null;
      }
      final bytes = file.readAsBytesSync();
      try {
        return utf8.decode(bytes);
      } on FormatException catch (error) {
        throw StorageDecodeError(
          'stored bytes are not valid UTF-8 (${bytes.length} byte(s))',
          cause: error,
        );
      }
    } on FileSystemException catch (error) {
      throw StorageIoError(path: file.path, operation: operation, cause: error);
    }
  }

  @override
  void writePrimaryAtomically(String key, String contents) {
    final directory = Directory(_dirPath(key));
    final primary = _primaryFile(key);
    final temp = _tempFile(key, _nextTempIndex(key));

    try {
      directory.createSync(recursive: true);
      // 1. Stage the new bytes and flush them to the filesystem.
      final handle = temp.openSync(mode: FileMode.write);
      try {
        handle.writeStringSync(contents);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: temp.path,
        operation: 'write temp file',
        cause: error,
      );
    }

    // 2. A crash here leaves the old primary and the backup intact.
    throwIfSwapFault();

    try {
      // 3. Rotate the previous good bytes to the backup, then publish.
      if (primary.existsSync()) {
        _replace(primary, _backupFile(key));
      }
      _replace(temp, primary);
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: primary.path,
        operation: 'swap in staged write',
        cause: error,
      );
    }
    _removeStaleTempFiles(key);
  }

  /// Renames [source] onto [target], replacing whatever was there.
  void _replace(File source, File target) {
    if (target.existsSync()) {
      target.deleteSync();
    }
    source.renameSync(target.path);
  }

  int _tempCounter = 0;

  int _nextTempIndex(String key) => ++_tempCounter;

  /// Drops `*.tmp` files left behind by an interrupted write. Only ever called
  /// after the record itself was published successfully.
  void _removeStaleTempFiles(String key) {
    final directory = Directory(_dirPath(key));
    if (!directory.existsSync()) {
      return;
    }
    final prefix = '${_fileName(key)}$_tempMarker';
    for (final entity in directory.listSync()) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      if (name.startsWith(prefix) && name.endsWith(_jsonSuffix)) {
        try {
          entity.deleteSync();
        } on FileSystemException {
          // A leftover temp file is inert: it is never read, never listed.
        }
      }
    }
  }

  @override
  void damagePrimaryBytes(String key, String contents) {
    final primary = _primaryFile(key);
    final temp = _tempFile(key, _nextTempIndex(key));
    try {
      Directory(_dirPath(key)).createSync(recursive: true);
      final handle = temp.openSync(mode: FileMode.write);
      try {
        handle.writeStringSync(contents);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      _replace(temp, primary);
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: primary.path,
        operation: 'overwrite primary',
        cause: error,
      );
    }
  }

  @override
  void removeRecordFiles(String key) {
    _remove(_primaryFile(key), 'delete');
    _remove(_backupFile(key), 'delete backup');
    _removeStaleTempFiles(key);
  }

  void _remove(File file, String operation) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on FileSystemException catch (error) {
      throw StorageIoError(path: file.path, operation: operation, cause: error);
    }
  }

  @override
  List<String> listRecordIds(String collection) {
    final directory = Directory('${root.path}/$collection');
    if (!directory.existsSync()) {
      return const <String>[];
    }
    final ids = <String>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith(_jsonSuffix)) {
        continue;
      }
      final id = name.substring(0, name.length - _jsonSuffix.length);
      // Skip the store's own side files.
      if (id.contains(_backupMarker) || id.contains(_tempMarker)) {
        continue;
      }
      ids.add(id);
    }
    ids.sort();
    return ids;
  }

  @override
  int nextQuarantineIndex(String key) {
    var index = 1;
    while (_quarantineFile(quarantineIdFor(key, index)).existsSync()) {
      index++;
    }
    return index;
  }

  @override
  String quarantinePrimary(String key, {required bool move}) {
    final id = quarantineIdFor(key, nextQuarantineIndex(key));
    final target = _quarantineFile(id);
    final source = _primaryFile(key);
    try {
      _quarantineRoot.createSync(recursive: true);
      if (!source.existsSync()) {
        return id;
      }
      if (move) {
        _replace(source, target);
      } else {
        source.copySync(target.path);
      }
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: target.path,
        operation: 'quarantine',
        cause: error,
      );
    }
    return id;
  }

  @override
  String? findQuarantineId(String key) {
    for (var index = 1000; index >= 1; index--) {
      final id = quarantineIdFor(key, index);
      if (_quarantineFile(id).existsSync()) {
        return id;
      }
    }
    return null;
  }

  @override
  String? readQuarantine(String id) =>
      _readFile(_quarantineFile(id), 'read quarantine');

  @override
  List<String> listQuarantineIds() {
    if (!_quarantineRoot.existsSync()) {
      return const <String>[];
    }
    final ids = _quarantineRoot.listSync().whereType<File>().map((file) {
      final name = file.uri.pathSegments.last;
      return name.endsWith(_jsonSuffix)
          ? name.substring(0, name.length - _jsonSuffix.length)
          : name;
    }).toList()..sort();
    return ids;
  }
}
