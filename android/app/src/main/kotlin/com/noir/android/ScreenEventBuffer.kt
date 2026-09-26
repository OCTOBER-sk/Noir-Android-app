// android/app/src/main/kotlin/com/noir/android/ScreenEventBuffer.kt — R2 (pure)
//
// Bounded, sanitized hand-off queue between capture and the Dart runtime.
//
// PURE KOTLIN BY CONTRACT: no android.* imports, no clock, no randomness.
// android/app/src/test/** exercises the bounds and the counters directly.
//
// Design rules that the tests pin down:
//
//   * Bounded. The queue never holds more than `capacity` events; the oldest is
//     evicted (and counted) rather than growing without limit.
//   * Sanitized before it can leave the service. The caller sanitizes, and the
//     `validator` is the last gate: returning null rejects the event outright.
//   * Never silently discarded. Every eviction and every rejection lands in a
//     counter *and* in a labelled reason map, so "we dropped something" is
//     visible in `serviceStatus` instead of being a mystery.
package com.noir.android

import java.util.ArrayDeque

/** One sanitized screen observation, ready for delivery. */
data class ScreenEvent(
  val id: Long,
  val capturedAtMs: Long,
  val nodes: List<Map<String, Any?>>,
  val droppedNodes: Int = 0,
  val redactedFields: Int = 0,
  val charSize: Int = 0
)

/**
 * Wire envelope for the `screenNodes` push.
 *
 * The first four keys are the historical contract read by
 * lib/platform/native_bridge.dart; the rest is additive transparency about what
 * redaction and the caps did to this capture.
 */
fun ScreenEvent.toEnvelope(source: String): Map<String, Any?> = mapOf(
  "nodes" to ArrayList<Map<String, Any?>>(nodes),
  "nodeCount" to nodes.size,
  "capturedAtMs" to capturedAtMs,
  "source" to source,
  "eventId" to id,
  "redactedFields" to redactedFields,
  "droppedNodes" to droppedNodes,
  "charSize" to charSize,
  // Parenthesised on purpose: `to` is an infix function and binds LOOSER than
  // `>`, so `a to b > c` parses as `(a to b) > c` and does not compile.
  "truncated" to (droppedNodes > 0)
)

/** Outcome of one [BoundedEventBuffer.ingest] call. */
enum class IngestOutcome {
  /** Queued; nothing was lost. */
  ACCEPTED,

  /** Refused by the validator. Counted as `rejected`. */
  REJECTED,

  /** Queued, but the oldest queued event had to be evicted to make room. */
  DROPPED_OLDEST
}

/** Immutable snapshot of the buffer, safe to hand to the MethodChannel. */
data class BufferCounters(
  val buffered: Int,
  val dropped: Int,
  val rejected: Int,
  val delivered: Int,
  val capacity: Int,
  val lastDropReason: String,
  val dropReasons: Map<String, Int>
) {
  fun toMap(): Map<String, Any?> = mapOf(
    "buffered" to buffered,
    "dropped" to dropped,
    "rejected" to rejected,
    "delivered" to delivered,
    "capacity" to capacity,
    "lastDropReason" to lastDropReason,
    "dropReasons" to LinkedHashMap(dropReasons)
  )

  companion object {
    /** Zeroed counters, used when the service is not connected so the
     *  `serviceStatus` reply keeps one stable shape in every state. */
    fun empty(capacity: Int): BufferCounters = BufferCounters(
      buffered = 0,
      dropped = 0,
      rejected = 0,
      delivered = 0,
      capacity = capacity,
      lastDropReason = "none",
      dropReasons = emptyMap()
    )
  }
}

class BoundedEventBuffer(
  capacity: Int,
  private val validator: (ScreenEvent) -> ScreenEvent? = { it }
) {
  private val capacity: Int = capacity
  private val lock = Any()
  private val queue = ArrayDeque<ScreenEvent>()
  private val dropReasons = LinkedHashMap<String, Int>()

  private var dropped = 0
  private var rejected = 0
  private var delivered = 0
  private var lastDropReason = REASON_NONE

  init {
    require(this.capacity > 0) { "BoundedEventBuffer capacity must be > 0, was $capacity" }
  }

  /**
   * Sanitizes (via [validator]) and queues [event].
   *
   * A `null` from the validator is a rejection, not a drop: rejected events were
   * never legitimate, whereas drops were legitimate but had no room.
   */
  fun ingest(event: ScreenEvent): IngestOutcome = synchronized(lock) {
    val accepted = try {
      validator(event)
    } catch (_: Throwable) {
      // A validator that throws degrades to "rejected": never a crash, and
      // never an unsanitized pass-through.
      null
    }
    if (accepted == null) {
      rejected++
      lastDropReason = REASON_REJECTED
      record(REASON_REJECTED)
      return IngestOutcome.REJECTED
    }
    if (queue.size >= capacity) {
      queue.pollFirst()
      dropped++
      lastDropReason = REASON_BUFFER_FULL
      record(REASON_BUFFER_FULL)
      queue.addLast(accepted)
      return IngestOutcome.DROPPED_OLDEST
    }
    queue.addLast(accepted)
    IngestOutcome.ACCEPTED
  }

  /** Removes and returns up to [maxEvents] events, oldest first. */
  fun drain(maxEvents: Int): List<ScreenEvent> = synchronized(lock) {
    val limit = maxEvents.coerceIn(0, queue.size)
    val out = ArrayList<ScreenEvent>(limit)
    while (out.size < limit) {
      val next = queue.pollFirst() ?: break
      out.add(next)
    }
    delivered += out.size
    out
  }

  fun size(): Int = synchronized(lock) { queue.size }

  fun isEmpty(): Boolean = size() == 0

  /** Most recently queued event, still owned by the buffer. */
  fun peekLatest(): ScreenEvent? = synchronized(lock) { queue.peekLast() }

  /**
   * Empties the buffer, counting every queued event as dropped under [reason].
   * Used when a capture can no longer be delivered (no Dart runtime attached)
   * and on teardown, so nothing disappears without a trace.
   */
  fun clear(reason: String): Int = synchronized(lock) {
    val discarded = queue.size
    if (discarded > 0) {
      queue.clear()
      dropped += discarded
      lastDropReason = reason
      record(reason, discarded)
    }
    discarded
  }

  fun counters(): BufferCounters = synchronized(lock) {
    BufferCounters(
      buffered = queue.size,
      dropped = dropped,
      rejected = rejected,
      delivered = delivered,
      capacity = capacity,
      lastDropReason = lastDropReason,
      dropReasons = LinkedHashMap(dropReasons)
    )
  }

  /** `dropReasons` counts EVENTS, so the map always sums to `dropped`. */
  private fun record(reason: String, count: Int = 1) {
    dropReasons[reason] = (dropReasons[reason] ?: 0) + count
  }

  companion object {
    const val REASON_NONE = "none"
    const val REASON_REJECTED = "rejected_by_validator"
    const val REASON_BUFFER_FULL = "buffer_full"
    const val REASON_NO_SINK = "no_runtime_sink"
    const val REASON_TEARDOWN = "service_teardown"
    const val REASON_REARMED = "capture_rearmed"
  }
}
