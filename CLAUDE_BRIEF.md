SOURCE OF TRUTH — Noir Android App, BACKEND ONLY (Addendum V2.2).
Repo: /tmp/noir-repo (wiped — build from scratch). Do NOT modify V2.3 UI spec (SOURCE_OF_TRUTH_ADDENDUM_V2.3_UI.md) — frontend is out of scope; it waits for user confirmation.

BACKEND SCOPE ONLY — implement these tracks/files, pinned to exact paths:
- A6 (Agent Runtime pipeline): lib/agent/agent_runtime.dart, lib/safety/policy_engine.dart, lib/safety/risk_classifier.dart, lib/agent/recovery_engine.dart + NEW lib/safety/screen_content_sanitizer.dart (A6a: strips zero-alpha / off-viewport / zero-width-unicode / bidi-override nodes; logs reason code; deterministic — NOT model call). lib/agent/task_controller.dart.
- A6b Undo Window: integrate into agent_runtime (5s cancellable for riskLevel>=1, toast notice for irreversible).
- A9 Cost Estimator: lib/agent/cost_estimator.dart — constants OPENROUTER_FREE_RPM_CAP=20, FREE_DAILY_CAP_UNFUNDED=50 / FUNDED=1000; live-fetch free-model list with cache+TTL; fallback array (2-3 IDs) per request; NOT a single hardcoded model.
- A12 Reflection/Critic Step: after Act→Verify, compare intended vs observed screen state, produce confidence score; low-confidence → Hierarchical Recovery (A4).
- B2 Provider Adapters (+ MCP): lib/providers/adapters/openrouter_adapter.dart, lib/providers/llm_provider.dart — add MCP adapter (JSON-RPC 2.0: Tools/Resources/Prompts), classify per-tool as backgroundSafe/uiBound; tool results go to Zone 5 (UNTRUSTED), no special trust.
- B3 Model Router + Budget Guard: lib/providers/model_router.dart, lib/providers/usage_tracker.dart — fallback array routing; treat rotated free-model list as normal event.
- C1 Enhanced AccessibilityService: android/app/src/main/kotlin/com/noir/android/AgentAccessibilityService.kt — preserve bounds/alpha/visibility/z-order for each node (not just text) for A6a.
- C2 Full Action Set + MethodChannel: android/ + lib/tools/tool_gateway.dart, lib/tools/tool_call.dart, lib/tools/tool_registry.dart — every dispatchGesture preceded by Policy Engine gate; any bypass = release-blocking.
- E4 Prompt-injection matrix (tests): test/ — include visual/rendered-content injection cases (off-screen text, zero-alpha nodes, bidi-override); 100% pass required. Add E10 Policy Engine cases: sanitizer-stripped content is the ONLY trigger blocked.

SECURITY NON-NEGOTIABLE (read V2.2 R0/R1): Policy Engine gate is the single most critical path. Any refactor that could bypass it is a release-blocking regression. Screen-Content Sanitizer is deterministic code — never rely on LLM to notice concealed content.

Constraints: Flutter/Android; monochrome 7-token palette from V2.3 (no new colors); never invent UI-only state; subscribe to single Stream<NoirUiEvent>; wire real backend events.

STOP when A6/A9/A12/B2/B3/C1/C2/E4 have real file outputs + a basic build/test can be verified. Report file paths + test counts + git sha. NO frontend (V2.3) — that needs the user's explicit "frontend go".
