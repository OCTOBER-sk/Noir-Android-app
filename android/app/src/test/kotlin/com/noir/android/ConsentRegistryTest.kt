// android/app/src/test/kotlin/com/noir/android/ConsentRegistryTest.kt
//
// Pure JVM unit tests for the user request token: default deny, single use,
// replay refusal, expiry and a bounded live set. The clock is injected, so
// none of these tests sleep.
package com.noir.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConsentRegistryTest {

  /** Manually advanced clock: the only source of time in these tests. */
  private class TestClock(var nowMs: Long = 1_000L) : () -> Long {
    override fun invoke(): Long = nowMs
    fun advance(ms: Long) {
      nowMs += ms
    }
  }

  private fun registry(
    clock: TestClock,
    ttlMs: Long = 10_000L,
    maxUses: Int = 1,
    maxLiveTokens: Int = 3
  ) = ConsentRegistry(ttlMs = ttlMs, defaultMaxUses = maxUses, maxLiveTokens = maxLiveTokens, clock = clock)

  // ---- default deny ---------------------------------------------------------

  @Test
  fun `a missing token is refused`() {
    val result = registry(TestClock()).consume(null)
    assertFalse(result.isGranted)
    assertEquals(ConsentDenial.NO_TOKEN, (result as ConsentResult.Denied).denial)
    assertEquals("CONSENT_REQUIRED", (result as ConsentResult.Denied).denial.code)
  }

  @Test
  fun `a blank token is refused`() {
    assertEquals(ConsentDenial.NO_TOKEN, (registry(TestClock()).consume("   ") as ConsentResult.Denied).denial)
  }

  @Test
  fun `an invented token is refused`() {
    val result = registry(TestClock()).consume("user_request-9999")
    assertEquals(ConsentDenial.UNKNOWN_TOKEN, (result as ConsentResult.Denied).denial)
  }

  @Test
  fun `refusals are counted, not swallowed`() {
    val reg = registry(TestClock())
    reg.consume(null)
    reg.consume("nope")

    val stats = reg.stats()
    assertEquals(2, stats["denied"])
    assertEquals(1, (stats["denialReasons"] as Map<*, *>)["NO_TOKEN"])
    assertEquals(1, (stats["denialReasons"] as Map<*, *>)["UNKNOWN_TOKEN"])
  }

  // ---- grant, spend, replay -------------------------------------------------

  @Test
  fun `a minted token grants exactly one use`() {
    val reg = registry(TestClock())
    val token = reg.mint("user_request")

    val granted = reg.consume(token.id)
    assertTrue(granted.isGranted)
    assertEquals(0, granted.tokenOrNull?.usesRemaining)
    assertEquals(1, granted.tokenOrNull?.maxUses)
    assertEquals(1, reg.stats()["consumed"])
  }

  @Test
  fun `a spent token cannot be replayed`() {
    val reg = registry(TestClock())
    val token = reg.mint("user_request")
    reg.consume(token.id)

    val replay = reg.consume(token.id)
    assertEquals(ConsentDenial.EXHAUSTED, (replay as ConsentResult.Denied).denial)
  }

  @Test
  fun `a multi use token is bounded by its own use count`() {
    val reg = registry(TestClock(), maxUses = 2)
    val token = reg.mint("session")

    assertTrue(reg.consume(token.id).isGranted)
    assertTrue(reg.consume(token.id).isGranted)
    assertEquals(ConsentDenial.EXHAUSTED, (reg.consume(token.id) as ConsentResult.Denied).denial)
  }

  // ---- expiry ---------------------------------------------------------------

  @Test
  fun `an expired token is refused`() {
    val clock = TestClock()
    val reg = registry(clock, ttlMs = 5_000L)
    val token = reg.mint("user_request")

    clock.advance(5_001L)

    val result = reg.consume(token.id)
    assertEquals(ConsentDenial.EXPIRED, (result as ConsentResult.Denied).denial)
    assertEquals("CONSENT_EXPIRED", result.denial.code)
  }

  @Test
  fun `a token is still valid at its exact expiry instant`() {
    val clock = TestClock()
    val reg = registry(clock, ttlMs = 5_000L)
    val token = reg.mint("user_request")

    clock.advance(5_000L)

    assertTrue(reg.consume(token.id).isGranted)
  }

  // ---- revocation -----------------------------------------------------------

  @Test
  fun `a revoked token is refused`() {
    val reg = registry(TestClock())
    val token = reg.mint("user_request")
    assertTrue(reg.revoke(token.id))

    assertEquals(ConsentDenial.REVOKED, (reg.consume(token.id) as ConsentResult.Denied).denial)
  }

  @Test
  fun `revokeAll ends every outstanding request`() {
    val reg = registry(TestClock())
    val first = reg.mint("user_request")
    val second = reg.mint("user_request")

    assertEquals(2, reg.revokeAll())
    assertEquals(0, reg.activeCount())
    assertEquals(ConsentDenial.REVOKED, (reg.consume(first.id) as ConsentResult.Denied).denial)
    assertEquals(ConsentDenial.REVOKED, (reg.consume(second.id) as ConsentResult.Denied).denial)
  }

  // ---- bounded live set -----------------------------------------------------

  @Test
  fun `the live token set stays bounded`() {
    val reg = registry(TestClock(), maxLiveTokens = 3)
    repeat(10) { reg.mint("user_request") }

    assertEquals(3, reg.activeCount())
    assertEquals(10, reg.stats()["minted"])
  }

  @Test
  fun `the oldest token is the one that is forgotten`() {
    val reg = registry(TestClock(), maxLiveTokens = 2)
    val first = reg.mint("user_request")
    reg.mint("user_request")
    reg.mint("user_request")

    assertEquals(ConsentDenial.UNKNOWN_TOKEN, (reg.consume(first.id) as ConsentResult.Denied).denial)
  }

  @Test
  fun `a spent token stops counting as active`() {
    val reg = registry(TestClock())
    val token = reg.mint("user_request")
    assertEquals(1, reg.activeCount())

    reg.consume(token.id)

    assertEquals(0, reg.activeCount())
  }

  @Test
  fun `prune forgets dead tokens`() {
    val clock = TestClock()
    val reg = registry(clock, ttlMs = 1_000L)
    reg.mint("user_request")

    clock.advance(2_000L)

    assertEquals(0, reg.activeCount())
    assertEquals(1, reg.prune())
    assertEquals(ConsentDenial.UNKNOWN_TOKEN, (reg.consume("user_request-1") as ConsentResult.Denied).denial)
  }

  @Test
  fun `explicit denials are recorded`() {
    val reg = registry(TestClock())
    val result = reg.deny(ConsentDenial.NO_TOKEN, "no confirmation")

    assertEquals(ConsentDenial.NO_TOKEN, (result as ConsentResult.Denied).denial)
    assertEquals(1, reg.stats()["denied"])
  }

  // ---- construction and liveness helpers -----------------------------------

  @Test
  fun `a registry must have a positive ttl and use count`() {
    assertTrue(runCatching { ConsentRegistry(ttlMs = 0) }.exceptionOrNull() is IllegalArgumentException)
    assertTrue(
      runCatching { ConsentRegistry(defaultMaxUses = 0) }.exceptionOrNull() is IllegalArgumentException
    )
    assertTrue(
      runCatching { ConsentRegistry(maxLiveTokens = 0) }.exceptionOrNull() is IllegalArgumentException
    )
  }

  @Test
  fun `liveness distinguishes validity from remaining uses`() {
    val clock = TestClock()
    val reg = registry(clock, ttlMs = 1_000L)
    val token = reg.mint("user_request")

    assertTrue("fresh token must be live", token.isLiveAt(clock.nowMs))
    assertTrue(token.isValidAt(clock.nowMs))

    val spent = reg.consume(token.id).tokenOrNull!!
    assertFalse("a spent token is no longer live", spent.isLiveAt(clock.nowMs))
    assertTrue(
      "a just-spent token must still be dispatchable for its own action",
      spent.isValidAt(clock.nowMs)
    )

    clock.advance(2_000L)
    assertFalse(spent.isValidAt(clock.nowMs))
  }

  @Test
  fun `token ids are unique and stable`() {
    val reg = registry(TestClock())
    val ids = (0 until 5).map { reg.mint("user_request").id }
    assertEquals(5, ids.toSet().size)
    assertEquals("user_request-3", ids[2])
  }
}
