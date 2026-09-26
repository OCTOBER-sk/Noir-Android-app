// android/app/src/main/kotlin/com/noir/android/MainActivity.kt — C2 (REAL PolicyEngine gate)
//
// The platform half of lib/platform/native_bridge.dart. Four responsibilities:
//
//   1. Serve read-only queries (getNodes, serviceStatus) from the live
//      AgentAccessibilityService. Both are redacted and size-capped in the
//      service before they reach this file, so nothing raw crosses the channel.
//   2. Own the R1 invariant: NO gesture is dispatched without a live, unspent
//      user request token, and NO capture is pushed without a user-initiated
//      arm. Default deny; every refusal is counted and reported in
//      `serviceStatus`.
//   3. Own the C2 invariant: NO gesture is dispatched unless the Dart
//      PolicyEngine has explicitly answered `allowed: true` on the same
//      MethodChannel. There are no policy rules in this file — the only field
//      that steers execution is a boolean produced by
//      lib/safety/policy_engine.dart. Unreachable, malformed, late or errored
//      gate replies all fail closed.
//   4. Turn a cleared consent token plus a cleared gate into a real
//      AccessibilityService.dispatchGesture.
//
// Method names and reply shapes are unchanged, so the Dart side of the bridge
// needs no edit. `beginUserRequest` / `endUserRequest` are additive: they let
// the Dart side present a real token later without changing the current flow.
package com.noir.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {

  private lateinit var channel: MethodChannel
  private val mainHandler = Handler(Looper.getMainLooper())

  /**
   * The user request tokens this activity has issued.
   *
   * Per-activity on purpose. A token is a statement about one user request, and
   * leaving the app is a user signal too: [onPause] disarms capture and
   * [onDestroy] revokes every outstanding token, so nothing outlives the user.
   */
  private val consent = ConsentRegistry(
    ttlMs = CONSENT_TTL_MS,
    defaultMaxUses = CONSENT_MAX_USES,
    maxLiveTokens = MAX_LIVE_CONSENT_TOKENS,
    clock = { SystemClock.uptimeMillis() }
  )

  override fun configureFlutterEngine(engine: FlutterEngine) {
    super.configureFlutterEngine(engine)
    channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
    channel.setMethodCallHandler { call, result -> onMethodCall(call, result) }

    // C1: an AccessibilityService holds no FlutterEngine reference, so
    // MainActivity installs the sink that AgentAccessibilityService pushes
    // sanitized node dumps into. It is torn down in cleanUpFlutterEngine so a
    // dead engine is never called back into.
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

  /**
   * The user just brought the app to the foreground. That is a user-initiated
   * moment, so event-driven capture is allowed for a bounded window
   * (AgentAccessibilityService.CAPTURE_ARM_TTL_MS).
   *
   * This is the ONLY thing onResume authorises, and it is deliberately not a
   * gesture: no gesture becomes possible without an explicit consent token.
   */
  override fun onResume() {
    super.onResume()
    AgentAccessibilityService.current()?.armCapture(ARM_REASON_ACTIVITY_RESUMED)
  }

  override fun onPause() {
    // Backgrounding the app ends observation: no further windows are read
    // while Noir is not in front of the user. Google Play's automation policy
    // has no room for a service that keeps watching on its own.
    AgentAccessibilityService.current()?.disarmCapture(ARM_REASON_ACTIVITY_PAUSED)
    super.onPause()
  }

  override fun onDestroy() {
    consent.revokeAll()
    AgentAccessibilityService.current()?.disarmCapture(ARM_REASON_ACTIVITY_DESTROYED)
    super.onDestroy()
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      METHOD_GET_NODES -> handleGetNodes(result)
      METHOD_SERVICE_STATUS -> result.success(currentServiceStatus())
      METHOD_DISPATCH_GESTURE -> handleDispatchGesture(call, result)
      METHOD_BEGIN_USER_REQUEST -> handleBeginUserRequest(call, result)
      METHOD_END_USER_REQUEST -> handleEndUserRequest(call, result)
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
    // captureSanitized() walks the live tree on this (platform/main) thread and
    // then redacts and size-caps it, so the reply is never a raw dump.
    //
    // No capture arm is required here, and that is deliberate: `getNodes` is a
    // direct answer to a request that is already in flight, not event-driven
    // background automation. The arm exists to stop the service from reading
    // windows nobody asked about.
    val payload = service.captureSanitized()
    if (payload == null) {
      result.error(ERR_NODE_DUMP_UNAVAILABLE, "no active window available to dump", null)
      return
    }
    result.success(AgentAccessibilityService.payloadOf(payload))
  }

  private fun currentServiceStatus(): Map<String, Any?> {
    val service = AgentAccessibilityService.current()
    val status = LinkedHashMap<String, Any?>()
    // One reply shape in every state: accessibility_status.dart discards a
    // status reply that is missing a key, so the disconnected case is built
    // from the same key set with zeroed values.
    if (service == null) {
      status.putAll(AgentAccessibilityService.disconnectedStatus())
    } else {
      status.putAll(service.statusSnapshot())
    }
    status["runtimeSinkInstalled"] = AgentAccessibilityService.runtimeSink != null
    status["gateSource"] = GATE_SOURCE
    status["defaultDeny"] = true
    status["captureArmed"] = service?.isCaptureArmed() ?: false
    status["consent"] = consent.stats()
    return status
  }

  // ---- R1: user requests ----------------------------------------------------

  /**
   * Opens an explicit, bounded user request.
   *
   * Additive and optional: the current Dart flow (a confirmed `dispatchGesture`)
   * still works without it. When the Dart side does adopt it, the returned
   * `userRequestToken` is what `dispatchGesture` must present.
   */
  private fun handleBeginUserRequest(call: MethodCall, result: MethodChannel.Result) {
    val kind = call.argument<String>("kind")?.takeIf { it.isNotBlank() } ?: KIND_USER_REQUEST
    val requested = (call.argument<Number>("maxActions")?.toInt() ?: CONSENT_MAX_USES)
      .coerceIn(1, MAX_ACTIONS_PER_REQUEST)
    val token = consent.mint(kind, maxUses = requested)
    // A live user request is also what allows observation, not just acting.
    AgentAccessibilityService.current()?.armCapture(ARM_REASON_USER_REQUEST)
    val now = SystemClock.uptimeMillis()
    result.success(
      mapOf(
        "userRequestToken" to token.id,
        "kind" to token.kind,
        "issuedAtMs" to token.issuedAtMs,
        "expiresAtMs" to token.expiresAtMs,
        "expiresInMs" to (token.expiresAtMs - now),
        "maxUses" to token.maxUses,
        "captureArmed" to (AgentAccessibilityService.current()?.isCaptureArmed() ?: false)
      )
    )
  }

  /** Ends a user request early, so its remaining uses are gone immediately. */
  private fun handleEndUserRequest(call: MethodCall, result: MethodChannel.Result) {
    val id = call.argument<String>("userRequestToken")
    if (id.isNullOrBlank()) {
      result.error(ERR_MALFORMED_CONSENT_REQUEST, "userRequestToken is required", null)
      return
    }
    val known = consent.revoke(id)
    val remaining = consent.activeCount()
    if (remaining == 0) {
      AgentAccessibilityService.current()?.disarmCapture(ARM_REASON_USER_REQUEST_ENDED)
    }
    result.success(
      mapOf(
        "ended" to true,
        "known" to known,
        "activeConsentTokens" to remaining
      )
    )
  }

  // ---- C2: consent, then gate, then dispatch -------------------------------

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

    // R1 first: a gesture with no live user request is refused before the Dart
    // isolate is troubled and before the service is touched at all.
    val consentResult = resolveConsent(call, confirmed, gateRequestId)
    val token = when (consentResult) {
      is ConsentResult.Granted -> consentResult.token
      is ConsentResult.Denied -> {
        Log.w(TAG, "gesture $gateRequestId refused: ${consentResult.denial.code}")
        result.error(
          consentResult.denial.code,
          consentResult.message,
          mapOf(
            "gateRequestId" to gateRequestId,
            "denial" to consentResult.denial.name,
            "defaultDeny" to true
          )
        )
        return
      }
    }

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
            executeGesture(targetOf(bounds), verdict, token, result)
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
   * Turns the incoming call into a spent consent token, or a refusal.
   *
   * Two accepted shapes:
   *
   *   1. An explicit `userRequestToken` from `beginUserRequest`. Preferred and
   *      self-describing: the token *is* the user request, and the registry
   *      enforces its own uses, expiry and revocation.
   *   2. The shape lib/platform/native_bridge.dart sends today, where
   *      `confirmed: true` is the only evidence that a human confirmation step
   *      has completed (NativeBridge.dispatchGesture will not send the call at
   *      all otherwise). A single-use token is minted here and spent
   *      immediately, so the gesture is still bound to one request and to the
   *      [CONSENT_TTL_MS] window, and the Dart side needs no change.
   *
   * Anything else — no token, `confirmed: false`, an invented, expired, revoked
   * or replayed token — is refused. Default deny, and never queued for later.
   */
  private fun resolveConsent(
    call: MethodCall,
    confirmed: Boolean,
    gateRequestId: String
  ): ConsentResult {
    val explicit = call.argument<String>("userRequestToken")
    if (!explicit.isNullOrBlank()) {
      val result = consent.consume(explicit)
      if (result is ConsentResult.Denied) {
        Log.w(TAG, "explicit consent refused for $gateRequestId: ${result.denial.code}")
      }
      return result
    }
    if (!confirmed) {
      return consent.deny(
        ConsentDenial.NO_TOKEN,
        "gesture $gateRequestId carried neither a userRequestToken nor a user confirmation; refusing by default"
      )
    }
    val minted = consent.mint(KIND_DART_CONFIRMED, maxUses = CONSENT_MAX_USES)
    Log.i(TAG, "minted a single-use consent token for $gateRequestId from a confirmed user request")
    return consent.consume(minted.id)
  }

  /**
   * Builds a real [GestureDescription] (Path + StrokeDescription) and hands it
   * to the live AccessibilityService. This path is ONLY reachable after a live
   * user request token AND a cleared Dart PolicyEngine verdict.
   */
  private fun executeGesture(
    target: GestureTarget?,
    verdict: GateVerdict,
    token: ConsentToken,
    result: MethodChannel.Result
  ) {
    val service = AgentAccessibilityService.current()
    if (service == null) {
      result.error(ERR_SERVICE_UNAVAILABLE, "AgentAccessibilityService is not connected", null)
      return
    }
    if (target == null) {
      // Same code GestureGate would answer with; kept explicit here so the path
      // below never needs a non-null assertion.
      result.error(GestureDenial.MALFORMED_TARGET.code, "bounds are not a rectangle", null)
      return
    }

    // R5: the decision table is the single authority for "may this be
    // dispatched". `capabilities == null` (unreadable serviceInfo) denies.
    val decision = GestureGate.decide(
      consent = ConsentResult.Granted(token),
      capabilities = service.gestureCapabilities(),
      target = target,
      onMainThread = Looper.myLooper() == Looper.getMainLooper(),
      nowMs = SystemClock.uptimeMillis(),
      gestureMask = AccessibilityServiceInfo.CAPABILITY_CAN_PERFORM_GESTURES
    )
    if (!decision.allowed) {
      val denial = decision.denial ?: GestureDenial.CONSENT_MISSING
      Log.w(TAG, "gesture refused after the gate: ${denial.code}")
      result.error(denial.code, denialMessage(denial, target), null)
      return
    }

    val x = (target.left + target.right) / 2f
    val y = (target.top + target.bottom) / 2f

    val path = Path().apply {
      moveTo(x, y)
      lineTo(x, y)
    }
    val stroke = GestureDescription.StrokeDescription(path, 0L, TAP_DURATION_MS)
    val gesture = GestureDescription.Builder()
      .addStroke(stroke)
      .build()

    val accepted = try {
      service.dispatchGestureNow(gesture, token, object : AccessibilityService.GestureResultCallback() {
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
              "gateMessage" to verdict.message,
              // Additive: which user request paid for this gesture.
              "consentTokenId" to token.id
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

  private fun denialMessage(denial: GestureDenial, target: GestureTarget): String = when (denial) {
    GestureDenial.CONSENT_MISSING -> "no live user request token; refusing by default"
    GestureDenial.CONSENT_EXPIRED -> "the user request that authorized this gesture is no longer valid"
    GestureDenial.GESTURE_UNAVAILABLE ->
      "canPerformGestures is not enabled for this service; refusing to dispatch"
    GestureDenial.MALFORMED_TARGET -> "bounds are not a rectangle"
    GestureDenial.EMPTY_TARGET -> "gesture target has no area: $target"
    GestureDenial.OFF_DISPLAY -> "gesture target is off display: $target"
    GestureDenial.WRONG_THREAD -> "dispatchGesture must be requested on the main looper"
  }

  /**
   * Reads a gesture rectangle. Only shape is checked here: whether the target
   * has area and sits on the display is GestureGate's call, so there is exactly
   * one answer to that question.
   */
  private fun targetOf(bounds: Map<*, *>): GestureTarget? {
    val left = intOf(bounds["left"]) ?: return null
    val top = intOf(bounds["top"]) ?: return null
    val right = intOf(bounds["right"]) ?: return null
    val bottom = intOf(bounds["bottom"]) ?: return null
    return GestureTarget(left, top, right, bottom)
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

    // Methods served to Dart. The first three are the historical contract
    // read by lib/platform/native_bridge.dart; the last two are additive.
    const val METHOD_GET_NODES = "getNodes"
    const val METHOD_DISPATCH_GESTURE = "dispatchGesture"
    const val METHOD_SERVICE_STATUS = "serviceStatus"
    const val METHOD_BEGIN_USER_REQUEST = "beginUserRequest"
    const val METHOD_END_USER_REQUEST = "endUserRequest"

    // Methods invoked on Dart.
    const val METHOD_POLICY_GATE = "policyGate"
    const val METHOD_SCREEN_NODES = "screenNodes"

    /** A consent token lives long enough for a confirmation prompt and no
     *  longer, so a stale confirmation cannot be replayed. */
    const val CONSENT_TTL_MS = 15_000L

    /** One user request buys one gated action. */
    const val CONSENT_MAX_USES = 1

    /** Ceiling for an explicitly requested multi-action request. */
    const val MAX_ACTIONS_PER_REQUEST = 4

    const val MAX_LIVE_CONSENT_TOKENS = 8

    const val KIND_USER_REQUEST = "user_request"
    const val KIND_DART_CONFIRMED = "dart_confirmed"

    const val ARM_REASON_ACTIVITY_RESUMED = "activity_resumed"
    const val ARM_REASON_ACTIVITY_PAUSED = "activity_paused"
    const val ARM_REASON_ACTIVITY_DESTROYED = "activity_destroyed"
    const val ARM_REASON_USER_REQUEST = "user_request_open"
    const val ARM_REASON_USER_REQUEST_ENDED = "user_request_ended"

    private const val GATE_TIMEOUT_MS = 3000L
    private const val TAP_DURATION_MS = 50L

    // Fail-closed error codes; mirrored by lib/platform/native_bridge.dart.
    // MALFORMED_GESTURE_TARGET, EMPTY_GESTURE_TARGET and DISPATCH_WRONG_THREAD
    // are now emitted by GestureDenial, which is the single authority for those
    // three verdicts; they are kept here because they are the wire contract
    // the Dart side already knows.
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

    // Additive: the consent layer's own codes. The wire values live on
    // ConsentDenial and GestureDenial (CONSENT_REQUIRED, CONSENT_EXPIRED,
    // CONSENT_REVOKED, CONSENT_EXHAUSTED, GESTURE_CAPABILITY_UNAVAILABLE).
    const val ERR_MALFORMED_CONSENT_REQUEST = "MALFORMED_CONSENT_REQUEST"
  }
}
