// lib/data/collections.dart — the collection names Noir stores.
//
// Part of the persisted contract: these strings become directory names and
// storage keys, so renaming one without a migration orphans the data.
library;

abstract final class NoirCollections {
  static const String conversations = 'conversations';
  static const String providerSettings = 'provider_settings';
  static const String prompts = 'prompts';
  static const String memories = 'memories';
  static const String usage = 'usage';
  static const String jobs = 'jobs';
}
