Agent: zeus
Task: VS.3 — B1 thin: LLMProvider interface and one adapter (OpenRouter free, poolside/laguna-s-2.1:free) (V2.1 §B1, §B2)

Repo: /home/santhosh/projects/Noir-Android-app
Source: SOURCE_OF_TRUTH.md (V2.1) — follow §B1, §B2, §B3 (Model Router) EXACTLY.

Deliverables (exact paths):
  1. lib/providers/llm_provider.dart — abstract class LLMProvider with:
        - Future<Stream<String>> completeStream(String prompt, Map<String, dynamic> parameters);
        - Future<int> countTokens(String text);
        - LLMProviderCapabilities getCapabilities(); // includes bool streaming, bool vision, bool toolUse, int contextLimit
        - Future<Usage> recordUsage(String model, int inputTokens, int outputTokens); // or similar
  2. lib/providers/adapters/openrouter_adapter.dart — implements LLMProvider for OpenRouter:
        - Uses the OpenRouter API key from environment (via dotenv or similar, but for now we can read from Platform.environment or a config class; we will assume a config class is provided elsewhere, but for this thin adapter we can hardcode the key from the environment variable OPENROUTER_API_KEY for the purpose of the thin adapter — note: in production we will use a secure config, but for the thin adapter we just need to show the structure).
        - Implements completeStream by making a POST to https://openrouter.ai/api/v1/chat/completions with stream: true.
        - Implements countTokens by calling the OpenRouter /token endpoint or using a local estimator (for thin, we can use a simple estimator: approx 4 chars per token).
        - getCapabilities() returns true for streaming, false for vision (unless the model supports it, but poolside/laguna-s-2.1:free does not), false for toolUse (unless the model supports it, but we don't know yet; we can set false for now), and contextLimit from the model (we can hardcode 262144 for poolside/laguna-s-2.1:free).
        - recordUsage updates a UsageTracker (we can have a simple in-memory tracker for thin).
  3. lib/providers/usage_tracker.dart — a simple class that tracks token usage and cost per model, per day, etc. (for thin, we can have a simple map).
  4. lib/providers/model_router.dart — a simple router that selects a model based on task complexity (simple, normal, complex) and respects the free-tier budget (using UsageTracker). For thin, we can have a hardcoded list of free models and a simple round-robin or fallback.

Constraints:
  - First output = tool call to create/edit the first file. Zero commentary lines.
  - Batch writes: write all files in ONE parallel tool-call block, then run the single verification command.
  - Verification command: flutter pub get && flutter analyze && flutter test test/providers_test.dart (we will create a simple test that checks the adapter can be instantiated and the capabilities are as expected).
  - Report in <=5 lines: files changed, test results (pass/fail), then STOP.
  - Do NOT run the app or try to make actual network calls in the test (we can mock the HTTP calls).
  - Do NOT touch files outside the listed deliverables.
  - Exact line anchors: if editing existing files, use the exact line numbers/paths given; do not grep/search/explore to rediscover.

Self-review (mandatory): re-read your diff; confirm the LLMProvider interface is abstract; confirm the adapter uses the OpenRouter API key from the environment (we can use Platform.environment['OPENROUTER_API_KEY'] for thin); run the verification command yourself; report files + test count + any risks. Then STOP.