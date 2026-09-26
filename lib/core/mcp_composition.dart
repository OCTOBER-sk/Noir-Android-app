// lib/core/mcp_composition.dart — the composition root for MCP (R2/B2).
//
// Before this file existed, MCPAdapter was real code that nothing in lib/ could
// construct: it was reachable only from a test. The composition is what closes
// that gap. It does three jobs and refuses to do a fourth:
//
//   1. Turns a *persisted, user-entered* [McpServerSettings] record into a live
//      [MCPAdapter]. There is no default endpoint and no fallback server, so an
//      empty configuration means the app has no MCP capability at all.
//   2. Asks [PolicyEngine] for a verdict before any tool whose classification
//      requires a gate, and treats "confirmed by the user" and "biometric
//      satisfied" as facts the caller has to supply. The adapter's
//      `gateApproved` flag is set from a real verdict and nothing else.
//   3. Returns every server payload as the McpUntrusted* type the adapter
//      produced, so nothing that arrives from a server can be mistaken for a
//      system or user instruction further up.
//
// Connections go through [McpTransportFactory], so the whole path is exercised
// in tests with a scripted transport and no network.
import 'dart:async';

import '../data/data.dart';
import '../providers/adapters/mcp_adapter.dart';
import '../providers/adapters/mcp_transport_factory.dart';
import '../providers/mcp/mcp_protocol.dart';
import '../providers/mcp/mcp_transport.dart';
import '../safety/policy_engine.dart';

/// A call was refused because the server is not in the user's configuration.
const String kMcpServerNotConfigured = 'MCP_SERVER_NOT_CONFIGURED';

/// A call was refused because no connection could be built for the server.
const String kMcpConnectionUnavailable = 'MCP_CONNECTION_UNAVAILABLE';

/// The policy engine blocked the call (UI lock, blacklist, malformed proposal).
const String kMcpPolicyBlocked = 'MCP_POLICY_BLOCKED';

/// The tool needs confirmation and the caller supplied none.
const String kMcpConfirmationRequired = 'MCP_CONFIRMATION_REQUIRED';

/// The tool needs a biometric check and the caller satisfied none.
const String kMcpBiometricRequired = 'MCP_BIOMETRIC_REQUIRED';

/// The action string the policy engine is asked about.
///
/// It is a stable, greppable name rather than a sentence, because the blacklist
/// matches on it: an operator who blocks `mcp:notes:delete_note` must block every
/// delete, whichever screen asked.
String mcpPolicyAction(String serverId, String toolName) =>
    'mcp:$serverId:$toolName';

/// The header an MCP server's bearer token travels in.
const String kMcpAuthorizationHeader = 'authorization';

/// What the user (or a caller standing in for one) has actually done.
///
/// Both fields are facts, not permissions: [McpComposition] refuses to set the
/// adapter's `gateApproved` flag from anything else. A UI that cannot produce a
/// real confirmation leaves them false and gets a refusal, which is the correct
/// outcome for a build with no biometric binding.
class McpConfirmation {
  const McpConfirmation({
    required this.userConfirmed,
    required this.biometricSatisfied,
  });

  /// Nobody confirmed anything.
  const McpConfirmation.none()
    : userConfirmed = false,
      biometricSatisfied = false;

  /// The user was asked and said yes.
  const McpConfirmation.user()
    : userConfirmed = true,
      biometricSatisfied = false;

  final bool userConfirmed;
  final bool biometricSatisfied;

  @override
  String toString() =>
      'McpConfirmation(user: $userConfirmed, biometric: $biometricSatisfied)';
}

/// A configured server, bound to a live adapter.
class McpServerBinding {
  McpServerBinding({required this.settings, required this.adapter});

  /// The persisted record this binding came from.
  final McpServerSettings settings;

  /// The adapter, built from that record's allowlist and endpoint.
  final MCPAdapter adapter;

  String get serverId => settings.id;

  /// The name shown in safety decisions: the user's own label, not the URI.
  String get label => settings.displayName;

  /// Whether the user's allowlist names [toolName]. The allowlist is the
  /// permission; the classification decides whether a gate is also required.
  bool isAllowed(String toolName) => settings.allowedTools.contains(toolName);

  /// The classification for [toolName]: the server's own catalogue once it has
  /// been read, the operator's declaration until then, and a fail-closed
  /// HIGH_RISK verdict when neither exists.
  McpToolSafety safetyFor(String toolName) => adapter.safetyFor(toolName);

  /// Reads the server's real tool list. This is the call that talks to the
  /// network, and it only happens when a caller asks for it.
  Future<List<MCPToolDef>> refreshTools() => adapter.listTools();

  Future<void> close() => adapter.close();

  @override
  String toString() => 'McpServerBinding($serverId, "$label", $settings)';
}

/// What a call through the composition produced.
///
/// Deliberately sealed: a caller has to say which of the three happened, and the
/// only successful case carries the untrusted result type rather than text.
sealed class McpToolOutcome {
  const McpToolOutcome();
}

/// The call never went out. [code] says why, in the same vocabulary the MCP
/// runtime uses, so a refusal is as inspectable as a protocol error.
final class McpToolRefused extends McpToolOutcome {
  const McpToolRefused({
    required this.code,
    required this.reason,
    required this.serverId,
    required this.toolName,
    this.safety,
    this.needsBiometric = false,
  });

  final String code;
  final String reason;
  final String serverId;
  final String toolName;

  /// The verdict that was used, when the call got as far as classification.
  final McpToolSafety? safety;

  /// Whether satisfying the refusal needs a biometric this build cannot perform.
  final bool needsBiometric;

  @override
  String toString() => 'McpToolRefused($code, $serverId/$toolName: $reason)';
}

/// The call went out and the connection or the server failed it. Still a typed
/// error rather than a result, and still nothing the server controls.
final class McpToolFailed extends McpToolOutcome {
  const McpToolFailed({
    required this.code,
    required this.message,
    required this.serverId,
    required this.toolName,
  });

  final String code;
  final String message;
  final String serverId;
  final String toolName;

  @override
  String toString() => 'McpToolFailed($code, $serverId/$toolName: $message)';
}

/// The call ran. The payload is UNTRUSTED data and stays that type here, in the
/// controller and in the widget: there is no accessor that returns server text as
/// something a model or a turn could read as an instruction.
final class McpToolCompleted extends McpToolOutcome {
  const McpToolCompleted(this.result);

  final McpUntrustedToolResult result;

  @override
  String toString() =>
      'McpToolCompleted(${result.serverId}/${result.toolName})';
}

/// Builds MCP adapters from persisted configuration and gates what they can do.
class McpComposition {
  McpComposition({
    required this.servers,
    required this.policy,
    McpTransportFactory? transportFactory,
    this.requestTimeout = const Duration(seconds: 20),
  }) : transportFactory = transportFactory ?? const IoMcpTransportFactory();

  /// The persisted configuration. The only source of MCP servers there is.
  final McpServerRepository servers;

  /// Noir's PolicyEngine stays the only authority for a gated call.
  final PolicyEngine policy;

  /// How a connection is made. Injected by tests; production opens sockets here
  /// and nowhere else.
  final McpTransportFactory transportFactory;

  /// Per-request deadline handed to each client this composition builds.
  final Duration requestTimeout;

  final Map<String, _CachedBinding> _bindings = <String, _CachedBinding>{};
  final Map<String, Future<McpServerBinding>> _building =
      <String, Future<McpServerBinding>>{};

  /// Every server the user configured, in id order. Empty means the app has no
  /// MCP capability — which the Safety Center says out loud.
  Future<List<McpServerSettings>> configuredServers() => servers.readAll();

  /// The binding for [serverId], or null when that server is not configured.
  ///
  /// Building a binding is not I/O: no frame is sent until someone asks for the
  /// tool list or calls a tool. A record that changed since the last bind (new
  /// endpoint, new allowlist) is rebuilt rather than reused, so a stale adapter
  /// can never outlive the configuration it was built from, and the session it
  /// replaced is closed.
  Future<McpServerBinding?> binding(String serverId) async {
    final McpServerSettings? settings = await servers.find(serverId);
    if (settings == null) return null;
    final _CachedBinding? cached = _bindings[serverId];
    if (cached != null && !cached.isStaleFor(settings)) return cached.binding;
    // One connection at a time: a caller that asks twice while a build is in
    // flight gets the same binding instead of two clients for one server.
    final Future<McpServerBinding>? pending = _building[serverId];
    if (pending != null) return pending;
    _building[serverId] = _replaceBinding(serverId, settings);
    final Future<McpServerBinding> building = _building[serverId]!;
    try {
      return await building;
    } finally {
      _building.remove(serverId);
    }
  }

  /// Builds the new connection, swaps it in, then closes the session it
  /// replaced. The close comes last so a rebuild never drops a live connection
  /// before its replacement exists.
  Future<McpServerBinding> _replaceBinding(
    String serverId,
    McpServerSettings settings,
  ) async {
    final McpServerBinding built = await _build(settings);
    final _CachedBinding? previous = _bindings[serverId];
    _bindings[serverId] = _CachedBinding(settings: settings, binding: built);
    if (previous != null) await previous.binding.close();
    return built;
  }

  Future<McpServerBinding> _build(McpServerSettings settings) async {
    final Map<String, String> headers = <String, String>{};
    final String? token = await servers.resolveToken(settings.id);
    if (token != null && token.isNotEmpty) {
      headers[kMcpAuthorizationHeader] = 'Bearer $token';
    }
    final McpTransport transport = transportFactory(settings, headers);
    final McpClient client = McpClient(
      transport: transport,
      defaultTimeout: requestTimeout,
    );
    // The allowlist is the permission and the safety declaration, and the
    // declaration is the user's: a tool is background safe only when the record
    // says the user vouched for it. The record holds names, not descriptions, so
    // the classifier falls back to the name and to the server's own annotations
    // — both the fail-closed direction, not the optimistic one.
    final MCPServerConfig config = MCPServerConfig(
      serverUri: settings.endpoint,
      exposedTools: <MCPToolDef>[
        for (final String tool in settings.allowedTools)
          MCPToolDef(
            name: tool,
            description: '',
            backgroundSafe: settings.vouchesForBackground(tool),
          ),
      ],
      client: client,
      transportKind: settings.transportKind,
    );
    return McpServerBinding(
      settings: settings,
      adapter: MCPAdapter.forConfig(config),
    );
  }

  /// Calls [toolName] on the configured server [serverId], through the policy
  /// gate.
  ///
  /// The order is deliberate and is the safety invariant of this file:
  /// allowlist, then classification, then the PolicyEngine verdict, then the
  /// user/biometric facts, and only then the wire. Every failure before the last
  /// step is a [McpToolRefused] and nothing has been sent.
  Future<McpToolOutcome> callTool(
    String serverId,
    String toolName,
    Map<String, dynamic> arguments, {
    McpConfirmation confirmation = const McpConfirmation.none(),
    McpCancellationToken? cancellation,
    Duration? timeout,
  }) async {
    final McpServerSettings? settings = await servers.find(serverId);
    if (settings == null) {
      return McpToolRefused(
        code: kMcpServerNotConfigured,
        reason: 'No MCP server is configured under "$serverId".',
        serverId: serverId,
        toolName: toolName,
      );
    }
    // Building the connection can fail (an unreachable endpoint, a refused
    // process start). That is a failed call, not a crash out of a screen.
    final McpServerBinding? bound;
    try {
      bound = await binding(serverId);
    } on McpException catch (error) {
      return McpToolFailed(
        code: error.code,
        message: error.message,
        serverId: serverId,
        toolName: toolName,
      );
    } on Object catch (error) {
      return McpToolFailed(
        code: kMcpConnectionUnavailable,
        message: mcpScrubExcerpt('$error', max: 120),
        serverId: serverId,
        toolName: toolName,
      );
    }
    if (bound == null) {
      return const McpToolRefused(
        code: kMcpServerNotConfigured,
        reason: 'The MCP server configuration could not be read.',
        serverId: '',
        toolName: '',
      );
    }
    if (!bound.isAllowed(toolName)) {
      return McpToolRefused(
        code: kMcpToolNotExposed,
        reason:
            '"$toolName" is not on the allowlist for ${settings.displayName}.',
        serverId: serverId,
        toolName: toolName,
      );
    }

    final McpToolSafety safety = bound.safetyFor(toolName);
    bool gateApproved = false;
    if (safety.requiresGate) {
      final GateResult verdict = policy.gate(<String, dynamic>{
        'action': mcpPolicyAction(serverId, toolName),
        'server': serverId,
        'serverUri': settings.endpoint,
        'tool': toolName,
        'riskLevel': safety.suggestedRiskLevel,
      }, riskLevel: safety.suggestedRiskLevel);

      if (!verdict.allowed) {
        return McpToolRefused(
          code: kMcpPolicyBlocked,
          reason: 'PolicyEngine ${verdict.message}',
          serverId: serverId,
          toolName: toolName,
          safety: safety,
        );
      }
      if (verdict.needsConfirmation && !confirmation.userConfirmed) {
        return McpToolRefused(
          code: kMcpConfirmationRequired,
          reason:
              '${safety.tier.name} tool ${settings.displayName}/$toolName needs '
              'confirmation: ${verdict.message}',
          serverId: serverId,
          toolName: toolName,
          safety: safety,
          needsBiometric: verdict.needsBiometric,
        );
      }
      if (verdict.needsBiometric && !confirmation.biometricSatisfied) {
        return McpToolRefused(
          code: kMcpBiometricRequired,
          reason:
              '${safety.tier.name} tool ${settings.displayName}/$toolName '
              'needs a biometric check. This build has no biometric binding, '
              'so the call is not made.',
          serverId: serverId,
          toolName: toolName,
          safety: safety,
          needsBiometric: true,
        );
      }
      // The only place `gateApproved` becomes true: after a real verdict, a real
      // confirmation and, where required, a real biometric result.
      gateApproved = true;
    }

    try {
      // The handshake happens here, after the gate: a refused call has sent
      // nothing at all, and a permitted one does not depend on somebody having
      // pressed "connect" first. [MCPAdapter.initialize] is idempotent.
      await bound.adapter.initialize();
      final McpUntrustedToolResult result = await bound.adapter.callTool(
        toolName,
        arguments,
        gateApproved: gateApproved,
        cancellation: cancellation,
        timeout: timeout,
      );
      return McpToolCompleted(result);
    } on McpException catch (error) {
      return McpToolFailed(
        code: error.code,
        message: error.message,
        serverId: serverId,
        toolName: toolName,
      );
    } on Object catch (error) {
      return McpToolFailed(
        code: kMcpConnectionUnavailable,
        message: mcpScrubExcerpt('$error', max: 120),
        serverId: serverId,
        toolName: toolName,
      );
    }
  }

  /// Closes the connection for [serverId] and forgets it, so a removed or edited
  /// server cannot keep talking on a session nothing is watching any more.
  Future<void> forget(String serverId) async {
    final _CachedBinding? cached = _bindings.remove(serverId);
    if (cached != null) {
      await cached.binding.close();
    }
  }

  /// Closes every open connection. The app owns the composition, so this is what
  /// a teardown path calls.
  Future<void> closeAll() async {
    final List<_CachedBinding> open = _bindings.values.toList();
    _bindings.clear();
    for (final _CachedBinding cached in open) {
      await cached.binding.close();
    }
  }
}

/// A built binding plus the record it was built from, so staleness is decided by
/// comparing the two rather than by hoping nothing changed.
class _CachedBinding {
  _CachedBinding({required this.settings, required this.binding});

  final McpServerSettings settings;
  final McpServerBinding binding;

  bool isStaleFor(McpServerSettings current) =>
      !current.updatedAt.isAtSameMomentAs(settings.updatedAt) ||
      current.endpoint != settings.endpoint ||
      current.transportKind != settings.transportKind ||
      !_sameList(current.allowedTools, settings.allowedTools) ||
      !_sameList(current.backgroundSafeTools, settings.backgroundSafeTools);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// What the composition root managed to build for MCP.
///
/// The app injects one of these into the Safety Center. A build that could not
/// open its data layer says why on screen instead of pretending MCP is merely
/// unconfigured.
sealed class McpWiring {
  const McpWiring();
}

/// The data layer opened; MCP is wired to persisted configuration.
final class McpWired extends McpWiring {
  const McpWired(this.composition);

  final McpComposition composition;
}

/// The configuration store could not be opened, so no MCP server is configured.
final class McpWiringFailed extends McpWiring {
  const McpWiringFailed(this.reason);

  final String reason;
}
