// android/app/src/main/kotlin/com/noir/android/MainActivity.kt — C2 (REAL PolicyEngine gate)
//
// The platform half of lib/platform/native_bridge.dart. Three responsibilities:
//
//   1. Serve read-only queries (getNodes, serviceStatus) from the live
//      AgentAccessibilityService.
//   2. Own the C2 invariant: NO gesture is dispatched unless the Dart
//      PolicyEngine has explicitly answered `allowed: true` on the same
//      MethodChannel. There are no policy rules in this file — the only field
//      that steers execution is a boolean produced by
//      lib/safety/policy_engine.dart. Unreachable, malformed, late or errored
//      gate replies all fail closed.
//   3. Turn a cleared gate into a real AccessibilityService.dispatchGesture.
package com.noir.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

  private lateinit var channel: MethodChannel
  private val mainHandler = Handler(Looper.getMainLooper())

  override fun configureFlutterEngine(engine: FlutterEngine) {
    super.configureFlutterEngine(engine)
    channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
    channel.setMethodCallHandler { call, result -> onMethodCall(call, result) }

    // C1: an AccessibilityService holds no FlutterEngine reference, so
    // MainActivity installs the sink that AgentAccessibilityService
    // .sendToRuntime pushes node dumps into. It is torn down in
    // cleanUpFlutterEngine so a dead engine is never called back into.
    AgentAccessibilityService.runtimeSink = ScreenNodeSink { payload ->
      runOnUiThread {
        if (!isFinishing && !isDestroyed) {
          try {
            channel.invokeMethod(METHOD_SCREEN_NODES, payload)
          } catch (t: Throwable) {
            Log.w(TAG, "screenNodes push failed: ${t.javaClass.simpleName}")
          }
        }
      }
    }
  }

  override fun cleanUpFlutterEngine(engine: FlutterEngine) {
    AgentAccessibilityService.runtimeSink = null
    if (::channel.isInitialized) {
      channel.setMethodCallHandler(null)
    }
    super.cleanUpFlutterEngine(engine)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      METHOD_GET_NODES -> handleGetNodes(result)
      METHOD_SERVICE_STATUS -> result.success(currentServiceStatus())
      METHOD_DISPATCH_GESTURE -> handleDispatchGesture(call, result)
      else -> result.notImplemented()
    }
  }

  // ---- C1: screen node dump -------------------------------------------------

  private fun handleGetNodes(result: MethodChannel.Result) {
    val service = AgentAccessibilityService.current()
    if (service == null) {
      result.error(ERR_SERVICE_UNAVAILABLE, "AgentAccessibilityService is not connected; enable it in Settings > Accessibility", null)
      return
    }
    // captureNow() walks the live tree on this (platform/main) thread.
    val nodes = service.captureNow()
    if (nodes == null) {
      result.error(ERR_NODE_DUMP_UNAVAILABLE, "no active window available to dump", null)
      return
    }
    result.success(AgentAccessibilityService.payloadOf(nodes))
  }

  private fun currentServiceStatus(): Map<String, Any?> {
    val service = AgentAccessibilityService.current()
    val status = LinkedHashMap<String, Any?>()
    if (service == null) {
      status["serviceConnected"] = false
      status["canPerformGestures"] = false
      status["canRetrieveWindowContent"] = false
      status["hasNodeDump"] = false
      status["lastNodeCount"] = 0
    } else {
      status.putAll(service.statusSnapshot())
    }
    status["runtimeSinkInstalled"] = AgentAccessibilityService.runtimeSink != null
    status["gateSource"] = GATE_SOURCE
    return status
  }

  // ---- C2: gate, then dispatch ---------------------------------------------

  private fun handleDispatchGesture(call: MethodCall, result: MethodChannel.Result) {
    // C2: EVERY dispatchGesture must pass the PolicyEngine gate before
    // execution. Any code path that reaches executeGesture() without a
    // cleared Dart verdict is a release-blocking regression.
    val proposal = call.argument<Map<*, *>>("proposal")
    if (proposal == null) {
      result.error(ERR_MALFORMED_GESTURE_REQUEST, "proposal is required", null)
      return
    }
    val bounds = call.argument<Map<*, *>>("bounds")
    if (bounds == null) {
      result.error(ERR_MALFORMED_GESTURE_REQUEST, "bounds are required", null)
      return
    }

    val gateRequestId = call.argument<String>("gateRequestId") ?: "unidentified"
    val confirmed = call.argument<Boolean>("confirmed") ?: false
    val settled = AtomicBoolean(false)

    val timeout = Runnable {
      if (settled.compareAndSet(false, true)) {
        result.error(
          ERR_POLICY_GATE_UNREACHABLE,
          "Dart PolicyEngine did not answer gate request $gateRequestId within ${GATE_TIMEOUT_MS}ms; failing closed",
          null
        )
      }
    }
    mainHandler.postDelayed(timeout, GATE_TIMEOUT_MS)

    try {
      // Re-entrant call into the Dart isolate. The Dart side is awaiting this
      // dispatch, so its isolate is free to answer. riskLevel is deliberately
      // NOT forwarded: Dart re-derives it with the authoritative RiskClassifier.
      channel.invokeMethod(
        METHOD_POLICY_GATE,
        mapOf(
          "proposal" to proposal,
          "bounds" to bounds,
          "gateRequestId" to gateRequestId,
          "confirmed" to confirmed
        ),
        object : MethodChannel.Result {
          override fun success(reply: Any?) {
            if (!settled.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeout)
            val verdict = GateVerdict.decode(reply)
            if (verdict == null) {
              // Fail closed: an undecodable reply is not an allow.
              result.error(ERR_POLICY_GATE_MALFORMED, "gate reply for $gateRequestId was not a GateVerdict", null)
              return
            }
            if (!verdict.allowed) {
              result.error(ERR_POLICY_BLOCKED, "PolicyEngine blocked: ${verdict.message}", verdict.toMap())
              return
            }
            Log.i(TAG, "gate cleared for $gateRequestId (risk=${verdict.riskLevel}, biometric=${verdict.needsBiometric})")
            executeGesture(bounds, verdict, result)
          }

          override fun error(code: String, message: String?, details: Any?) {
            if (!settled.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeout)
            result.error(ERR_POLICY_GATE_UNREACHABLE, "Dart PolicyEngine gate failed ($code): $message", null)
          }

          override fun notImplemented() {
            if (!settled.compareAndSet(false, true)) return
            mainHandler.removeCallbacks(timeout)
            result.error(ERR_POLICY_GATE_UNREACHABLE, "Dart PolicyEngine gate is not implemented; failing closed", null)
          }
        }
      )
    } catch (t: Throwable) {
      if (settled.compareAndSet(false, true)) {
        mainHandler.removeCallbacks(timeout)
        result.error(ERR_POLICY_GATE_UNREACHABLE, "gate request for $gateRequestId threw ${t.javaClass.simpleName}", null)
      }
    }
  }

  /**
   * Builds a real [android.accessibilityservice.GestureDescription] (Path +
   * StrokeDescription) from the proposal bounds and hands it to the live
   * AccessibilityService. This path is ONLY reachable after the Dart
   * PolicyEngine gate has cleared (C2).
   */
  private fun executeGesture(
    bounds: Map<*, *>,
    verdict: GateVerdict,
    result: MethodChannel.Result
  ) {
    val service = AgentAccessibilityService.current()
    if (service == null) {
      result.error(ERR_SERVICE_UNAVAILABLE, "AgentAccessibilityService is not connected", null)
      return
    }
    // dispatchGesture must be issued from the main looper.
    if (Looper.myLooper() != Looper.getMainLooper()) {
      result.error(ERR_WRONG_THREAD, "dispatchGesture must be requested on the main looper", null)
      return
    }
    val rect = rectOf(bounds)
    if (rect == null) {
      result.error(ERR_MALFORMED_GESTURE_TARGET, "bounds are not a rectangle: $bounds", null)
      return
    }
    if (rect.isEmpty) {
      result.error(ERR_EMPTY_GESTURE_TARGET, "gesture target has no area: $rect", null)
      return
    }
    val x = (rect.left + rect.right) / 2f
    val y = (rect.top + rect.bottom) / 2f
    if (x < 0f || y < 0f) {
      result.error(ERR_MALFORMED_GESTURE_TARGET, "gesture target is off display at ($x, $y)", null)
      return
    }

    val path = Path().apply {
      moveTo(x, y)
      lineTo(x, y)
    }
    val stroke = GestureDescription.StrokeDescription(path, 0L, TAP_DURATION_MS)
    val gesture = GestureDescription.Builder()
      .addStroke(stroke)
      .build()

    val accepted = try {
      service.dispatchGestureNow(gesture, object : AccessibilityService.GestureResultCallback() {
        override fun onCompleted(description: GestureDescription?) {
          result.success(
            mapOf(
              "executed" to true,
              "gesture" to "tap",
              "x" to x.toDouble(),
              "y" to y.toDouble(),
              "durationMs" to TAP_DURATION_MS,
              "riskLevel" to verdict.riskLevel,
              "gateSource" to GATE_SOURCE,
              "gateMessage" to verdict.message
            )
          )
        }

        override fun onCancelled(description: GestureDescription?) {
          result.error(ERR_GESTURE_CANCELLED, "system cancelled the gesture at ($x, $y)", null)
        }
      })
    } catch (t: Throwable) {
      Log.e(TAG, "dispatchGesture threw ${t.javaClass.simpleName}", t)
      false
    }

    if (!accepted) {
      result.error(ERR_GESTURE_DISPATCH_REJECTED, "AccessibilityService refused the gesture at ($x, $y)", null)
    }
  }

  private fun rectOf(bounds: Map<*, *>): Rect? {
    val left = intOf(bounds["left"]) ?: return null
    val top = intOf(bounds["top"]) ?: return null
    val right = intOf(bounds["right"]) ?: return null
    val bottom = intOf(bounds["bottom"]) ?: return null
    if (right < left || bottom < top) return null
    return Rect(left, top, right, bottom)
  }

  private fun intOf(raw: Any?): Int? = (raw as? Number)?.toInt()

  /**
   * Structural decoding of the Dart GateVerdict.
   *
   * This class intentionally contains NO policy rules. Its only steering field
   * is `allowed`, and that boolean is produced by PolicyEngine in
   * lib/safety/policy_engine.dart. Every other field is decoded defensively so
   * that a partial or wrong-typed reply yields null, which fails closed.
   */
  private data class GateVerdict(
    val allowed: Boolean,
    val message: String,
    val needsBiometric: Boolean,
    val riskLevel: Int
  ) {
    fun toMap(): Map<String, Any?> = mapOf(
      "allowed" to allowed,
      "message" to message,
      "needsBiometric" to needsBiometric,
      "riskLevel" to riskLevel,
      "source" to GATE_SOURCE
    )

    companion object {
      fun decode(raw: Any?): GateVerdict? {
        val map = raw as? Map<*, *> ?: return null
        val allowed = map["allowed"] as? Boolean ?: return null
        val message = (map["message"] as? String)?.takeIf { it.isNotBlank() } ?: return null
        val needsBiometric = map["needsBiometric"] as? Boolean ?: return null
        val riskLevel = (map["riskLevel"] as? Number)?.toInt() ?: return null
        return GateVerdict(allowed, message, needsBiometric, riskLevel)
      }
    }
  }

  companion object {
    private const val TAG = "MainActivity"

    const val CHANNEL = "com.noir.android/channel"

    /** Provenance stamped on every verdict so a log line can never be mistaken
     *  for a locally invented decision. */
    const val GATE_SOURCE = "dart:lib/safety/policy_engine.dart"

    // Methods served to Dart.
    const val METHOD_GET_NODES = "getNodes"
    const val METHOD_DISPATCH_GESTURE = "dispatchGesture"
    const val METHOD_SERVICE_STATUS = "serviceStatus"

    // Methods invoked on Dart.
    const val METHOD_POLICY_GATE = "policyGate"
    const val METHOD_SCREEN_NODES = "screenNodes"

    private const val GATE_TIMEOUT_MS = 3000L
    private const val TAP_DURATION_MS = 50L

    // Fail-closed error codes; mirrored by lib/platform/native_bridge.dart.
    const val ERR_POLICY_BLOCKED = "POLICY_BLOCKED"
    const val ERR_POLICY_GATE_UNREACHABLE = "POLICY_GATE_UNREACHABLE"
    const val ERR_POLICY_GATE_MALFORMED = "POLICY_GATE_MALFORMED"
    const val ERR_MALFORMED_GESTURE_REQUEST = "MALFORMED_GESTURE_REQUEST"
    const val ERR_MALFORMED_GESTURE_TARGET = "MALFORMED_GESTURE_TARGET"
    const val ERR_EMPTY_GESTURE_TARGET = "EMPTY_GESTURE_TARGET"
    const val ERR_SERVICE_UNAVAILABLE = "SERVICE_UNAVAILABLE"
    const val ERR_NODE_DUMP_UNAVAILABLE = "NODE_DUMP_UNAVAILABLE"
    const val ERR_GESTURE_CANCELLED = "GESTURE_CANCELLED"
    const val ERR_GESTURE_DISPATCH_REJECTED = "GESTURE_DISPATCH_REJECTED"
    const val ERR_WRONG_THREAD = "DISPATCH_WRONG_THREAD"
  }
}
