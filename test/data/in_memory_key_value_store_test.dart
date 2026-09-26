import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/data/data.dart';

import 'support/key_value_store_contract.dart';

void main() {
  // The in-memory double must be indistinguishable from the real store: it runs
  // the identical contract below.
  keyValueStoreContract(
    name: 'InMemoryKeyValueStore',
    create: (catalog, clock) =>
        InMemoryKeyValueStore(catalog: catalog, clock: clock),
  );

  test(
    'the in-memory double survives a new instance over the same backing map',
    () async {
      DateTime clock() => DateTime.utc(2026, 3, 4, 5, 6, 7);
      final first = InMemoryKeyValueStore(
        catalog: buildContractCatalog(),
        clock: clock,
      );
      await first.write(widgetCollection, 'w1', <String, Object?>{'a': 1});

      final second = InMemoryKeyValueStore(
        catalog: buildContractCatalog(),
        clock: clock,
        backing: first.backing,
      );

      expect(await second.read(widgetCollection, 'w1'), <String, Object?>{
        'a': 1,
      });
    },
  );

  test(
    'the in-memory double is deterministic for a fixed clock and payload',
    () async {
      Future<String> encode() async {
        final store = InMemoryKeyValueStore(
          catalog: buildContractCatalog(),
          clock: () => DateTime.utc(2026, 3, 4, 5, 6, 7),
        );
        await store.write(widgetCollection, 'w1', <String, Object?>{
          'b': 1,
          'a': <Object?>[1, 2, 3],
          'c': <String, Object?>{'nested': 'value'},
        });
        return (await (store as RawStoreAccess).rawEnvelope(
          widgetCollection,
          'w1',
        ))!;
      }

      expect(await encode(), await encode());
    },
  );

  test(
    'the in-memory double is not shared between instances by default',
    () async {
      DateTime clock() => DateTime.utc(2026, 3, 4, 5, 6, 7);
      final first = InMemoryKeyValueStore(
        catalog: buildContractCatalog(),
        clock: clock,
      );
      final second = InMemoryKeyValueStore(
        catalog: buildContractCatalog(),
        clock: clock,
      );
      await first.write(widgetCollection, 'w1', <String, Object?>{'a': 1});

      expect(await second.read(widgetCollection, 'w1'), isNull);
    },
  );
}
