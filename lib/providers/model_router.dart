// lib/providers/model_router.dart — B3
// Fallback array routing; treat rotated free-model list as normal event.
class ModelRouter {
  static List<String> resolve() => ['poolside/laguna-s-2.1:free', 'thinkingmachines/inkling:free', 'dots-studio/dots-3-note-preview:free'];
}

// Fallback array routing: 3-model chain (inkling:free primary -> poolside:free -> dots-studio:free).
