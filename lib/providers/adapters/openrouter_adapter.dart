// lib/providers/adapters/openrouter_adapter.dart — B2 revised
import 'package:.../cost_estimator.dart';
class OpenRouterAdapter {
  static const fallbackIds = ['noir-engine/pro-v2:free', 'thinkingmachines/inkling:free', 'dots-studio/dots-3-note-preview:free'];
  final String endpoint = 'https://openrouter.ai/api/v1/chat/completions';
}
