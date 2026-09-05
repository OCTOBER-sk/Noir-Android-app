# Noir — Atom's Execution Todo (derived from `SOURCE_OF_TRUTH.md` V2.1)

**Last updated:** 2026-09-05
**Source of truth:** [SOURCE_OF_TRUTH.md](./SOURCE_OF_TRUTH.md) (V2.1)
**Role:** This file is Atom's own checklist. Every brief I delegate to Zeus/Midas/Amush is derived from this list. Update as work completes.

**Standing rules (Sandy):**
- Quality > speed. Never rush polish.
- UI = pure B/W only: `#000000`, `#FFFFFF`, `#121212`, `#1E1E1E`, `#2A2A2A`, `#E5E5E5`, `#B0B0B0`. Zero color accents.
- Coding-agent routing: primary = `openrouter/poolside/laguna-s-2.1:free`; fallback = `opencode/muse-spark-1.2-contributor-free` → `mimo-v2.5-free` → `ling-3.0-flash-fin-free`.
- $10 OR credit = permanent 1k RPD floor (20 RPM shared). Never spend.
- Each task → run verification → self-review → commit → push → report to Sandy with proof (SHA, test counts, screenshots).

**Sequencing rule (V2.1 §12):** Mandatory vertical slice FIRST. No broad parallel work until slice is green.

---

## Phase 0 — Repo scaffold + plan

- [x] **0.P1** Wipe old `noir-android` (local + remote) — done
- [x] **0.P2** Create fresh `Noir-Android-app` repo (public, Apache-2.0) — done
- [x] **0.P3** Read V2.1 plan end-to-end — done
- [x] **0.P4** Write this todo list (`TODO_ATOM.md`) — done
- [x] **0.P5** Push V2.1 plan as `SOURCE_OF_TRUTH.md` to repo root — done (commit pushed)
- [x] **0.P6** Add repo metadata: `README.md`, `LICENSE` (Apache-2.0), `.gitignore`, `THIRD_PARTY_NOTICE.md` — done
- [ ] **0.P7** Add `vendor/upstream` submodule: `https://github.com/orailnoor/private-agent.git` at tag `v1.0.2` — **BLOCKED on R1 (license)**
- [ ] **0.8** Add `STATUS.md` (live state, entry point for next session)
- [ ] **0.9** Add `.noir/briefs/` skeleton with Task IDs matching V2.1

---

## Phase 1 — Vertical Slice (mandatory before broad parallel work, per V2.1 §12)

Sequence: 0.1 → C1 thin → B1 thin + one adapter → minimal TaskController + one UI tool → A1 memory + A3 skill save/replay (safe) → D2 Command Centre shell + token counter.

- [ ] **VS.1** Track 0.1 — Scaffold, package rename `com.orailnoor.privateagent` → `com.noir.android`, monochrome theme (`lib/core/theme/noir_theme.dart`).
  - **Verify:** `flutter pub get` ✓, `flutter analyze` clean, `flutter test` on theme test passes (only 7 colors), `flutter build apk --debug` succeeds.
- [ ] **VS.2** Track C1 (thin) — `AgentAccessibilityService` event-driven path, exclude own overlay, basic node dump.
  - **Verify:** service starts, AccessibilityEvent arrives on UI change, no polling.
- [ ] **VS.3** Track B1 (thin) — `LLMProvider` interface + one adapter (OpenRouter free, `poolside/laguna-s-2.1:free`).
  - **Verify:** `chat/completions` call returns 200, `Usage` parsed, capability flags set.
- [ ] **VS.4** Minimal `TaskController` + one UI tool — end-to-end: goal → planner → one action → execute → verify.
  - **Verify:** goal completes on emulator, screenshot before/after captured, action recorded.
- [ ] **VS.5** Track A1 (memory) + A3 (skill save/replay safe path).
  - **Verify:** Drift schema generated, memory table CRUD works, one skill saved + replayed zero-token on same input.
- [ ] **VS.6** D2 Command Centre shell + live token/cost counter.
  - **Verify:** counter ticks during a real LLM call, opens to placeholder Usage Dashboard.
- [ ] **VS.GATE** Vertical slice green on real device/emulator. Atom verifies all 6 steps, takes screenshots, writes `VERTICAL_SLICE_PROOF.md`. **Only then proceed to Phase 2.**

---

## Phase 2 — Track 0 Foundations (parallel with Phase 1+ as budgets allow)

- [ ] **0.1** Scaffold + rename + monochrome theme (if not in VS.1)
- [ ] **0.2** Unified error model + local structured logging
- [ ] **0.3** Cancel tokens + lightweight isolate pool

---

## Phase 3 — Track A Agent Runtime (Dart, Zeus primary)

- [ ] **A1** Layered memory schema (Drift) — Profile / Facts / Preferences / Learnings / Session. WAL + FTS5 on Facts.content. `profileId` for future multi-profile. Skills stored separately.
- [ ] **A2** Memory CRUD service — sensitivity filtering, export/import, progressive disclosure helpers.
- [ ] **A3** Skill lifecycle + ranking — states: candidate → validated → draft → active → disabled; degraded → needs_review. Multi-condition fast-path gate. **High-risk never bypasses confirm/biometric.**
- [ ] **A4** Hierarchical recovery engine (7-step).
- [ ] **A5** EventBus + simplified TaskController (states: idle → planning → awaiting_confirmation → executing → recovering → paused → terminal).
- [ ] **A6** Planner + RiskClassifier (0–3) + Policy Engine + Tool Router.
- [ ] **A7** PromptBuilder (zones + teaching) — 6 zones, runtime owns zero-token decision, prompt only says "may be executed by runtime".
- [ ] **A8** Biometric gate + audit log.
- [ ] **A9** Cost Estimator (pre-call, before model selection).
- [ ] **A10** Offline / degraded mode.
- [ ] **A11** Track A integration.

---

## Phase 4 — Track B Providers, Tools, Web Search (Dart, Zeus primary)

- [ ] **B1** Canonical ToolCall + `LLMProvider` interface + `UsageTracker` streams.
- [ ] **B2** Provider adapters — OpenRouter / OpenAI / Anthropic / Gemini / Ollama / CustomHttp.
- [ ] **B3** Model Router + free-tier/budget guard (uses Cost Estimator).
- [ ] **B4** Tool Registry + Tool Gateway — every tool declares `name`, `description`, `jsonSchema`, `riskLevel`, `executionClass: uiBound|backgroundSafe`, `requiredPermissions`. Gateway enforces UI_LOCK.
- [ ] **B5** Tool Calling Loop (adapter-translated).
- [ ] **B6** Web Search (UNTRUSTED when injected).
- [ ] **B7** Streaming + Cancellation.
- [ ] **B8** Token/Cost Tracker + Daily Cap + Dashboard data.
- [ ] **B9** Track B integration.

---

## Phase 5 — Track C Android Native Layer (Kotlin, Zeus primary)

- [ ] **C1** Enhanced `AgentAccessibilityService` — event-driven, richer dump, multi-window, exclude own overlay.
- [ ] **C2** Full action set via MethodChannel with structured results.
- [ ] **C3** WorkManagerScheduler (background-safe work only).
- [ ] **C4** KeystoreBridge.
- [ ] **C5** NotificationListenerBridge.
- [ ] **C6** BatteryThermalMonitor + ForegroundService.
- [ ] **C7** Permission & package blacklist.
- [ ] **C8** Process-death recovery (session serialization).
- [ ] **C9** UI_LOCK coordination with Dart side.
- [ ] **C10** Selector robustness + service health / re-bind UX.
- [ ] **C11** Track C integration.

---

## Phase 6 — Track D Flutter UI (Midas primary)

- [ ] **D1** Onboarding (progressive, testable steps).
- [ ] **D2** Command Centre Chat — streaming + caret, model selector, live token/cost counter, branch/side, confirmation cards, message actions.
- [ ] **D3** Live Task View (core states + event stream).
- [ ] **D4** Streaming UX.
- [ ] **D5** Side Conversations.
- [ ] **D6** Usage Dashboard (first-class surface).
- [ ] **D7** Skill Manager (lifecycle visible, promote, degrade, history).
- [ ] **D8** Memory Center.
- [ ] **D9** Safety Center (Policy Engine toggles, blacklist, audit, injection status).
- [ ] **D10** Debug Mode.
- [ ] **D11** Empty states & polish.
- [ ] **D12** Navigation + integration.
- [ ] **D13** Floating overlay (monochrome, optional).
- [ ] **D14** Settings / provider management.

---

## Phase 7 — Track E Tests, Hardening, Release (Ambush primary)

- [ ] **E1** CI foundation (GitHub Actions: build, test, lint, coverage).
- [ ] **E2** Failure-injection suite (timeout, stale UI, permission denied, OOM, process kill).
- [ ] **E3** Battery/thermal scenarios (idle 8h, navigation 4h, gaming 2h, charging, extreme temp).
- [ ] **E4** Prompt-injection matrix — 100% pass.
- [ ] **E5** UX gates (monochrome, touch targets ≥48dp, contrast).
- [ ] **E6** Release checklist (HARD gates).
- [ ] **E7** Demo GIF.
- [ ] **E8** Documentation (incl. "How memory & skills work").
- [ ] **E9** Final integration.
- [ ] **E10** Skill lifecycle + Policy Engine tests.
- [ ] **E11** Token/cost accuracy tests.
- [ ] **E12** Device/OEM matrix (Pixel 6, Samsung S22, Xiaomi Note 12).

---

## Risks tracked (from V2.1 + Sandy's rules)

- **R1 — License risk on `orailnoor/private-agent`** — no LICENSE on the upstream repo. **Mitigation:** fork and treat as inspiration + re-implement, not copy. Add `THIRD_PARTY_NOTICE.md` clearly. Confirm with Sandy before vendoring.
- **R2 — 20 RPM shared OR bucket** — coding agents + Atom share. **Mitigation:** atom-personal requests use `minimax-m3:free`; coding agent requests use `poolside/laguna-s-2.1:free`. When 429 hits, agent prompts fall through to OpenCode Zen free models.
- **R3 — Quality over speed** — never rush polish, especially chat/composer interactions.
- **R4 — Vertical slice gate** — V2.1 §12 forbids broad parallel work before slice is green. Hold the line.

---

## Definition of Done (project level, from V2.1 §13)

- [ ] Vertical slice green on real device/emulator.
- [ ] All tracks integrated; CI green.
- [ ] Coverage ≥ 80% on critical packages.
- [ ] Event-driven observation + UI_LOCK verified.
- [ ] Skill fast-path only under full safety conditions; high-risk never bypasses.
- [ ] Policy Engine + RiskClassifier + Biometric/Confirm path tested.
- [ ] Live token/cost/provider/model visibility works.
- [ ] Prompt-injection suite 100% pass.
- [ ] Demo GIF + docs complete.
- [ ] No secrets in repo.
- [ ] Privacy statement accurate (user-enabled integrations only).

---

## Current blocker

**R1 — License on `orailnoor/private-agent` v1.0.2 must be confirmed before vendoring the submodule.** No LICENSE file. Two paths:

- **Path A (safer):** treat V2.1 as architecture reference only, re-implement the Kotlin accessibility bits ourselves in `android/app/src/main/kotlin/com/noir/android/`. Slower but clean.
- **Path B (faster):** vendor as `vendor/upstream` with `THIRD_PARTY_NOTICE.md` clearly stating "no LICENSE on upstream, used under fair-use architectural reference, all code re-implemented or migrated to com.noir.android namespace".

Awaiting Sandy's call on R1.
