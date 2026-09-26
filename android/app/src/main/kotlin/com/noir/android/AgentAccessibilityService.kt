// android/app/src/main/kotlin/com/noir/android/AgentAccessibilityService.kt — C1 (REAL)
//
// The screen-capture half of the bridge. What this file guarantees, and what
// its unit tests plus lib/platform/native_bridge.dart depend on:
//
//   * DEFAULT DENY (R1). Event-driven capture is DISARMED until a user-
//     initiated moment arms it, and even then only for a bounded window. With
//     no live user request the service reads no window and pushes nothing;
//     `suppressedEvents` counts those refusals so they are visible instead of
//     mysterious.
//   * BOUNDED + SANITIZED (R2/R3). Every capture is redacted and size-capped by
//     ScreenRedactor before it reaches the hand-off queue, the queue itself is
//     capacity-bounded, and every drop and rejection is counted and labelled in
//     `serviceStatus`. Nothing is ever discarded silently.
//   * CONSENT-BOUNDED GESTURES (R5). `dispatchGestureNow` requires a live
//     ConsentToken and a positive AccessibilityServiceInfo capability bit.
//     Missing capability information is a refusal, never an assumption.
//
// Every dispatch is preceded by the Dart PolicyEngine gate (C2), which
// MainActivity owns. This class only *executes* gestures MainActivity has
// already cleared; it holds no policy rules.
package com.noir.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class AgentAccessibilityService : AccessibilityService() {

  /** Where a captured node dump is delivered. Installed by MainActivity. */
  fun interface NodeDumpSink {
    fun accept(payload: Map<String, Any?>)
  }

  companion object {
    private const val TAG = "AgentAccessibilityService"

    /** Hard cap on nodes per raw dump: bounds both payload size and walk cost.
     *  ScreenRedactor applies the (smaller) wire cap afterwards. */
    const val MAX_NODES = 2000

    /** Hard cap on tree depth so a hostile app cannot blow the stack. */
    const val MAX_DEPTH = 60

    /** Screen dumps are throttled; accessibility events arrive in bursts. */
    const val DUMP_THROTTLE_MS = 250L

    /** Bounded hand-off queue: at most this many sanitized captures may wait
     *  for the Dart runtime. Beyond it the OLDEST is evicted and counted. */
    const val MAX_BUFFERED_EVENTS = 8

    /** Deliveries per flush, so one dump cannot monopolise the main looper. */
    const val MAX_DELIVER_PER_FLUSH = 2

    /** Longest a user-initiated arm can survive without being re-armed. */
    const val CAPTURE_ARM_TTL_MS = 30_000L

    /** Provenance for `serviceStatus`: the service is only ever bound by the
     *  user in Settings, never started by the app. */
    const val SOURCE_USER_ENABLED = "user_enabled_in_settings"

    const val SOURCE_NOT_ENABLED = "not_enabled_in_settings"

    const val CAPTURE_DISARMED = "no_user_request"

    const val REJECT_NO_CAPABILITY = "gesture_capability_unavailable"
    const val REJECT_NO_CONSENT = "consent_not_live"
    const val REJECT_NOT_LIVE = "service_not_live"
    const val REJECT_DISPATCH_THREW = "dispatch_threw"
    const val REJECT_DISPATCH_REFUSED = "dispatch_refused_by_platform"

    private val TRACKED_EVENT_TYPES = setOf(
      AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
      AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
    )

    @Volatile
    private var liveInstance: AgentAccessibilityService? = null

    /**
     * Set by MainActivity.configureFlutterEngine and cleared in
     * cleanUpFlutterEngine. A null sink means no Dart runtime is attached, in
     * which case queued captures are dropped *and counted* rather than kept
     * forever or delivered into a dead engine.
     */
    @Volatile
    @JvmStatic
    var runtimeSink: NodeDumpSink? = null

    /**
     * The live service instance, or null when the service is not enabled.
     * This is the handle MainActivity needs: dispatchGesture is an instance
     * method on AccessibilityService, so there is nothing to call without it.
     */
    @JvmStatic
    fun current(): AgentAccessibilityService? = liveInstance

    @JvmStatic
    fun isConnected(): Boolean = liveInstance != null

    /** Reply envelope for `getNodes`; shape is the historical contract. */
    @JvmStatic
    fun payloadOf(payload: ScreenRedactor.NodePayload): Map<String, Any?> =
      payload.toEnvelope(SystemClock.uptimeMillis(), TAG)

    /**
     * The same reply shape as [statusSnapshot] with every value zeroed.
     *
     * `serviceStatus` must have ONE shape in every state: lib/platform/
     * accessibility_status.dart fails the whole reply closed when a key is
     * missing, and a disconnected service has to be reportable too.
     */
    @JvmStatic
    fun disconnectedStatus(): Map<String, Any?> {
      val counters = BufferCounters.empty(MAX_BUFFERED_EVENTS)
      return LinkedHashMap<String, Any?>().apply {
        put("serviceConnected", false)
        put("canPerformGestures", false)
        put("canRetrieveWindowContent", false)
        put("hasNodeDump", false)
        put("lastNodeCount", 0)
        put("runtimeSinkInstalled", false)
        put("serviceSource", SOURCE_NOT_ENABLED)
        put("bufferCounters", counters.toMap())
        put("bufferedEvents", counters.buffered)
        put("droppedEvents", counters.dropped)
        put("rejectedEvents", counters.rejected)
        put("deliveredEvents", counters.delivered)
        put("bufferCapacity", counters.capacity)
        put("lastDropReason", counters.lastDropReason)
        put("dropReasons", LinkedHashMap<String, Int>())
        put("captures", 0)
        put("suppressedEvents", 0)
        put("redactedFields", 0)
        put("droppedNodes", 0)
        put("lastPayloadChars", 0)
        put("maxPayloadChars", ScreenRedactor.MAX_PAYLOAD_CHARS)
        put("maxFieldChars", ScreenRedactor.MAX_FIELD_CHARS)
        put("maxNodesPerPayload", ScreenRedactor.MAX_NODES_PER_PAYLOAD)
        put("gesturesDispatched", 0)
        put("gesturesRejected", 0)
        put("lastGestureRejection", "none")
        put("captureArmed", false)
        put("captureArmReason", CAPTURE_DISARMED)
        put("captureArmExpiresInMs", 0L)
      }
    }
  }

  private val mainHandler = Handler(Looper.getMainLooper())

  /**
   * Bounded, sanitized hand-off queue. Its validator is the last gate before a
   * capture may leave this process: an event with no nodes is rejected rather
   * than pushed as an empty screen.
   */
  private val eventBuffer = BoundedEventBuffer(MAX_BUFFERED_EVENTS) { event ->
    event.takeIf { it.nodes.isNotEmpty() }
  }

  @Volatile
  private var latestNodes: List<Map<String, Any?>>? = null

  @Volatile
  private var lastPayload: ScreenRedactor.NodePayload? = null

  @Volatile
  private var captureArmedUntilMs = 0L

  @Volatile
  private var captureArmReason = CAPTURE_DISARMED

  private var lastDumpAtMs = 0L
  private var dumpScheduled = false
  private var destroyed = false

  // Monotonic capture id, so a reply can be tied to a push.
  private var eventSequence = 0L

  // Counters. Every one of these is surfaced in statusSnapshot().
  private var captures = 0
  private var suppressedEvents = 0
  private var redactedFieldsTotal = 0
  private var droppedNodesTotal = 0
  private var gesturesDispatched = 0
  private var gesturesRejected = 0
  private var lastGestureRejection = "none"

  // Per-walk budget/counters. Only touched on the main thread.
  private var nodeBudget = 0
  private var nodeIndex = 0

  override fun onServiceConnected() {
    super.onServiceConnected()
    liveInstance = this
    Log.i(
      TAG,
      "AccessibilityService connected (user-enabled); canPerformGestures=${canPerformGesturesNow()}"
    )
  }

  override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    // C1: full node dump with metadata preserved for the A6a Sanitizer, but
    // only for the window events that can actually change the tree, and only
    // while a user request is live.
    if (event == null) return
    if (event.eventType !in TRACKED_EVENT_TYPES) return
    if (!isCaptureArmed()) {
      // Default deny. The user has not asked for anything, so the window is not
      // read at all. Counted so the absence is auditable, not silent.
      suppressedEvents++
      return
    }
    scheduleDump()
  }

  override fun onInterrupt() {
    // An interrupt means the system wants the service to stop acting. Drop
    // anything armed rather than resuming on the next event.
    disarmCapture("system_interrupt")
  }

  override fun onDestroy() {
    destroyed = true
    disarmCapture("service_destroyed")
    if (liveInstance === this) liveInstance = null
    val discarded = eventBuffer.clear(BoundedEventBuffer.REASON_TEARDOWN)
    if (discarded > 0) Log.i(TAG, "dropped $discarded buffered capture(s) on teardown")
    mainHandler.removeCallbacksAndMessages(null)
    super.onDestroy()
  }

  // ---- R1: consent-bound capture arming ------------------------------------

  /**
   * Allows event-driven capture for a bounded window.
   *
   * The only callers are in MainActivity, and only from a user-initiated
   * moment: the user bringing the app to the foreground, or a `beginUserRequest`
   * call that carries a fresh consent token. This arms *observation*; it never
   * arms a gesture.
   */
  fun armCapture(reason: String, ttlMs: Long = CAPTURE_ARM_TTL_MS): Boolean {
    if (destroyed) return false
    val window = ttlMs.coerceIn(1_000L, CAPTURE_ARM_TTL_MS)
    captureArmedUntilMs = SystemClock.uptimeMillis() + window
    captureArmReason = reason
    return true
  }

  /** Stops event-driven capture. Safe to call when already disarmed. */
  fun disarmCapture(reason: String): Boolean {
    val wasArmed = isCaptureArmed()
    captureArmedUntilMs = 0L
    captureArmReason = reason
    return wasArmed
  }

  fun isCaptureArmed(): Boolean = !destroyed && SystemClock.uptimeMillis() < captureArmedUntilMs

  fun captureArmExpiryInMs(): Long =
    (captureArmedUntilMs - SystemClock.uptimeMillis()).coerceAtLeast(0L)

  // ---- C1: capture, sanitize, buffer, push ---------------------------------

  /** Throttled capture: at most one dump per DUMP_THROTTLE_MS. */
  private fun scheduleDump() {
    if (dumpScheduled || destroyed) return
    val now = SystemClock.uptimeMillis()
    val elapsed = now - lastDumpAtMs
    if (elapsed < DUMP_THROTTLE_MS) {
      dumpScheduled = true
      mainHandler.postDelayed({
        dumpScheduled = false
        captureAndSend()
      }, DUMP_THROTTLE_MS - elapsed)
    } else {
      captureAndSend()
    }
  }

  private fun captureAndSend() {
    if (!isCaptureArmed()) {
      // The arm expired between the event and the scheduled dump.
      suppressedEvents++
      return
    }
    val payload = captureSanitized() ?: return
    val event = ScreenEvent(
      id = ++eventSequence,
      capturedAtMs = SystemClock.uptimeMillis(),
      nodes = payload.nodes,
      droppedNodes = payload.droppedNodes,
      redactedFields = payload.redactedFields,
      charSize = payload.charSize
    )
    when (eventBuffer.ingest(event)) {
      IngestOutcome.REJECTED -> Log.w(TAG, "capture #${event.id} rejected before delivery")
      IngestOutcome.DROPPED_OLDEST ->
        Log.w(TAG, "capture buffer full; evicted the oldest of $MAX_BUFFERED_EVENTS pending captures")
      IngestOutcome.ACCEPTED -> Unit
    }
    flush()
  }

  /**
   * Drains the buffer into the Dart runtime.
   *
   * With no runtime attached the queued captures are dropped *with a counted
   * reason*: holding them would leak memory, and dropping them silently would
   * make the loss impossible to explain.
   */
  private fun flush() {
    if (eventBuffer.isEmpty()) return
    val sink = runtimeSink
    if (sink == null) {
      val discarded = eventBuffer.clear(BoundedEventBuffer.REASON_NO_SINK)
      Log.w(TAG, "no Dart runtime attached; dropped $discarded capture(s) as ${BoundedEventBuffer.REASON_NO_SINK}")
      return
    }
    for (event in eventBuffer.drain(MAX_DELIVER_PER_FLUSH)) deliver(sink, event)
  }

  /**
   * Fresh, sanitized dump of the current window.
   *
   * Serves the explicit `getNodes` request from Dart (a direct reply, not the
   * event-driven path) and the event-driven capture. Must be called on the main
   * thread. Returns null when there is no active window, so the caller can tell
   * "no window" from "no nodes".
   */
  fun captureSanitized(): ScreenRedactor.NodePayload? {
    val raw = captureNow() ?: return null
    val payload = ScreenRedactor.sanitizeNodes(raw)
    captures++
    redactedFieldsTotal += payload.redactedFields
    droppedNodesTotal += payload.droppedNodes
    lastPayload = payload
    latestNodes = payload.nodes
    return payload
  }

  /**
   * Fresh RAW dump of the current window. Private on purpose: raw node text is
   * unredacted, so there must be no public path to it. Everything that leaves
   * this class goes through [captureSanitized] first. Must be called on the
   * main thread. Returns null when there is no active window.
   */
  private fun captureNow(): List<Map<String, Any?>>? {
    if (destroyed) return null
    val root = rootInActiveWindow ?: return null
    beginWalk()
    val nodes = walk(root, depth = 0)
    // rootInActiveWindow must not be recycled (recycle() is deprecated from
    // API 33 and the node is owned by the framework), so let it be collected.
    lastDumpAtMs = SystemClock.uptimeMillis()
    return nodes
  }

  /** The last sanitized dump this service actually pushed, if any. */
  fun latestNodeDump(): List<Map<String, Any?>>? = latestNodes

  /**
   * Full node metadata walk. Child nodes are intentionally not recycled: that
   * is deprecated from API 33 and unnecessary for a read-only snapshot.
   */
  private fun walk(node: AccessibilityNodeInfo, depth: Int): List<Map<String, Any?>> {
    if (nodeBudget <= 0 || depth > MAX_DEPTH) return emptyList()

    val result = mutableListOf<Map<String, Any?>>()
    val parentBounds = Rect()
    node.getBoundsInParent(parentBounds)
    val screenBounds = Rect()
    node.getBoundsInScreen(screenBounds)
    val visible = node.isVisibleToUser

    result.add(
      mapOf(
        "text" to (node.text?.toString()?.trim() ?: ""),
        "contentDescription" to (node.contentDescription?.toString()?.trim() ?: ""),
        "className" to (node.className?.toString() ?: ""),
        "packageName" to (node.packageName?.toString() ?: ""),
        "viewIdResourceName" to (node.viewIdResourceName ?: ""),
        "clickable" to node.isClickable,
        "editable" to node.isEditable,
        "bounds" to rectToMap(parentBounds),
        "screenBounds" to rectToMap(screenBounds),
        // A6a: alpha is what the sanitizer uses to catch hidden-injection nodes.
        "alpha" to (if (visible) 1.0 else 0.0),
        "zOrder" to node.drawingOrder,
        "visible" to visible,
        "depth" to depth,
        "nodeIndex" to nodeIndex++
      )
    )
    nodeBudget--

    for (i in 0 until node.childCount) {
      if (nodeBudget <= 0) break
      val child = node.getChild(i) ?: continue
      result.addAll(walk(child, depth + 1))
    }
    return result
  }

  private fun rectToMap(rect: Rect): Map<String, Any?> = mapOf(
    "left" to rect.left,
    "top" to rect.top,
    "right" to rect.right,
    "bottom" to rect.bottom
  )

  /**
   * C1: hand the sanitized node dump to the Dart runtime for the A6a
   * Sanitizer. MainActivity installs [runtimeSink] and turns this into a
   * `screenNodes` MethodChannel push, which lib/platform/native_bridge.dart
   * turns into a SanitizedResult.
   */
  private fun deliver(sink: NodeDumpSink, event: ScreenEvent) {
    if (destroyed) return
    val payload = event.toEnvelope(TAG)
    // Accessibility callbacks arrive on the main thread, but the sink may be
    // invoked from a worker if a dump is ever taken off-thread; post anyway.
    if (Looper.myLooper() == Looper.getMainLooper()) {
      accept(sink, payload)
    } else {
      mainHandler.post { accept(sink, payload) }
    }
  }

  private fun accept(sink: NodeDumpSink, payload: Map<String, Any?>) {
    if (destroyed) return
    try {
      sink.accept(payload)
    } catch (t: Throwable) {
      Log.e(TAG, "runtime sink rejected node dump: ${t.javaClass.simpleName}", t)
    }
  }

  // ---- C2 execution: MainActivity calls this only after the Dart gate -------

  /**
   * Real AccessibilityService.dispatchGesture.
   *
   * The caller (MainActivity.executeGesture) is the single owner of the gate,
   * and this method must never be reachable without a cleared Dart PolicyEngine
   * verdict *and* a live user request token. Both are re-checked here so a
   * future caller cannot skip either. Must be called on the main thread.
   */
  fun dispatchGestureNow(
    description: GestureDescription,
    token: ConsentToken?,
    callback: AccessibilityService.GestureResultCallback
  ): Boolean {
    if (destroyed || liveInstance !== this) return rejectGesture(REJECT_NOT_LIVE)
    if (!canPerformGesturesNow()) return rejectGesture(REJECT_NO_CAPABILITY)
    if (token == null || !token.isValidAt(SystemClock.uptimeMillis())) {
      return rejectGesture(REJECT_NO_CONSENT)
    }
    val accepted = try {
      // A null callback handler means the main looper.
      dispatchGesture(description, callback, null)
    } catch (t: Throwable) {
      Log.e(TAG, "dispatchGesture threw ${t.javaClass.simpleName}", t)
      return rejectGesture(REJECT_DISPATCH_THREW)
    }
    if (!accepted) return rejectGesture(REJECT_DISPATCH_REFUSED)
    gesturesDispatched++
    lastGestureRejection = "none"
    return true
  }

  /** Records a refusal and returns false, so every branch reads the same. */
  private fun rejectGesture(reason: String): Boolean {
    gesturesRejected++
    lastGestureRejection = reason
    Log.w(TAG, "gesture refused: $reason")
    return false
  }

  /**
   * The AccessibilityServiceInfo capability bits, or null when the platform
   * will not say (a throwing or absent serviceInfo). null is what makes
   * [canPerformGesturesNow] fail closed.
   */
  fun gestureCapabilities(): Int? {
    val info = try {
      serviceInfo
    } catch (t: Throwable) {
      null
    }
    return try {
      info?.getCapabilities()
    } catch (t: Throwable) {
      null
    }
  }

  /**
   * True only on a positive capability bit. `capabilities == null` (a throwing
   * or absent serviceInfo) is what makes both capability answers fail closed.
   */
  fun canPerformGesturesNow(): Boolean = hasCapabilityNow(
    AccessibilityServiceInfo.CAPABILITY_CAN_PERFORM_GESTURES
  )

  /**
   * Same question for capture, asked the same way.
   *
   * Read from the capability bitmask rather than the deprecated
   * `AccessibilityServiceInfo.canRetrieveWindowContent` flag: in AOSP that
   * getter is itself defined as this bit, so nothing is lost and the answer
   * cannot come from a field the platform has stopped maintaining.
   */
  fun canRetrieveWindowContentNow(): Boolean = hasCapabilityNow(
    AccessibilityServiceInfo.CAPABILITY_CAN_RETRIEVE_WINDOW_CONTENT
  )

  private fun hasCapabilityNow(mask: Int): Boolean =
    GestureGate.hasCapability(gestureCapabilities(), mask)

  /** Runtime truth used by `serviceStatus`; surfaces a missing manifest flag. */
  fun statusSnapshot(): Map<String, Any?> {
    val counters = eventBuffer.counters()
    val nodes = latestNodes
    val payload = lastPayload
    return LinkedHashMap<String, Any?>().apply {
      put("serviceConnected", liveInstance === this@AgentAccessibilityService)
      put("canPerformGestures", canPerformGesturesNow())
      put("canRetrieveWindowContent", canRetrieveWindowContentNow())
      put("hasNodeDump", nodes != null)
      put("lastNodeCount", nodes?.size ?: 0)
      put("runtimeSinkInstalled", runtimeSink != null)
      put("serviceSource", SOURCE_USER_ENABLED)
      put("bufferCounters", counters.toMap())
      put("bufferedEvents", counters.buffered)
      put("droppedEvents", counters.dropped)
      put("rejectedEvents", counters.rejected)
      put("deliveredEvents", counters.delivered)
      put("bufferCapacity", counters.capacity)
      put("lastDropReason", counters.lastDropReason)
      put("dropReasons", LinkedHashMap(counters.dropReasons))
      put("captures", captures)
      put("suppressedEvents", suppressedEvents)
      put("redactedFields", redactedFieldsTotal)
      put("droppedNodes", droppedNodesTotal)
      put("lastPayloadChars", payload?.charSize ?: 0)
      put("maxPayloadChars", ScreenRedactor.MAX_PAYLOAD_CHARS)
      put("maxFieldChars", ScreenRedactor.MAX_FIELD_CHARS)
      put("maxNodesPerPayload", ScreenRedactor.MAX_NODES_PER_PAYLOAD)
      put("gesturesDispatched", gesturesDispatched)
      put("gesturesRejected", gesturesRejected)
      put("lastGestureRejection", lastGestureRejection)
      put("captureArmed", isCaptureArmed())
      put("captureArmReason", captureArmReason)
      put("captureArmExpiresInMs", captureArmExpiryInMs())
    }
  }

  /** Per-walk budget/counter reset. Only called on the main thread. */
  private fun beginWalk() {
    nodeBudget = MAX_NODES
    nodeIndex = 0
  }
}

/** Short name for the sink SAM, so MainActivity reads cleanly. */
typealias ScreenNodeSink = AgentAccessibilityService.NodeDumpSink
