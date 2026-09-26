// android/app/src/test/kotlin/com/noir/android/ScreenEventBufferTest.kt
//
// Pure JVM unit tests for the bounded hand-off queue: capacity is a hard bound,
// rejections are counted, and nothing is ever dropped without a labelled reason.
package com.noir.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenEventBufferTest {

  private fun event(id: Long, nodes: Int = 1) = ScreenEvent(
    id = id,
    capturedAtMs = id,
    nodes = (0 until nodes).map { mapOf("text" to "node $it") }
  )

  @Test
  fun `a buffer must have a positive capacity`() {
    val failure = runCatching { BoundedEventBuffer(0) }.exceptionOrNull()
    assertTrue("capacity 0 must be rejected", failure is IllegalArgumentException)
  }

  @Test
  fun `drains in fifo order and counts deliveries`() {
    val buffer = BoundedEventBuffer(4)
    assertEquals(IngestOutcome.ACCEPTED, buffer.ingest(event(1)))
    assertEquals(IngestOutcome.ACCEPTED, buffer.ingest(event(2)))

    val drained = buffer.drain(10)

    assertEquals(listOf(1L, 2L), drained.map { it.id })
    assertEquals(2, buffer.counters().delivered)
    assertEquals(0, buffer.size())
  }

  @Test
  fun `never holds more than capacity events`() {
    val buffer = BoundedEventBuffer(3)
    repeat(3) { assertEquals(IngestOutcome.ACCEPTED, buffer.ingest(event(it.toLong()))) }

    assertEquals(IngestOutcome.DROPPED_OLDEST, buffer.ingest(event(99)))

    val counters = buffer.counters()
    assertEquals("queue grew past capacity", 3, counters.buffered)
    assertEquals(1, counters.dropped)
    assertEquals(BoundedEventBuffer.REASON_BUFFER_FULL, counters.lastDropReason)
    assertEquals(1, counters.dropReasons[BoundedEventBuffer.REASON_BUFFER_FULL])
    // The newest event is the one that survived.
    assertEquals(99L, buffer.peekLatest()?.id)
  }

  @Test
  fun `drain respects its limit and leaves the rest queued`() {
    val buffer = BoundedEventBuffer(5)
    repeat(4) { buffer.ingest(event(it.toLong())) }

    assertEquals(2, buffer.drain(2).size)
    assertEquals(2, buffer.size())
    assertEquals(2, buffer.counters().delivered)
  }

  @Test
  fun `a rejected event is never queued and is counted`() {
    val buffer = BoundedEventBuffer(4) { candidate -> if (candidate.nodes.isEmpty()) null else candidate }

    assertEquals(IngestOutcome.REJECTED, buffer.ingest(event(1, nodes = 0)))

    val counters = buffer.counters()
    assertEquals(0, counters.buffered)
    assertEquals(1, counters.rejected)
    assertEquals(0, counters.dropped)
    assertEquals(BoundedEventBuffer.REASON_REJECTED, counters.lastDropReason)
  }

  @Test
  fun `a validator that throws degrades to rejection, never a crash`() {
    val buffer = BoundedEventBuffer(4) { throw IllegalStateException("sanitizer bug") }

    assertEquals(IngestOutcome.REJECTED, buffer.ingest(event(1)))
    assertEquals(1, buffer.counters().rejected)
    assertEquals(0, buffer.size())
  }

  @Test
  fun `clear discards but records why`() {
    val buffer = BoundedEventBuffer(4)
    repeat(3) { buffer.ingest(event(it.toLong())) }

    assertEquals(3, buffer.clear(BoundedEventBuffer.REASON_NO_SINK))

    val counters = buffer.counters()
    assertEquals(0, counters.buffered)
    assertEquals(3, counters.dropped)
    assertEquals(BoundedEventBuffer.REASON_NO_SINK, counters.lastDropReason)
    assertEquals(3, counters.dropReasons[BoundedEventBuffer.REASON_NO_SINK])
  }

  @Test
  fun `clearing an empty buffer changes nothing`() {
    val buffer = BoundedEventBuffer(2)
    assertEquals(0, buffer.clear(BoundedEventBuffer.REASON_TEARDOWN))
    assertEquals(BoundedEventBuffer.REASON_NONE, buffer.counters().lastDropReason)
  }

  @Test
  fun `counters snapshot is a copy`() {
    val buffer = BoundedEventBuffer(2)
    buffer.ingest(event(1))
    val snapshot = buffer.counters()
    buffer.ingest(event(2))
    buffer.ingest(event(3))

    assertEquals("snapshot mutated with the buffer", 1, snapshot.buffered)
    assertEquals(2, buffer.counters().buffered)
  }

  @Test
  fun `empty counters keep a stable shape`() {
    val map = BufferCounters.empty(capacity = 8).toMap()
    assertEquals(0, map["buffered"])
    assertEquals(0, map["dropped"])
    assertEquals(0, map["rejected"])
    assertEquals(0, map["delivered"])
    assertEquals(8, map["capacity"])
    assertEquals(BoundedEventBuffer.REASON_NONE, map["lastDropReason"])
  }

  @Test
  fun `peekLatest on an empty buffer is null`() {
    assertNull(BoundedEventBuffer(2).peekLatest())
    assertTrue(BoundedEventBuffer(2).isEmpty())
  }

  // ---- wire envelope --------------------------------------------------------

  @Test
  fun `the push envelope keeps the historical contract keys`() {
    val envelope = event(7, nodes = 2).toEnvelope("AgentAccessibilityService")
    for (key in listOf("nodes", "nodeCount", "capturedAtMs", "source")) {
      assertTrue("missing wire key $key", envelope.containsKey(key))
    }
    assertEquals(2, envelope["nodeCount"])
    assertEquals(7L, envelope["capturedAtMs"])
    assertEquals(7L, envelope["eventId"])
    assertEquals("AgentAccessibilityService", envelope["source"])
    assertEquals(false, envelope["truncated"])
  }

  @Test
  fun `a capture that lost nodes says so in the envelope`() {
    val envelope = event(1).copy(droppedNodes = 12).toEnvelope("AgentAccessibilityService")
    assertEquals(12, envelope["droppedNodes"])
    assertEquals(true, envelope["truncated"])
  }

  @Test
  fun `both envelopes agree on the wire contract`() {
    val fromEvent = event(1).toEnvelope("x").keys
    val fromPayload = com.noir.android.ScreenRedactor.sanitizeNodes(listOf(mapOf("text" to "hi")))
      .toEnvelope(1L, "x").keys
    for (key in listOf("nodes", "nodeCount", "capturedAtMs", "source")) {
      assertTrue("missing $key", fromEvent.contains(key) && fromPayload.contains(key))
    }
  }
}
