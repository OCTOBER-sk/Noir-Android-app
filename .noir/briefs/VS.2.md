Agent: zeus
Task: VS.2 — C1 thin: AccessibilityService event-driven path (V2.1 §C1)

Repo: /home/santhosh/projects/Noir-Android-app
Source: SOURCE_OF_TRUTH.md (V2.1) — follow §C1 (Enhanced AgentAccessibilityService) EXACTLY.

Deliverables (exact paths):
  1. android/app/src/main/kotlin/com/noir/android/AgentAccessibilityService.kt — service that:
     - Extends AccessibilityService
     - Overrides onServiceConnected, onAccessibilityEvent, onInterrupt
     - In onServiceConnected: sets up feedback flags (default: FLAG_INCLUDE_NOT_IMPORTANT_VIEWS)
     - In onAccessibilityEvent: processes events only when a task is active (we will have a placeholder flag for now)
     - Does NOT do continuous polling; only reacts to events
     - Excludes own overlay window (package name com.noir.android)
     - Provides basic health check (e.g., last event timestamp) via a MethodChannel (we will add a simple channel for now)
     - Does not perform any UI actions yet (those will come in later tasks)
  2. Add the service to AndroidManifest.xml (inside <application>):
        <service
            android:name=".AgentAccessibilityService"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/accessibility_service_config" />
        </service>
  3. Create xml/accessibility_service_config.xml in android/app/src/main/res/xml/ with:
        <accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"
            android:accessibilityEventTypes="typeAllMask"
            android:accessibilityFeedbackType="feedbackSpoken"
            android:accessibilityFlags="flagDefault"
            android:canRetrieveWindowContent="true"
            android:canRequestEnhancedWebAccessibility="true"
            android:canRequestFilterKeyEvents="false"
            android:description="@string/accessibility_service_description"
            android:notificationTimeout="100"
            android:packageNames="com.noir.android"
            android:settingsActivity="com.noir.android.SettingsActivity" />
     (We will create the string resource later; for now, use a placeholder)

Constraints:
  - First output = tool call to create/edit the first file. Zero commentary lines.
  - Batch writes: write all files in ONE parallel tool-call block, then run the single verification command.
  - Verification command: ./gradlew :app:compileDebugJavaWithJavac (or ./gradlew :app:compileDebugKotlin) to ensure the Kotlin compiles without errors.
  - Report in <=5 lines: files changed, compilation success/fail, then STOP.
  - Do NOT run the full assembleDebug (takes too long).
  - Do NOT touch files outside the listed deliverables.
  - Exact line anchors: if editing existing files, use the exact line numbers/paths given; do NOT grep/search/explore to rediscover.

Self-review (mandatory): re-read your diff; confirm the service only reacts to events (no polling loop); confirm it excludes own overlay; run the verification command yourself; report files + compile status + any risks. Then STOP.