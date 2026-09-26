// android/app/src/test/kotlin/com/noir/android/GestureGateTest.kt
//
// Pure JVM unit tests for the platform-side gesture decision table: default
// deny, fail-closed capability check, target validation, main-looper check.
package com.noir.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GestureGateTest {

  /** AccessibilityServiceInfo.CAPABILITY_CAN_PERFORM_GESTURES. */
  private val gestureMask = 0x00000002

  /** AccessibilityServiceInfo.CAPABILITY_CAN_RETRIEVE_WINDOW_CONTENT. */
  private val contentMask = 0x00000001

  private val granted = ConsentResult.Granted(
    ConsentToken(
      id = "user_request-1",
      kind = "user_request",
      issuedAtMs = 1_000L,
      expiresAtMs = 11_000L,
      maxUses = 1,
      usesRemaining = 0
    )
  )

  private val now = 1_500L
  private val target = GestureTarget(left = 10, top = 20, right = 110, bottom = 220)

  private fun decide(
    consent: ConsentResult = granted,
    capabilities: Int? = gestureMask,
    gestureTarget: GestureTarget? = target,
    onMainThread: Boolean = true,
    atMs: Long = now
  ) = GestureGate.decide(
    consent = consent,
    capabilities = capabilities,
    target = gestureTarget,
    onMainThread = onMainThread,
    nowMs = atMs,
    gestureMask = gestureMask
  )

  // ---- capability bit -------------------------------------------------------

  @Test
  fun `capability is present only when the bit is set`() {
    assertTrue(GestureGate.hasCapability(gestureMask, gestureMask))
    assertTrue(GestureGate.hasCapability(gestureMask or contentMask, gestureMask))
    assertFalse(GestureGate.hasCapability(contentMask, gestureMask))
    assertFalse(GestureGate.hasCapability(0, gestureMask))
  }

  @Test
  fun `an unknown capability set fails closed`() {
    assertFalse("null capabilities must deny", GestureGate.hasCapability(null, gestureMask))
    assertFalse(GestureGate.hasCapability(gestureMask, 0))
  }

  @Test
  fun `a missing capability bit refuses the gesture`() {
    val decision = decide(capabilities = contentMask)
    assertFalse(decision.allowed)
    assertEquals(GestureDenial.GESTURE_UNAVAILABLE, decision.denial)
    assertEquals("GESTURE_CAPABILITY_UNAVAILABLE", decision.code)
  }

  @Test
  fun `an unreadable service info refuses the gesture`() {
    val decision = decide(capabilities = null)
    assertFalse(decision.allowed)
    assertEquals(GestureDenial.GESTURE_UNAVAILABLE, decision.denial)
  }

  // ---- consent --------------------------------------------------------------

  @Test
  fun `a refused consent refuses the gesture`() {
    val decision = decide(consent = ConsentResult.Denied(ConsentDenial.NO_TOKEN, "default deny"))
    assertFalse(decision.allowed)
    assertEquals(GestureDenial.CONSENT_MISSING, decision.denial)
    assertEquals("CONSENT_REQUIRED", decision.code)
  }

  @Test
  fun `consent is checked before anything else`() {
    // Everything else is perfect; the verdict must still be a refusal.
    val decision = decide(consent = ConsentResult.Denied(ConsentDenial.UNKNOWN_TOKEN, "not live"))
    assertEquals(GestureDenial.CONSENT_MISSING, decision.denial)
  }

  @Test
  fun `a token past its expiry refuses the gesture`() {
    val decision = decide(atMs = 11_001L)
    assertFalse(decision.allowed)
    assertEquals(GestureDenial.CONSENT_EXPIRED, decision.denial)
  }

  @Test
  fun `a revoked token refuses the gesture`() {
    val revoked = ConsentResult.Granted(granted.tokenOrNull!!.copy(revoked = true))
    val decision = decide(consent = revoked)
    assertEquals(GestureDenial.CONSENT_EXPIRED, decision.denial)
  }

  // ---- target ---------------------------------------------------------------

  @Test
  fun `a missing target refuses the gesture`() {
    val decision = decide(gestureTarget = null)
    assertEquals(GestureDenial.MALFORMED_TARGET, decision.denial)
    assertEquals("MALFORMED_GESTURE_TARGET", decision.code)
  }

  @Test
  fun `a zero area target refuses the gesture`() {
    val decision = decide(gestureTarget = GestureTarget(10, 20, 10, 20))
    assertEquals(GestureDenial.EMPTY_TARGET, decision.denial)
    assertEquals("EMPTY_GESTURE_TARGET", decision.code)
  }

  @Test
  fun `an inverted target refuses the gesture`() {
    val decision = decide(gestureTarget = GestureTarget(110, 220, 10, 20))
    assertEquals(GestureDenial.EMPTY_TARGET, decision.denial)
  }

  @Test
  fun `an off display target refuses the gesture`() {
    assertEquals(
      GestureDenial.OFF_DISPLAY,
      decide(gestureTarget = GestureTarget(-40, 0, -10, 10)).denial
    )
    assertEquals(
      GestureDenial.OFF_DISPLAY,
      decide(gestureTarget = GestureTarget(0, -40, 10, -10)).denial
    )
  }

  @Test
  fun `a target touching the origin is on display`() {
    assertTrue(GestureTarget(0, 0, 10, 10).isOnDisplay)
    assertEquals(GestureTarget(0, 0, 10, 10).toMap()["left"], 0)
  }

  // ---- thread ---------------------------------------------------------------

  @Test
  fun `a worker thread refuses the gesture`() {
    val decision = decide(onMainThread = false)
    assertEquals(GestureDenial.WRONG_THREAD, decision.denial)
    assertEquals("DISPATCH_WRONG_THREAD", decision.code)
  }

  // ---- the cleared path -----------------------------------------------------

  @Test
  fun `a live consent with the capability and a real target is allowed`() {
    val decision = decide()
    assertTrue(decision.allowed)
    assertNull(decision.denial)
    assertEquals("user_request-1", decision.token?.id)
  }

  @Test
  fun `a just spent single use token is still dispatchable for its own action`() {
    // granted carries usesRemaining == 0: the registry has already spent it.
    assertTrue(granted.tokenOrNull!!.isValidAt(now))
    assertTrue(decide().allowed)
  }

  @Test
  fun `the documented mirror matches the platform constant`() {
    assertEquals(0x00000002, GestureGate.DEFAULT_GESTURE_MASK)
  }

  // ---- the whole chain, pure halves only -----------------------------------

  /**
   * The production chain for a gesture is: ConsentRegistry.consume, then
   * GestureGate.decide, then dispatchGesture. The last step needs a device, so
   * this pins the two halves that decide whether it is ever reached.
   */
  @Test
  fun `one user request buys exactly one dispatch`() {
    var now = 1_000L
    val registry = ConsentRegistry(ttlMs = 15_000L, defaultMaxUses = 1, maxLiveTokens = 4) { now }
    val token = registry.mint("user_request")

    val first = GestureGate.decide(
      consent = registry.consume(token.id),
      capabilities = gestureMask,
      target = target,
      onMainThread = true,
      nowMs = now,
      gestureMask = gestureMask
    )
    assertTrue("a live request must reach the service", first.allowed)

    // Same request replayed: the registry refuses, so the gate never runs.
    val replay = GestureGate.decide(
      consent = registry.consume(token.id),
      capabilities = gestureMask,
      target = target,
      onMainThread = true,
      nowMs = now,
      gestureMask = gestureMask
    )
    assertFalse("a replay must not reach the service", replay.allowed)
    assertEquals(GestureDenial.CONSENT_MISSING, replay.denial)
  }

  @Test
  fun `a request that outlives its window never dispatches`() {
    var now = 1_000L
    val registry = ConsentRegistry(ttlMs = 5_000L, defaultMaxUses = 1, maxLiveTokens = 4) { now }
    val token = registry.mint("user_request")

    now += 5_001L

    val decision = GestureGate.decide(
      consent = registry.consume(token.id),
      capabilities = gestureMask,
      target = target,
      onMainThread = true,
      nowMs = now,
      gestureMask = gestureMask
    )
    assertFalse(decision.allowed)
    assertEquals(GestureDenial.CONSENT_MISSING, decision.denial)
  }

  @Test
  fun `no request means no dispatch, and nothing was minted`() {
    val registry = ConsentRegistry(clock = { 1_000L })

    val decision = GestureGate.decide(
      consent = registry.consume(null),
      capabilities = gestureMask,
      target = target,
      onMainThread = true,
      nowMs = 1_000L,
      gestureMask = gestureMask
    )

    assertFalse(decision.allowed)
    assertEquals(GestureDenial.CONSENT_MISSING, decision.denial)
    assertEquals(0, registry.stats()["minted"])
    assertEquals(0, registry.activeCount())
  }
}
