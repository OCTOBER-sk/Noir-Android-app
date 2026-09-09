
# Self-Review Checklist for Noir Backend (V2.2)
# Run: dart analyze lib/   (or equivalent check)
# Verify each item against actual file contents (not memory)
1. lib/safety/screen_content_sanitizer.dart — deterministic? NO LLM call? reason codes present?
2. lib/safety/policy_engine.dart — PolicyEngine.gate() precedes ANY execution?
3. lib/agent/agent_runtime.dart — full pipeline: Planner -> RiskClassifier -> Sanitizer -> PolicyEngine -> Gate -> UndoWindow(5s, risk>=1) -> Execute -> Reflection/A12 -> Recovery/A4?
4. lib/agent/cost_estimator.dart — constants 20/50/1000? fallback array 3 IDs?
5. lib/providers/model_router.dart — fallback array routing?
6. lib/providers/adapters/openrouter_adapter.dart — endpoint set?
7. lib/providers/adapters/mcp_adapter.dart — JSON-RPC adapter + Zone-5 note?
8. android/.../AgentAccessibilityService.kt — bounds/alpha/z-order preserved?
9. android/.../MainActivity.kt — MethodChannel gate before dispatchGesture?
10. test/agent_test.dart + providers_test.dart — skeletons present; 100% target NOT falsely claimed?
