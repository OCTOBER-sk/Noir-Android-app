// lib/providers/adapters/mcp_adapter.dart — B2 (MCP: Tools, Resources, Prompts)
// JSON-RPC 2.0 adapter; per-tool classification: backgroundSafe / uiBound.
class MCPAdapter {
  final String serverUri; final List<String> exposedTools;
  MCPAdapter(this.serverUri, this.exposedTools);
  // Tool results enter Zone 5 (UNTRUSTED) — no special trust granted.
}

// Security note: tool results from MCP servers enter Zone 5 (TOOL RESULTS, UNTRUSTED) — no special trust granted.
