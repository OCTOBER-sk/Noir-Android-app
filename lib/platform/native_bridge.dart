// lib/platform/native_bridge.dart — C1/C2 real Dart <-> Kotlin bridge.
//
// One MethodChannel, "com.noir.android/channel", carries both directions:
//
//   Dart -> platform : getNodes, dispatchGesture, serviceStatus
//   platform -> Dart : policyGate, screenNodes
//
// Security invariant (C2): the ONLY policy authority is PolicyEngine in
// lib/safety/policy_engine.dart. There is no Kotlin copy of any rule. The
// platform never decides on its own — it calls back into `policyGate` on this
// same channel and only dispatches a gesture when Dart answers with an
// explicit `allowed: true` verdict. Missing, malformed, late or errored
// replies all fail closed.
import 'dart:async';

import 'package:flutter/services.dart';

import '../safety/policy_engine.dart' show GateResult, PolicyEngine;
import '../safety/risk_classifier.dart' show RiskClassifier, RiskLevel;
import '../safety/screen_content_sanitizer.dart'
    show SanitizedResult, Sanitizer;

/// Channel name, identical to MainActivity.kt `CHANNEL`.
const String kNativeChannelName = 'com.noir.android/channel';

/// Methods invoked on the platform (MainActivity.kt).
const String kMethodGetNodes = 'getNodes';
const String kMethodDispatchGesture = 'dispatchGesture';
const String kMethodServiceStatus = 'serviceStatus';

/// Methods the platform invokes back on this bridge.
const String kMethodPolicyGate = 'policyGate';
const String kMethodScreenNodes = 'screenNodes';

/// Identifies the verdict source so a log line can never be mistaken for a
/// locally invented decision.
const String kGateSource = 'dart:lib/safety/policy_engine.dart';

// Block reasons produced on the Dart side. These are wire-stable identifiers:
// the Kotlin side surfaces them verbatim as PlatformException codes.
const String kCodeConfirmationRequired = 'CONFIRMATION_REQUIRED';
const String kCodeMalformedGateRequest = 'MALFORMED_GATE_REQUEST';
const String kCodeMalformedGestureTarget = 'MALFORMED_GESTURE_TARGET';
const String kCodeNativeBridgeUnavailable = 'NATIVE_BRIDGE_UNAVAILABLE';
const String kCodeNativeDispatchFailed = 'NATIVE_DISPATCH_FAILED';
const String kCodePolicyGateUnreachable = 'POLICY_GATE_UNREACHABLE';
const String kCodeNodeDumpUnavailable = 'NODE_DUMP_UNAVAILABLE';

/// Screen rectangle of a gesture target, as reported by
/// AgentAccessibilityService (`getBoundsInScreen`).
class GestureBounds {
  final int left;
  final int top;
  final int right;
  final int bottom;

  const GestureBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get centerX => (left + right) / 2.0;
  double get centerY => (top + bottom) / 2.0;

  bool get isEmpty => right <= left || bottom <= top;

  /// A gesture point must land inside the display, otherwise the tap is
  /// silently dropped by the framework.
  bool get hasOnScreenCenter => centerX >= 0 && centerY >= 0 && !isEmpty;

  Map<String, dynamic> toChannelMap() => <String, dynamic>{
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  /// Reads a rectangle out of an AgentAccessibilityService node dump.
  /// `screenBounds` wins because `dispatchGesture` works in screen
  /// coordinates, while `bounds` is parent-relative.
  static GestureBounds? fromNode(Map<String, dynamic> node) {
    final raw = _asIntMap(node['screenBounds']) ?? _asIntMap(node['bounds']);
    if (raw == null) return null;
    final left = raw['left'];
    final top = raw['top'];
    final right = raw['right'];
    final bottom = raw['bottom'];
    if (left == null || top == null || right == null || bottom == null) {
      return null;
    }
    return GestureBounds(left: left, top: top, right: right, bottom: bottom);
  }
}

/// The Dart PolicyEngine's answer, in the shape the platform requires.
class NativeGateVerdict {
  final bool allowed;
  final String message;
  final bool needsBiometric;
  final int riskLevel;

  const NativeGateVerdict({
    required this.allowed,
    required this.message,
    this.needsBiometric = false,
    this.riskLevel = 0,
  });

  const NativeGateVerdict.blocked(
    this.message, {
    this.riskLevel = 0,
    this.needsBiometric = false,
  }) : allowed = false;

  /// Wraps a real `GateResult` without re-deriving any of its fields.
  factory NativeGateVerdict.fromGateResult(
    GateResult result, {
    int riskLevel = 0,
  }) {
    return NativeGateVerdict(
      allowed: result.allowed,
      message: result.message,
      needsBiometric: result.needsBiometric,
      riskLevel: riskLevel,
    );
  }

  Map<String, dynamic> toChannelMap() => <String, dynamic>{
    'allowed': allowed,
    'message': message,
    'needsBiometric': needsBiometric,
    'riskLevel': riskLevel,
    'source': kGateSource,
  };

  /// Strict decoder. Anything unexpected is `null` so callers can fail closed
  /// rather than guess.
  static NativeGateVerdict? fromChannelMap(Object? raw) {
    final map = _asMap(raw);
    if (map == null) return null;
    final allowed = map['allowed'];
    final message = map['message'];
    final needsBiometric = map['needsBiometric'];
    final riskLevel = map['riskLevel'];
    if (allowed is! bool || message is! String || needsBiometric is! bool) {
      return null;
    }
    if (message.trim().isEmpty) return null;
    // The standard MethodChannel codec hands back Int/Long/Double
    // interchangeably, so an integral `riskLevel` is accepted at whatever width
    // it arrives in — this mirrors `GateVerdict.decode` in GateVerdict.kt, and
    // the two decoders claiming the same wire format must agree. A Double that
    // is not integral is still rejected, so this widens the accepted numeric
    // width without ever accepting a fractional or non-numeric risk level.
    if (riskLevel is! num) return null;
    if (riskLevel is double && riskLevel != riskLevel.roundToDouble()) {
      return null;
    }
    if (riskLevel.isNaN || riskLevel.isInfinite) return null;
    return NativeGateVerdict(
      allowed: allowed,
      message: message,
      needsBiometric: needsBiometric,
      riskLevel: riskLevel.toInt(),
    );
  }
}

/// Result of a `dispatchGesture` request. `executed` is the only field that
/// may be trusted to mean "a gesture actually reached the accessibility
/// service".
class NativeGestureOutcome {
  final bool executed;
  final NativeGateVerdict verdict;
  final String? platformCode;
  final Map<String, dynamic> receipt;

  const NativeGestureOutcome({
    required this.executed,
    required this.verdict,
    this.platformCode,
    this.receipt = const <String, dynamic>{},
  });

  factory NativeGestureOutcome.blocked(
    NativeGateVerdict verdict, {
    String? platformCode,
    Map<String, dynamic> receipt = const <String, dynamic>{},
  }) {
    return NativeGestureOutcome(
      executed: false,
      verdict: verdict,
      platformCode: platformCode,
      receipt: receipt,
    );
  }

  /// Block reason: the PolicyEngine message when there is one, otherwise the
  /// platform error code, otherwise a generic fail-closed identifier.
  String get blockReason {
    if (verdict.allowed) return kCodeNativeDispatchFailed;
    final code = platformCode;
    if (code != null && code.trim().isNotEmpty) return code;
    return verdict.message;
  }
}

/// Result of a `getNodes` request. `available` is false when the accessibility
/// service is not connected, which the caller must treat as "no screen data",
/// never as "screen is empty".
class NativeNodeDump {
  final List<Map<String, dynamic>> nodes;
  final bool available;
  final String? code;

  const NativeNodeDump({
    required this.nodes,
    required this.available,
    this.code,
  });

  const NativeNodeDump.unavailable(String this.code)
    : nodes = const <Map<String, dynamic>>[],
      available = false;

  bool get isEmpty => nodes.isEmpty;

  /// Feeds the raw dump through the deterministic A6a sanitizer.
  SanitizedResult sanitized() => Sanitizer.sanitize(nodes);
}

/// Typed wrapper over the platform channel.
class NativeBridge {
  NativeBridge({
    MethodChannel? channel,
    PolicyEngine? policyEngine,
    RiskClassifier? riskClassifier,
  }) : _channel = channel ?? const MethodChannel(kNativeChannelName),
       _policyEngine = policyEngine ?? PolicyEngine(),
       _riskClassifier = riskClassifier ?? RiskClassifier() {
    _channel.setMethodCallHandler(handlePlatformMethod);
  }

  /// Lazily created shared instance for app wiring. Tests construct their own.
  static NativeBridge? _shared;

  static NativeBridge get instance => _shared ??= NativeBridge();

  final MethodChannel _channel;
  final PolicyEngine _policyEngine;
  final RiskClassifier _riskClassifier;

  final StreamController<List<Map<String, dynamic>>> _nodeDumps =
      StreamController<List<Map<String, dynamic>>>.broadcast();

  /// The engine this bridge answers `policyGate` with.
  ///
  /// Exposed so an object graph can adopt the *bridge's* engine rather than
  /// building a second one. Two PolicyEngine instances in one process is a
  /// split authority: the platform would be gated by one set of rules and the
  /// pipeline by another, and a UI lock set on one would not apply to the
  /// other. Whoever wires a bridge in is expected to use this instance.
  PolicyEngine get policyEngine => _policyEngine;

  /// The classifier this bridge scores every proposal with.
  RiskClassifier get riskClassifier => _riskClassifier;

  bool _disposed = false;
  int _gestureSequence = 0;

  /// Node dumps pushed by AgentAccessibilityService via `screenNodes`.
  Stream<List<Map<String, dynamic>>> get screenNodeDumps => _nodeDumps.stream;

  bool get isDisposed => _disposed;

  /// The platform's re-entrant gate call lands here. Kept public and free of
  /// any messenger internals so it is directly testable.
  Future<Object?> handlePlatformMethod(MethodCall call) async {
    switch (call.method) {
      case kMethodPolicyGate:
        final verdict = await evaluateGate(call.arguments);
        return verdict.toChannelMap();
      case kMethodScreenNodes:
        return _ingestScreenNodes(call.arguments);
      default:
        throw MissingPluginException(
          'NativeBridge received an unknown platform call: ${call.method}',
        );
    }
  }

  /// Authoritative gate used by the platform's re-entrant `policyGate` call.
  ///
  /// The risk level is ALWAYS recomputed here with the Dart RiskClassifier.
  /// A riskLevel supplied by the platform is deliberately ignored, so the
  /// native side cannot downgrade a HIGH_RISK action to "no biometric".
  Future<NativeGateVerdict> evaluateGate(Object? rawArguments) async {
    final arguments = _asMap(rawArguments);
    if (arguments == null) {
      return const NativeGateVerdict.blocked(kCodeMalformedGateRequest);
    }
    final proposal = _asMap(arguments['proposal']);
    if (proposal == null) {
      return const NativeGateVerdict.blocked(kCodeMalformedGateRequest);
    }

    final RiskLevel risk = await _classify(proposal);
    final GateResult result = _policyEngine.gate(
      proposal,
      riskLevel: risk.level,
    );

    if (!result.allowed) {
      return NativeGateVerdict.fromGateResult(result, riskLevel: risk.level);
    }

    // PolicyEngine always asks for confirmation on a non-blocked action. The
    // gate only clears once the human/biometric step has actually happened
    // (the same requirement AgentRuntimePipeline enforces via Gate.check).
    if (arguments['confirmed'] != true) {
      return NativeGateVerdict.blocked(
        kCodeConfirmationRequired,
        riskLevel: risk.level,
        needsBiometric: result.needsBiometric,
      );
    }

    return NativeGateVerdict.fromGateResult(result, riskLevel: risk.level);
  }

  /// Full screen node dump from the live AgentAccessibilityService.
  ///
  /// The platform replies with the envelope produced by
  /// `AgentAccessibilityService.payloadOf` (`{nodes, nodeCount, capturedAtMs,
  /// source}`); a reply that is not that shape is reported as unavailable.
  Future<NativeNodeDump> getNodes() async {
    try {
      final reply = await _channel.invokeMapMethod<String, dynamic>(
        kMethodGetNodes,
      );
      final raw = reply?['nodes'];
      if (raw is! List) {
        return const NativeNodeDump.unavailable(kCodeNodeDumpUnavailable);
      }
      final nodes = <Map<String, dynamic>>[];
      for (final entry in raw) {
        final node = _asMap(entry);
        if (node != null) nodes.add(node);
      }
      return NativeNodeDump(nodes: nodes, available: true);
    } on MissingPluginException {
      return const NativeNodeDump.unavailable(kCodeNativeBridgeUnavailable);
    } on PlatformException catch (error) {
      return NativeNodeDump.unavailable(
        _codeOf(error, kCodeNodeDumpUnavailable),
      );
    }
  }

  /// Screen dump plus the A6a sanitizer verdict in one call.
  Future<SanitizedResult> getSanitizedNodes() async {
    final dump = await getNodes();
    return dump.sanitized();
  }

  /// Connectivity of the platform half of the bridge.
  Future<Map<String, dynamic>> serviceStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        kMethodServiceStatus,
      );
      return raw ?? const <String, dynamic>{};
    } on MissingPluginException {
      return const <String, dynamic>{'serviceConnected': false};
    } on PlatformException {
      return const <String, dynamic>{'serviceConnected': false};
    }
  }

  /// Gate-then-dispatch. The Dart PolicyEngine runs first, so a blocked
  /// action never reaches the platform at all, and the platform independently
  /// re-verifies through [evaluateGate] before touching the screen.
  ///
  /// [confirmed] must only be true once the user's confirmation/biometric
  /// prompt has been satisfied.
  Future<NativeGestureOutcome> dispatchGesture({
    required Map<String, dynamic> proposal,
    GestureBounds? bounds,
    bool confirmed = false,
  }) async {
    final RiskLevel risk = await _classify(proposal);
    final GateResult result = _policyEngine.gate(
      proposal,
      riskLevel: risk.level,
    );
    final NativeGateVerdict verdict = NativeGateVerdict.fromGateResult(
      result,
      riskLevel: risk.level,
    );

    if (!verdict.allowed) {
      return NativeGestureOutcome.blocked(verdict);
    }
    if (!confirmed) {
      return NativeGestureOutcome.blocked(
        NativeGateVerdict.blocked(
          kCodeConfirmationRequired,
          riskLevel: risk.level,
          needsBiometric: result.needsBiometric,
        ),
      );
    }
    if (bounds == null || !bounds.hasOnScreenCenter) {
      return NativeGestureOutcome.blocked(
        NativeGateVerdict.blocked(
          kCodeMalformedGestureTarget,
          riskLevel: risk.level,
        ),
      );
    }

    _gestureSequence++;
    final Map<String, dynamic> payload = <String, dynamic>{
      'proposal': proposal,
      'bounds': bounds.toChannelMap(),
      'riskLevel': risk.level,
      'confirmed': confirmed,
      'gateRequestId': 'gate-$_gestureSequence',
    };

    try {
      final reply = await _channel.invokeMapMethod<String, dynamic>(
        kMethodDispatchGesture,
        payload,
      );
      if (reply == null || reply['executed'] != true) {
        // The platform answered without confirming execution. Fail closed.
        return NativeGestureOutcome.blocked(
          NativeGateVerdict.blocked(
            kCodeNativeDispatchFailed,
            riskLevel: risk.level,
          ),
          platformCode: kCodeNativeDispatchFailed,
          receipt: reply ?? const <String, dynamic>{},
        );
      }
      return NativeGestureOutcome(
        executed: true,
        verdict: verdict,
        receipt: reply,
      );
    } on MissingPluginException {
      // No native handler at all (host-only run, desktop, or the Kotlin side
      // was never registered). Fail closed — never report success.
      return NativeGestureOutcome.blocked(
        const NativeGateVerdict.blocked(kCodeNativeBridgeUnavailable),
        platformCode: kCodeNativeBridgeUnavailable,
      );
    } on PlatformException catch (error) {
      return NativeGestureOutcome.blocked(
        NativeGateVerdict.blocked(
          _codeOf(error, kCodeNativeDispatchFailed),
          riskLevel: risk.level,
        ),
        platformCode: _codeOf(error, kCodeNativeDispatchFailed),
      );
    }
  }

  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    _disposed = true;
    _channel.setMethodCallHandler(null);
    return _nodeDumps.close();
  }

  Future<RiskLevel> _classify(Map<String, dynamic> proposal) async {
    try {
      return await _riskClassifier.classify(proposal);
    } catch (_) {
      // Classification failure must never look like a low-risk action.
      return RiskLevel(level: 3);
    }
  }

  Object? _ingestScreenNodes(Object? raw) {
    final map = _asMap(raw);
    if (map == null) return false;
    final rawNodes = map['nodes'];
    if (rawNodes is! List) return false;
    final nodes = <Map<String, dynamic>>[];
    for (final entry in rawNodes) {
      final node = _asMap(entry);
      if (node != null) nodes.add(node);
    }
    if (_disposed) return false;
    _nodeDumps.add(List<Map<String, dynamic>>.unmodifiable(nodes));
    return nodes.length;
  }
}

String _codeOf(PlatformException error, String fallback) {
  final code = error.code.trim();
  return code.isEmpty ? fallback : code;
}

Map<String, dynamic>? _asMap(Object? raw) {
  if (raw is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is String) result[key] = entry.value;
  }
  return result;
}

Map<String, int>? _asIntMap(Object? raw) {
  final map = _asMap(raw);
  if (map == null) return null;
  final result = <String, int>{};
  for (final entry in map.entries) {
    final value = entry.value;
    if (value is int) {
      result[entry.key] = value;
    } else if (value is double) {
      result[entry.key] = value.toInt();
    } else if (value is num) {
      result[entry.key] = value.toInt();
    }
  }
  return result;
}
