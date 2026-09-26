// android/app/src/main/kotlin/com/noir/android/AgentAccessibilityService.kt — C1 (REAL)
// Enhanced: preserves bounds, screen bounds, alpha/visibility, z-order and
// identity metadata per node for the A6a Sanitizer, and pushes the dump to the
// Dart runtime over the MethodChannel.
// Every dispatchGesture preceded by the Dart PolicyEngine gate (C2) —
// release-blocking regression if bypassed. This class only *executes* gestures
// that MainActivity has already cleared; it holds no policy rules.
package com.noir.android

import android.accessibilityservice.AccessibilityService
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

    /** Hard cap on nodes per dump: bounds both payload size and walk cost. */
    const val MAX_NODES = 2000

    /** Hard cap on tree depth so a hostile app cannot blow the stack. */
    const val MAX_DEPTH = 60

    /** Screen dumps are throttled; accessibility events arrive in bursts. */
    const val DUMP_THROTTLE_MS = 250L

    @Volatile
    private var liveInstance: AgentAccessibilityService? = null

    /**
     * Set by MainActivity.configureFlutterEngine and cleared in
     * cleanUpFlutterEngine. A null sink means no Dart runtime is attached, in
     * which case dumps are dropped instead of queued forever.
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

    /** Envelope pushed to Dart and returned by `getNodes`. */
    @JvmStatic
    fun payloadOf(nodes: List<Map<String, Any?>>): Map<String, Any?> = mapOf(
      "nodes" to ArrayList<Map<String, Any?>>(nodes),
      "nodeCount" to nodes.size,
      "capturedAtMs" to SystemClock.uptimeMillis(),
      "source" to TAG
    )
  }

  private val mainHandler = Handler(Looper.getMainLooper())

  @Volatile
  private var latestNodes: List<Map<String, Any?>>? = null

  private var lastDumpAtMs = 0L
  private var dumpScheduled = false
  private var destroyed = false

  // Per-walk budget/counters. Only touched on the main thread.
  private var nodeBudget = 0
  private var nodeIndex = 0

  override fun onServiceConnected() {
    super.onServiceConnected()
    liveInstance = this
    Log.i(TAG, "AccessibilityService connected; canPerformGestures=${serviceInfo?.canPerformGestures ?: false}")
  }

  override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    // C1: full node dump with metadata preserved for the A6a Sanitizer, but
    // only for the window events that can actually change the tree.
    if (event == null) return
    if (event.eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
      event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
    ) return
    scheduleDump()
  }

  override fun onInterrupt() {}

  override fun onDestroy() {
    destroyed = true
    if (liveInstance === this) liveInstance = null
    mainHandler.removeCallbacksAndMessages(null)
    super.onDestroy()
  }

  // ---- C1: capture + push ---------------------------------------------------

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
    if (destroyed) return
    val root = rootInActiveWindow ?: return
    beginWalk()
    val nodes = walk(root, depth = 0)
    // rootInActiveWindow must not be recycled (recycle() is deprecated from
    // API 33 and the node is owned by the framework), so let it be collected.
    lastDumpAtMs = SystemClock.uptimeMillis()
    latestNodes = nodes
    sendToRuntime(nodes)
  }

  /**
   * Fresh dump of the current window, for an explicit `getNodes` request from
   * Dart. Must be called on the main thread. Returns null when there is no
   * active window, so the caller can distinguish "no window" from "no nodes".
   */
  fun captureNow(): List<Map<String, Any?>>? {
    if (destroyed) return null
    val root = rootInActiveWindow ?: return null
    beginWalk()
    val nodes = walk(root, depth = 0)
    lastDumpAtMs = SystemClock.uptimeMillis()
    latestNodes = nodes
    return nodes
  }

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
   * C1: hand the structured node dump to the Dart runtime for the A6a
   * Sanitizer. MainActivity installs [runtimeSink] and turns this into a
   * `screenNodes` MethodChannel push, which lib/platform/native_bridge.dart
   * turns into a SanitizedResult.
   */
  private fun sendToRuntime(nodes: List<Map<String, Any?>>) {
    if (nodes.isEmpty()) return
    val sink = runtimeSink
    if (sink == null) {
      Log.w(TAG, "No runtime sink installed; dropping node dump of ${nodes.size} nodes")
      return
    }
    val payload = payloadOf(nodes)
    // Accessibility callbacks arrive on the main thread, but the sink may be
    // invoked from a worker if a dump is ever taken off-thread; post anyway.
    if (Looper.myLooper() == Looper.getMainLooper()) {
      deliver(sink, payload)
    } else {
      mainHandler.post { deliver(sink, payload) }
    }
  }

  private fun deliver(sink: NodeDumpSink, payload: Map<String, Any?>) {
    if (destroyed) return
    try {
      sink.accept(payload)
    } catch (t: Throwable) {
      Log.e(TAG, "runtime sink rejected node dump: ${t.javaClass.simpleName}", t)
    }
  }

  // ---- C2 execution: MainActivity calls this only after the Dart gate -------

  /**
   * Real AccessibilityService.dispatchGesture. The caller (MainActivity
   * .executeGesture) is the single owner of the gate, and this method must
   * never be reachable without a cleared Dart PolicyEngine verdict.
   * Must be called on the main thread.
   */
  fun dispatchGestureNow(
    description: GestureDescription,
    callback: AccessibilityService.GestureResultCallback
  ): Boolean {
    if (destroyed || liveInstance !== this) return false
    if (serviceInfo?.canPerformGestures != true) {
      Log.w(TAG, "canPerformGestures is not enabled; refusing to dispatch")
      return false
    }
    return try {
      // A null callback handler means the main looper.
      dispatchGesture(description, callback, null)
    } catch (t: Throwable) {
      Log.e(TAG, "dispatchGesture threw ${t.javaClass.simpleName}", t)
      false
    }
  }

  /** Runtime truth used by `serviceStatus`; surfaces a missing manifest flag. */
  fun statusSnapshot(): Map<String, Any?> {
    val info = try {
      serviceInfo
    } catch (t: Throwable) {
      null
    }
    val nodes = latestNodes
    return mapOf(
      "serviceConnected" to (liveInstance === this),
      "canPerformGestures" to (info?.canPerformGestures ?: false),
      "canRetrieveWindowContent" to (info?.canRetrieveWindowContent ?: false),
      "hasNodeDump" to (nodes != null),
      "lastNodeCount" to (nodes?.size ?: 0),
      "runtimeSinkInstalled" to (runtimeSink != null)
    )
  }

  /** Per-walk budget/counter reset. Only called on the main thread. */
  private fun beginWalk() {
    nodeBudget = MAX_NODES
    nodeIndex = 0
  }
}

/** Short name for the sink SAM, so MainActivity reads cleanly. */
typealias ScreenNodeSink = AgentAccessibilityService.NodeDumpSink
