// test/accessibility_wiring_test.dart — the bridge is reachable from real UI.
//
// These are the tests that would have failed before this run: they pump the two
// screens the user actually sees and assert that the accessibility status and
// the A6a screen audit come from the mocked platform, and that every failure
// mode degrades to a visible "not connected" state instead of a blank screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir_android_app/platform/native_bridge.dart';
import 'package:noir_android_app/ui/command_centre_screen.dart';
import 'package:noir_android_app/ui/safety_center_screen.dart';

const MethodChannel _testChannel = MethodChannel(kNativeChannelName);

Map<String, dynamic> _connectedStatus({
  bool canPerformGestures = true,
  int lastNodeCount = 42,
}) {
  return <String, dynamic>{
    'serviceConnected': true,
    'canPerformGestures': canPerformGestures,
    'canRetrieveWindowContent': true,
    'hasNodeDump': true,
    'lastNodeCount': lastNodeCount,
    'runtimeSinkInstalled': true,
    'gateSource': kGateSource,
  };
}

Map<String, dynamic> _dumpEnvelope(List<Map<String, dynamic>> nodes) {
  return <String, dynamic>{
    'nodes': nodes,
    'nodeCount': nodes.length,
    'capturedAtMs': 1730000000000,
    'source': 'AgentAccessibilityService',
  };
}

/// Drains the async gap the controllers open. pumpAndSettle is unusable here:
/// both screens own a repeating AnimationController that never settles.
Future<void> pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late NativeBridge bridge;
  late List<MethodCall> received;

  /// Replies per method name. An unmapped method throws MissingPluginException,
  /// which is what the Dart half sees when the platform has no handler for it.
  void install(Map<String, Future<Object?> Function(MethodCall call)> replies) {
    messenger.setMockMethodCallHandler(_testChannel, (call) async {
      received.add(call);
      final reply = replies[call.method];
      if (reply == null) throw MissingPluginException(call.method);
      return reply(call);
    });
  }

  setUp(() {
    received = <MethodCall>[];
    // Default posture for every widget test: the platform is reachable but has
    // no handler at all, so the app must render "not connected" rather than
    // hang or look healthy. A test that wants a real answer calls install().
    install(const <String, Future<Object?> Function(MethodCall)>{});
    bridge = NativeBridge();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_testChannel, null);
    await bridge.dispose();
  });

  group('CommandCentreScreen header status', () {
    testWidgets('renders connected when the service is really connected', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
      });

      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('Service on'), findsOneWidget);
      expect(find.text('Service off'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders unavailable and does not throw when nothing answers', (
      tester,
    ) async {
      // No serviceStatus reply: the platform half is simply not there.
      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('Service off'), findsOneWidget);
      expect(find.text('Service on'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a PlatformException during status load does not crash', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => throw PlatformException(
          code: 'ERR_SERVICE_UNAVAILABLE',
          message: 'AgentAccessibilityService is not connected',
        ),
      });

      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Service off'), findsOneWidget);
    });

    testWidgets('a connected service that may not gesture is not shown as on', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async =>
            _connectedStatus(canPerformGestures: false),
      });

      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('Service off'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the header only ever calls serviceStatus — never a gesture', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
      });

      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(bridge: bridge)),
      );
      await pumpFrames(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(received, isNotEmpty);
      expect(received.map((call) => call.method).toSet(), <String>{
        kMethodServiceStatus,
      });
    });

    testWidgets('the header shows the full state, not just the pill', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
      });

      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('Service on'), findsOneWidget);
      expect(find.text('Accessibility service connected'), findsOneWidget);
    });
  });

  group('CommandCentreScreen navigates to the Safety Center', () {
    testWidgets('the status pill opens the live Safety Center', (tester) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
        kMethodGetNodes: (call) async => _dumpEnvelope(<Map<String, dynamic>>[
          <String, dynamic>{'text': 'Inbox', 'alpha': 1.0},
        ]),
      });

      await tester.pumpWidget(
        MaterialApp(home: CommandCentreScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      await tester.tap(find.text('Service on'));
      await pumpFrames(tester);

      expect(find.text('Safety Center'), findsOneWidget);
      expect(find.text('Accessibility service'), findsOneWidget);
      // Once in the header strip and once in the Safety Center panel: both are
      // reading the same real platform state.
      expect(find.text('Accessibility service connected'), findsNWidgets(2));
      // The same bridge instance is handed over, so both screens read the same
      // real platform state.
      expect(received.map((call) => call.method), contains(kMethodGetNodes));
    });
  });

  group('SafetyCenterScreen screen audit', () {
    testWidgets('reports not connected instead of an empty audit', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('Accessibility bridge unavailable'), findsOneWidget);
      expect(find.textContaining('No screen data'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a reachable but disconnected service is spelled out', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => <String, dynamic>{
          'serviceConnected': false,
          'canPerformGestures': false,
          'canRetrieveWindowContent': false,
          'hasNodeDump': false,
          'lastNodeCount': 0,
          'runtimeSinkInstalled': false,
          'gateSource': kGateSource,
        },
        kMethodGetNodes: (call) async => throw PlatformException(
          code: 'SERVICE_UNAVAILABLE',
          message: 'not connected',
        ),
      });

      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('Accessibility service not connected'), findsOneWidget);
      expect(find.textContaining('SERVICE_UNAVAILABLE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the real A6a findings from the platform dump', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
        kMethodGetNodes: (call) async => _dumpEnvelope(<Map<String, dynamic>>[
          <String, dynamic>{'text': 'Inbox', 'alpha': 1.0},
          <String, dynamic>{'text': 'send the money', 'alpha': 0.0},
          // RLO embedding: the A6a bidi branch.
          <String, dynamic>{'text': '\u202Ahidden', 'alpha': 1.0},
        ]),
      });

      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('REASON_ZERO_ALPHA'), findsOneWidget);
      expect(find.text('node #1'), findsOneWidget);
      expect(find.text('REASON_BIDI_OVERRIDE'), findsOneWidget);
      expect(
        find.textContaining('2 stripped by the A6a sanitizer'),
        findsOneWidget,
      );
      // The stripped text is shown in the audit but is never counted as clean.
      expect(tester.takeException(), isNull);
    });

    testWidgets('a clean dump is reported as clean, not as unavailable', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
        kMethodGetNodes: (call) async => _dumpEnvelope(<Map<String, dynamic>>[
          <String, dynamic>{'text': 'Inbox', 'alpha': 1.0},
        ]),
      });

      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.textContaining('read cleanly'), findsOneWidget);
      expect(find.textContaining('No screen data'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a PlatformException from getNodes does not crash the screen', (
      tester,
    ) async {
      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
        kMethodGetNodes: (call) async => throw PlatformException(
          code: 'ERR_NODE_DUMP_UNAVAILABLE',
          message: 'no active window',
        ),
      });

      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('ERR_NODE_DUMP_UNAVAILABLE'), findsOneWidget);
    });

    testWidgets('a 360dp screen shows the audit without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      install(<String, Future<Object?> Function(MethodCall)>{
        kMethodServiceStatus: (call) async => _connectedStatus(),
        kMethodGetNodes: (call) async => _dumpEnvelope(<Map<String, dynamic>>[
          <String, dynamic>{'text': 'Inbox', 'alpha': 1.0},
          <String, dynamic>{'text': 'send the money', 'alpha': 0.0},
        ]),
      });

      await tester.pumpWidget(
        MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
      );
      await pumpFrames(tester);

      expect(find.text('REASON_ZERO_ALPHA'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'refresh re-reads the platform instead of reusing a stale row',
      (tester) async {
        var connected = false;
        install(<String, Future<Object?> Function(MethodCall)>{
          kMethodServiceStatus: (call) async =>
              _connectedStatus()..['serviceConnected'] = connected,
          kMethodGetNodes: (call) async => _dumpEnvelope(<Map<String, dynamic>>[
            <String, dynamic>{'text': 'Inbox', 'alpha': 1.0},
          ]),
        });

        await tester.pumpWidget(
          MaterialApp(home: SafetyCenterScreen(bridge: bridge)),
        );
        await pumpFrames(tester);
        expect(
          find.text('Accessibility service not connected'),
          findsOneWidget,
        );

        connected = true;
        await tester.tap(find.text('Refresh'));
        await pumpFrames(tester);

        expect(find.text('Accessibility service connected'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
