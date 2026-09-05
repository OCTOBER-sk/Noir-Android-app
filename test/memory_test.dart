import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/memory/layers.dart';
import 'package:noir_android_app/memory/memory_store.dart';

void main() {
  test('MemoryStore starts empty for every layer', () {
    final store = MemoryStore();
    for (final layer in MemoryLayer.values) {
      expect(store.getAll(layer), isEmpty);
    }
  });

  test('add stores an item retrievable by id across layers', () {
    final store = MemoryStore();
    final item = MemoryItem(
      content: 'hello',
      source: 'test',
      layer: MemoryLayer.shortTerm,
    );
    store.add(item);
    expect(store.getAll(MemoryLayer.shortTerm), hasLength(1));
    expect(store.get(item.id), same(item));
  });

  test('getAll isolates items per layer', () {
    final store = MemoryStore();
    store.add(MemoryItem(content: 'a', layer: MemoryLayer.sensory));
    store.add(MemoryItem(content: 'b', layer: MemoryLayer.episodic));
    store.add(MemoryItem(content: 'c', layer: MemoryLayer.sensory));
    expect(store.getAll(MemoryLayer.sensory), hasLength(2));
    expect(store.getAll(MemoryLayer.episodic), hasLength(1));
    expect(store.getAll(MemoryLayer.sensory).map((e) => e.content),
        containsAllInOrder(['a', 'c']));
  });

  test('remove clears a single item; clear wipes all layers', () {
    final store = MemoryStore();
    final item = MemoryItem(content: 'x', layer: MemoryLayer.meta);
    store.add(item);
    expect(store.remove(item.id), isTrue);
    expect(store.get(item.id), isNull);
    expect(store.remove('nonexistent'), isFalse);

    store.add(MemoryItem(content: 'y', layer: MemoryLayer.sensory));
    store.add(MemoryItem(content: 'z', layer: MemoryLayer.procedural));
    store.clear();
    expect(store.getAll(MemoryLayer.sensory), isEmpty);
    expect(store.getAll(MemoryLayer.procedural), isEmpty);
  });
}
