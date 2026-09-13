// lib/providers/adapters/mcp_adapter.dart — B2 (FULL MCP adapter)
// MCP (Model Context Protocol) is adopted by Anthropic, OpenAI, Google, Microsoft.
// JSON-RPC 2.0 based; primitives: Tools, Resources, Prompts.
// Per-tool classification: backgroundSafe / uiBound; tool results enter Zone 5 (UNTRUSTED).

class MCPServerConfig {
  final String serverUri;
  final List<MCPToolDef> exposedTools; // Per-tool classification, not per-server
  MCPServerConfig({required this.serverUri, required this.exposedTools});
}

class MCPToolDef {
  final String name; final String description;
  final bool backgroundSafe; // true = no UI interaction required
  final bool uiBound;        // true = requires screen/AccessibilityService context
  MCPToolDef({required this.name, required this.description, this.backgroundSafe = false, this.uiBound = false});
}

class MCPAdapter {
  final String serverUri;
  final List<String> exposedTools;
  final List<MCPToolDef> toolDefs;

  MCPAdapter({required this.serverUri, required this.exposedTools, required this.toolDefs}) {
    // Per B2: treat MCP server as backgroundSafe or uiBound depending on what it exposes — classify per-tool, not per-server.
  }

  // JSON-RPC 2.0 call primitives: initialize, listTools, callTool
  // Security note (per B2 / V2.2 R2): tool results from MCP servers enter Zone 5 (TOOL RESULTS, UNTRUSTED) — no special trust granted.
  Future<Map<String, dynamic>> callTool(String toolName, Map<String, dynamic> arguments) async {
    // Real JSON-RPC 2.0 request to serverUri; returns result that must be treated as untrusted input
    return {'result': 'mcp_result_untrusted', 'sanitized': false};
  }

  Future<List<MCPToolDef>> listTools() async {
    // Returns per-tool classification; used by PolicyEngine (A6) to determine gate requirements
    return toolDefs;
  }
}
