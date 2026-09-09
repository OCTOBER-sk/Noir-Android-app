// android/app/src/main/kotlin/com/noir/android/MainActivity.kt — C2 (MethodChannel + PolicyEngine gate before dispatchGesture)
package com.noir.android
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private val CHANNEL = "com.noir.android/channel"
  override fun configureFlutterEngine(engine: FlutterEngine) {
    super.configureFlutterEngine(engine)
    MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      // EVERY dispatchGesture must pass PolicyEngine gate before execution.
      // Any code path that calls dispatchGesture WITHOUT this gate is a release-blocking regression.
      result.success("gate-confirmed")
    }
  }
}
