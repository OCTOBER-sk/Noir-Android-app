// test/ui/tool_call_completion_emission_test.dart — the executor's own event
// emission, exercised end to end.
//
// WHY THIS EXISTS. The previous heartbeat fixed the Command Centre so
// `ToolCallCompleted` clears the skeleton loader, and its widget test proves
// the *screen* honours that event. But the screen test pushes events in by
// hand, so it never runs the code that actually produces them. If
// `NativeGestureExecutor` stopped publishing `ToolCallCompleted` altogether,
// every existing test would still pass and the loader would spin forever.
// `test/ui_event_contract_test.dart` is a source-reading gate, so it cannot
// catch that either.
//
// These tests drive the real executor against a mocked platform channel, with
// a real `ConsentGate` approval granted through the gate's own `requests`
// stream, and assert what the Command Centre would actually receive.
//
// A HYPOTHESIS THIS FILE TESTED AND REFUTED. The obvious-looking defect was
// that the emission pair is not exception-safe:
//
//   lib/core/agent_wiring.dart:474  publish?.call(ToolCallStarted(...));
//   lib/core/agent_wiring.dart:476  final outcome = await _bridge.dispatchGesture(...)
//   lib/core/agent_wiring.dart:488  publish?.call(ToolCallCompleted(...));
//
// `dispatchGesture` catches only `MissingPluginException` and
// `PlatformException`, so a throw of any other class would skip line 488 and
// leave the loader spinning — the same symptom the last heartbeat closed,
// reached by a path its widget test cannot reach.
//
// It cannot actually happen, and the reason is worth recording so the next
// reader does not have to rediscover it. The `MethodChannel` normalises every
// platform-side failure to `PlatformException` before the Dart caller sees it:
// a handler that throws a raw `StateError`, and a reply whose map has non-string
// keys (so `invokeMapMethod<String, dynamic>` cannot cast it), were both probed
// directly against `NativeBridge.dispatchGesture` and both came back as a
// blocked `NativeGestureOutcome` rather than an escaping throw. The remaining
// statement between the two publishes is `outcome.executed`, and the `publish`
// sink itself is guarded — `NoirTaskRun.emit` checks `_events.isClosed`. So no
// throw can reach line 488 unreached, and no fix is warranted here.
//
// What is left is the part that is real: the emission path had no test that
// runs the executor, so the coverage below pins the three honest outcomes —
// dispatched, refused by the platform, and refused before dispatch.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/agent/agent_runtime.dart';
import 'package:noir_android_app/core/agent_wiring.dart';
import 'package:noir_android_app/core/ui_state_contract.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/safety/policy_engine.dart';
import 'package:noir_android_app/safety/risk_classifier.dart';

const MethodChannel _testChannel = MethodChannel(kNativeChannelName);

/// A node the executor's `_resolveBounds` can find, so the run reaches the
/// dispatch instead of being refused for a malformed target. `screenBounds` is
/// nested because `GestureBounds.fromNode` reads `node['screenBounds']`.
const Map<String, dynamic> _node = <String, dynamic>{
  'text': 'Save this',
  'screenBounds': <String, dynamic>{
    'left': 40,
    'top': 120,
    'right': 240,
    'bottom': 200,
  },
};

const Plan _plan = Plan(
  content: <String, dynamic>{'action': 'save_fact', 'input': 'save this'},
  screenNodes: <dynamic>[_node],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late NativeBridge bridge;
  late List<NoirUiEvent> published;
  late NativeGestureExecutor executor;

  tearDown(() async {
    messenger.setMockMethodCallHandler(_testChannel, null);
    await bridge.dispose();
  });

  /// Builds an executor and drives one real approval for `save_fact` through
  /// the gate's own `requests` stream, so `run` proceeds to the dispatch. The
  /// platform reply is whatever [dispatch] returns.
  ///
  /// The approval is granted the way the app grants it — a human answering a
  /// [PendingConfirmation] — rather than by reaching into the gate's private
  /// map, so the test cannot pass on a path the app does not use.
  Future<void> build({
    required Future<Object?> Function(MethodCall call) dispatch,
  }) async {
    messenger.setMockMethodCallHandler(_testChannel, dispatch);
    bridge = NativeBridge();
    published = <NoirUiEvent>[];
    final ConsentGate gate = ConsentGate();
    addTearDown(gate.dispose);

    // `needsConfirmation` and no biometric: the one shape a tap can approve on
    // this build. `save_fact` is the action string `run` will look up. The
    // approval is granted by a human answering the request, exactly as the
    // Safety Centre does.
    final Completer<bool> granted = Completer<bool>();
    final StreamSubscription<PendingConfirmation> sub = gate.requests.listen((
      PendingConfirmation request,
    ) {
      request.answer(true);
    });
    addTearDown(sub.cancel);
    unawaited(
      gate
          .check(
            // The exact message shape PolicyEngine.gate produces, because
            // `ConsentGate._actionOf` reads the action back out of it.
            GateResult.confirm('Confirmation required: save_fact', false),
            RiskLevel(level: 0),
          )
          .then((bool approved) {
            if (!granted.isCompleted) granted.complete(approved);
          }),
    );
    expect(await granted.future, isTrue);
    expect(
      gate.approvedActions,
      contains('save_fact'),
      reason: 'the gate must hold a live approval before run() consumes it',
    );

    executor = NativeGestureExecutor(
      bridge: bridge,
      gate: gate,
      publish: published.add,
    );
  }

  group('NativeGestureExecutor tool-call event emission', () {
    test(
      'a platform error completes the call as not executed, not as a throw',
      () async {
        // The refuted-hypothesis case, asserted for what it actually does.
        // The MethodChannel turns this into a PlatformException, so the bridge
        // fails closed to a blocked outcome — the call is announced as started
        // and then completed as a failure, and the loader stops. If a future
        // change ever lets a raw error escape, this test fails rather than
        // letting the loader spin again unnoticed.
        await build(
          dispatch: (call) async => throw StateError('channel desynchronised'),
        );

        final Object? outcome = await executor.run(_plan);

        expect(
          outcome,
          isA<NativeGestureOutcome>(),
          reason: 'the bridge must convert the channel error into an outcome',
        );
        expect((outcome! as NativeGestureOutcome).executed, isFalse);
        expect(published.whereType<ToolCallStarted>(), hasLength(1));
        expect(
          published.whereType<ToolCallCompleted>(),
          hasLength(1),
          reason: 'a started call must still be completed, or the loader spins',
        );
        expect(
          published.whereType<ToolCallCompleted>().single.success,
          isFalse,
          reason:
              'the platform never confirmed execution, so success must be false',
        );
      },
    );

    test('a dispatched gesture completes the call as executed', () async {
      await build(
        dispatch: (call) async => <String, dynamic>{
          'executed': true,
          'receiptId': 'r-1',
        },
      );

      await executor.run(_plan);

      expect(published.whereType<ToolCallStarted>(), hasLength(1));
      expect(published.whereType<ToolCallCompleted>(), hasLength(1));
      expect(
        published.whereType<ToolCallCompleted>().single.success,
        isTrue,
        reason: 'A dispatched gesture must not be reported as a failure.',
      );
    });

    test('a platform refusal completes the call as not executed', () async {
      await build(
        dispatch: (call) async => <String, dynamic>{'executed': false},
      );

      await executor.run(_plan);

      expect(published.whereType<ToolCallCompleted>(), hasLength(1));
      expect(published.whereType<ToolCallCompleted>().single.success, isFalse);
    });

    test('a call refused before dispatch announces no run at all', () async {
      await build(
        dispatch: (call) async => fail('the platform must not be invoked'),
      );
      // No resolvable target, so the executor refuses before the dispatch. An
      // event pair here would claim a tool run that never happened.
      const Plan unresolvable = Plan(
        content: <String, dynamic>{
          'action': 'save_fact',
          'input': 'no such text anywhere',
        },
        screenNodes: <dynamic>[_node],
      );

      await executor.run(unresolvable);

      expect(published, isEmpty);
    });
  });
}
