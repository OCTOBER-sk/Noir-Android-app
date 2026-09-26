// lib/providers/adapters/mcp_adapter.dart — B2, the MCP adapter Noir exposes to
// the agent.
//
// The adapter is the seam between the A6 safety layer and an untrusted MCP
// server. It holds no protocol logic of its own: the session lives in
// [McpClient] (JSON-RPC 2.0 over an injectable transport) and the untrusted
// labelling lives in lib/providers/mcp/mcp_untrusted.dart. What the adapter
// adds is the policy Noir owes its user, per B2 / V2.2 R2:
//
//   * Per-tool, never per-server, classification. [MCPToolDef]s on
//     [exposedTools] are the allowlist AND the operator's safety declaration.
//   * A tool that is not on the allowlist is refused before a single byte goes
//     out ([kMcpToolNotExposed]).
//   * A tool whose classification requires a gate is refused until the caller
//     passes the PolicyEngine verdict it already has ([kMcpGateRequired]). Noir's
//     PolicyEngine stays the only authority; this adapter never approves
//     anything, it only refuses to proceed without a verdict.
//   * Everything a server sends comes back as an McpUntrusted* type. There is no
//     method here that returns raw server text, and no method that could be
//     mistaken for system instructions.
import '../mcp/mcp_client.dart';
import '../mcp/mcp_protocol.dart';
import '../mcp/mcp_safety.dart';
import '../mcp/mcp_untrusted.dart';

export '../mcp/mcp_client.dart'
    show McpCancellationToken, McpCapabilityDiscovery, McpClient;
export '../mcp/mcp_safety.dart'
    show MCPToolDef, McpToolSafety, McpToolClassifier;
export '../mcp/mcp_untrusted.dart'
    show
        kMcpUntrustedHeader,
        kMcpUntrustedTrust,
        kMcpUntrustedZone,
        McpTrustLevel,
        McpUntrustedContent,
        McpUntrustedSanitizer,
        McpUntrustedText,
        McpUntrustedToolResult;

/// How one MCP server is wired up: where it lives, which tools Noir is willing
/// to expose, and the client that talks to it.
class MCPServerConfig {
  MCPServerConfig({
    required this.serverUri,
    required this.exposedTools,
    required this.client,
    this.transportKind = 'unknown',
  });

  /// Identifier for this server in logs and Safety Center rows. Also the
  /// `server` field on every untrusted payload it produces.
  final String serverUri;

  /// The allowlist. A tool absent from this list can never be called.
  final List<MCPToolDef> exposedTools;

  final McpClient client;

  /// `http` or `stdio`, for diagnostics.
  final String transportKind;
}

class MCPAdapter {
  MCPAdapter({
    required this.serverUri,
    required this.exposedTools,
    required List<MCPToolDef> toolDefs,
    required this.client,
    this.requireGateForRiskyTools = true,
  }) : toolDefs = List<MCPToolDef>.unmodifiable(toolDefs);

  /// Builds an adapter from a server config, using the config's allowlist as
  /// the adapter's tool declarations.
  factory MCPAdapter.forConfig(
    MCPServerConfig config, {
    bool requireGateForRiskyTools = true,
  }) {
    return MCPAdapter(
      serverUri: config.serverUri,
      exposedTools: config.exposedTools,
      toolDefs: config.exposedTools,
      client: config.client,
      requireGateForRiskyTools: requireGateForRiskyTools,
    );
  }

  /// Identifier of the server this adapter fronts.
  final String serverUri;

  /// The operator's allowlist and safety declarations.
  final List<MCPToolDef> exposedTools;

  /// Extra tool declarations carried over from older config shapes. They are
  /// declarations only; nothing is called unless it is also on the allowlist.
  final List<MCPToolDef> toolDefs;

  final McpClient client;

  /// When true, a tool classified as needing a gate is refused until
  /// [callTool] is given `gateApproved: true`.
  final bool requireGateForRiskyTools;

  final Map<String, MCPToolDef> _catalog = <String, MCPToolDef>{};
  static const McpToolClassifier _classifier = McpToolClassifier();

  // -------------------------------------------------------------------------
  // Session
  // -------------------------------------------------------------------------

  /// Completes the real initialize handshake. Idempotent.
  Future<McpInitializeResult> initialize({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    if (client.isInitialized) return client.initialization!;
    return client.initialize(timeout: timeout, cancellation: cancellation);
  }

  /// What the server can do and what it actually exposes.
  Future<McpCapabilityDiscovery> discover({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    await initialize(timeout: timeout, cancellation: cancellation);
    return client.discover(timeout: timeout, cancellation: cancellation);
  }

  // -------------------------------------------------------------------------
  // Tools
  // -------------------------------------------------------------------------

  /// Re-reads the server's tool catalogue and classifies every entry, layering
  /// the operator's declarations on top. This is the only source of "what can
  /// this server do"; the allowlist stays the source of "what may Noir do".
  Future<List<MCPToolDef>> refreshCatalog({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    final List<McpToolSpec> specs = await client.listTools(
      timeout: timeout,
      cancellation: cancellation,
    );
    _catalog.clear();
    for (final McpToolSpec spec in specs) {
      _catalog[spec.name] = MCPToolDef.fromSpec(
        spec,
        override: toolDefFor(spec.name),
      );
    }
    return List<MCPToolDef>.unmodifiable(_catalog.values);
  }

  /// The server's tools, classified. Fails when the server never declared the
  /// tools capability, rather than reporting an empty catalogue as success.
  Future<List<MCPToolDef>> listTools({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    await initialize(timeout: timeout, cancellation: cancellation);
    return refreshCatalog(timeout: timeout, cancellation: cancellation);
  }

  /// The operator's declaration for [name], if the tool is on the allowlist.
  MCPToolDef? toolDefFor(String name) {
    for (final MCPToolDef def in <MCPToolDef>[...exposedTools, ...toolDefs]) {
      if (def.name == name) return def;
    }
    return null;
  }

  /// The classification used for [name]: the live catalogue entry when the
  /// server has been read, the operator's declaration otherwise, and a
  /// fail-closed HIGH_RISK verdict when neither exists.
  McpToolSafety safetyFor(String name) =>
      _catalog[name]?.safety ??
      _classifier.classifyTool(name: name, override: toolDefFor(name));

  /// Calls [toolName] and returns the result as UNTRUSTED data.
  ///
  /// [gateApproved] must only be true once the PolicyEngine has actually
  /// returned `needsConfirmation: false` for this action. Passing true without
  /// a real verdict is a lie the adapter cannot detect, which is exactly why the
  /// default is false and the requirement is explicit.
  Future<McpUntrustedToolResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    bool gateApproved = false,
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    if (toolName.trim().isEmpty) {
      throw const McpMalformedMessageException(
        kMcpInvalidArguments,
        'MCP tool name must not be empty',
      );
    }
    final MCPToolDef? declared = toolDefFor(toolName);
    if (declared == null) {
      throw McpPolicyException(
        kMcpToolNotExposed,
        'MCP tool $toolName is not on the allowlist for $serverUri',
      );
    }
    final McpToolSafety safety = safetyFor(toolName);
    if (requireGateForRiskyTools && safety.requiresGate && !gateApproved) {
      throw McpPolicyException(
        kMcpGateRequired,
        'MCP tool $toolName is classified ${safety.tier.name} '
        '(${safety.basis}); a PolicyEngine verdict is required before it runs',
      );
    }
    final McpToolCallOutcome outcome = await client.callTool(
      toolName,
      arguments,
      timeout: timeout,
      cancellation: cancellation,
    );
    return McpUntrustedToolResult.fromOutcome(
      serverId: serverUri,
      toolName: toolName,
      outcome: outcome,
    );
  }

  /// The legacy map shape, now backed by the real result and an honest
  /// `sanitized` flag. The text inside is the labelled, fenced untrusted block.
  Future<Map<String, dynamic>> callToolMap(
    String toolName,
    Map<String, dynamic> arguments, {
    bool gateApproved = false,
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    final McpUntrustedToolResult result = await callTool(
      toolName,
      arguments,
      gateApproved: gateApproved,
      cancellation: cancellation,
      timeout: timeout,
    );
    return result.toLegacyMap();
  }

  // -------------------------------------------------------------------------
  // Resources and prompts (also untrusted)
  // -------------------------------------------------------------------------

  Future<List<McpResourceSpec>> listResources({
    String? cursor,
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    await initialize(timeout: timeout, cancellation: cancellation);
    return client.listResources(timeout: timeout, cancellation: cancellation);
  }

  Future<McpResourceContents> readResource(
    String uri, {
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    await initialize(timeout: timeout, cancellation: cancellation);
    return client.readResource(
      uri,
      timeout: timeout,
      cancellation: cancellation,
    );
  }

  /// Resource bodies are server-controlled too, so they come back scrubbed and
  /// labelled.
  Future<McpUntrustedContent> readResourceUntrusted(
    String uri, {
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    final McpResourceContents contents = await readResource(
      uri,
      cancellation: cancellation,
      timeout: timeout,
    );
    return McpUntrustedContent.resourceContents(
      '$serverUri/resources/$uri',
      contents,
    );
  }

  Future<List<McpPromptSpec>> listPrompts({
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    await initialize(timeout: timeout, cancellation: cancellation);
    return client.listPrompts(timeout: timeout, cancellation: cancellation);
  }

  Future<McpPromptResult> getPrompt(
    String name, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    await initialize(timeout: timeout, cancellation: cancellation);
    return client.getPrompt(
      name,
      arguments: arguments,
      timeout: timeout,
      cancellation: cancellation,
    );
  }

  /// A prompt's messages rendered as untrusted content.
  Future<McpUntrustedContent> getPromptUntrusted(
    String name, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    final McpPromptResult prompt = await getPrompt(
      name,
      arguments: arguments,
      cancellation: cancellation,
      timeout: timeout,
    );
    return McpUntrustedContent(
      source: '$serverUri/prompts/$name',
      rawText: prompt.messages
          .map(
            (McpPromptMessage message) =>
                '${message.role}: ${message.content.text ?? ''}',
          )
          .join('\n'),
      kind: 'prompt-messages',
    );
  }

  /// The server's `initialize.instructions`, if it sent any, as untrusted
  /// content. A server cannot use this field to reach Noir's model as a system
  /// prompt.
  McpUntrustedContent? serverInstructions() {
    final McpInitializeResult? initialization = client.initialization;
    if (initialization == null) return null;
    if (initialization.instructions == null) return null;
    return McpUntrustedContent.serverInstructions(initialization);
  }

  Future<void> close() => client.close();
}
