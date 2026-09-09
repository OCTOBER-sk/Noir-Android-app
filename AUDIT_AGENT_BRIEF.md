AUDIT AGENT BRIEF — Noir Android (workdir: /tmp/noir-repo)
Purpose: full code audit (no rubber stamp) against V2.2 backend spec + V2.3 frontend spec.

READ FIRST (source of truth, not summary):
- /tmp/noir-repo/CLAUDE_BRIEF.md (backend brief, V2.2 scope pinned)
- /tmp/noir-repo/SOURCE_OF_TRUTH_ADDENDUM.md (V2.2 addendum — R0-R7: A6/A9/A12 security, B2/B3 provider, C1/C2 native, D2/D15 UI revisions, E4/E10 test expansions)
- /tmp/noir-repo/SOURCE_OF_TRUTH_ADDENDUM_V2.3_UI.md (V2.3 UI spec — monochrome 7-token, D2/D3/D6/D7/D9/D15 screens, Section 3 backend-frontend contract Dart code, Section 4 what NOT to copy)
- /tmp/noir-repo/SUPERVISOR_EVIDENCE.json + FINAL_EVIDENCE_BACKEND_FRONTEND.json (real verification evidence; NOT agent-invented claims)

VERIFICATION TASK (execute physically; report PASS/FAIL with line numbers or file content evidence, NOT summaries):
1. BACKEND — verify ALL 14 tracked files exist with real content (>50B) and keywords match spec (A6a REASON_*; A6 PolicyEngine.gate(); A5 TaskState; A4 HierarchicalRecovery; A12 Reflection; A9 constants 20/50/1000 + fallbackIds; B2 adapters endpoint + MCP adapter + fallback array; B3 model_router resolve + usage_tracker; C1 bounds/alpha/z-order; C2 MethodChannel + PolicyEngine gate; E4/E10 skeletons real). Report any MISSING or PARTIAL.
2. SECURITY — verify: PolicyEngine gate before ANY dispatchGesture (C2); Sanitizer deterministic (no LLM call, A6a); no minimax/minimax-m3 model slug in code; monochrome 7-token palette (noir_theme.dart — verify zero new colors outside spec); frontend V2.3 untouched by backend work (.open-design.json present, binding verified).
3. FRONTEND — verify .open-design.json binding (design_system=mono, version=0.21.1 real value, theme=monochrome-dark, engine=claude-code-v2.1.261); noir_theme.dart 7 tokens only; ui_state_contract.dart NoirUiEvent contract wired; D2 screen exists; design token audit passes (no accent colors); WeasyPrint PDF proof exists (docs/noir-ui-proof.pdf) — real file, not fabricated.
4. MODEL FALLBACK — confirm adapter/model files reference 3-model chain: thinkingmachines/inkling:free (primary, verified SMOKE_OK) -> poolside/laguna-s-2.1:free -> dots-studio/dots-3-note-preview:free; confirm no paid/non-:free model used.
5. REAL EVIDENCE — for EVERY claim, cite file path + line number or byte size. For FAIL claims, quote the failing line. For PASS claims, quote the confirming line. NEVER say "PASS" without evidence. NEVER invent file contents.
6. GAPS LIST — if any V2.2 spec item is MISSING, PARTIAL, or WRONG, list it explicitly with the spec reference (e.g. "A6b UndoWindow logic partial — only skeleton, no 5s countdown timer" or "E4 injection matrix — skeleton only, no real 100% pass").
7. FRONTEND CONFIRMATION — confirm V2.3 started (per user's 'frontend go'); confirm no backend code leaked into frontend; confirm .open-design.json is the binding mechanism.
8. HONESTY NOTE — state clearly: which files were produced by Claude agent vs direct supervisor writes; any model fallback actually triggered; any 429/timeout observed; any fabricated claim made by previous agent run (if any).

STOP after reporting: brief per-file table (PASS/FAIL + evidence), gaps list, security summary, frontend confirmation, model chain confirmation, evidence file references, and a one-line honesty note. No more than 5min; no fabrication; supervisor (Atom) verifies every claim independently afterwards.
