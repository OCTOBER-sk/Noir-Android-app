// android/app/src/test/kotlin/com/noir/android/GateVerdictTest.kt
//
// Pure JVM unit tests for the gate-reply decoder that actually runs on device:
// the C2 fail-closed boundary. Every shape MainActivity cannot decode must come
// back null, and a denial must come back decodable, or a PolicyEngine block
// could never be reported to Dart.
package com.noir.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GateVerdictTest {

  /**
   * A cleared reply, field for field as PolicyEngine.gate produces it for an
   * action that clears at riskLevel 2: `GateResult.confirm` sets allowed and
   * `NativeGateVerdict.toChannelMap` puts those four keys on the channel.
   */
  private val cleared = mapOf(
    "allowed" to true,
    "message" to "Confirmation required: tap",
    "needsBiometric" to true,
    "riskLevel" to 2,
    "source" to "dart:lib/safety/policy_engine.dart"
  )

  /**
   * A denial as `GateResult.blocked('UI_LOCK')` actually reaches this side.
   * The case that must never be mistaken for a malformed reply.
   */
  private val blocked = mapOf(
    "allowed" to false,
    "message" to "UI_LOCK",
    "needsBiometric" to false,
    "riskLevel" to 3,
    "source" to "dart:lib/safety/policy_engine.dart"
  )

  /** The same reply with one key dropped. */
  private fun without(vararg keys: String): Map<String, Any?> =
    cleared.filterKeys { it !in keys }

  // ---- the well-formed reply -------------------------------------------------

  @Test
  fun `a well formed reply decodes to its own field values`() {
    val verdict = GateVerdict.decode(cleared)

    assertNotNull("a complete reply must decode", verdict)
    assertTrue(verdict!!.allowed)
    assertEquals("Confirmation required: tap", verdict.message)
    assertTrue(verdict.needsBiometric)
    assertEquals(2, verdict.riskLevel)
  }

  @Test
  fun `a denial is decodable and reports allowed false`() {
    // The critical case: if a refusal did not decode, MainActivity would answer
    // POLICY_GATE_MALFORMED instead of the POLICY_BLOCKED the Dart side is
    // waiting for, and the real reason for the block would be lost.
    val verdict = GateVerdict.decode(blocked)

    assertNotNull("a denial must decode", verdict)
    assertFalse("a denial must never read as an allow", verdict!!.allowed)
    assertEquals("UI_LOCK", verdict.message)
    assertFalse(verdict.needsBiometric)
    assertEquals(3, verdict.riskLevel)
  }

  @Test
  fun `unknown extra keys are ignored`() {
    // The wire format may grow; an extra field is not a malformed reply.
    val verdict = GateVerdict.decode(cleared + ("needsConfirmation" to true))

    assertNotNull(verdict)
    assertTrue(verdict!!.allowed)
    assertEquals(2, verdict.riskLevel)
  }

  // ---- nothing to decode ----------------------------------------------------

  @Test
  fun `a null reply fails closed`() {
    assertNull(GateVerdict.decode(null))
  }

  @Test
  fun `a non map reply fails closed`() {
    assertNull(GateVerdict.decode("allowed"))
    assertNull(GateVerdict.decode(1))
    assertNull(GateVerdict.decode(listOf("allowed", true)))
    assertNull(GateVerdict.decode(true))
  }

  @Test
  fun `an empty map fails closed`() {
    assertNull(GateVerdict.decode(emptyMap<String, Any?>()))
  }

  @Test
  fun `a map that is not keyed by the wire names fails closed`() {
    // Same values, wrong keys: a reply whose field names have drifted is not a
    // reply this decoder may guess at.
    assertNull(
      GateVerdict.decode(
        mapOf("permitted" to true, "why" to "allowed", "bio" to false, "risk" to 0)
      )
    )
  }

  // ---- every field is mandatory ----------------------------------------------

  @Test
  fun `a reply missing any single field fails closed`() {
    // Each drop is made from an otherwise complete reply, so the only reason
    // these are null is the missing key.
    assertNotNull(GateVerdict.decode(cleared))
    assertNull("no allowed key", GateVerdict.decode(without("allowed")))
    assertNull("no message key", GateVerdict.decode(without("message")))
    assertNull("no needsBiometric key", GateVerdict.decode(without("needsBiometric")))
    assertNull("no riskLevel key", GateVerdict.decode(without("riskLevel")))
  }

  @Test
  fun `a reply with no message fails closed`() {
    assertNull(GateVerdict.decode(without("message")))
  }

  @Test
  fun `a reply with no risk level fails closed`() {
    assertNull(GateVerdict.decode(without("riskLevel")))
  }

  // ---- wrong types are not defaults -------------------------------------------

  @Test
  fun `a truthy string is not an allowed verdict`() {
    // "true" is a String, not a Boolean. Reading it as an allow would be the
    // single worst failure this decoder has.
    assertNull(GateVerdict.decode(cleared + ("allowed" to "true")))
    assertNull(GateVerdict.decode(cleared + ("allowed" to 1)))
    assertNull(GateVerdict.decode(cleared + ("allowed" to null)))
  }

  @Test
  fun `a wrong typed needsBiometric fails closed`() {
    assertNull(GateVerdict.decode(cleared + ("needsBiometric" to "false")))
    assertNull(GateVerdict.decode(cleared + ("needsBiometric" to 0)))
    assertNull(GateVerdict.decode(cleared + ("needsBiometric" to null)))
  }

  @Test
  fun `a blank message fails closed`() {
    assertNull(GateVerdict.decode(cleared + ("message" to "")))
    assertNull(GateVerdict.decode(cleared + ("message" to "   ")))
    assertNull(GateVerdict.decode(cleared + ("message" to "\t\n ")))
  }

  @Test
  fun `a non string message fails closed`() {
    assertNull(GateVerdict.decode(cleared + ("message" to 42)))
    assertNull(GateVerdict.decode(cleared + ("message" to listOf("blocked"))))
  }

  @Test
  fun `a string risk level fails closed`() {
    assertNull(GateVerdict.decode(cleared + ("riskLevel" to "3")))
    assertNull(GateVerdict.decode(cleared + ("riskLevel" to null)))
  }

  // ---- the number widening ---------------------------------------------------

  @Test
  fun `a long or double risk level still decodes`() {
    // The standard channel codec hands back Long/Double for a Dart int, so the
    // decoder widens rather than rejecting an otherwise sound reply.
    assertEquals(3, GateVerdict.decode(cleared + ("riskLevel" to 3L))?.riskLevel)
    assertEquals(3, GateVerdict.decode(cleared + ("riskLevel" to 3.0))?.riskLevel)
    assertEquals(3, GateVerdict.decode(blocked + ("riskLevel" to 3L))?.riskLevel)
    assertEquals(3, GateVerdict.decode(blocked + ("riskLevel" to 3.0))?.riskLevel)
  }

  @Test
  fun `the widening conversion to int is pinned`() {
    // Lossy for a fractional Double. Pinned, not endorsed: any change here is a
    // behaviour change on the only path that can clear a dispatch.
    assertEquals(2, GateVerdict.decode(cleared + ("riskLevel" to 2.9))?.riskLevel)
    assertEquals(-1, GateVerdict.decode(cleared + ("riskLevel" to -1.5))?.riskLevel)
  }

  // ---- the receipt -----------------------------------------------------------

  @Test
  fun `toMap reports every field and the dart provenance`() {
    val map = GateVerdict.decode(blocked)!!.toMap()

    assertEquals(5, map.size)
    assertEquals(false, map["allowed"])
    assertEquals("UI_LOCK", map["message"])
    assertEquals(false, map["needsBiometric"])
    assertEquals(3, map["riskLevel"])
    assertEquals(MainActivity.GATE_SOURCE, map["source"])
    assertEquals("dart:lib/safety/policy_engine.dart", map["source"])
  }

  @Test
  fun `toMap on a cleared verdict still carries the source`() {
    val map = GateVerdict.decode(cleared)!!.toMap()

    assertEquals(true, map["allowed"])
    assertEquals(true, map["needsBiometric"])
    assertEquals("Confirmation required: tap", map["message"])
    assertEquals(2, map["riskLevel"])
    assertEquals(GateVerdict.GATE_SOURCE, map["source"])
    assertEquals(MainActivity.GATE_SOURCE, map["source"])
  }

  @Test
  fun `the source constant is the one the activity advertises`() {
    assertEquals(MainActivity.GATE_SOURCE, GateVerdict.GATE_SOURCE)
    assertEquals("dart:lib/safety/policy_engine.dart", GateVerdict.GATE_SOURCE)
  }

  @Test
  fun `the source on the receipt is stamped here, not taken from the reply`() {
    // The inbound `source` is never decoded, so a reply that names a different
    // authority cannot launder its provenance into the receipt Dart reads.
    val verdict = GateVerdict.decode(cleared + ("source" to "somewhere:else"))

    assertNotNull(verdict)
    assertEquals("dart:lib/safety/policy_engine.dart", verdict!!.toMap()["source"])
    assertEquals(MainActivity.GATE_SOURCE, verdict.toMap()["source"])
  }
}
