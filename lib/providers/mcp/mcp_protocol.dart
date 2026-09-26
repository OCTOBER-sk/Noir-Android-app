// lib/providers/mcp/mcp_protocol.dart — JSON-RPC 2.0 + MCP wire contract.
//
// This is the only file that knows what an MCP frame looks like. Everything
// above it (transports, client, adapter) works with [McpMessage] and the typed
// spec objects, and everything below it works with raw strings and bytes.
//
// Design rules, in the spirit of the rest of Noir (see
// lib/platform/native_bridge.dart):
//
//   * Fail closed. A frame that cannot be understood is a TYPED exception, not
//     a null, not an empty list and definitely not a fabricated success value.
//   * Untrusted text stays untrusted. [mcpScrubExcerpt] is the ONLY sanctioned
//     way to put server bytes into an exception message, a log line or a
//     Safety Center row, so a hostile server cannot inject fake log entries or
//     fake gate verdicts through a control character.
//   * MCP results are objects. JSON-RPC 2.0 allows any JSON value as a result,
//     but the MCP schema does not, so a scalar result is treated as malformed
//     rather than coerced.
import 'dart:convert';

// ---------------------------------------------------------------------------
// Versions and methods
// ---------------------------------------------------------------------------

/// The MCP revision this client speaks by default.
const String mcpProtocolVersion = '2025-06-18';

/// Revisions this client can talk. An initialize reply outside this set means
/// the peer and Noir disagree about the contract, so the session is refused
/// instead of being "best effort" compatible.
const Set<String> mcpSupportedProtocolVersions = <String>{
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
};

const String kMcpMethodInitialize = 'initialize';
const String kMcpMethodInitialized = 'notifications/initialized';
const String kMcpMethodPing = 'ping';
const String kMcpMethodToolsList = 'tools/list';
const String kMcpMethodToolsCall = 'tools/call';
const String kMcpMethodResourcesList = 'resources/list';
const String kMcpMethodResourcesRead = 'resources/read';
const String kMcpMethodResourcesSubscribe = 'resources/subscribe';
const String kMcpMethodPromptsList = 'prompts/list';
const String kMcpMethodPromptsGet = 'prompts/get';
const String kMcpMethodCancelled = 'notifications/cancelled';
const String kMcpMethodToolsListChanged = 'notifications/tools/list_changed';

/// JSON-RPC error codes Noir itself emits.
const int kRpcMethodNotFound = -32601;
const int kRpcInvalidParams = -32602;

// ---------------------------------------------------------------------------
// Failure codes. Wire-stable identifiers: the Safety Center and the logs print
// these verbatim, so they never change meaning between releases.
// ---------------------------------------------------------------------------

const String kMcpMalformedJson = 'MCP_MALFORMED_JSON';
const String kMcpMalformedEnvelope = 'MCP_MALFORMED_ENVELOPE';
const String kMcpBadJsonRpcVersion = 'MCP_BAD_JSONRPC_VERSION';
const String kMcpMalformedParams = 'MCP_MALFORMED_PARAMS';
const String kMcpMalformedError = 'MCP_MALFORMED_ERROR';
const String kMcpMalformedResult = 'MCP_MALFORMED_RESULT';
const String kMcpMissingResultOrError = 'MCP_MISSING_RESULT_OR_ERROR';
const String kMcpBothResultAndError = 'MCP_BOTH_RESULT_AND_ERROR';
const String kMcpUnknownResponseId = 'MCP_UNKNOWN_RESPONSE_ID';
const String kMcpLateResponse = 'MCP_LATE_RESPONSE';
const String kMcpDuplicateResponse = 'MCP_DUPLICATE_RESPONSE';
const String kMcpInvalidArguments = 'MCP_INVALID_ARGUMENTS';
const String kMcpFrameTooLarge = 'MCP_FRAME_TOO_LARGE';
const String kMcpRemoteError = 'MCP_REMOTE_ERROR';
const String kMcpTimeout = 'MCP_TIMEOUT';
const String kMcpCancelled = 'MCP_CANCELLED';
const String kMcpTransportClosed = 'MCP_TRANSPORT_CLOSED';
const String kMcpTransportFailure = 'MCP_TRANSPORT_FAILURE';
const String kMcpHttpStatus = 'MCP_HTTP_STATUS';
const String kMcpProcessStartFailed = 'MCP_PROCESS_START_FAILED';
const String kMcpNotInitialized = 'MCP_NOT_INITIALIZED';
const String kMcpAlreadyInitialized = 'MCP_ALREADY_INITIALIZED';
const String kMcpClientClosed = 'MCP_CLIENT_CLOSED';
const String kMcpUnsupportedProtocolVersion =
    'MCP_UNSUPPORTED_PROTOCOL_VERSION';
const String kMcpCapabilityUnsupported = 'MCP_CAPABILITY_UNSUPPORTED';
const String kMcpPaginationLimit = 'MCP_PAGINATION_LIMIT';
const String kMcpToolNotExposed = 'MCP_TOOL_NOT_EXPOSED';
const String kMcpGateRequired = 'MCP_GATE_REQUIRED';

/// Why a request stopped. [McpCancelledException.reason] and the
/// `notifications/cancelled` params both carry one of these.
const String kMcpCancelReasonTimeout = 'timeout';
const String kMcpCancelReasonClient = 'client';

/// What sort of failure it was, for callers that branch on a category rather
/// than a code.
enum McpFailureKind {
  transport,
  framing,
  malformed,
  protocol,
  remote,
  timeout,
  cancelled,
  lifecycle,
  capability,
  policy,
}

/// Base of every failure the MCP runtime can raise.
///
/// [message] is always Noir's own text or a scrubbed excerpt. It must never
/// contain raw server bytes.
class McpException implements Exception {
  const McpException(
    this.code,
    this.message, {
    this.kind = McpFailureKind.protocol,
  });

  final String code;
  final String message;
  final McpFailureKind kind;

  @override
  String toString() => 'McpException($code): $message';
}

/// The connection itself failed: closed, unreachable, or a bad HTTP status.
class McpTransportException extends McpException {
  const McpTransportException(super.code, super.message, {this.statusCode})
    : super(kind: McpFailureKind.transport);

  /// HTTP status, when the failure came from an HTTP transport.
  final int? statusCode;
}

/// A frame could not be framed: too large, or the byte stream lied.
class McpFramingException extends McpException {
  const McpFramingException(super.code, super.message)
    : super(kind: McpFailureKind.framing);
}

/// A frame decoded, but it is not a legal JSON-RPC 2.0 / MCP envelope, or a
/// result is missing a field its method requires.
class McpMalformedMessageException extends McpException {
  const McpMalformedMessageException(super.code, super.message)
    : super(kind: McpFailureKind.malformed);
}

/// The server answered with a JSON-RPC `error` member. [remoteCode] is the
/// server's own code and [remoteData] its optional payload, both already
/// scrubbed.
class McpRemoteErrorException extends McpException {
  McpRemoteErrorException(
    String message, {
    required this.remoteCode,
    Map<String, dynamic>? data,
  }) : remoteData = data ?? const <String, dynamic>{},
       super(kMcpRemoteError, message, kind: McpFailureKind.remote);

  final int remoteCode;
  final Map<String, dynamic> remoteData;
}

/// No reply inside the deadline. The pending entry is dropped and
/// `notifications/cancelled` is sent, so a late reply is reported instead of
/// being applied to whatever request happens to be running next.
class McpTimeoutException extends McpException {
  const McpTimeoutException(String message)
    : super(kMcpTimeout, message, kind: McpFailureKind.timeout);
}

/// The caller cancelled, or the client was torn down.
class McpCancelledException extends McpException {
  McpCancelledException(String message, {this.reason})
    : super(kMcpCancelled, message, kind: McpFailureKind.cancelled);

  final String? reason;
}

/// Session lifecycle: not initialized, already initialized, closed, or a
/// server that will not stop paginating.
class McpLifecycleException extends McpException {
  const McpLifecycleException(super.code, super.message)
    : super(kind: McpFailureKind.lifecycle);
}

/// The server never declared the capability this method belongs to.
class McpCapabilityException extends McpException {
  const McpCapabilityException(String message)
    : super(
        kMcpCapabilityUnsupported,
        message,
        kind: McpFailureKind.capability,
      );
}

/// Noir's own gate refused the call: not on the allowlist, or the tool needs a
/// confirmation/biometric verdict that has not been given.
class McpPolicyException extends McpException {
  const McpPolicyException(super.code, super.message)
    : super(kind: McpFailureKind.policy);
}

// ---------------------------------------------------------------------------
// Scrubbing
// ---------------------------------------------------------------------------

final RegExp _ansiPattern = RegExp('\u001B\\[[0-9;?]*[ -/]*[@-~]');
final RegExp _controlPattern = RegExp(
  '[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]',
);

/// Strips ANSI escapes and control characters from untrusted bytes and clips
/// the result to [max] characters, appending an ellipsis when it had to cut.
///
/// The output is safe to log: it is one line, it cannot move a cursor, and it
/// cannot fake a Safety Center table row.
String mcpScrubExcerpt(String raw, {int max = 120}) {
  final String scrubbed = raw
      .replaceAll(_ansiPattern, '')
      .replaceAll(_controlPattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (max <= 0 || scrubbed.length <= max) return scrubbed;
  return '${scrubbed.substring(0, max)}…';
}

// ---------------------------------------------------------------------------
// Envelopes
// ---------------------------------------------------------------------------

/// A decoded JSON-RPC 2.0 envelope. Exactly one of [method] (request or
/// notification) and [result]/[error] (response) is present.
class McpMessage {
  const McpMessage({
    this.rawId,
    this.method,
    this.params,
    this.result,
    this.error,
  });

  final Object? rawId;
  final String? method;
  final Map<String, dynamic>? params;
  final Map<String, dynamic>? result;
  final McpRemoteErrorException? error;

  /// Correlation id in string form. Noir always sends string ids, and string
  /// comparison is what keeps a server that echoes `1` from ever matching
  /// `mcp-1`.
  String? get id => rawId == null ? null : '$rawId';

  bool get isRequest => method != null && rawId != null;
  bool get isNotification => method != null && rawId == null;
  bool get isResponse => method == null && (result != null || error != null);

  /// The frame to put on the wire.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'jsonrpc': '2.0',
    if (rawId != null) 'id': rawId,
    if (method != null) 'method': method,
    if (params != null) 'params': params,
    if (result != null) 'result': result,
    if (error != null)
      'error': <String, dynamic>{
        'code': error!.remoteCode,
        'message': error!.message,
        if (error!.remoteData.isNotEmpty) 'data': error!.remoteData,
      },
  };

  /// Decodes a raw frame. Throws [McpMalformedMessageException] — with a
  /// specific code — for anything that is not a legal envelope.
  static McpMessage decode(String frame) {
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } on FormatException catch (error) {
      throw McpMalformedMessageException(
        kMcpMalformedJson,
        'MCP frame is not valid JSON: ${mcpScrubExcerpt(error.message, max: 60)}',
      );
    }
    return fromJson(decoded);
  }

  static McpMessage fromJson(Object? decoded) {
    if (decoded is! Map) {
      throw const McpMalformedMessageException(
        kMcpMalformedEnvelope,
        'MCP frame is not a JSON object',
      );
    }
    final version = decoded['jsonrpc'];
    if (version != '2.0') {
      throw const McpMalformedMessageException(
        kMcpBadJsonRpcVersion,
        'MCP frame does not declare jsonrpc 2.0',
      );
    }

    final Object? rawId = decoded['id'];
    if (rawId != null && rawId is! String && rawId is! int) {
      throw const McpMalformedMessageException(
        kMcpMalformedEnvelope,
        'MCP frame id must be a string or an integer',
      );
    }

    final Object? rawMethod = decoded['method'];
    final Object? rawParams = decoded['params'];
    final bool hasResult = decoded.containsKey('result');
    final bool hasError = decoded.containsKey('error');

    if (rawMethod != null) {
      if (rawMethod is! String || rawMethod.isEmpty) {
        throw const McpMalformedMessageException(
          kMcpMalformedEnvelope,
          'MCP frame method must be a non-empty string',
        );
      }
      if (rawParams != null) {
        if (rawParams is! Map) {
          throw const McpMalformedMessageException(
            kMcpMalformedParams,
            'MCP frame params must be an object',
          );
        }
        if (hasResult || hasError) {
          throw const McpMalformedMessageException(
            kMcpMalformedEnvelope,
            'MCP frame carries both a method and a result',
          );
        }
      }
      return McpMessage(
        rawId: rawId,
        method: rawMethod,
        params: rawParams == null
            ? null
            : _asMap(rawParams, kMcpMalformedParams),
      );
    }

    if (hasResult && hasError) {
      throw const McpMalformedMessageException(
        kMcpBothResultAndError,
        'MCP reply carries both a result and an error',
      );
    }
    if (!hasResult && !hasError) {
      throw const McpMalformedMessageException(
        kMcpMissingResultOrError,
        'MCP reply carries neither a result nor an error',
      );
    }
    if (hasResult) {
      final Object? rawResult = decoded['result'];
      if (rawResult is! Map) {
        throw const McpMalformedMessageException(
          kMcpMalformedResult,
          'MCP result must be an object',
        );
      }
      return McpMessage(
        rawId: rawId,
        result: _asMap(rawResult, kMcpMalformedResult),
      );
    }
    return McpMessage(rawId: rawId, error: _remoteError(decoded['error']));
  }

  static McpRemoteErrorException _remoteError(Object? raw) {
    if (raw is! Map) {
      throw const McpMalformedMessageException(
        kMcpMalformedError,
        'MCP error member must be an object',
      );
    }
    final Object? code = raw['code'];
    final Object? message = raw['message'];
    if (code is! int || message is! String || message.isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedError,
        'MCP error member needs an integer code and a non-empty string message',
      );
    }
    final Object? data = raw['data'];
    return McpRemoteErrorException(
      mcpScrubExcerpt(message, max: 200),
      remoteCode: code,
      data: data is Map ? _asMap(data, kMcpMalformedError) : null,
    );
  }
}

/// Builds a request frame. [id] must be the correlation id the caller will
/// match the reply against.
Map<String, dynamic> buildMcpRequestFrame({
  required String id,
  required String method,
  Map<String, dynamic>? params,
}) => <String, dynamic>{
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  if (params != null) 'params': params,
};

/// Builds a notification frame: a method with no id, never answered.
Map<String, dynamic> buildMcpNotificationFrame({
  required String method,
  Map<String, dynamic>? params,
}) => <String, dynamic>{
  'jsonrpc': '2.0',
  'method': method,
  if (params != null) 'params': params,
};

/// Builds a successful reply to a server-initiated request.
Map<String, dynamic> buildMcpResultFrame({
  required Object id,
  required Map<String, dynamic> result,
}) => <String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result};

/// Builds a reply to a server-initiated request. Noir uses this to refuse
/// server-initiated work with JSON-RPC "method not found".
Map<String, dynamic> buildMcpErrorFrame({
  required Object id,
  required int code,
  required String message,
}) => <String, dynamic>{
  'jsonrpc': '2.0',
  'id': id,
  'error': <String, dynamic>{'code': code, 'message': message},
};

// ---------------------------------------------------------------------------
// MCP result types
// ---------------------------------------------------------------------------

/// One page of a list method, with the cursor for the next one.
class McpPage<T> {
  const McpPage({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;
}

class McpToolSpec {
  const McpToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.annotations,
    this.title,
  });

  final String name;
  final String description;
  final String? title;
  final Map<String, dynamic> inputSchema;
  final Map<String, dynamic> annotations;

  static McpToolSpec fromJson(Map<String, dynamic> json) {
    final Object? name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP tool entry has no usable name',
      );
    }
    return McpToolSpec(
      name: name,
      description: json['description'] is String
          ? json['description']! as String
          : '',
      title: json['title'] is String ? json['title']! as String : null,
      inputSchema: json['inputSchema'] is Map
          ? _asMap(json['inputSchema'], kMcpMalformedResult)
          : const <String, dynamic>{},
      annotations: json['annotations'] is Map
          ? _asMap(json['annotations'], kMcpMalformedResult)
          : const <String, dynamic>{},
    );
  }

  static McpPage<McpToolSpec> pageFrom(Map<String, dynamic> result) =>
      _page<McpToolSpec>(result, 'tools', McpToolSpec.fromJson);
}

class McpContent {
  const McpContent({
    required this.type,
    this.text,
    this.mimeType,
    this.uri,
    this.data,
    this.resource,
  });

  final String type;
  final String? text;
  final String? mimeType;
  final String? uri;
  final String? data;
  final Map<String, dynamic>? resource;

  static McpContent fromJson(Map<String, dynamic> json) {
    final Object? type = json['type'];
    if (type is! String || type.isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP content block has no type',
      );
    }
    return McpContent(
      type: type,
      text: json['text'] is String ? json['text']! as String : null,
      mimeType: json['mimeType'] is String ? json['mimeType']! as String : null,
      uri: json['uri'] is String ? json['uri']! as String : null,
      data: json['data'] is String ? json['data']! as String : null,
      resource: json['resource'] is Map
          ? _asMap(json['resource'], kMcpMalformedResult)
          : null,
    );
  }
}

/// `tools/call` result. Note that a tool reporting failure answers with
/// `isError: true` and a normal result object — it is NOT a JSON-RPC error, and
/// it is still untrusted content.
class McpToolCallOutcome {
  const McpToolCallOutcome({
    required this.content,
    required this.isError,
    this.structuredContent,
  });

  final List<McpContent> content;
  final bool isError;
  final Map<String, dynamic>? structuredContent;

  static McpToolCallOutcome fromResult(Map<String, dynamic> result) {
    final Object? rawContent = result['content'];
    if (rawContent is! List) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP tools/call result has no content array',
      );
    }
    final Object? isError = result['isError'];
    if (isError != null && isError is! bool) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP tools/call isError must be a boolean',
      );
    }
    final List<McpContent> blocks = <McpContent>[];
    for (final Object? entry in rawContent) {
      if (entry is! Map) {
        throw const McpMalformedMessageException(
          kMcpMalformedResult,
          'MCP content block is not an object',
        );
      }
      blocks.add(McpContent.fromJson(_asMap(entry, kMcpMalformedResult)));
    }
    final Object? structured = result['structuredContent'];
    return McpToolCallOutcome(
      content: List<McpContent>.unmodifiable(blocks),
      isError: isError == true,
      structuredContent: structured is Map
          ? _asMap(structured, kMcpMalformedResult)
          : null,
    );
  }
}

class McpResourceSpec {
  const McpResourceSpec({
    required this.uri,
    required this.name,
    this.description,
    this.mimeType,
  });

  final String uri;
  final String name;
  final String? description;
  final String? mimeType;

  static McpResourceSpec fromJson(Map<String, dynamic> json) {
    final Object? uri = json['uri'];
    if (uri is! String || uri.trim().isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP resource entry has no usable uri',
      );
    }
    return McpResourceSpec(
      uri: uri,
      name: json['name'] is String ? json['name']! as String : uri,
      description: json['description'] is String
          ? json['description']! as String
          : null,
      mimeType: json['mimeType'] is String ? json['mimeType']! as String : null,
    );
  }

  static McpPage<McpResourceSpec> pageFrom(Map<String, dynamic> result) =>
      _page<McpResourceSpec>(result, 'resources', McpResourceSpec.fromJson);
}

class McpResourceContent {
  const McpResourceContent({
    required this.uri,
    this.mimeType,
    this.text,
    this.blob,
  });

  final String uri;
  final String? mimeType;
  final String? text;
  final String? blob;

  static McpResourceContent fromJson(Map<String, dynamic> json) {
    final Object? uri = json['uri'];
    if (uri is! String || uri.isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP resource content has no uri',
      );
    }
    return McpResourceContent(
      uri: uri,
      mimeType: json['mimeType'] is String ? json['mimeType']! as String : null,
      text: json['text'] is String ? json['text']! as String : null,
      blob: json['blob'] is String ? json['blob']! as String : null,
    );
  }
}

class McpResourceContents {
  const McpResourceContents({required this.contents});

  final List<McpResourceContent> contents;

  static McpResourceContents fromResult(Map<String, dynamic> result) {
    final Object? raw = result['contents'];
    if (raw is! List) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP resources/read result has no contents array',
      );
    }
    final List<McpResourceContent> entries = <McpResourceContent>[];
    for (final Object? entry in raw) {
      if (entry is! Map) {
        throw const McpMalformedMessageException(
          kMcpMalformedResult,
          'MCP resource content entry is not an object',
        );
      }
      entries.add(
        McpResourceContent.fromJson(_asMap(entry, kMcpMalformedResult)),
      );
    }
    return McpResourceContents(
      contents: List<McpResourceContent>.unmodifiable(entries),
    );
  }
}

class McpPromptArgument {
  const McpPromptArgument({
    required this.name,
    this.description,
    this.required = false,
  });

  final String name;
  final String? description;
  final bool required;

  static McpPromptArgument fromJson(Map<String, dynamic> json) =>
      McpPromptArgument(
        name: json['name'] is String ? json['name']! as String : '',
        description: json['description'] is String
            ? json['description']! as String
            : null,
        required: json['required'] == true,
      );
}

class McpPromptSpec {
  const McpPromptSpec({
    required this.name,
    required this.description,
    required this.arguments,
  });

  final String name;
  final String description;
  final List<McpPromptArgument> arguments;

  static McpPromptSpec fromJson(Map<String, dynamic> json) {
    final Object? name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP prompt entry has no usable name',
      );
    }
    final Object? rawArguments = json['arguments'];
    final List<McpPromptArgument> arguments = <McpPromptArgument>[];
    if (rawArguments is List) {
      for (final Object? entry in rawArguments) {
        if (entry is Map) {
          arguments.add(
            McpPromptArgument.fromJson(_asMap(entry, kMcpMalformedResult)),
          );
        }
      }
    }
    return McpPromptSpec(
      name: name,
      description: json['description'] is String
          ? json['description']! as String
          : '',
      arguments: List<McpPromptArgument>.unmodifiable(arguments),
    );
  }

  static McpPage<McpPromptSpec> pageFrom(Map<String, dynamic> result) =>
      _page<McpPromptSpec>(result, 'prompts', McpPromptSpec.fromJson);
}

class McpPromptMessage {
  const McpPromptMessage({required this.role, required this.content});

  final String role;
  final McpContent content;

  static McpPromptMessage fromJson(Map<String, dynamic> json) {
    final Object? role = json['role'];
    if (role is! String || role.isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP prompt message has no role',
      );
    }
    final Object? content = json['content'];
    if (content is! Map) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP prompt message has no content object',
      );
    }
    return McpPromptMessage(
      role: role,
      content: McpContent.fromJson(_asMap(content, kMcpMalformedResult)),
    );
  }
}

class McpPromptResult {
  const McpPromptResult({required this.description, required this.messages});

  final String? description;
  final List<McpPromptMessage> messages;

  static McpPromptResult fromResult(Map<String, dynamic> result) {
    final Object? raw = result['messages'];
    if (raw is! List) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP prompts/get result has no messages array',
      );
    }
    final List<McpPromptMessage> messages = <McpPromptMessage>[];
    for (final Object? entry in raw) {
      if (entry is! Map) {
        throw const McpMalformedMessageException(
          kMcpMalformedResult,
          'MCP prompt message entry is not an object',
        );
      }
      messages.add(
        McpPromptMessage.fromJson(_asMap(entry, kMcpMalformedResult)),
      );
    }
    return McpPromptResult(
      description: result['description'] is String
          ? result['description']! as String
          : null,
      messages: List<McpPromptMessage>.unmodifiable(messages),
    );
  }
}

class McpServerInfo {
  const McpServerInfo({required this.name, required this.version});

  final String name;
  final String version;

  static McpServerInfo fromJson(Map<String, dynamic> json) {
    final Object? name = json['name'];
    if (name is! String || name.isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP initialize result has no serverInfo.name',
      );
    }
    return McpServerInfo(
      name: name,
      version: json['version'] is String ? json['version']! as String : '',
    );
  }
}

/// What the server says it can do. An absent capability is always `false`:
/// Noir never assumes a primitive exists because a method name is familiar.
class McpServerCapabilities {
  const McpServerCapabilities({
    required this.supportsTools,
    required this.toolsListChanged,
    required this.supportsResources,
    required this.supportsResourceSubscribe,
    required this.resourcesListChanged,
    required this.supportsPrompts,
    required this.promptsListChanged,
    required this.supportsLogging,
    required this.supportsCompletions,
  });

  final bool supportsTools;
  final bool toolsListChanged;
  final bool supportsResources;
  final bool supportsResourceSubscribe;
  final bool resourcesListChanged;
  final bool supportsPrompts;
  final bool promptsListChanged;
  final bool supportsLogging;
  final bool supportsCompletions;

  static const McpServerCapabilities none = McpServerCapabilities(
    supportsTools: false,
    toolsListChanged: false,
    supportsResources: false,
    supportsResourceSubscribe: false,
    resourcesListChanged: false,
    supportsPrompts: false,
    promptsListChanged: false,
    supportsLogging: false,
    supportsCompletions: false,
  );

  static McpServerCapabilities fromResult(Map<String, dynamic> result) {
    final Object? raw = result['capabilities'];
    if (raw == null) return none;
    if (raw is! Map) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP capabilities must be an object',
      );
    }
    final Map<String, dynamic> capabilities = _asMap(raw, kMcpMalformedResult);
    return McpServerCapabilities(
      supportsTools: capabilities.containsKey('tools'),
      toolsListChanged: _flag(capabilities['tools'], 'listChanged'),
      supportsResources: capabilities.containsKey('resources'),
      supportsResourceSubscribe: _flag(capabilities['resources'], 'subscribe'),
      resourcesListChanged: _flag(capabilities['resources'], 'listChanged'),
      supportsPrompts: capabilities.containsKey('prompts'),
      promptsListChanged: _flag(capabilities['prompts'], 'listChanged'),
      supportsLogging: capabilities.containsKey('logging'),
      supportsCompletions: capabilities.containsKey('completions'),
    );
  }

  /// Whether the server declared the capability [method] belongs to.
  bool supportsMethod(String method) {
    switch (method) {
      case kMcpMethodToolsList:
      case kMcpMethodToolsCall:
        return supportsTools;
      case kMcpMethodResourcesList:
      case kMcpMethodResourcesRead:
        return supportsResources;
      case kMcpMethodResourcesSubscribe:
        return supportsResourceSubscribe;
      case kMcpMethodPromptsList:
      case kMcpMethodPromptsGet:
        return supportsPrompts;
      default:
        return false;
    }
  }

  static bool _flag(Object? capability, String key) {
    if (capability is Map) {
      final Object? value = capability[key];
      return value == true;
    }
    return false;
  }
}

/// The real `initialize` reply.
///
/// [instructions] is what the SERVER wants Noir's model to do. It is
/// attacker-controlled text: read it through
/// `McpUntrustedContent.serverInstructions`, never straight into a prompt.
class McpInitializeResult {
  const McpInitializeResult({
    required this.protocolVersion,
    required this.serverInfo,
    required this.capabilities,
    this.instructions,
  });

  final String protocolVersion;
  final McpServerInfo serverInfo;
  final McpServerCapabilities capabilities;
  final String? instructions;

  static McpInitializeResult fromResult(Map<String, dynamic> result) {
    final Object? version = result['protocolVersion'];
    if (version is! String || version.isEmpty) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP initialize result has no protocolVersion',
      );
    }
    final Object? info = result['serverInfo'];
    if (info is! Map) {
      throw const McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP initialize result has no serverInfo object',
      );
    }
    return McpInitializeResult(
      protocolVersion: version,
      serverInfo: McpServerInfo.fromJson(_asMap(info, kMcpMalformedResult)),
      capabilities: McpServerCapabilities.fromResult(result),
      instructions: result['instructions'] is String
          ? result['instructions']! as String
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared decoding helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _asMap(Object? raw, String code) {
  if (raw is! Map) {
    throw McpMalformedMessageException(code, 'MCP expected a JSON object');
  }
  final Map<String, dynamic> map = <String, dynamic>{};
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    final Object? key = entry.key;
    if (key is String) map[key] = entry.value;
  }
  return map;
}

McpPage<T> _page<T>(
  Map<String, dynamic> result,
  String field,
  T Function(Map<String, dynamic>) decode,
) {
  final Object? raw = result[field];
  if (raw is! List) {
    throw McpMalformedMessageException(
      kMcpMalformedResult,
      'MCP $field is missing or is not an array',
    );
  }
  final List<T> items = <T>[];
  for (final Object? entry in raw) {
    if (entry is! Map) {
      throw McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP $field entry is not an object',
      );
    }
    items.add(decode(_asMap(entry, kMcpMalformedResult)));
  }
  final Object? cursor = result['nextCursor'];
  return McpPage<T>(
    items: List<T>.unmodifiable(items),
    nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
  );
}
