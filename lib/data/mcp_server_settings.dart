// lib/data/mcp_server_settings.dart — one MCP server the user configured, as
// persisted data (R2/B2).
//
// This record exists because an MCPAdapter is only allowed to exist for a server
// the user actually named. There is no default server, no bundled demo endpoint
// and no "example" host: if this collection is empty the app has no MCP
// capability at all, and says so on screen.
//
// Two boundaries are enforced here rather than remembered at the call site:
//
//   * The allowlist is part of the record. [allowedTools] is what Noir may call,
//     and a server with an empty allowlist can never do anything, so it is
//     refused at write time rather than saved as a dead record.
//   * The operator's safety declaration is part of the record too.
//     [backgroundSafeTools] is the set of tools the user vouches for as
//     read-only, and it is the only way a tool can run with no gate. The
//     classifier still wins over it where a fact says otherwise: a tool the
//     server annotates as destructive, or whose name says it mutates, stays
//     gated whatever the user wrote here.
//   * The auth token is a *reference*, never a value, exactly like a provider's
//     API key. [toJson] persists the reference, [toRedactedJson] replaces it with
//     a placeholder, and [secretValue] exists only to be null so a caller cannot
//     be tempted to reach for a field that holds plaintext.
import 'codecs.dart';
import 'collections.dart';
import 'data_errors.dart';
import 'records.dart';
import 'secrets.dart';

/// The suffix that makes an MCP server's token reference predictable.
const String mcpServerSecretSuffix = '-mcp-token';

/// The reference an MCP server's bearer token is stored under.
String mcpServerSecretRef(String serverId) => '$serverId$mcpServerSecretSuffix';

/// The transport kinds a record may name. Anything else is a typo, not a new
/// transport: refusing it keeps the record from describing a connection Noir
/// cannot make.
const Set<String> kMcpTransportKinds = <String>{'http', 'stdio'};

/// Tool names as MCP servers spell them in practice (letters, digits, `_`, `-`,
/// `.`, `:`). The bound is a storage bound, not a protocol one: the name goes
/// into a JSON record and a log line, and an unbounded string in either is a
/// problem somebody else has to solve later.
final RegExp mcpToolNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$');

/// The longest stdio executable path a record will hold.
const int maxMcpCommandLength = 200;

class McpServerSettings extends DataRecord {
  McpServerSettings({
    required super.id,
    required this.displayName,
    required this.endpoint,
    required this.transportKind,
    required List<String> allowedTools,
    required List<String> backgroundSafeTools,
    required super.createdAt,
    required super.updatedAt,
    this.secretRef,
    this.secretUpdatedAt,
  }) : allowedTools = List<String>.unmodifiable(allowedTools),
       backgroundSafeTools = List<String>.unmodifiable(backgroundSafeTools) {
    validate();
  }

  /// The label shown in the Safety Center and written into safety log lines.
  final String displayName;

  /// Where the server lives: an `http(s)` URL, or the executable of a stdio
  /// server. Never inferred, never defaulted.
  final String endpoint;

  /// `http` or `stdio`.
  final String transportKind;

  /// The allowlist. A tool that is not in this list can never be called, and a
  /// tool here is still classified per tool before it runs.
  final List<String> allowedTools;

  /// The tools the user vouches for as read-only. A subset of [allowedTools];
  /// anything not named here is gated until the user confirms.
  final List<String> backgroundSafeTools;

  /// The secret store reference for this server's bearer token. Never a value.
  final String? secretRef;
  final DateTime? secretUpdatedAt;

  bool get hasSecret => secretRef != null && secretRef!.isNotEmpty;

  /// Present so callers cannot be tempted to reach for a field that holds
  /// plaintext. Reading a token means asking the repository for it by reference.
  String? get secretValue => null;

  /// Whether the user declared [toolName] background safe.
  bool vouchesForBackground(String toolName) =>
      backgroundSafeTools.contains(toolName);

  bool get isStdio => transportKind == 'stdio';

  /// The endpoint as a URL, or null for a stdio server.
  Uri? get httpEndpoint => isStdio ? null : Uri.tryParse(endpoint);

  void validate() {
    if (displayName.trim().isEmpty) {
      throw const InvalidDataError('an MCP server needs a display name');
    }
    if (!kMcpTransportKinds.contains(transportKind)) {
      throw InvalidDataError(
        '"$transportKind" is not an MCP transport kind '
        '(${kMcpTransportKinds.join(', ')})',
      );
    }
    final Uri? parsed = Uri.tryParse(endpoint);
    if (isStdio) {
      // The executable is handed to Process.start as-is, with no argument
      // parsing, so anything that could split it into two programs is refused.
      if (endpoint.trim().isEmpty) {
        throw const InvalidDataError(
          'a stdio MCP server needs an executable to run',
        );
      }
      if (endpoint.length > maxMcpCommandLength) {
        throw InvalidDataError(
          'a stdio executable must be at most $maxMcpCommandLength characters',
        );
      }
      if (RegExp(r'[\x00-\x1f]').hasMatch(endpoint)) {
        throw const InvalidDataError(
          'a stdio executable must not contain control characters',
        );
      }
    } else {
      if (parsed == null ||
          !parsed.hasScheme ||
          (parsed.scheme != 'http' && parsed.scheme != 'https') ||
          parsed.host.isEmpty) {
        throw InvalidDataError('"$endpoint" is not an http(s) MCP endpoint');
      }
    }
    if (allowedTools.isEmpty) {
      // Not a style rule: a server with nothing on the allowlist cannot be
      // called, so storing one would create a record that looks configured and
      // can never act.
      throw const InvalidDataError(
        'an MCP server needs at least one allowed tool',
      );
    }
    final Set<String> seen = <String>{};
    for (final String tool in allowedTools) {
      if (!mcpToolNamePattern.hasMatch(tool)) {
        throw InvalidDataError('"$tool" is not a usable MCP tool name');
      }
      if (!seen.add(tool)) {
        throw InvalidDataError('"$tool" is listed twice on the allowlist');
      }
    }
    final Set<String> declared = <String>{};
    for (final String tool in backgroundSafeTools) {
      if (!seen.contains(tool)) {
        // A declaration about a tool the allowlist does not name describes
        // something the app would never call.
        throw InvalidDataError(
          '"$tool" is declared background safe but is not on the allowlist',
        );
      }
      if (!declared.add(tool)) {
        throw InvalidDataError('"$tool" is declared background safe twice');
      }
    }
    if (secretRef != null && secretRef!.isNotEmpty) {
      checkedSecretRef(secretRef!);
    }
  }

  /// Whether [value] can be used as an http MCP endpoint.
  static bool isValidHttpEndpoint(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  McpServerSettings copyWith({
    String? displayName,
    String? endpoint,
    String? transportKind,
    List<String>? allowedTools,
    List<String>? backgroundSafeTools,
    DateTime? updatedAt,
    String? secretRef,
    bool clearSecretRef = false,
    DateTime? secretUpdatedAt,
    bool clearSecretUpdatedAt = false,
  }) {
    return McpServerSettings(
      id: id,
      displayName: displayName ?? this.displayName,
      endpoint: endpoint ?? this.endpoint,
      transportKind: transportKind ?? this.transportKind,
      allowedTools: allowedTools ?? this.allowedTools,
      backgroundSafeTools: backgroundSafeTools ?? this.backgroundSafeTools,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      secretRef: clearSecretRef ? null : (secretRef ?? this.secretRef),
      secretUpdatedAt: clearSecretUpdatedAt
          ? null
          : (secretUpdatedAt ?? this.secretUpdatedAt),
    );
  }

  /// The persisted form. Contains a reference, never a value.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'displayName': displayName,
      'endpoint': endpoint,
      'transportKind': transportKind,
      'allowedTools': List<String>.of(allowedTools),
      'backgroundSafeTools': List<String>.of(backgroundSafeTools),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
    if (hasSecret) {
      json['secretRef'] = secretRef;
      if (secretUpdatedAt != null) {
        json['secretUpdatedAt'] = secretUpdatedAt!.toUtc().toIso8601String();
      }
    }
    return json;
  }

  /// The redacted form: everything except the reference, plus presence. Safe for
  /// an export, a bug report or a screen.
  Map<String, Object?> toRedactedJson() {
    final json = toJson();
    if (json.containsKey('secretRef')) {
      json['secretRef'] = redactedSecretPlaceholder;
    }
    json['secretConfigured'] = hasSecret;
    return json;
  }

  @override
  String toString() =>
      'McpServerSettings($id, "$displayName", $transportKind, '
      'tools: ${allowedTools.length} '
      '(${backgroundSafeTools.length} declared read-only), '
      '${describeSecret(secretRef ?? '-', present: hasSecret)})';
}

/// Reads and writes [McpServerSettings] records.
class McpServerSettingsCodec extends RecordCodec<McpServerSettings> {
  const McpServerSettingsCodec();

  @override
  Map<String, Object?> encode(McpServerSettings record) => record.toJson();

  @override
  McpServerSettings decode(String id, Map<String, Object?> json) {
    const collection = NoirCollections.mcpServers;
    final displayName = requireString(json, 'displayName', collection, id);
    final endpoint = requireString(json, 'endpoint', collection, id);
    final transportKind = requireString(json, 'transportKind', collection, id);
    final allowedTools = requireStringList(
      json,
      'allowedTools',
      collection,
      id,
    );
    final backgroundSafeTools = requireStringList(
      json,
      'backgroundSafeTools',
      collection,
      id,
    );
    final createdAt = requireTimestamp(json, 'createdAt', collection, id);
    final updatedAt = requireTimestamp(json, 'updatedAt', collection, id);
    final secretRef = optionalString(json, 'secretRef');
    final secretUpdatedAt = json.containsKey('secretUpdatedAt')
        ? requireTimestamp(json, 'secretUpdatedAt', collection, id)
        : null;

    try {
      return McpServerSettings(
        id: id,
        displayName: displayName,
        endpoint: endpoint,
        transportKind: transportKind,
        allowedTools: allowedTools,
        backgroundSafeTools: backgroundSafeTools,
        createdAt: createdAt,
        updatedAt: updatedAt,
        secretRef: secretRef,
        secretUpdatedAt: secretUpdatedAt,
      );
    } on InvalidDataError catch (error) {
      throw MalformedRecordError(
        collection: collection,
        id: id,
        field: 'value',
        detail: error.message,
        cause: error,
      );
    }
  }
}
