package com.noir.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.annotation.SuppressLint
import android.content.Intent
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class AgentAccessibilityService : AccessibilityService() {

    private var isTaskActive = false
    private var lastEventTimeMillis: Long = 0

    override fun onServiceConnected() {
        super.onServiceConnected()
        val info = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_SPOKEN
            notificationTimeout = 100
            flags = AccessibilityServiceInfo.FLAG_DEFAULT
        }
        serviceInfo = info
    }

    @SuppressLint("MissingSuperCall")
    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        // Only process events when a task is active
        if (!isTaskActive) return

        // Exclude our own overlay windows
        val packageName = event.packageName?.toString()
        if (packageName == "com.noir.android") return

        lastEventTimeMillis = System.currentTimeMillis()
        // TODO: Process event for task execution
    }

    override fun onInterrupt() {
        // Service interrupted, clean up if needed
        isTaskActive = false
    }

    /** Called from Dart to set task active state */
    fun setTaskActive(active: Boolean) {
        isTaskActive = active
        if (!active) {
            lastEventTimeMillis = 0
        }
    }

    /** Called from Dart to get last event time */
    fun getLastEventTimeMillis(): Long {
        return lastEventTimeMillis
    }
}