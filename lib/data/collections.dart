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

  /// The jobs in `lib/automations`, one record per scheduled automation.
  static const String automations = 'automations';

  /// Their append-only revision history, one record per automation id.
  ///
  /// Separate from [automations] because history outlives the job: a deleted
  /// automation's revisions stay, which is the whole point of an audit trail.
  static const String automationHistory = 'automation_history';
}
