/// Chat adapter for OpenAI-compatible endpoints (OpenRouter, gateways, local
/// servers), speaking both buffered and SSE-streamed completions.
///
/// The transport is injected, so the whole adapter is exercised in tests
/// without a network call.
library;

import 'dart:async';
import 'dart:convert';

import '../auth_config.dart';
import '../cancellation.dart';
import '../chat_types.dart';
import '../errors.dart';
import '../model_discovery.dart';
import '../provider_client.dart';
import '../streaming.dart';
import '../transport.dart';

/// Runs one buffered chat completion.
class OpenRouterAdapter {
  OpenRouterAdapter({
    required this.transport,
    required this.auth,
    RetryPolicy retry = const RetryPolicy(),
    ProviderTimeouts timeouts = const ProviderTimeouts(),
    Sleeper? sleep,
    DateTime Function() clock = DateTime.now,
  }) : _clock = clock,
       _client = ProviderHttpClient(
         transport: transport,
         retry: retry,
         timeouts: timeouts,
         sleep: sleep,
       );

  /// Path appended to the base URL.
  static const String chatCompletionsPath = 'chat/completions';

  /// Injected HTTP seam; swap it to change where requests go.
  final ProviderTransport transport;

  /// Base URL and credentials used for every call.
  final ProviderAuthConfig auth;

  final DateTime Function() _clock;
  final ProviderHttpClient _client;

  ModelDiscovery? _discovery;

  /// Discovers models through the same transport and credentials.
  ModelDiscovery get discovery => _discovery ??= ModelDiscovery(
    transport: transport,
    auth: auth,
    timeouts: _client.timeouts,
    sleep: _client.sleep,
    clock: _clock,
  );

  /// Runs a buffered completion and returns the parsed result.
  ///
  /// Throws a typed [ProviderException] on auth, rate-limit, network, timeout,
  /// malformed-response and cancellation failures.
  Future<ChatCompletion> completeChat({
    required ChatRequest request,
    CancellationToken? cancellation,
  }) async {
    final ProviderRequest providerRequest = _buildRequest(
      request: request,
      stream: false,
    );
    final String body = await _client.sendText(
      request: providerRequest,
      cancellation: cancellation,
    );
    return ChatCompletion.fromJson(_decodeObject(body));
  }

  /// Streams a completion.
  ///
  /// Emits [ProviderTextDelta] as content arrives, [ProviderUsage] when the
  /// provider reports usage, and exactly one terminal event: either
  /// [ProviderCompleted] or [ProviderFailed]. Nothing is emitted after it, and
  /// a cancelled or stalled stream still ends with a terminal event.
  ///
  /// Cancelling either the [cancellation] token or the returned stream's
  /// subscription stops the request, the stream and any pending retry.
  Stream<ProviderStreamEvent> streamChat({
    required ChatRequest request,
    CancellationToken? cancellation,
  }) {
    final StreamController<ProviderStreamEvent> controller =
        StreamController<ProviderStreamEvent>();
    // One internal token, so a caller token and a consumer subscription can
    // both stop the same pump.
    final CancellationToken pump = CancellationToken();
    void Function() removeCallerListener = () {};
    if (cancellation != null) {
      removeCallerListener = cancellation.addListener(
        () => pump.cancel(cancellation.reason),
      );
    }
    controller.onCancel = () {
      removeCallerListener();
      pump.cancel('consumer unsubscribed');
    };
    // The pump only completes once the stream has terminated, so the caller
    // token stays wired for the whole exchange.
    unawaited(
      _pump(request, pump, controller).whenComplete(removeCallerListener),
    );
    return controller.stream;
  }

  /// Live model discovery through this adapter's transport and credentials.
  Future<ModelDiscoveryResult> listModels({
    CancellationToken? cancellation,
    ModelDiscoveryFilter filter = const ModelDiscoveryFilter(),
  }) => discovery.fetch(cancellation: cancellation, filter: filter);

  ProviderRequest _buildRequest({
    required ChatRequest request,
    required bool stream,
  }) => ProviderRequest.json(
    method: 'POST',
    uri: auth.resolve(chatCompletionsPath),
    headers: auth.requestHeaders(streaming: stream),
    payload: request.toJson(stream: stream),
    expectsStream: stream,
  );

  Future<void> _pump(
    ChatRequest request,
    CancellationToken? cancellation,
    StreamController<ProviderStreamEvent> controller,
  ) async {
    try {
      final TransportResponse response = await _client.sendSuccess(
        request: _buildRequest(request: request, stream: true),
        cancellation: cancellation,
      );
      if (controller.isClosed) return;
      await _pumpBody(response, cancellation, controller);
    } on Object catch (error) {
      _emitTerminal(controller, ProviderFailed(ProviderException.from(error)));
    }
  }

  /// Streams the response body, completing when the stream terminates.
  Future<void> _pumpBody(
    TransportResponse response,
    CancellationToken? cancellation,
    StreamController<ProviderStreamEvent> controller,
  ) async {
    final ChatStreamDecoder decoder = ChatStreamDecoder();
    final Completer<void> terminated = Completer<void>();
    StreamSubscription<String>? lines;
    Timer? idleTimer;
    Timer? overallTimer;
    void Function() removeCancelListener = () {};
    bool done = false;

    void cleanup() {
      idleTimer?.cancel();
      overallTimer?.cancel();
      idleTimer = null;
      overallTimer = null;
      removeCancelListener();
      removeCancelListener = () {};
      final StreamSubscription<String>? pending = lines;
      lines = null;
      if (pending != null) unawaited(pending.cancel());
    }

    void terminal(ProviderStreamEvent event) {
      if (done || controller.isClosed) return;
      done = true;
      cleanup();
      controller.add(event);
      unawaited(controller.close());
      if (!terminated.isCompleted) terminated.complete();
    }

    void armIdle() {
      idleTimer?.cancel();
      idleTimer = Timer(timeouts.idle, () {
        terminal(
          ProviderFailed(
            ProviderException.timeout(
              'no stream data for more than ${timeouts.idle}',
            ),
          ),
        );
      });
    }

    final SseParser parser = SseParser((SseEvent frame) {
      armIdle();
      if (done) return;
      if (frame.isDone) {
        terminal(ProviderCompleted(decoder.completion()));
        return;
      }
      for (final ProviderStreamEvent event in decoder.add(frame)) {
        if (done) return;
        if (event is ProviderFailed) {
          terminal(event);
          return;
        }
        controller.add(event);
      }
    });

    final Duration? overall = _client.timeouts.overall;
    if (overall != null) {
      overallTimer = Timer(overall, () {
        terminal(
          ProviderFailed(
            ProviderException.timeout('stream exceeded the $overall deadline'),
          ),
        );
      });
    }
    if (cancellation != null) {
      removeCancelListener = cancellation.addListener(() {
        terminal(
          ProviderFailed(ProviderException.cancelled(cancellation.reason)),
        );
      });
    }
    armIdle();

    try {
      lines = response.body
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            parser.addLine,
            onError: (Object error) =>
                terminal(ProviderFailed(_streamFailure(error))),
            onDone: () {
              if (done) return;
              parser.flush();
              if (done) return;
              terminal(
                decoder.sawFrame
                    ? ProviderCompleted(decoder.completion())
                    : ProviderFailed(
                        ProviderException.malformed(
                          'stream ended before any usable frame arrived',
                        ),
                      ),
              );
            },
          );
    } on Object catch (error) {
      terminal(ProviderFailed(_streamFailure(error)));
    }
    return terminated.future;
  }

  /// Deadlines applied to each attempt.
  ProviderTimeouts get timeouts => _client.timeouts;

  static void _emitTerminal(
    StreamController<ProviderStreamEvent> controller,
    ProviderStreamEvent event,
  ) {
    if (controller.isClosed) return;
    controller.add(event);
    unawaited(controller.close());
  }

  static ProviderException _streamFailure(Object error) {
    if (error is ProviderException) return error;
    if (error is FormatException) {
      return ProviderException.malformed(
        'stream contained undecodable data: ${error.message}',
      );
    }
    return ProviderException.network('stream failed: $error');
  }

  static Map<String, dynamic> _decodeObject(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw ProviderException.malformed(
        'response was not valid JSON: ${error.message}',
        body: body,
      );
    }
    if (decoded is! Map) {
      throw ProviderException.malformed('response was not a JSON object');
    }
    return Map<String, dynamic>.from(decoded);
  }
}
