// lib/providers/mcp/mcp_client.dart — the JSON-RPC 2.0 session.
//
// One [McpClient] is one MCP session over one [McpTransport]. It owns:
//   * the initialize handshake and the capability table that comes out of it;
//   * request correlation (string ids, matched by id, never by arrival order);
//   * a deadline per request, with the pending entry dropped and the server told
//     `notifications/cancelled` when it expires;
//   * caller-side cancellation, including while the request is still queued;
//   * a hard cap on in-flight requests, with the rest queued;
//   * typed failures for everything that is not a well-formed reply.
//
// Two behaviours are load-bearing for safety:
//
//   * A frame that cannot be parsed desynchronises the stream: it can no longer
//     be proven which reply belonged to which request, so every in-flight
//     request fails closed and the reason is published on [protocolErrors].
//   * Server-initiated requests are DENIED by default. Noir declares no
//     sampling/roots capability, so a server that asks anyway is answered with
//     JSON-RPC "method not found" and the attempt is published on
//     [serverRequests] for the Safety Center.
import 'dart:async';
import 'dart:convert';

import 'mcp_protocol.dart';
import 'mcp_transport.dart';

/// Caller-side cancellation for one request.
class McpCancellationToken {
  final List<void Function()> _hooks = <void Function()>[];
  bool _cancelled = false;
  String? _reason;

  bool get isCancelled => _cancelled;
  String? get reason => _reason;

  void cancel([String? why]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = why;
    for (final void Function() hook in List<void Function()>.of(_hooks)) {
      hook();
    }
    _hooks.clear();
  }

  void _add(void Function() hook) {
    if (_cancelled) {
      hook();
      return;
    }
    _hooks.add(hook);
  }

  void _remove(void Function() hook) {
    _hooks.remove(hook);
  }
}

/// A request the SERVER sent to Noir. Never answered with anything but a refusal
/// unless a handler is installed.
class McpServerRequest {
  const McpServerRequest({
    required this.id,
    required this.method,
    required this.params,
  });

  final String id;
  final String method;
  final Map<String, dynamic> params;
}

/// What the server can actually do, plus the catalogue it exposed.
class McpCapabilityDiscovery {
  const McpCapabilityDiscovery({
    required this.initialization,
    required this.capabilities,
    required this.tools,
    required this.resources,
    required this.prompts,
  });

  final McpInitializeResult initialization;
  final McpServerCapabilities capabilities;
  final List<McpToolSpec> tools;
  final List<McpResourceSpec> resources;
  final List<McpPromptSpec> prompts;

  int get toolCount => tools.length;
  int get resourceCount => resources.length;
  int get promptCount => prompts.length;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'server': initialization.serverInfo.name,
    'protocolVersion': initialization.protocolVersion,
    'tools': toolCount,
    'resources': resourceCount,
    'prompts': promptCount,
    'capabilities': <String, dynamic>{
      'tools': capabilities.supportsTools,
      'resources': capabilities.supportsResources,
      'resourceSubscribe': capabilities.supportsResourceSubscribe,
      'prompts': capabilities.supportsPrompts,
      'logging': capabilities.supportsLogging,
    },
  };
}

class McpClient {
  /// [maxConcurrentRequests] bounds how many requests may be on the wire at
  /// once; the rest wait their turn instead of piling onto the server.
  factory McpClient({
    required McpTransport transport,
    Duration defaultTimeout = const Duration(seconds: 20),
    int maxConcurrentRequests = 4,
    String clientName = 'noir-android',
    String clientVersion = '2.3.0',
    String protocolVersion = mcpProtocolVersion,
    String idPrefix = 'mcp',
  }) {
    if (maxConcurrentRequests < 1) {
      throw ArgumentError.value(
        maxConcurrentRequests,
        'maxConcurrentRequests',
        'must be at least 1',
      );
    }
    if (defaultTimeout <= Duration.zero) {
      throw ArgumentError.value(
        defaultTimeout,
        'defaultTimeout',
        'must be greater than zero',
      );
    }
    return McpClient._(
      transport: transport,
      defaultTimeout: defaultTimeout,
      maxConcurrentRequests: maxConcurrentRequests,
      clientName: clientName,
      clientVersion: clientVersion,
      protocolVersion: protocolVersion,
      idPrefix: idPrefix,
    );
  }

  McpClient._({
    required this.transport,
    required this.defaultTimeout,
    required this.maxConcurrentRequests,
    required this.clientName,
    required this.clientVersion,
    required this.protocolVersion,
    required this.idPrefix,
  }) {
    _frameSubscription = transport.frames.listen(
      _onFrame,
      onError: _onTransportError,
      onDone: _onTransportClosed,
    );
  }

  final McpTransport transport;
  final Duration defaultTimeout;
  final int maxConcurrentRequests;
  final String clientName;
  final String clientVersion;
  final String protocolVersion;
  final String idPrefix;

  /// Hard cap on pages followed by a `nextCursor` loop. A server that keeps
  /// handing out cursors is refused rather than allowed to spin Noir forever.
  int maxPages = 20;

  /// Typed protocol violations: malformed frames, unknown ids, late replies,
  /// duplicate replies, transport errors. The Safety Center reads this stream.
  final StreamController<McpException> _protocolErrors =
      StreamController<McpException>.broadcast();

  /// Requests the server tried to make Noir perform. Denied by default.
  final StreamController<McpServerRequest> _serverRequests =
      StreamController<McpServerRequest>.broadcast();

  /// Notifications the server sent, e.g. `tools/list_changed`.
  final StreamController<McpMessage> _serverNotifications =
      StreamController<McpMessage>.broadcast();

  final Map<String, _PendingRequest> _pending = <String, _PendingRequest>{};
  final List<_PendingRequest> _waiters = <_PendingRequest>[];
  final Set<String> _settledIds = <String>{};
  final List<String> _settledOrder = <String>[];
  final Set<String> _abandonedIds = <String>{};
  final List<String> _abandonedOrder = <String>[];

  late final StreamSubscription<String> _frameSubscription;
  McpInitializeResult? _initialization;
  int _inFlight = 0;
  int _maxObservedConcurrency = 0;
  int _idCounter = 0;
  bool _closed = false;

  Stream<McpException> get protocolErrors => _protocolErrors.stream;
  Stream<McpServerRequest> get serverRequests => _serverRequests.stream;
  Stream<McpMessage> get serverNotifications => _serverNotifications.stream;

  bool get isInitialized => _initialization != null;
  bool get isClosed => _closed;
  McpInitializeResult? get initialization => _initialization;
  McpServerCapabilities? get capabilities => _initialization?.capabilities;

  /// Requests sent and not yet settled (sent, timed out or cancelled).
  int get pendingCount => _pending.length;

  /// Requests currently on the wire.
  int get inFlightCount => _inFlight;

  /// Requests waiting for a concurrency slot.
  int get queuedCount => _waiters.length;

  /// High-water mark of [inFlightCount]. Exposed so the bound is observable
  /// rather than merely documented.
  int get maxObservedConcurrency => _maxObservedConcurrency;

  // -------------------------------------------------------------------------
  // MCP methods
  // -------------------------------------------------------------------------

  /// The real MCP handshake. The capabilities Noir declares are deliberately
  /// empty: it will not sample on a server's behalf and it will not serve roots.
  Future<McpInitializeResult> initialize({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    _requireOpen();
    if (_initialization != null) {
      throw const McpLifecycleException(
        kMcpAlreadyInitialized,
        'MCP session is already initialized',
      );
    }
    final Map<String, dynamic> result = await _requestResult(
      kMcpMethodInitialize,
      params: <String, dynamic>{
        'protocolVersion': protocolVersion,
        'capabilities': const <String, dynamic>{},
        'clientInfo': <String, dynamic>{
          'name': clientName,
          'version': clientVersion,
        },
      },
      timeout: timeout,
      cancellation: cancellation,
    );
    final McpInitializeResult initialization = McpInitializeResult.fromResult(
      result,
    );
    if (!mcpSupportedProtocolVersions.contains(
      initialization.protocolVersion,
    )) {
      throw McpLifecycleException(
        kMcpUnsupportedProtocolVersion,
        'MCP server speaks ${initialization.protocolVersion}; this client speaks '
        '${mcpSupportedProtocolVersions.join(', ')}',
      );
    }
    _initialization = initialization;
    await notify(kMcpMethodInitialized);
    return initialization;
  }

  /// One page of the server's tool catalogue.
  Future<McpPage<McpToolSpec>> listToolsPage({
    String? cursor,
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    _requireReady(kMcpMethodToolsList);
    final Map<String, dynamic> result = await _requestResult(
      kMcpMethodToolsList,
      params: _cursorParams(cursor),
      timeout: timeout,
      cancellation: cancellation,
    );
    return McpToolSpec.pageFrom(result);
  }

  /// Every tool the server exposes, following cursors up to [maxPages].
  Future<List<McpToolSpec>> listTools({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    return _followCursors<McpToolSpec>(
      (String? cursor) => listToolsPage(
        cursor: cursor,
        timeout: timeout,
        cancellation: cancellation,
      ),
      kMcpMethodToolsList,
    );
  }

  /// `tools/call`. A tool reporting failure comes back as a result with
  /// `isError: true`, not as a JSON-RPC error, and its content is still
  /// untrusted.
  Future<McpToolCallOutcome> callTool(
    String name,
    Map<String, dynamic> arguments, {
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    if (name.trim().isEmpty) {
      throw const McpMalformedMessageException(
        kMcpInvalidArguments,
        'MCP tool name must not be empty',
      );
    }
    _requireReady(kMcpMethodToolsCall);
    final Map<String, dynamic> result = await _requestResult(
      kMcpMethodToolsCall,
      params: <String, dynamic>{'name': name, 'arguments': arguments},
      timeout: timeout,
      cancellation: cancellation,
    );
    return McpToolCallOutcome.fromResult(result);
  }

  Future<McpPage<McpResourceSpec>> listResourcesPage({
    String? cursor,
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    _requireReady(kMcpMethodResourcesList);
    final Map<String, dynamic> result = await _requestResult(
      kMcpMethodResourcesList,
      params: _cursorParams(cursor),
      timeout: timeout,
      cancellation: cancellation,
    );
    return McpResourceSpec.pageFrom(result);
  }

  Future<List<McpResourceSpec>> listResources({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    return _followCursors<McpResourceSpec>(
      (String? cursor) => listResourcesPage(
        cursor: cursor,
        timeout: timeout,
        cancellation: cancellation,
      ),
      kMcpMethodResourcesList,
    );
  }

  Future<McpResourceContents> readResource(
    String uri, {
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    if (uri.trim().isEmpty) {
      throw const McpMalformedMessageException(
        kMcpInvalidArguments,
        'MCP resource uri must not be empty',
      );
    }
    _requireReady(kMcpMethodResourcesRead);
    final Map<String, dynamic> result = await _requestResult(
      kMcpMethodResourcesRead,
      params: <String, dynamic>{'uri': uri},
      timeout: timeout,
      cancellation: cancellation,
    );
    return McpResourceContents.fromResult(result);
  }

  Future<McpPage<McpPromptSpec>> listPromptsPage({
    String? cursor,
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    _requireReady(kMcpMethodPromptsList);
    final Map<String, dynamic> result = await _requestResult(
      kMcpMethodPromptsList,
      params: _cursorParams(cursor),
      timeout: timeout,
      cancellation: cancellation,
    );
    return McpPromptSpec.pageFrom(result);
  }

  Future<List<McpPromptSpec>> listPrompts({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    return _followCursors<McpPromptSpec>(
      (String? cursor) => listPromptsPage(
        cursor: cursor,
        timeout: timeout,
        cancellation: cancellation,
      ),
      kMcpMethodPromptsList,
    );
  }

  Future<McpPromptResult> getPrompt(
    String name, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    if (name.trim().isEmpty) {
      throw const McpMalformedMessageException(
        kMcpInvalidArguments,
        'MCP prompt name must not be empty',
      );
    }
    _requireReady(kMcpMethodPromptsGet);
    final Map<String, dynamic> result = await _requestResult(
      kMcpMethodPromptsGet,
      params: <String, dynamic>{'name': name, 'arguments': arguments},
      timeout: timeout,
      cancellation: cancellation,
    );
    return McpPromptResult.fromResult(result);
  }

  /// Everything the server will admit to, gathered from its own replies. A
  /// capability the server never declared is reported as empty, never probed.
  Future<McpCapabilityDiscovery> discover({
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    _requireOpen();
    _requireInitialized();
    final McpServerCapabilities caps = _initialization!.capabilities;
    return McpCapabilityDiscovery(
      initialization: _initialization!,
      capabilities: caps,
      tools: caps.supportsTools
          ? await listTools(timeout: timeout, cancellation: cancellation)
          : const <McpToolSpec>[],
      resources: caps.supportsResources
          ? await listResources(timeout: timeout, cancellation: cancellation)
          : const <McpResourceSpec>[],
      prompts: caps.supportsPrompts
          ? await listPrompts(timeout: timeout, cancellation: cancellation)
          : const <McpPromptSpec>[],
    );
  }

  /// Sends a notification: a method with no id, never answered.
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    _requireOpen();
    await _write(buildMcpNotificationFrame(method: method, params: params));
  }

  /// Drops every in-flight request, then closes the transport.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAllPending(
      const McpLifecycleException(
        kMcpClientClosed,
        'MCP client was closed before the reply arrived',
      ),
    );
    await _frameSubscription.cancel();
    await transport.close();
    if (!_protocolErrors.isClosed) await _protocolErrors.close();
    if (!_serverRequests.isClosed) await _serverRequests.close();
    if (!_serverNotifications.isClosed) await _serverNotifications.close();
  }

  // -------------------------------------------------------------------------
  // Request pipeline
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _requestResult(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    final Object? raw = await _sendRequest(
      method,
      params: params,
      timeout: timeout,
      cancellation: cancellation,
    );
    if (raw is! Map<String, dynamic>) {
      throw McpMalformedMessageException(
        kMcpMalformedResult,
        'MCP $method did not answer with an object result',
      );
    }
    return raw;
  }

  Future<Object?> _sendRequest(
    String method, {
    Map<String, dynamic>? params,
    Duration? timeout,
    McpCancellationToken? cancellation,
  }) async {
    _requireOpen();
    if (cancellation != null && cancellation.isCancelled) {
      throw McpCancelledException(
        'MCP $method was cancelled before it was sent',
        reason: cancellation.reason,
      );
    }

    final Duration deadline = timeout ?? defaultTimeout;
    final String id = '$idPrefix-${_idCounter += 1}';
    final _PendingRequest pending = _PendingRequest(id, method);
    _pending[id] = pending;

    pending.timer = Timer(deadline, () {
      _abandon(
        pending,
        McpTimeoutException(
          'MCP $method (id $id) timed out after ${deadline.inMilliseconds}ms',
        ),
        kMcpCancelReasonTimeout,
      );
    });
    void hook() {
      _abandon(
        pending,
        McpCancelledException(
          'MCP $method (id $id) was cancelled',
          reason: cancellation?.reason,
        ),
        kMcpCancelReasonClient,
      );
    }

    pending.tokenHook = hook;
    cancellation?._add(hook);

    try {
      // Phase 1: wait for a concurrency slot. Cancellable, because a request
      // that never made it onto the wire has nothing to abort.
      final Completer<void> slot = Completer<void>();
      pending.slotCompleter = slot;
      if (_inFlight < maxConcurrentRequests) {
        _takeSlot(pending);
      } else {
        _waiters.add(pending);
        await slot.future;
      }
      if (pending.isSettled) throw pending.failure!;

      // Phase 2: on the wire. The send is not awaited here: a transport that
      // blocks forever must not stop the caller from being told the request was
      // cancelled.
      unawaited(
        _dispatch(
          pending,
          buildMcpRequestFrame(id: id, method: method, params: params),
        ),
      );
      return await pending.completer.future;
    } finally {
      pending.timer?.cancel();
      final void Function()? tokenHook = pending.tokenHook;
      if (tokenHook != null) cancellation?._remove(tokenHook);
      _waiters.remove(pending);
      if (pending.slotHeld) {
        pending.slotHeld = false;
        _releaseSlot();
      }
      _pending.remove(id);
    }
  }

  Future<void> _dispatch(
    _PendingRequest pending,
    Map<String, dynamic> frame,
  ) async {
    try {
      await _write(frame);
    } on McpException catch (error) {
      _settleWithError(pending, error);
    } catch (error) {
      _settleWithError(
        pending,
        McpTransportException(
          kMcpTransportFailure,
          'MCP transport failed while sending ${pending.method}: '
          '${mcpScrubExcerpt('$error', max: 80)}',
        ),
      );
    }
  }

  Future<void> _write(Map<String, dynamic> frame) async {
    try {
      await transport.send(jsonEncode(frame));
    } on McpException {
      rethrow;
    } catch (error) {
      throw McpTransportException(
        kMcpTransportFailure,
        'MCP transport could not send a frame: ${mcpScrubExcerpt('$error', max: 80)}',
      );
    }
  }

  /// Best-effort notification: a cancellation the server never hears about is
  /// not worth failing the caller over.
  Future<void> _writeQuietly(Map<String, dynamic> frame) async {
    try {
      await transport.send(jsonEncode(frame));
    } on Object {
      // Intentionally ignored: this frame carries no result.
    }
  }

  /// Grants a slot to a request, waking it if it was queued. The caller is
  /// responsible for the [_inFlight] bookkeeping.
  void _grantSlot(_PendingRequest pending) {
    pending.slotHeld = true;
    final Completer<void>? slot = pending.slotCompleter;
    if (slot != null && !slot.isCompleted) slot.complete();
  }

  /// Takes a fresh slot, counting it.
  void _takeSlot(_PendingRequest pending) {
    _inFlight += 1;
    if (_inFlight > _maxObservedConcurrency) {
      _maxObservedConcurrency = _inFlight;
    }
    _grantSlot(pending);
  }

  void _releaseSlot() {
    while (_waiters.isNotEmpty) {
      final _PendingRequest next = _waiters.removeAt(0);
      if (next.isSettled) continue; // abandoned while queued
      // Hand the slot straight over. The count is deliberately unchanged, so
      // the cap holds across the handover instead of drifting upwards.
      _grantSlot(next);
      return;
    }
    _inFlight -= 1;
  }

  /// Drops a request: pending entry gone, transport told to abandon, server
  /// told to stop working on it.
  void _abandon(_PendingRequest pending, McpException error, String reason) {
    if (pending.isSettled) return;
    if (pending.slotHeld) {
      _rememberAbandoned(pending.id);
      _settleWithError(pending, error);
      transport.abandon(pending.id);
      if (!_closed) {
        unawaited(
          _writeQuietly(
            buildMcpNotificationFrame(
              method: kMcpMethodCancelled,
              params: <String, dynamic>{
                'requestId': pending.id,
                'reason': reason,
              },
            ),
          ),
        );
      }
      return;
    }
    // Still queued: the awaiting caller surfaces the error itself.
    _waiters.remove(pending);
    final Completer<void>? slot = pending.slotCompleter;
    if (slot != null && !slot.isCompleted) slot.completeError(error);
  }

  void _settleWithError(_PendingRequest pending, McpException error) {
    if (pending.isSettled) return;
    _pending.remove(pending.id);
    _rememberSettled(pending.id);
    pending.fail(error);
  }

  void _settleWithResult(_PendingRequest pending, Map<String, dynamic> result) {
    if (pending.isSettled) return;
    _pending.remove(pending.id);
    _rememberSettled(pending.id);
    pending.succeed(result);
  }

  void _rememberSettled(String id) {
    if (_settledIds.add(id)) {
      _settledOrder.add(id);
      _trim(_settledIds, _settledOrder);
    }
  }

  void _rememberAbandoned(String id) {
    if (_abandonedIds.add(id)) {
      _abandonedOrder.add(id);
      _trim(_abandonedIds, _abandonedOrder);
    }
  }

  /// Bounded history: enough to catch a duplicate or a late reply, not enough to
  /// grow for the life of the process.
  static void _trim(Set<String> set, List<String> order) {
    const int keep = 128;
    while (order.length > keep) {
      set.remove(order.removeAt(0));
    }
  }

  void _failAllPending(McpException error) {
    final List<_PendingRequest> inFlight = _pending.values.toList();
    for (final _PendingRequest pending in inFlight) {
      pending.timer?.cancel();
      _settleWithError(pending, error);
    }
    for (final _PendingRequest queued in List<_PendingRequest>.of(_waiters)) {
      _waiters.remove(queued);
      final Completer<void>? slot = queued.slotCompleter;
      if (slot != null && !slot.isCompleted) slot.completeError(error);
    }
  }

  // -------------------------------------------------------------------------
  // Incoming frames
  // -------------------------------------------------------------------------

  void _onFrame(String frame) {
    final McpMessage message;
    try {
      message = McpMessage.decode(frame);
    } on McpException catch (error) {
      // The stream can no longer be trusted to be aligned with our requests.
      _report(error);
      _failAllPending(error);
      return;
    }
    if (message.isResponse) {
      _deliverResponse(message);
      return;
    }
    if (message.isRequest) {
      _handleServerRequest(message);
      return;
    }
    if (message.isNotification) {
      if (!_serverNotifications.isClosed) _serverNotifications.add(message);
      return;
    }
    _report(
      const McpMalformedMessageException(
        kMcpMalformedEnvelope,
        'MCP frame carried neither a method, a result, nor an error',
      ),
    );
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    final McpException failure = error is McpException
        ? error
        : McpTransportException(
            kMcpTransportFailure,
            'MCP transport failed: ${mcpScrubExcerpt('$error', max: 80)}',
          );
    _report(failure);
    _failAllPending(failure);
  }

  void _onTransportClosed() {
    if (_closed) return;
    _failAllPending(
      const McpTransportException(
        kMcpTransportClosed,
        'MCP transport closed before the reply arrived',
      ),
    );
  }

  void _deliverResponse(McpMessage message) {
    final String id = message.id ?? '';
    if (id.isEmpty) {
      _report(
        const McpMalformedMessageException(
          kMcpUnknownResponseId,
          'MCP reply arrived without a correlation id',
        ),
      );
      return;
    }
    final _PendingRequest? pending = _pending[id];
    if (pending == null) {
      if (_abandonedIds.contains(id)) {
        _report(
          McpMalformedMessageException(
            kMcpLateResponse,
            'MCP reply for $id arrived after the request was abandoned',
          ),
        );
        return;
      }
      if (_settledIds.contains(id)) {
        _report(
          McpMalformedMessageException(
            kMcpDuplicateResponse,
            'MCP sent a second reply for $id, which was already settled',
          ),
        );
        return;
      }
      _report(
        McpMalformedMessageException(
          kMcpUnknownResponseId,
          'MCP sent a reply for $id, which was never requested',
        ),
      );
      return;
    }
    final McpRemoteErrorException? error = message.error;
    if (error != null) {
      _settleWithError(pending, error);
      return;
    }
    _settleWithResult(pending, message.result ?? const <String, dynamic>{});
  }

  /// Noir answers a server-initiated request with JSON-RPC "method not found",
  /// except for `ping`, which the specification defines as a liveness check and
  /// which grants the server nothing.
  void _handleServerRequest(McpMessage message) {
    final McpServerRequest request = McpServerRequest(
      id: message.id ?? '',
      method: message.method ?? '',
      params: message.params ?? const <String, dynamic>{},
    );
    if (!_serverRequests.isClosed) _serverRequests.add(request);
    if (message.method == kMcpMethodPing) {
      unawaited(
        _writeQuietly(
          buildMcpResultFrame(
            id: request.id,
            result: const <String, dynamic>{},
          ),
        ),
      );
      return;
    }
    unawaited(
      _writeQuietly(
        buildMcpErrorFrame(
          id: request.id,
          code: kRpcMethodNotFound,
          message:
              'Noir does not act on server-initiated requests: ${request.method}',
        ),
      ),
    );
  }

  void _report(McpException error) {
    if (_protocolErrors.isClosed) return;
    _protocolErrors.add(error);
  }

  // -------------------------------------------------------------------------
  // Guards and helpers
  // -------------------------------------------------------------------------

  void _requireOpen() {
    if (_closed) {
      throw const McpLifecycleException(
        kMcpClientClosed,
        'MCP client is closed',
      );
    }
  }

  void _requireInitialized() {
    _requireOpen();
    if (_initialization == null) {
      throw const McpLifecycleException(
        kMcpNotInitialized,
        'MCP session has not completed the initialize handshake',
      );
    }
  }

  /// The handshake must be done, and the server must have declared the
  /// capability this method belongs to. An undeclared method never reaches the
  /// wire: there is nothing to gain from asking and a protocol violation to
  /// lose.
  void _requireReady(String method) {
    _requireInitialized();
    if (!_initialization!.capabilities.supportsMethod(method)) {
      throw McpCapabilityException(
        'MCP server $method is not supported: it did not declare the capability',
      );
    }
  }

  Future<List<T>> _followCursors<T>(
    Future<McpPage<T>> Function(String? cursor) fetch,
    String method,
  ) async {
    final List<T> all = <T>[];
    String? cursor;
    int pages = 0;
    do {
      final McpPage<T> page = await fetch(cursor);
      all.addAll(page.items);
      cursor = page.nextCursor;
      pages += 1;
      if (cursor != null && pages >= maxPages) {
        throw McpLifecycleException(
          kMcpPaginationLimit,
          'MCP $method returned a cursor for $maxPages pages without ending',
        );
      }
    } while (cursor != null);
    return all;
  }

  static Map<String, dynamic> _cursorParams(String? cursor) =>
      <String, dynamic>{
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      };
}

class _PendingRequest {
  _PendingRequest(this.id, this.method);

  final String id;
  final String method;
  final Completer<Object?> completer = Completer<Object?>();
  Timer? timer;
  void Function()? tokenHook;
  Completer<void>? slotCompleter;
  bool slotHeld = false;
  McpException? failure;

  bool get isSettled => completer.isCompleted;

  void succeed(Map<String, dynamic> result) {
    failure = null;
    completer.complete(result);
  }

  void fail(McpException error) {
    failure = error;
    completer.completeError(error);
  }
}
