// lib/data/secrets.dart — the secret provider boundary.
//
// Noir never puts a secret in a record, a log line or an export. A record holds
// a *reference*; the value itself lives behind [SecretStore], and reaching it
// means asking for it by reference on purpose. The two shipped stores say
// plainly what they are: one volatile, one durable and not encrypted at rest —
// no claim is made here that a build cannot keep.

import 'dart:convert';
import 'dart:io';

import 'data_errors.dart';
import 'key_value_store.dart';

/// What every redaction of a secret looks like.
const String redactedSecretPlaceholder = '<redacted>';

/// A provider of secret values, addressed by reference.
///
/// Implementations must never log a value and never include one in an error
/// message. This is the only place in the data layer that can hand out a
/// plaintext secret.
abstract interface class SecretStore {
  /// The value behind [ref], or null.
  Future<String?> read(String ref);

  /// Stores [value] under [ref], replacing any previous value.
  Future<void> write(String ref, String value);

  /// Removes [ref]. Deleting a ref that is not held is a no-op.
  Future<void> delete(String ref);

  /// Whether a value is held for [ref].
  Future<bool> has(String ref);

  /// Every ref this store holds, sorted.
  Future<List<String>> listRefs();

  /// Whether values survive a process restart. In-memory: false.
  bool get isDurable;

  /// Whether values are encrypted on disk. False for both shipped stores: this
  /// build has no platform keystore binding, and says so.
  bool get isEncryptedAtRest;

  /// What this store does protect against, in one line, for diagnostics.
  String get protectionSummary;
}

/// A [SecretStore] that keeps values in memory only.
///
/// The default for tests and for a session that must not write secrets out.
class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? initial])
    : _values = Map<String, String>.of(initial ?? const <String, String>{});

  final Map<String, String> _values;

  /// A read-only view of the refs, for assertions and diagnostics. Values are
  /// not exposed: assertions check presence, not plaintext.
  List<String> get refs => listRefsSync();

  List<String> listRefsSync() => _values.keys.toList()..sort();

  @override
  bool get isDurable => false;

  @override
  bool get isEncryptedAtRest => false;

  @override
  String get protectionSummary =>
      'in-memory only: values are lost when the process exits';

  @override
  Future<String?> read(String ref) async => _values[checkedSecretRef(ref)];

  @override
  Future<void> write(String ref, String value) async {
    final key = checkedSecretRef(ref);
    if (value.isEmpty) {
      throw const InvalidDataError('a secret value must not be empty');
    }
    _values[key] = value;
  }

  @override
  Future<void> delete(String ref) async {
    _values.remove(checkedSecretRef(ref));
  }

  @override
  Future<bool> has(String ref) async =>
      _values.containsKey(checkedSecretRef(ref));

  @override
  Future<List<String>> listRefs() async => listRefsSync();
}

/// A [SecretStore] that keeps values in files under a private directory.
///
/// Honest limitations, asserted by the tests: values are stored as plain text,
/// protected only by whatever the filesystem and OS sandboxing provide. Dart has
/// no chmod, so this cannot tighten the file mode itself. On Android the store
/// must live in app-private storage, and a production build should bind
/// [SecretStore] to the platform keystore instead of using this.
class FileSecretStore implements SecretStore {
  FileSecretStore({
    required this.root,
    bool Function(String ref)? existsSyncOverride,
  }) : _existsSyncOverride = existsSyncOverride {
    try {
      root.createSync(recursive: true);
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: root.path,
        operation: 'create secret directory',
        cause: error,
      );
    }
  }

  /// The directory holding the secret files.
  final Directory root;

  final bool Function(String ref)? _existsSyncOverride;

  File _fileFor(String ref) =>
      File('${root.path}/${checkedSecretRef(ref)}.secret');

  @override
  bool get isDurable => true;

  @override
  bool get isEncryptedAtRest => false;

  @override
  String get protectionSummary =>
      'plain text in ${root.path}; protected only by OS-level access to the '
      'app-private directory, not encrypted at rest';

  @override
  Future<String?> read(String ref) async {
    final file = _fileFor(ref);
    try {
      if (!file.existsSync()) {
        return null;
      }
      return utf8.decode(file.readAsBytesSync());
    } on FormatException {
      // Values are written as UTF-8 text; unreadable bytes are unreadable
      // secrets, and a secret must never leak through an error message.
      throw const SecretNotFoundError('<unreadable secret bytes>');
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: file.path,
        operation: 'read secret',
        cause: error,
      );
    }
  }

  @override
  Future<void> write(String ref, String value) async {
    final file = _fileFor(ref);
    if (value.isEmpty) {
      throw const InvalidDataError('a secret value must not be empty');
    }
    try {
      root.createSync(recursive: true);
      final handle = file.openSync(mode: FileMode.write);
      try {
        handle.writeStringSync(value);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: file.path,
        operation: 'write secret',
        cause: error,
      );
    }
  }

  @override
  Future<void> delete(String ref) async {
    final file = _fileFor(ref);
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on FileSystemException catch (error) {
      throw StorageIoError(
        path: file.path,
        operation: 'delete secret',
        cause: error,
      );
    }
  }

  @override
  Future<bool> has(String ref) async {
    if (_existsSyncOverride != null) {
      return _existsSyncOverride(ref);
    }
    return _fileFor(ref).existsSync();
  }

  @override
  Future<List<String>> listRefs() async {
    if (!root.existsSync()) {
      return const <String>[];
    }
    final refs =
        root
            .listSync()
            .whereType<File>()
            .map((file) {
              final name = file.uri.pathSegments.last;
              return name.endsWith('.secret')
                  ? name.substring(0, name.length - '.secret'.length)
                  : null;
            })
            .whereType<String>()
            .toList()
          ..sort();
    return refs;
  }
}

/// Validates a secret reference so it can never become a path escape.
String checkedSecretRef(String ref) {
  if (ref.isEmpty) {
    throw const StorageKeyError('', 'a secret reference must not be empty');
  }
  if (ref.length > maxRecordIdLength) {
    throw StorageKeyError(
      ref,
      'a secret reference must be at most $maxRecordIdLength characters',
    );
  }
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(ref)) {
    throw StorageKeyError(
      ref,
      'a secret reference must be letters, digits, dot, underscore and dash',
    );
  }
  if (ref.contains('__')) {
    throw StorageKeyError(ref, 'a secret reference must not contain "__"');
  }
  return ref;
}

/// Replaces every occurrence of any known secret value in [text].
///
/// Used before anything is written to a log or an export, because a secret only
/// has to leak once.
String redactSecretsIn(String text, Iterable<String> secrets) {
  var result = text;
  for (final secret in secrets) {
    if (secret.isEmpty) {
      continue;
    }
    result = result.replaceAll(secret, redactedSecretPlaceholder);
  }
  return result;
}

/// A display-safe rendering of a secret: its presence, never its value.
String describeSecret(String ref, {required bool present}) =>
    'secret($ref, ${present ? 'configured' : 'absent'})';
