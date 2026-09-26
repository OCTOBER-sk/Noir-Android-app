// lib/platform/accessibility_status.dart — the app's only view of the platform.
//
// Two things the UI is allowed to know about the accessibility service:
//
//   1. [AccessibilityStatus]  — is the service really connected right now, and
//      is it really allowed to dispatch gestures.
//   2. [ScreenAudit]          — what the A6a Sanitizer actually stripped out of
//      the last real screen dump.
//
// Both are produced by reading [NativeBridge]. Nothing here opens a
// MethodChannel, so no widget can ever reach the platform except through the
// bridge, and `dispatchGesture` stays the only gesture path with PolicyEngine
// in front of it.
//
// Fail-closed posture, applied to both:
//   * a status that cannot be parsed is indistinguishable from a disconnected
//     service — never "ready";
//   * a screen dump that cannot be read is `ScreenAudit.unavailable`, which is
//     a DIFFERENT state from a dump that was read and found clean. An
//     unavailable service must never render as an empty (healthy-looking) log.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../safety/screen_content_sanitizer.dart'
    show SanitizedItem, SanitizedResult;
import 'native_bridge.dart'
    show
        NativeBridge,
        NativeNodeDump,
        kCodeNativeBridgeUnavailable,
        kCodeNodeDumpUnavailable;

/// Wire keys of `MainActivity.currentServiceStatus()` / `AgentAccessibilityService.statusSnapshot()`.
///
/// [kWireGateSource] is present on EVERY reply the platform actually produced.
/// Its absence therefore means the fail-closed stub that
/// [NativeBridge.serviceStatus] substitutes when the channel is dead, which is
/// how a genuine platform answer is told apart from an unreachable one without
/// widening the bridge's public API.
const String kWireServiceConnected = 'serviceConnected';
const String kWireCanPerformGestures = 'canPerformGestures';
const String kWireCanRetrieveWindowContent = 'canRetrieveWindowContent';
const String kWireHasNodeDump = 'hasNodeDump';
const String kWireLastNodeCount = 'lastNodeCount';
const String kWireRuntimeSinkInstalled = 'runtimeSinkInstalled';
const String kWireGateSource = 'gateSource';

/// Immutable snapshot of the live accessibility service.
class AccessibilityStatus {
  /// True when a reply that genuinely came from the platform was parsed.
  final bool platformReachable;

  /// `AgentAccessibilityService.current() != null`.
  final bool connected;

  /// Whether the OS granted the service the gesture capability.
  final bool canPerformGestures;

  /// Whether the OS granted the service window-content retrieval.
  final bool canRetrieveWindowContent;

  /// Whether the service is holding a node dump right now.
  final bool hasNodeDump;

  /// Size of the service's most recent dump, 0 when it has none.
  final int lastNodeCount;

  /// Whether `MainActivity` installed the `screenNodes` push sink.
  final bool runtimeSinkInstalled;

  /// The gate authority the platform reports, for display only.
  final String? gateSource;

  const AccessibilityStatus({
    required this.platformReachable,
    required this.connected,
    required this.canPerformGestures,
    required this.canRetrieveWindowContent,
    required this.hasNodeDump,
    required this.lastNodeCount,
    required this.runtimeSinkInstalled,
    this.gateSource,
  });

  /// Nothing is known. Every capability is off.
  static const AccessibilityStatus unavailable = AccessibilityStatus(
    platformReachable: false,
    connected: false,
    canPerformGestures: false,
    canRetrieveWindowContent: false,
    hasNodeDump: false,
    lastNodeCount: 0,
    runtimeSinkInstalled: false,
  );

  /// Strict, fail-closed decode of a `serviceStatus` reply.
  ///
  /// Only the literal `true` counts as a granted capability, and a reply that
  /// does not carry the platform's own gate marker is discarded entirely.
  factory AccessibilityStatus.fromChannelMap(Map<String, dynamic>? raw) {
    if (raw == null) return unavailable;
    final gateSource = raw[kWireGateSource];
    if (gateSource is! String || gateSource.trim().isEmpty) {
      return unavailable;
    }
    return AccessibilityStatus(
      platformReachable: true,
      connected: raw[kWireServiceConnected] == true,
      canPerformGestures: raw[kWireCanPerformGestures] == true,
      canRetrieveWindowContent: raw[kWireCanRetrieveWindowContent] == true,
      hasNodeDump: raw[kWireHasNodeDump] == true,
      lastNodeCount: _asCount(raw[kWireLastNodeCount]),
      runtimeSinkInstalled: raw[kWireRuntimeSinkInstalled] == true,
      gateSource: gateSource,
    );
  }

  /// The only condition under which a gesture may be attempted. False means the
  /// UI must render every gesture affordance as disabled.
  bool get canDispatchGesture => connected && canPerformGestures;

  /// Whether a screen dump can be expected at all.
  bool get canReadScreen => connected && canRetrieveWindowContent;

  /// Everything is working: the service is live and may act.
  bool get isReady => canDispatchGesture;

  /// One-line state for the header pill. Never says "ready" unless [isReady].
  String get headline {
    if (!platformReachable) return 'Accessibility bridge unavailable';
    if (!connected) return 'Accessibility service not connected';
    if (!canPerformGestures) return 'Accessibility connected — gestures off';
    return 'Accessibility service connected';
  }

  /// What the user can do about [headline], or null when there is nothing to do.
  String? get remedy {
    if (!platformReachable) {
      return 'No platform answer. Noir cannot read the screen or act.';
    }
    if (!connected) {
      return 'Turn on Noir in Settings > Accessibility, then refresh.';
    }
    if (!canPerformGestures) {
      return 'Gestures are off: the service may only observe.';
    }
    return null;
  }
}

/// Loads [AccessibilityStatus] through the bridge and notifies listeners.
///
/// [refresh] never throws and never leaves a stale "ready" state on screen: a
/// thrown channel error resolves to [AccessibilityStatus.unavailable].
class AccessibilityStatusController extends ChangeNotifier {
  AccessibilityStatusController({NativeBridge? bridge})
      : _bridge = bridge ?? NativeBridge.instance;

  final NativeBridge _bridge;

  AccessibilityStatus _status = AccessibilityStatus.unavailable;
  bool _loading = false;
  bool _disposed = false;
  int _requestId = 0;

  AccessibilityStatus get status => _status;

  /// True only between a [refresh] call and its answer.
  bool get isLoading => _loading;

  /// Re-reads the live status. Concurrent calls are safe; a stale answer from
  /// a superseded request is discarded.
  Future<void> refresh() async {
    final token = ++_requestId;
    _setLoading(true);

    Map<String, dynamic>? raw;
    try {
      raw = await _bridge.serviceStatus();
    } catch (_) {
      // NativeBridge.serviceStatus already degrades to a disconnected stub;
      // this keeps the guarantee local to the controller as well.
      raw = null;
    }
    if (_disposed || token != _requestId) return;

    _status = AccessibilityStatus.fromChannelMap(raw);
    _setLoading(false);
  }

  void _setLoading(bool value) {
    if (_disposed || _loading == value) return;
    _loading = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// What the A6a Sanitizer found in one real screen dump.
class ScreenAudit {
  /// False means "no screen data was obtained" — the service was unreachable.
  /// It is never the same thing as a dump that was read and found clean.
  final bool available;

  /// Number of nodes in the dump the audit was derived from.
  final int nodeCount;

  /// Nodes the Sanitizer stripped, with the A6a reason for each.
  final List<SanitizedItem> stripped;

  /// Text that survived the Sanitizer, in dump order.
  final List<String> cleanTextNodes;

  /// Wire-stable reason the dump was unavailable, when [available] is false.
  final String? code;

  const ScreenAudit({
    required this.available,
    required this.nodeCount,
    required this.stripped,
    required this.cleanTextNodes,
    this.code,
  });

  const ScreenAudit.unavailable(String this.code)
      : available = false,
        nodeCount = 0,
        stripped = const <SanitizedItem>[],
        cleanTextNodes = const <String>[];

  int get blockedCount => stripped.length;

  /// The real dump, run through the real deterministic sanitizer.
  static ScreenAudit fromDump(NativeNodeDump dump) {
    final SanitizedResult sanitized = dump.sanitized();
    return ScreenAudit(
      available: true,
      nodeCount: dump.nodes.length,
      stripped: sanitized.stripped,
      cleanTextNodes: sanitized.cleanTextNodes,
    );
  }
}

/// Feeds the Safety Center from the real platform dump.
///
/// Two real sources, both through [NativeBridge]: a pull via `getNodes`, and
/// the push stream the service emits while it is live. Neither can make the
/// audit look healthy when no data arrived.
class ScreenAuditController extends ChangeNotifier {
  ScreenAuditController({
    NativeBridge? bridge,
    bool listenToPushes = true,
  }) : _bridge = bridge ?? NativeBridge.instance {
    if (listenToPushes) {
      _pushes = _bridge.screenNodeDumps.listen(_onPushedDump);
    }
  }

  final NativeBridge _bridge;
  StreamSubscription<List<Map<String, dynamic>>>? _pushes;

  ScreenAudit _audit = const ScreenAudit.unavailable(kCodeNodeDumpUnavailable);
  bool _loading = false;
  bool _disposed = false;
  int _requestId = 0;

  ScreenAudit get audit => _audit;

  /// True only between a [refresh] call and its answer.
  bool get isLoading => _loading;

  /// Pulls a dump from the live service and re-runs the A6a sanitizer over it.
  Future<void> refresh() async {
    final token = ++_requestId;
    _setLoading(true);

    NativeNodeDump dump;
    try {
      dump = await _bridge.getNodes();
    } catch (_) {
      dump = const NativeNodeDump.unavailable(kCodeNativeBridgeUnavailable);
    }
    if (_disposed || token != _requestId) return;

    _audit = dump.available
        ? ScreenAudit.fromDump(dump)
        : ScreenAudit.unavailable(dump.code ?? kCodeNodeDumpUnavailable);
    _setLoading(false);
  }

  /// A dump pushed by the service while it was connected.
  void _onPushedDump(List<Map<String, dynamic>> nodes) {
    if (_disposed) return;
    _requestId++;
    _audit = ScreenAudit.fromDump(
      NativeNodeDump(nodes: nodes, available: true),
    );
    _setLoading(false);
  }

  void _setLoading(bool value) {
    if (_disposed || _loading == value) return;
    _loading = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _requestId++;
    final pushes = _pushes;
    _pushes = null;
    if (pushes != null) {
      unawaited(pushes.cancel());
    }
    super.dispose();
  }
}

int _asCount(Object? raw) {
  if (raw is int) return raw < 0 ? 0 : raw;
  if (raw is double && raw.isFinite && raw >= 0) return raw.toInt();
  return 0;
}
