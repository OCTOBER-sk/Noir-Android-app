import 'layers.dart';

/// Counter backing the zero-dependency ID generator.
int _idCounter = 0;

/// Generates a monotonically unique id without external packages.
String _generateId() {
  _idCounter += 1;
  return '${DateTime.now().microsecondsSinceEpoch}_$_idCounter';
}

/// An atomic item of agent memory, stamped with a [MemoryLayer].
class MemoryItem {
  /// Stable unique identifier.
  final String id;

  /// The textual content of the memory item.
  final String content;

  /// When the item was recorded.
  final DateTime timestamp;

  /// Optional origin label (e.g. provider name, task id).
  final String? source;

  /// Which [MemoryLayer] this item belongs to.
  final MemoryLayer layer;

  /// Creates a new [MemoryItem].
  ///
  /// If [id] is omitted, a unique id is generated automatically.
  MemoryItem({
    String? id,
    required this.content,
    DateTime? timestamp,
    this.source,
    required this.layer,
  })  : id = id ?? _generateId(),
        timestamp = timestamp ?? DateTime.now();
}

/// In-memory CRUD store partitioned by [MemoryLayer] (V2.1 §A1 thin).
///
/// Each layer keeps its own insertion-ordered list. This is the pure-Dart
/// stand-in for the eventual Drift-backed memory; the persistence layer is a
/// future concern.
class MemoryStore {
  final Map<MemoryLayer, List<MemoryItem>> _byLayer = {
    for (final layer in MemoryLayer.values) layer: <MemoryItem>[],
  };

  /// Adds [item] to the list for its [MemoryItem.layer].
  void add(MemoryItem item) {
    _byLayer[item.layer]!.add(item);
  }

  /// Returns the [MemoryItem] with the given [id], or `null` if absent.
  MemoryItem? get(String id) {
    for (final list in _byLayer.values) {
      for (final item in list) {
        if (item.id == id) return item;
      }
    }
    return null;
  }

  /// Returns all items stored under [layer] (insertion order).
  List<MemoryItem> getAll(MemoryLayer layer) =>
      List<MemoryItem>.unmodifiable(_byLayer[layer]!);

  /// Removes the [MemoryItem] with the given [id]. Returns `true` if removed.
  bool remove(String id) {
    for (final list in _byLayer.values) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].id == id) {
          list.removeAt(i);
          return true;
        }
      }
    }
    return false;
  }

  /// Removes every item across every layer.
  void clear() {
    for (final list in _byLayer.values) {
      list.clear();
    }
  }
}
