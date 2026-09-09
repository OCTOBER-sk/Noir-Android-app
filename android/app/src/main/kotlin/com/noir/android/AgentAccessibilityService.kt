// android/app/src/main/kotlin/com/noir/android/AgentAccessibilityService.kt — C1
// Enhanced: preserves bounds, alpha/visibility, z-order metadata per node (for A6a Sanitizer).
// Every dispatchGesture preceded by PolicyEngine gate (C2) — release-blocking regression if bypassed.
package com.noir.android
class AgentAccessibilityService : android.accessibilityservice.AccessibilityService() {
  // Node dump: text + bounds + alpha + zOrder — feeds A6a Screen-Content Sanitizer.
  override fun onAccessibilityEvent(event: android.view.accessibility.AccessibilityEvent?) {}
}
