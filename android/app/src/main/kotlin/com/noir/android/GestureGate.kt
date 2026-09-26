// android/app/src/main/kotlin/com/noir/android/GestureGate.kt — R5 (pure)
//
// The platform-side decision table for a single gesture, kept free of
// android.* so android/app/src/test/** can prove each refusal branch.
//
// This is NOT a policy engine. It holds no rules about what a gesture may *do* —
// that authority is lib/safety/policy_engine.dart, reached over the
// MethodChannel. What lives here is only the mechanical preconditions for
// dispatching at all:
//
//   1. a live, unspent user request token (default deny),
//   2. the AccessibilityServiceInfo gesture capability bit (fail closed when
//      the platform will not tell us),
//   3. a non-empty, on-display target,
//   4. the main looper.
//
// Every one of these is a refusal by default: an unexpected value denies.
package com.noir.android

/**
 * A screen rectangle, deliberately not `android.graphics.Rect` so the decision
 * table stays unit-testable on a plain JVM.
 */
data class GestureTarget(
  val left: Int,
  val top: Int,
  val right: Int,
  val bottom: Int
) {
  val hasArea: Boolean get() = right > left && bottom > top
  val centerX: Double get() = (left + right) / 2.0
  val centerY: Double get() = (top + bottom) / 2.0
  val isOnDisplay: Boolean get() = hasArea && centerX >= 0.0 && centerY >= 0.0

  fun toMap(): Map<String, Any?> = mapOf(
    "left" to left,
    "top" to top,
    "right" to right,
    "bottom" to bottom
  )
}

/** Refusal reasons. `code` is a wire-stable MethodChannel error code. */
enum class GestureDenial(val code: String) {
  CONSENT_MISSING("CONSENT_REQUIRED"),
  CONSENT_EXPIRED("CONSENT_EXPIRED"),
  GESTURE_UNAVAILABLE("GESTURE_CAPABILITY_UNAVAILABLE"),
  MALFORMED_TARGET("MALFORMED_GESTURE_TARGET"),
  EMPTY_TARGET("EMPTY_GESTURE_TARGET"),
  OFF_DISPLAY("MALFORMED_GESTURE_TARGET"),
  WRONG_THREAD("DISPATCH_WRONG_THREAD")
}

/** The verdict. `allowed == false` always carries a [denial]; `allowed == true`
 *  never does. */
data class GestureDecision(
  val allowed: Boolean,
  val denial: GestureDenial?,
  val token: ConsentToken?
) {
  val code: String? get() = denial?.code

  companion object {
    fun allow(token: ConsentToken?): GestureDecision = GestureDecision(true, null, token)

    fun deny(denial: GestureDenial): GestureDecision = GestureDecision(false, denial, null)
  }
}

object GestureGate {

  /**
   * Mirror of `AccessibilityServiceInfo.CAPABILITY_CAN_PERFORM_GESTURES`.
   *
   * The production call sites always pass the SDK constant explicitly, so a
   * future change to that value cannot loosen the real check; this default only
   * exists so the pure decision table is testable on its own.
   */
  const val DEFAULT_GESTURE_MASK = 0x00000002

  /**
   * True only when the platform positively reported the capability.
   *
   * `capabilities == null` (serviceInfo unavailable or the read threw) is
   * false: fail closed, never assume.
   */
  fun hasCapability(capabilities: Int?, requiredMask: Int): Boolean {
    if (capabilities == null) return false
    if (requiredMask == 0) return false
    return (capabilities and requiredMask) == requiredMask
  }

  /**
   * Decides whether a gesture may reach `dispatchGesture`.
   *
   * Checked in order: consent, capability, target shape, thread. The first
   * failure wins, and each is independent of the Dart PolicyEngine, which has
   * already cleared by the time this runs.
   */
  fun decide(
    consent: ConsentResult,
    capabilities: Int?,
    target: GestureTarget?,
    onMainThread: Boolean,
    nowMs: Long,
    gestureMask: Int = DEFAULT_GESTURE_MASK
  ): GestureDecision {
    val token = when (consent) {
      is ConsentResult.Denied -> return GestureDecision.deny(GestureDenial.CONSENT_MISSING)
      is ConsentResult.Granted -> consent.token
    }
    if (!token.isValidAt(nowMs)) return GestureDecision.deny(GestureDenial.CONSENT_EXPIRED)
    if (!hasCapability(capabilities, gestureMask)) {
      return GestureDecision.deny(GestureDenial.GESTURE_UNAVAILABLE)
    }
    if (target == null) return GestureDecision.deny(GestureDenial.MALFORMED_TARGET)
    if (!target.hasArea) return GestureDecision.deny(GestureDenial.EMPTY_TARGET)
    if (!target.isOnDisplay) return GestureDecision.deny(GestureDenial.OFF_DISPLAY)
    if (!onMainThread) return GestureDecision.deny(GestureDenial.WRONG_THREAD)
    return GestureDecision.allow(token)
  }
}
