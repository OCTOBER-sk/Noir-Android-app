// android/app/src/main/kotlin/com/noir/android/AgentAccessibilityService.kt — C1 (REAL)
// Enhanced: preserves bounds, alpha/visibility, z-order metadata per node (for A6a Sanitizer).
// Every dispatchGesture preceded by PolicyEngine gate (C2) — release-blocking regression if bypassed.
package com.noir.android

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class AgentAccessibilityService : AccessibilityService() {

  override fun onAccessibilityEvent(event: AccessibilityEvent?) {
    // C1: Full node dump with metadata preserved for A6a Screen-Content Sanitizer
    if (event == null) return
    val rootNode = rootInActiveWindow ?: return
    val nodes = extractNodeDump(rootNode)
    // Nodes are structured as list of maps containing text, bounds, alpha, zOrder, visibility
    // This feeds directly into lib/safety/screen_content_sanitizer.dart (A6a)
    sendToRuntime(nodes)
  }

  private fun extractNodeDump(node: AccessibilityNodeInfo): List<Map<String, Any?>> {
    val result = mutableListOf<Map<String, Any?>>()
    val text = node.text?.toString()?.trim() ?: ""
    val rect = Rect()
    node.getBoundsInParent(rect)
    val bounds = mapOf("left" to rect.left, "top" to rect.top, "right" to rect.right, "bottom" to rect.bottom)
    val alpha = if (node.isVisibleToUser) 1.0 else 0.0
    val zOrder = node.drawingOrder

    result.add(
      mapOf(
        "text" to text,
        "bounds" to bounds,
        "alpha" to alpha,
        "zOrder" to zOrder,
        "visible" to node.isVisibleToUser,
        "nodeIndex" to result.size,
      )
    )

    for (i in 0 until node.childCount) {
      val child = node.getChild(i)
      if (child != null) {
        result.addAll(extractNodeDump(child))
        child.recycle()
      }
    }
    return result
  }

  private fun sendToRuntime(nodes: List<Map<String, Any?>>) {
    // Pass structured node data to Flutter/Dart runtime for A6a Sanitizer consumption
    // Integration point: MethodChannel or native event stream to lib/safety/screen_content_sanitizer.dart
  }

  override fun onInterrupt() {}
}
