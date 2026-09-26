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

  /// MCP servers the user configured (R2/B2). Empty means the app has no MCP
  /// capability, which the Safety Center states rather than filling in.
  static const String mcpServers = 'mcp_servers';
}
