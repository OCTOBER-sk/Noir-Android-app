# SOURCE_OF_TRUTH — Addendum V2.2 (Research-Backed Hardening & UX Uplift)

Purpose: patch to SOURCE_OF_TRUTH.md. Adds R0 rationale + R1 Track A revisions (A6, A9, A12), R2 Track B revisions (B2, B3), R3 Track C revisions (C1, C2), R4 Track D revisions (D2, D15), R5 Track E revisions (E4), R6 new use-case suggestions, R7 sources.

Key new security-critical paths (must be treated as blocking):
- A6a Screen-Content Sanitizer (strips zero-alpha / off-viewport / zero-width nodes before Zone 6).
- A6b Undo Window (5s, cancellable for riskLevel >= 1).
- A12 Reflection/Critic Step (compare intended vs observed, confidence score, route low-confidence to Hierarchical Recovery).
- A9 Cost Estimator: OPENROUTER_FREE_RPM_CAP=20 (fixed); FREE_DAILY_CAP_UNFUNDED=50 / FUNDED=1000; live-fetch free-model list with TTL; fallback array of 2-3 IDs per request.
- B2 Provider Adapters: add MCP (JSON-RPC 2.0: Tools, Resources, Prompts) as first-class adapter.
- B3 Model Router: fallback array, treat rotated free-model list as normal event.
- C1: preserve bounds/alpha/z-order metadata in accessibility-tree dump (for A6a).
- C2: Policy Engine gate must precede every dispatchGesture (release-blocking regression if bypassed).
- E4: include visual/rendered-content injection test cases (off-screen text, zero-alpha nodes, bidi-override) — 100% pass required.
