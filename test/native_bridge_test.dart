// test/native_bridge_test.dart — C2 gate wrapper tests.
//
// The MethodChannel is mocked, so these tests exercise the real wrapper in
// lib/platform/native_bridge.dart and the real PolicyEngine it delegates to.
// Three properties are asserted, all of them fail-closed:
//
//   * gate clear    -> the platform is asked to dispatch, and only then
//   * gate block    -> the platform is NEVER asked to dispatch
//   * channel gone  -> the result is a block, never a silent success
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/safety/policy_engine.dart';

const MethodChannel _testChannel = MethodChannel(kNativeChannelName);

/// A proposal the Dart RiskClassifier rates HIGH_RISK (action contains
/// "delete"), so the biometric branch of the PolicyEngine is exercised.
const Map<String, dynamic> _highRiskProposal = <String, dynamic>{
  'action': 'delete_thread',
  'input': 'all messages',
};

/// A proposal the RiskClassifier rates SAFE.
const Map<String, dynamic> _safeProposal = <String, dynamic>{
  'action': 'save_fact',
  'input': 'remember this',
};

const GestureBounds _target = GestureBounds(
  left: 40,
  top: 120,
  right: 240,
  bottom: 200,
);

/// The production PolicyEngine is a plain mutable class, so these configure the
/// very same rules the app uses rather than standing in for them.
PolicyEngine _engineWith({String? blacklistedAction, bool uiLock = false}) {
  final engine = PolicyEngine();
  if (blacklistedAction != null) engine.blacklist.add(blacklistedAction);
  engine.uiLock = uiLock;
  return engine;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late NativeBridge bridge;
  late List<MethodCall> received;

  /// Records every Dart -> platform call and replies with [handler].
  void install(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(_testChannel, (call) async {
      received.add(call);
      return handler(call);
    });
  }

  /// Installs a mock platform handler and returns a restore function.
  void installUnreachable() {
    install((call) async => fail('platform must not be invoked'));
  }

  setUp(() {
    received = <MethodCall>[];
    bridge = NativeBridge();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_testChannel, null);
    await bridge.dispose();
  });

  group('NativeBridge.dispatchGesture - gate clear', () {
    test(
      'calls dispatchGesture and reports execution when the gate clears',
      () async {
        install(
          (call) async => <String, dynamic>{
            'executed': true,
            'gesture': 'tap',
            'x': 140.0,
            'y': 160.0,
            'gateSource': kGateSource,
            'gateMessage': 'Confirmation required: save_fact',
          },
        );

        final outcome = await bridge.dispatchGesture(
          proposal: _safeProposal,
          bounds: _target,
          confirmed: true,
        );

        expect(outcome.executed, isTrue);
        expect(outcome.verdict.allowed, isTrue);
        expect(outcome.verdict.riskLevel, 0);
        expect(outcome.receipt['x'], 140.0);
        expect(outcome.receipt['gateSource'], kGateSource);

        expect(received, hasLength(1));
        expect(received.single.method, kMethodDispatchGesture);
        final payload = received.single.arguments as Map<Object?, Object?>;
        expect(payload['proposal'], _safeProposal);
        expect(payload['bounds'], <String, dynamic>{
          'left': 40,
          'top': 120,
          'right': 240,
          'bottom': 200,
        });
        expect(payload['confirmed'], isTrue);
        expect(payload['gateRequestId'], isA<String>());
      },
    );

    test(
      'a level-3 action keeps its biometric requirement end to end',
      () async {
        install(
          (call) async => <String, dynamic>{
            'executed': true,
            'riskLevel': 3,
            'gateSource': kGateSource,
          },
        );

        final outcome = await bridge.dispatchGesture(
          proposal: _highRiskProposal,
          bounds: _target,
          confirmed: true,
        );

        expect(outcome.executed, isTrue);
        expect(outcome.verdict.needsBiometric, isTrue);
        expect(outcome.verdict.riskLevel, 3);
        final payload = received.single.arguments as Map<Object?, Object?>;
        expect(payload['riskLevel'], 3);
      },
    );

    test(
      'a platform reply without executed:true is treated as a block',
      () async {
        install((call) async => <String, dynamic>{'gesture': 'tap'});

        final outcome = await bridge.dispatchGesture(
          proposal: _safeProposal,
          bounds: _target,
          confirmed: true,
        );

        expect(outcome.executed, isFalse);
        expect(outcome.blockReason, kCodeNativeDispatchFailed);
      },
    );
  });

  group('NativeBridge.dispatchGesture - gate block', () {
    test('a blacklisted action never reaches the platform', () async {
      await bridge.dispose();
      bridge = NativeBridge(
        policyEngine: _engineWith(blacklistedAction: 'delete_thread'),
      );
      installUnreachable();

      final outcome = await bridge.dispatchGesture(
        proposal: _highRiskProposal,
        bounds: _target,
        confirmed: true,
      );

      expect(outcome.executed, isFalse);
      expect(outcome.verdict.allowed, isFalse);
      expect(outcome.verdict.message, 'BLACKLIST');
      expect(received, isEmpty);
    });

    test('a UI lock never reaches the platform', () async {
      await bridge.dispose();
      bridge = NativeBridge(policyEngine: _engineWith(uiLock: true));
      installUnreachable();

      final outcome = await bridge.dispatchGesture(
        proposal: _safeProposal,
        bounds: _target,
        confirmed: true,
      );

      expect(outcome.executed, isFalse);
      expect(outcome.verdict.message, 'UI_LOCK');
      expect(received, isEmpty);
    });

    test(
      'an unconfirmed action is blocked before the platform is called',
      () async {
        installUnreachable();

        final outcome = await bridge.dispatchGesture(
          proposal: _safeProposal,
          bounds: _target,
        );

        expect(outcome.executed, isFalse);
        expect(outcome.blockReason, kCodeConfirmationRequired);
        expect(received, isEmpty);
      },
    );

    test('an off-screen or degenerate target is blocked', () async {
      installUnreachable();

      final collapsed = await bridge.dispatchGesture(
        proposal: _safeProposal,
        bounds: const GestureBounds(left: 10, top: 10, right: 10, bottom: 10),
        confirmed: true,
      );
      final offScreen = await bridge.dispatchGesture(
        proposal: _safeProposal,
        bounds: const GestureBounds(
          left: -400,
          top: -400,
          right: -200,
          bottom: -200,
        ),
        confirmed: true,
      );

      expect(collapsed.executed, isFalse);
      expect(collapsed.blockReason, kCodeMalformedGestureTarget);
      expect(offScreen.executed, isFalse);
      expect(offScreen.blockReason, kCodeMalformedGestureTarget);
      expect(received, isEmpty);
    });

    test('a POLICY_BLOCKED platform error surfaces as a block', () async {
      install(
        (call) async => throw PlatformException(
          code: 'POLICY_BLOCKED',
          message: 'PolicyEngine blocked: UI_LOCK',
        ),
      );

      final outcome = await bridge.dispatchGesture(
        proposal: _safeProposal,
        bounds: _target,
        confirmed: true,
      );

      expect(outcome.executed, isFalse);
      expect(outcome.blockReason, 'POLICY_BLOCKED');
    });
  });

  group('NativeBridge fails closed when the channel is unavailable', () {
    test('dispatchGesture blocks on MissingPluginException', () async {
      install((call) async => throw MissingPluginException());

      final outcome = await bridge.dispatchGesture(
        proposal: _safeProposal,
        bounds: _target,
        confirmed: true,
      );

      expect(outcome.executed, isFalse);
      expect(outcome.blockReason, kCodeNativeBridgeUnavailable);
      expect(outcome.verdict.allowed, isFalse);
    });

    test('an unreachable Dart gate is reported as fail-closed', () async {
      install(
        (call) async => throw PlatformException(
          code: 'POLICY_GATE_UNREACHABLE',
          message: 'Dart PolicyEngine did not answer within 3000ms',
        ),
      );

      final outcome = await bridge.dispatchGesture(
        proposal: _safeProposal,
        bounds: _target,
        confirmed: true,
      );

      expect(outcome.executed, isFalse);
      expect(outcome.blockReason, kCodePolicyGateUnreachable);
    });

    test('getNodes reports unavailable instead of an empty screen', () async {
      install((call) async => throw MissingPluginException());

      final dump = await bridge.getNodes();

      expect(dump.available, isFalse);
      expect(dump.code, kCodeNativeBridgeUnavailable);
      expect(dump.isEmpty, isTrue);
    });

    test(
      'getNodes surfaces a service error rather than empty content',
      () async {
        install(
          (call) async => throw PlatformException(
            code: 'SERVICE_UNAVAILABLE',
            message: 'enable the accessibility service',
          ),
        );

        final dump = await bridge.getNodes();

        expect(dump.available, isFalse);
        expect(dump.code, 'SERVICE_UNAVAILABLE');
      },
    );

    test('serviceStatus degrades to disconnected, never throws', () async {
      install((call) async => throw MissingPluginException());

      final status = await bridge.serviceStatus();

      expect(status['serviceConnected'], isFalse);
    });

    test('serviceStatus reports a connected service verbatim', () async {
      install(
        (call) async => <String, dynamic>{
          'serviceConnected': true,
          'canPerformGestures': true,
          'canRetrieveWindowContent': true,
          'hasNodeDump': true,
          'lastNodeCount': 42,
          'runtimeSinkInstalled': true,
          'gateSource': kGateSource,
        },
      );

      final status = await bridge.serviceStatus();

      expect(status['serviceConnected'], isTrue);
      expect(status['canPerformGestures'], isTrue);
      expect(status['lastNodeCount'], 42);
      expect(status['gateSource'], kGateSource);
    });
  });

  group('NativeBridge screenNodes push', () {
    test('a pushed dump reaches the screenNodeDumps stream', () async {
      final received = bridge.screenNodeDumps.first;

      final acknowledged = await bridge.handlePlatformMethod(
        MethodCall(kMethodScreenNodes, <String, dynamic>{
          'nodes': <Object?>[
            <String, dynamic>{'text': 'hello', 'alpha': 1.0},
          ],
          'nodeCount': 1,
          'source': 'AgentAccessibilityService',
        }),
      );

      expect(acknowledged, 1);
      final nodes = await received;
      expect(nodes, hasLength(1));
      expect(nodes.single['text'], 'hello');
    });

    test('a malformed push is rejected without polluting the stream', () async {
      for (final arguments in <Object?>[
        null,
        'nodes',
        <String, dynamic>{'nodes': 'not-a-list'},
      ]) {
        final acknowledged = await bridge.handlePlatformMethod(
          MethodCall(kMethodScreenNodes, arguments),
        );
        expect(acknowledged, isFalse, reason: 'arguments: $arguments');
      }
    });
  });

  group('NativeBridge.getNodes', () {
    test(
      'parses the platform envelope and sanitizes through the A6a sanitizer',
      () async {
        // Exactly the envelope AgentAccessibilityService.payloadOf produces.
        install(
          (call) async => <String, dynamic>{
            'nodes': <Object?>[
              <String, dynamic>{
                'text': 'Invisible instructions',
                'alpha': 0.0,
                'visible': false,
                'zOrder': 2,
                'screenBounds': <String, dynamic>{
                  'left': 0,
                  'top': 0,
                  'right': 10,
                  'bottom': 10,
                },
              },
              <String, dynamic>{
                'text': 'Compose message',
                'alpha': 1.0,
                'visible': true,
                'zOrder': 1,
                'screenBounds': <String, dynamic>{
                  'left': 0,
                  'top': 100,
                  'right': 200,
                  'bottom': 150,
                },
              },
            ],
            'nodeCount': 2,
            'capturedAtMs': 1234,
            'source': 'AgentAccessibilityService',
          },
        );

        final dump = await bridge.getNodes();

        expect(dump.available, isTrue);
        expect(dump.nodes, hasLength(2));

        final sanitized = dump.sanitized();
        expect(sanitized.cleanTextNodes, <String>['Compose message']);
        expect(sanitized.stripped, hasLength(1));
        expect(sanitized.stripped.single.text, 'Invisible instructions');
      },
    );

    test(
      'a reply that is not the documented envelope is unavailable',
      () async {
        install((call) async => <String, dynamic>{'unexpected': true});

        final dump = await bridge.getNodes();

        expect(dump.available, isFalse);
        expect(dump.code, kCodeNodeDumpUnavailable);
      },
    );
  });

  group('NativeBridge re-entrant policyGate', () {
    Future<Map<Object?, Object?>> askGate(Object? arguments) async {
      final reply = await bridge.handlePlatformMethod(
        MethodCall(kMethodPolicyGate, arguments),
      );
      return reply! as Map<Object?, Object?>;
    }

    test(
      'a confirmed, allowed proposal is authorised by PolicyEngine',
      () async {
        final reply = await askGate(<String, dynamic>{
          'proposal': _safeProposal,
          'confirmed': true,
          'gateRequestId': 'gate-1',
        });

        expect(reply['allowed'], isTrue);
        expect(reply['needsBiometric'], isFalse);
        expect(reply['riskLevel'], 0);
        expect(reply['source'], kGateSource);
        expect(reply['message'], contains('save_fact'));
      },
    );

    test(
      'a high-risk proposal is authorised but still demands a biometric',
      () async {
        final reply = await askGate(<String, dynamic>{
          'proposal': _highRiskProposal,
          'confirmed': true,
        });

        expect(reply['allowed'], isTrue);
        expect(reply['needsBiometric'], isTrue);
        expect(reply['riskLevel'], 3);
      },
    );

    test('an unconfirmed request is blocked', () async {
      final reply = await askGate(<String, dynamic>{'proposal': _safeProposal});

      expect(reply['allowed'], isFalse);
      expect(reply['message'], kCodeConfirmationRequired);
    });

    test('a malformed request is blocked, not guessed', () async {
      for (final arguments in <Object?>[
        null,
        'save_fact',
        <String, dynamic>{},
        <String, dynamic>{'proposal': 'save_fact'},
        <String, dynamic>{'proposal': null},
      ]) {
        final reply = await askGate(arguments);

        expect(reply['allowed'], isFalse, reason: 'arguments: $arguments');
        expect(reply['message'], kCodeMalformedGateRequest);
      }
    });

    test(
      'a platform-supplied riskLevel cannot downgrade the classification',
      () async {
        final reply = await askGate(<String, dynamic>{
          'proposal': _highRiskProposal,
          'confirmed': true,
          // A tampered native caller asking for "this is safe".
          'riskLevel': 0,
        });

        expect(reply['riskLevel'], 3);
        expect(reply['needsBiometric'], isTrue);
      },
    );

    test('an unknown platform call is not implemented', () async {
      expect(
        bridge.handlePlatformMethod(const MethodCall('dropTables')),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('NativeGateVerdict decoding', () {
    test('round-trips a well-formed verdict', () {
      const verdict = NativeGateVerdict(
        allowed: true,
        message: 'ok',
        needsBiometric: true,
        riskLevel: 2,
      );

      final decoded = NativeGateVerdict.fromChannelMap(verdict.toChannelMap());

      expect(decoded, isNotNull);
      expect(decoded!.allowed, isTrue);
      expect(decoded.message, 'ok');
      expect(decoded.needsBiometric, isTrue);
      expect(decoded.riskLevel, 2);
    });

    test('refuses anything malformed so callers fail closed', () {
      expect(NativeGateVerdict.fromChannelMap(null), isNull);
      expect(NativeGateVerdict.fromChannelMap('allowed'), isNull);
      expect(NativeGateVerdict.fromChannelMap(<Object?, Object?>{}), isNull);
      expect(
        NativeGateVerdict.fromChannelMap(<Object?, Object?>{
          'allowed': true,
          'message': 'ok',
        }),
        isNull,
      );
      expect(
        NativeGateVerdict.fromChannelMap(<Object?, Object?>{
          'allowed': 'true',
          'message': 'ok',
          'needsBiometric': false,
          'riskLevel': 0,
        }),
        isNull,
      );
      expect(
        NativeGateVerdict.fromChannelMap(<Object?, Object?>{
          'allowed': true,
          'message': '   ',
          'needsBiometric': false,
          'riskLevel': 0,
        }),
        isNull,
      );
    });

    // These pin the agreement with `GateVerdict.decode` in GateVerdict.kt. The
    // two decoders claim the same wire format, so a value one accepts and the
    // other refuses is a silent divergence. Dart now widens the same way Kotlin
    // does, while still refusing anything that is not an exact integer.
    test('accepts an integral Double riskLevel, as the platform decoder does', () {
      final decoded = NativeGateVerdict.fromChannelMap(<Object?, Object?>{
        'allowed': true,
        'message': 'ok',
        'needsBiometric': false,
        'riskLevel': 2.0,
      });

      expect(decoded, isNotNull);
      expect(decoded!.riskLevel, 2);
      expect(decoded.riskLevel, isA<int>());
    });

    test('accepts a negative integral Double, matching the platform decoder', () {
      final decoded = NativeGateVerdict.fromChannelMap(<Object?, Object?>{
        'allowed': false,
        'message': 'denied',
        'needsBiometric': false,
        'riskLevel': -1.0,
      });

      expect(decoded, isNotNull);
      expect(decoded!.riskLevel, -1);
    });

    test('still refuses a fractional, non-numeric or non-finite riskLevel', () {
      NativeGateVerdict? refused(Object? riskLevel) =>
          NativeGateVerdict.fromChannelMap(<Object?, Object?>{
            'allowed': true,
            'message': 'ok',
            'needsBiometric': false,
            'riskLevel': riskLevel,
          });

      expect(refused(2.5), isNull);
      expect(refused('2'), isNull);
      expect(refused(null), isNull);
      expect(refused(double.nan), isNull);
      expect(refused(double.infinity), isNull);
      expect(refused(double.negativeInfinity), isNull);
    });

    test('the steering field stays strict even when riskLevel widens', () {
      // Widening `riskLevel` must not have relaxed anything else: `allowed` is
      // the field a gesture actually depends on, and both decoders still
      // require a strict Boolean for it.
      final decoded = NativeGateVerdict.fromChannelMap(<Object?, Object?>{
        'allowed': 1,
        'message': 'ok',
        'needsBiometric': false,
        'riskLevel': 2.0,
      });

      expect(decoded, isNull);
    });
  });

  group('GestureBounds', () {
    test('prefers screenBounds over parent-relative bounds', () {
      final bounds = GestureBounds.fromNode(<String, dynamic>{
        'bounds': <String, dynamic>{
          'left': 0,
          'top': 0,
          'right': 1,
          'bottom': 1,
        },
        'screenBounds': <String, dynamic>{
          'left': 100,
          'top': 200,
          'right': 300,
          'bottom': 260,
        },
      });

      expect(bounds, isNotNull);
      expect(bounds!.left, 100);
      expect(bounds.centerX, 200.0);
      expect(bounds.centerY, 230.0);
      expect(bounds.hasOnScreenCenter, isTrue);
    });

    test('returns null when a node carries no usable rectangle', () {
      expect(GestureBounds.fromNode(<String, dynamic>{}), isNull);
      expect(
        GestureBounds.fromNode(<String, dynamic>{
          'screenBounds': <String, dynamic>{'left': 1, 'top': 2},
        }),
        isNull,
      );
    });
  });
}
