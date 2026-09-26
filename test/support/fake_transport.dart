// Test support: no-socket transport doubles for the provider runtime.
//
// Every test in test/provider_*_test.dart drives real lib/providers code through
// these doubles. No socket is opened and no external endpoint is contacted.
import 'dart:async';
import 'dart:convert';

import 'package:noir_android_app/providers/cancellation.dart';
import 'package:noir_android_app/providers/errors.dart';
import 'package:noir_android_app/providers/transport.dart';

/// Scripted response for one [FakeTransport.send] call.
typedef FakeHandler =
    FutureOr<TransportResponse> Function(ProviderRequest request);

/// Replays scripted [TransportResponse]s and records every request it received.
class FakeTransport implements ProviderTransport {
  FakeTransport(this.handlers);

  FakeTransport.single(TransportResponse response)
    : handlers = <FakeHandler>[(ProviderRequest _) => response];

  final List<FakeHandler> handlers;
  final List<ProviderRequest> requests = <ProviderRequest>[];

  int closedCalls = 0;
  int _index = 0;

  int get callCount => requests.length;

  @override
  Future<TransportResponse> send(
    ProviderRequest request, {
    CancellationToken? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      throw ProviderException.cancelled();
    }
    requests.add(request);
    if (_index >= handlers.length) {
      throw StateError(
        'FakeTransport: no scripted handler for request #${requests.length}',
      );
    }
    final FakeHandler handler = handlers[_index];
    _index += 1;
    return handler(request);
  }

  @override
  void close() {
    closedCalls += 1;
  }
}

/// JSON body response.
TransportResponse jsonResponse(
  Object payload, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) => rawResponse(
  jsonEncode(payload),
  status: status,
  headers: <String, String>{'content-type': 'application/json', ...headers},
);

/// Raw text body response (used for malformed-body and SSE cases).
TransportResponse rawResponse(
  String body, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) => TransportResponse(
  statusCode: status,
  headers: headers,
  body: Stream<List<int>>.value(utf8.encode(body)),
);

/// Server-sent-events response; one `data:` frame per payload.
TransportResponse sseResponse(
  List<String> payloads, {
  int status = 200,
  bool includeDone = true,
  String? eventName,
  Map<String, String> headers = const <String, String>{},
}) {
  final StringBuffer buffer = StringBuffer();
  for (final String payload in payloads) {
    if (eventName != null) buffer.write('event: $eventName\n');
    buffer.write('data: $payload\n\n');
  }
  if (includeDone) buffer.write('data: [DONE]\n\n');
  return rawResponse(
    buffer.toString(),
    status: status,
    headers: <String, String>{'content-type': 'text/event-stream', ...headers},
  );
}

/// SSE response that arrives as [chunks]: the first chunk is delivered
/// immediately, every later chunk after [gap]. This is how the suite proves the
/// decoder buffers partial frames and how idle/overall deadlines fire.
TransportResponse chunkedSseResponse(
  List<String> chunks, {
  int status = 200,
  bool includeDone = true,
  Duration gap = Duration.zero,
  String? eventName,
  void Function()? onBodyCancel,
}) {
  final List<String> parts = <String>[
    for (final String chunk in chunks) chunk,
    if (includeDone) 'data: [DONE]\n\n',
  ];
  final StreamController<List<int>> controller = StreamController<List<int>>(
    onCancel: onBodyCancel,
  );
  Future<void> emit() async {
    for (int i = 0; i < parts.length; i++) {
      if (i > 0 && gap > Duration.zero) await Future<void>.delayed(gap);
      if (controller.isClosed) return;
      controller.add(utf8.encode(parts[i]));
    }
    if (!controller.isClosed) await controller.close();
  }

  unawaited(emit());
  return TransportResponse(
    statusCode: status,
    headers: const <String, String>{'content-type': 'text/event-stream'},
    body: controller.stream,
  );
}

/// Response whose headers arrive but whose body never emits and never closes.
TransportResponse hangingResponse({int status = 200}) {
  final StreamController<List<int>> controller = StreamController<List<int>>();
  return TransportResponse(
    statusCode: status,
    headers: const <String, String>{'content-type': 'text/event-stream'},
    body: controller.stream,
  );
}

/// Response whose body emits [chunks] and then fails with [error].
TransportResponse erroringResponse(
  Object error, {
  List<String> chunks = const <String>[],
  int status = 200,
}) {
  final StreamController<List<int>> controller = StreamController<List<int>>();
  Future<void> emit() async {
    for (final String chunk in chunks) {
      controller.add(utf8.encode(chunk));
    }
    controller.addError(error);
    await controller.close();
  }

  unawaited(emit());
  return TransportResponse(
    statusCode: status,
    headers: const <String, String>{'content-type': 'text/event-stream'},
    body: controller.stream,
  );
}
