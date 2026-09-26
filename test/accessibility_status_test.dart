// test/accessibility_status_test.dart — the live view of the platform.
//
// These cover the fail-closed decoding and the two controllers the Safety
// Center and the Command Centre header now read from. The MethodChannel is
// mocked exactly as in test/native_bridge_test.dart, so the real NativeBridge,
// the real PolicyEngine and the real A6a Sanitizer are all exercised.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/platform/accessibility_status.dart';
import 'package:noir_android_app/platform/native_bridge.dart';

const MethodChannel _testChannel = MethodChannel(kNativeChannelName);

/// The exact shape MainActivity.currentServiceStatus() produces for a live
/// service: every key present, including the platform's own gate marker.
Map<String, dynamic> _connectedStatus({
  bool canPerformGestures = true,
  bool canRetrieveWindowContent = true,
  bool hasNodeDump = true,
  int lastNodeCount = 42,
}) {
  return <String, dynamic>{
    'serviceConnected': true,
    'canPerformGestures': canPerformGestures,
    'canRetrieveWindowContent': canRetrieveWindowContent,
    'hasNodeDump': hasNodeDump,
    'lastNodeCount': lastNodeCount,
    'runtimeSinkInstalled': true,
    'gateSource': kGateSource,
  };
}

/// A dump envelope as AgentAccessibilityService.payloadOf() produces it.
Map<String, dynamic> _dumpEnvelope(List<Map<String, dynamic>> nodes) {
  return <String, dynamic>{
    'nodes': nodes,
    'nodeCount': nodes.length,
    'capturedAtMs': 1730000000000,
    'source': 'AgentAccessibilityService',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late NativeBridge bridge;
  late List<MethodCall> received;

  void install(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(_testChannel, (call) async {
      received.add(call);
      return handler(call);
    });
  }

  setUp(() {
    received = <MethodCall>[];
    bridge = NativeBridge();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_testChannel, null);
    await bridge.dispose();
  });

  group('AccessibilityStatus decoding is fail-closed', () {
    test('a null reply is unavailable and never ready', () {
      final status = AccessibilityStatus.fromChannelMap(null);

      expect(status.platformReachable, isFalse);
      expect(status.connected, isFalse);
      expect(status.isReady, isFalse);
      expect(status.canDispatchGesture, isFalse);
      expect(status.headline, 'Accessibility bridge unavailable');
    });

    test('a reply without the platform gate marker is discarded', () {
      // This is the stub NativeBridge.serviceStatus() hands back when the
      // channel is dead. It claims nothing and proves nothing, so a service
      // that says "connected" in it must not be believed.
      final status = AccessibilityStatus.fromChannelMap(<String, dynamic>{
        'serviceConnected': true,
        'canPerformGestures': true,
      });

      expect(status.platformReachable, isFalse);
      expect(status.connected, isFalse);
      expect(status.isReady, isFalse);
      expect(status.remedy, contains('cannot read the screen or act'));
    });

    test('a real connected snapshot reports its granted capabilities', () {
      final status = AccessibilityStatus.fromChannelMap(_connectedStatus());

      expect(status.platformReachable, isTrue);
      expect(status.connected, isTrue);
      expect(status.canPerformGestures, isTrue);
      expect(status.canReadScreen, isTrue);
      expect(status.hasNodeDump, isTrue);
      expect(status.lastNodeCount, 42);
      expect(status.runtimeSinkInstalled, isTrue);
      expect(status.isReady, isTrue);
      expect(status.remedy, isNull);
      expect(status.headline, 'Accessibility service connected');
    });

    test('a connected service without the gesture grant cannot dispatch', () {
      final status = AccessibilityStatus.fromChannelMap(
        _connectedStatus(canPerformGestures: false),
      );

      expect(status.connected, isTrue);
      expect(status.canDispatchGesture, isFalse);
      expect(status.isReady, isFalse);
      expect(status.headline, 'Accessibility connected — gestures off');
      expect(status.remedy, contains('may only observe'));
    });

    test('a reachable but disconnected service says so', () {
      final status = AccessibilityStatus.fromChannelMap(
        _connectedStatus().map((key, value) => MapEntry(key, false))
          ..['lastNodeCount'] = 0
          ..['gateSource'] = kGateSource,
      );

      expect(status.platformReachable, isTrue);
      expect(status.connected, isFalse);
      expect(status.isReady, isFalse);
      expect(status.headline, 'Accessibility service not connected');
      expect(status.remedy, contains('Settings > Accessibility'));
    });

    test('only a literal true counts as a granted capability', () {
      final status = AccessibilityStatus.fromChannelMap(<String, dynamic>{
        'serviceConnected': 'true',
        'canPerformGestures': 1,
        'canRetrieveWindowContent': 'yes',
        'hasNodeDump': null,
        'lastNodeCount': -9,
        'runtimeSinkInstalled': 'true',
        'gateSource': kGateSource,
      });

      expect(status.platformReachable, isTrue);
      expect(status.connected, isFalse);
      expect(status.canPerformGestures, isFalse);
      expect(status.canRetrieveWindowContent, isFalse);
      expect(status.hasNodeDump, isFalse);
      expect(status.runtimeSinkInstalled, isFalse);
      expect(status.lastNodeCount, 0);
    });
  });

  group('AccessibilityStatusController', () {
    test('resolves a connected service to ready', () async {
      install((call) async => _connectedStatus());

      final controller = AccessibilityStatusController(bridge: bridge);
      addTearDown(controller.dispose);
      await controller.refresh();

      expect(controller.isLoading, isFalse);
      expect(controller.status.connected, isTrue);
      expect(controller.status.isReady, isTrue);
      expect(received.single.method, kMethodServiceStatus);
    });

    test('a missing plugin degrades to unavailable without throwing', () async {
      // No mock handler at all: invokeMethod throws MissingPluginException.
      final controller = AccessibilityStatusController(bridge: bridge);
      addTearDown(controller.dispose);

      await expectLater(controller.refresh(), completes);

      expect(controller.status.platformReachable, isFalse);
      expect(controller.status.isReady, isFalse);
      expect(controller.isLoading, isFalse);
    });

    test(
      'a PlatformException degrades to unavailable without throwing',
      () async {
        install(
          (call) async => throw PlatformException(
            code: 'ERR_SERVICE_UNAVAILABLE',
            message: 'AgentAccessibilityService is not connected',
          ),
        );

        final controller = AccessibilityStatusController(bridge: bridge);
        addTearDown(controller.dispose);

        await expectLater(controller.refresh(), completes);

        expect(controller.status.platformReachable, isFalse);
        expect(controller.status.isReady, isFalse);
      },
    );

    test('refresh notifies listeners and the last answer wins', () async {
      var connected = false;
      install(
        (call) async =>
            _connectedStatus().map((key, value) => MapEntry(key, value))
              ..['serviceConnected'] = connected,
      );

      final controller = AccessibilityStatusController(bridge: bridge);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.refresh();
      expect(controller.status.connected, isFalse);

      connected = true;
      await controller.refresh();
      expect(controller.status.connected, isTrue);
      expect(notifications, greaterThanOrEqualTo(2));
    });
  });

  group('ScreenAuditController is fed by the real platform dump', () {
    test(
      'an unreachable service is unavailable, never an empty audit',
      () async {
        install(
          (call) async => throw PlatformException(
            code: 'SERVICE_UNAVAILABLE',
            message: 'not connected',
          ),
        );

        final controller = ScreenAuditController(bridge: bridge);
        addTearDown(controller.dispose);
        await controller.refresh();

        expect(controller.audit.available, isFalse);
        expect(controller.audit.code, 'SERVICE_UNAVAILABLE');
        expect(controller.audit.nodeCount, 0);
        expect(controller.audit.stripped, isEmpty);
      },
    );

    test('a missing plugin keeps the audit unavailable', () async {
      final controller = ScreenAuditController(bridge: bridge);
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.audit.available, isFalse);
      expect(controller.audit.code, kCodeNativeBridgeUnavailable);
    });

    test('a real dump is run through the real A6a sanitizer', () async {
      install(
        (call) async => _dumpEnvelope(<Map<String, dynamic>>[
          <String, dynamic>{'text': 'Inbox', 'alpha': 1.0},
          <String, dynamic>{'text': 'pay the invoice now', 'alpha': 0.0},
        ]),
      );

      final controller = ScreenAuditController(bridge: bridge);
      addTearDown(controller.dispose);
      await controller.refresh();

      final audit = controller.audit;
      expect(audit.available, isTrue);
      expect(audit.nodeCount, 2);
      expect(audit.cleanTextNodes, <String>['Inbox']);
      expect(audit.blockedCount, 1);
      expect(audit.stripped.single.reason.name, 'REASON_ZERO_ALPHA');
      expect(audit.stripped.single.text, 'pay the invoice now');
      expect(received.single.method, kMethodGetNodes);
    });

    test(
      'a dump that was read and found clean is available, not unavailable',
      () async {
        install(
          (call) async => _dumpEnvelope(<Map<String, dynamic>>[
            <String, dynamic>{'text': 'Inbox', 'alpha': 1.0},
          ]),
        );

        final controller = ScreenAuditController(bridge: bridge);
        addTearDown(controller.dispose);
        await controller.refresh();

        expect(controller.audit.available, isTrue);
        expect(controller.audit.code, isNull);
        expect(controller.audit.blockedCount, 0);
        expect(controller.audit.cleanTextNodes, <String>['Inbox']);
      },
    );

    test('a dump pushed by the service updates the audit', () async {
      final controller = ScreenAuditController(bridge: bridge);
      addTearDown(controller.dispose);

      final acknowledged = await bridge.handlePlatformMethod(
        MethodCall(
          kMethodScreenNodes,
          _dumpEnvelope(<Map<String, dynamic>>[
            <String, dynamic>{'text': 'pushed', 'alpha': 1.0},
          ]),
        ),
      );
      expect(acknowledged, 1);

      // The push is delivered on a microtask; let it land.
      await Future<void>.delayed(Duration.zero);

      expect(controller.audit.available, isTrue);
      expect(controller.audit.nodeCount, 1);
      expect(controller.audit.cleanTextNodes, <String>['pushed']);
    });

    test(
      'a controller that does not subscribe to pushes stays pull-only',
      () async {
        final controller = ScreenAuditController(
          bridge: bridge,
          listenToPushes: false,
        );
        addTearDown(controller.dispose);

        await bridge.handlePlatformMethod(
          MethodCall(
            kMethodScreenNodes,
            _dumpEnvelope(<Map<String, dynamic>>[
              <String, dynamic>{'text': 'pushed', 'alpha': 1.0},
            ]),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.audit.available, isFalse);
      },
    );
  });
}
