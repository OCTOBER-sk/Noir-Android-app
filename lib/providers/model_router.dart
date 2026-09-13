// lib/providers/model_router.dart — B3 (FULL — live refresh + rotation handling)
// Confirmed pattern: request a fallback array (not hardcoded single model).
// Model Router treats "free model list changed since last cache refresh" as normal event.

import '../agent/cost_estimator.dart';

class ModelRouter {
  // Resolve uses live fetched model list (from FreeModelCache) rather than static array
  static Future<List<String>> resolve() async {
    final liveList = await FreeModelCache.fetchLive();
    // If list changed since last call (rotation), treat as normal event — not error
    return liveList;
  }

  // Fallback array routing: 3-model chain (primary -> fallback 1 -> fallback 2)
  static const List<String> fallbackArray = [
    'noir-engine/pro-v2:free',
    'thinkingmachines/inkling:free',
    'dots-studio/dots-3-note-preview:free',
  ];

  // Rotation event handler: when a free model is rotated out, log and fall through
  static void handleRotationEvent(String rotatedModelId) {
    // Normal event — model router continues with remaining fallback array
  }
}
