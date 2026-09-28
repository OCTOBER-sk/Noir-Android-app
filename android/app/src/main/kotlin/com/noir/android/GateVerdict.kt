// android/app/src/main/kotlin/com/noir/android/GateVerdict.kt — C2 (pure)
//
// Structural decoding of the Dart PolicyEngine's gate reply: the last thing
// that stands between a PolicyEngine answer and a real dispatchGesture.
//
// PURE KOTLIN BY CONTRACT: no android.* imports. The android-free shape is
// what lets android/app/src/test/** prove every fail-closed branch of the
// decoder that actually runs on device; the identical decoder nested inside
// MainActivity could not be loaded by a plain JVM unit test at all, because
// MainActivity extends FlutterActivity.
//
// This is NOT a policy engine and holds no rules about what a gesture may do.
// That authority is lib/safety/policy_engine.dart. This type only reads the
// boolean the engine produced and fails closed on everything else.
//
// Fail closed means fail closed: a null, a non-Map, an empty map, a missing
// field, a wrong-typed field and a blank message are ALL null, which
// MainActivity reports as ERR_POLICY_GATE_MALFORMED — never as an allow.
//
// The Dart-side mirror of this shape is NativeGateVerdict.fromChannelMap
// (lib/platform/native_bridge.dart, pinned by test/native_bridge_test.dart).
// Two decoders, two languages, one wire format: a divergence between them
// would be a silent fail-open, so the Kotlin one is pinned here too.
package com.noir.android

/**
 * A decoded gate reply. [allowed] is the only field that steers execution.
 */
data class GateVerdict(
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
    /** Provenance stamped on every verdict so a log line can never be mistaken
     *  for a locally invented decision. */
    const val GATE_SOURCE = "dart:lib/safety/policy_engine.dart"

    /**
     * Decodes a gate reply, or returns null.
     *
     * Every field is mandatory and type-checked, and a blank [message] is
     * treated as absent: a denial must always be able to say why. Note the
     * `as? Number` widening on [riskLevel] — the standard MethodChannel codec
     * hands back Int/Long/Double interchangeably, so a reply that survives the
     * crossing is accepted at whatever width it arrives in.
     */
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
