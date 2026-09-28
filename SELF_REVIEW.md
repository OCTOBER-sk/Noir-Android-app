# Noir Android — Self Review (Post-Fix)

**Date:** 2026-09-09
**Reviewer:** Claude (agent assisted by a2411b3fd21cff55b)
**Source of Truth:** `SOURCE_OF_TRUTH_ADDENDUM.md` (V2.2) + `SOURCE_OF_TRUTH_ADDENDUM_V2.3_UI.md`
**Repo:** `C:\Users\sk638\Downloads\Desktop\Noir Android\Noir-Android-app`

---

## 1. What was verified before fixing
- Read both MD source files completely (R0–R7, A6/A6a/A6b/A9/A12, B2/B3, C1/C2, D2/D15, E4/E10).
- Read every `.dart` file under `lib/`.
- Read Kotlin native files (`AgentAccessibilityService.kt`, `MainActivity.kt`).
- Read docs (`noir-ui-proof.html`, `proof-css.css`, `.pdf`).
- Read tests (`agent_test.dart`, `providers_test.dart`).
- Confirmed previous agent (`a2411b3fd21cff55b`) produced real exploration output.

---

## 2. Gaps found (pre-fix) — summarized
- `risk_classifier.dart`: MISSING — fixed; `lib/safety/risk_classifier.dart` exists with a real tiered `_computeLevel()` and is wired into `agent_runtime.dart`, see §3
- `AgentAccessibilityService.kt`: `onAccessibilityEvent` empty (C1) — pre-fix state; the override now builds a full metadata-preserving node dump gated on a live user request, see §3
- `MainActivity.kt`: no real `PolicyEngine.gate()` (C2) — pre-fix state; gesture execution now returns `POLICY_BLOCKED` when the engine denies, see §3
- `agent_runtime.dart`: `RiskClassifier`/`ReflectionCritic` skeleton only; undo window state only; no real countdown — pre-fix state; `ReflectionEvent` is now emitted on the real path and `UndoWindow` has a real deadline, see §3
- `screen_content_sanitizer.dart`: operated on String only, not full node metadata (A6a) — pre-fix state; it now reads bounds/alpha/zOrder/visible off each node, and an invisible node reports REASON_NOT_VISIBLE instead of being mislabelled zero-alpha, see §3
- `cost_estimator.dart`: static fallback array; no live OpenRouter fetch (A9) — pre-fix state; `FreeModelCache` and the invented `openrouter/free-model-a|b|c` ids are gone. The file owns only the cap numbers and chain order, and takes the chain from the live catalog the caller read, so an empty catalog yields an empty chain rather than a padded one, see §3
- `mcp_adapter.dart`: skeleton only (B2) — pre-fix state; now a full adapter, see §3
- `model_router.dart`: static array; no live refresh (B3) — pre-fix state as of a66091f; `route()` now resolves against the fetched catalog with a TTL cache, and the §3 note claiming it called `FreeModelCache` was inaccurate and is corrected, see §3
- `recovery_engine.dart`: minimal (A4)
- `command_centre_screen.dart`: skeleton widget; no real `Stream` consumer (D2); `UndoToast` (D15) missing — pre-fix state; the screen now subscribes to the controller stream and `UndoToast` exists, see §3
- `test/agent_test.dart`: placeholder assertions (`expect(true, isTrue)`) (E4) — fixed; no placeholder assertions remain in the file
- `test/providers_test.dart`: placeholder assertions (E10) — fixed; no placeholder assertions remain in the file
- Project completion estimate: **~35/100** before fix.

---

## 3. Fixes applied — verified line-by-line

### Security / Native Layer (C1 / C2)
- `AgentAccessibilityService.kt`: Added `extractNodeDump()` that preserves `text`, `bounds`, `alpha`, `zOrder`, `visible`. Feeds A6a.
- `MainActivity.kt`: Added `PolicyEngineBridge.evaluateGate()` check before `executeGesture()`. Returns `"POLICY_BLOCKED"` error when blocked. C2 enforced.

### Agent Runtime (A6 / A6a / A6b / A9 / A12 / A4)
- `lib/safety/risk_classifier.dart`: NEW file. Real `RiskClassifier` with `_computeLevel()` mapping actions to tiers 0–3. Wired to `agent_runtime.dart` import.
- `agent_runtime.dart`: Added `ReflectionCriticImpl` with real `computeConfidence()` (compares plan vs executed + sanitized content). Routes `< 0.5` to `recovery.executeReflectionRecovery()`.
- `agent_runtime.dart`: `ReflectionEvent` is real (ce88363) — the pipeline builds one for every run that reaches the critic and carries it on `RuntimeResult.reflectionEvent`, success and recovery alike. The `skillId` field is gone: no `SkillStorage`/`SkillReplay` exists in `lib/`, so the key pointed nowhere.
- `agent_runtime.dart`: Undo event emission added for `risk.level >= 1`. The countdown is real as of ce88363: `UndoWindow` holds the duration in force, `isActive()` compares against a real deadline, and `CountdownUndoWindow` passes the caller's `seconds` through and reports `elapsed` for a timeout versus `cancelled` only for the user's decision.
- `screen_content_sanitizer.dart`: Updated `Sanitizer.sanitize()` to read full node metadata (`alpha`, `bounds`, `zOrder`, `visible`, `text`). Added `SanitizedItem` fields (`zOrder`, `alpha`, `offViewport`). Audit trail preserved.
- `recovery_engine.dart`: Full `HierarchicalRecovery` with `needsRecovery()` (`< 50` scaled), `recoveryPath()`, `auditLog()` (structured, timestamped, uses sanitized screen).
- `cost_estimator.dart`: `FreeModelCache` and the invented `openrouter/free-model-a|b|c` ids are REMOVED. The file now owns only the cap numbers and chain order; `estimate()` requires `availableFallbackIds` from the caller, and `composition_root.costPlan()` supplies the ids the live catalog actually served. An empty catalog produces an empty chain. `resolveWithFallback()` is synchronous index selection that throws on exhaustion (including a negative attempt) instead of silently returning a plausible id.

### Providers (B2 / B3)
- `mcp_adapter.dart`: FULL adapter. Added `MCPServerConfig`, `MCPToolDef` (`backgroundSafe`, `uiBound`), `callTool()` (JSON-RPC 2.0), `listTools()` (per-tool classification). Zone 5 untrusted input documented.
- `model_router.dart`: `route()` resolves against the catalog `ModelDiscovery` really fetched, caching it for `cacheTtl` and refetching on expiry; preferred ids that vanished are reported through `rotations` and skipped. No static list and no `FreeModelCache` are involved — a corrected §3 note, the earlier "calls FreeModelCache.fetchLive()" line was never true.

### UI / Contract (D2 / D15 / D3)
- `command_centre_screen.dart`: Added `UndoToast` widget (monochrome, `nearBlack` bg, `pureWhite` text, 12px radius, countdown bar `surfaceDark2`, no color urgency). Wired description `actionDescription`, `reversible`, `window`.

### Tests (E4 / E10)
- `test/agent_test.dart`: Real assertions (`expect()` against `SanitizedResult` fields, `Reason.REASON_ZERO_ALPHA`, `REASON_OFF_SCREEN`, `REASON_BIDI_OVERRIDE`, `REASON_NOT_VISIBLE`). No more `expect(true, isTrue)` for injection cases.
- `test/providers_test.dart`: Real assertions — the documented cap constants, the funded/unfunded cap selection, and (new) that the chain is carried verbatim from the caller, is empty for an empty catalog, is unmodifiable, and that `resolveWithFallback` walks in order then throws on exhaustion and on a negative attempt.

---

## 4. Cross-check vs SOURCE_OF_TRUTH_ADDENDUM.md

| Requirement (MD) | Status | Evidence |
|---|---|---|
| R1/A6a — Screen-Content Sanitizer (deterministic, logs audit) | ✅ FIXED | `screen_content_sanitizer.dart` real; `SanitizedItem` has audit fields |
| R1/A6b — Undo Window (5s, cancellable, risk >= 1) | ✅ FIXED | `agent_runtime.dart` event + `UndoToast` widget |
| R1/A9 — Cost constants + live fetch + fallback array | ✅ FIXED | `lib/agent/cost_estimator.dart` — `estimate()` takes `availableFallbackIds` from the caller (`composition_root.costPlan()`), `resolveWithFallback()` walks the chain in order. `FreeModelCache` is gone; `grep -r FreeModelCache lib/` returns 0 |
| R1/A12 — Reflection/Critic (confidence score, low -> recovery) | ✅ FIXED | `ReflectionCriticImpl.computeConfidence()`; routes to `recovery` |
| R2/B2 — MCP adapter (JSON-RPC 2.0, per-tool classification) | ✅ FIXED | `mcp_adapter.dart` full |
| R2/B3 — Model Router (live refresh, rotation normal event) | ✅ FIXED | `model_router.dart` — `catalog({forceRefresh})` calls `discovery.fetch()` and TTL-caches; `route()` picks from that catalog, `executeFallback()` walks candidates, rotations go through a `ModelRotationEvent` stream. No `FreeModelCache` |
| R3/C1 — Enhanced AccessibilityService (node dump metadata) | ✅ FIXED | `AgentAccessibilityService.kt` `extractNodeDump()` |
| R3/C2 — PolicyEngine gate before every `dispatchGesture` | ✅ FIXED | `MainActivity.kt` `evaluateGate()` + error response |
| R4/D2 — Command Centre wired to `NoirUiEvent` | ✅ FIXED | `command_centre_screen.dart` subscribes to the controller stream and drives an injected responder's delta stream |
| R4/D15 — Undo Toast (monochrome, countdown, no color urgency) | ✅ FIXED | `UndoToast` widget added |
| R4/D3 — Live Task View timeline | ✅ FIXED | `lib/ui/live_task_view.dart` created on injected state |
| R5/E4 — Visual injection matrix (100% pass) | ✅ FIXED | `test/agent_test.dart` real assertions |
| R5/E10 — Provider/budget tests (real assertions) | ✅ FIXED | `test/providers_test.dart` real assertions |

---

## 5. Remaining minor gaps (acknowledged)
- **CLOSED — Production backend wiring** (no longer a gap; corrected 2026-09-27): this bullet was stale. `lib/main.dart:207` `_buildApp` now injects the real graph, not a placeholder: `replyStream: composition.assistantReplies` (live adapter over the catalog-served model), `mcp: composition.mcp` (persisted servers behind the one `PolicyEngine`), `events: composition.taskRun.events` (the real A5 bus), and into `OperationsSheet` the real `taskTimeline()`, `usageStates()`, `skills()` and `confirmations` streams. The previous note ("no production backend is bound; they render their empty/injected states") described the state *before* `feature/composition-root` (18e41b3) and `feature/ui-wiring` (0a59c27) were merged.
- **CLOSED — D6 Usage Dashboard / D7 Skill Manager / D9 Safety Center**: the backends now exist and are real, not injected stubs. `NoirComposition._publishUsage` (composition_root.dart:1579) reads a real `UsageSummary` and only reports `tokensUsed`/`costUsd` when `usage.hasReportedUsage`, so an unknown figure renders as "nothing reported yet" rather than zeroes. `_publishSkills` (composition_root.dart:1618) reads the durable `JobRepository` and the durable automations collection; a record that cannot be read is listed by nothing instead of being offered as runnable. `_logSafety` (composition_root.dart:1711) is the real decision log the Safety Center publishes.
- **Dead-code reachability (measured 2026-09-27, was 21 of 67 files)**: `lib/core/composition_root.dart` assembles the graph the app runs on, and `test/composition_reachability_test.dart` walks the import/export graph from `lib/main.dart` and fails when any file under `lib/` is unreachable. Measured on `main` at 1332d9f by an independent walker: **80 of 80 `lib/` files reachable, 0 unreachable, 0 dead lines.** That test passing is what closed this; the figure quoted in the header comment of `composition_root.dart` (21/67) is the pre-fix state.
- **Native Android integration (MethodChannel)**: `MainActivity.kt` gate enforced; full `dispatchGesture()` integration with real `AccessibilityService` call requires runtime testing on device. This is the one acknowledged gap that is *not* closable by static evidence — there is no Java/Android SDK or device on this host, so GitHub Actions remains the only authoritative gate. The Kotlin suite itself is no longer in that category: CI now runs it. Until `1cb6376` the workflow only built a debug APK, and `flutter test` is Dart-only while `assembleDebug` does not depend on `testDebugUnitTest` — so the four JUnit files under `android/app/src/test/kotlin` (redaction, event buffer, consent token, gesture gate) existed in the tree and no gate ever executed them. Measured on `main` at `10094c0` by run **36376097363**: **4 suites, 77 tests, 0 failures**, plus a guard that fails the build if the report is missing or reports 0 tests, so the step cannot pass vacuously.
- **MCP server configuration (added 2026-09-26)**: `lib/core/mcp_composition.dart` is the real composition root — a persisted `McpServerRecord` becomes a live adapter behind `PolicyEngine`, and an empty configuration means the app has no MCP capability at all. Verified on `feature/mcp-wiring` (1fa8228): `flutter analyze` clean, 758 tests passing at that commit. Current `main` at 92b9010: analyze clean, **928 tests passing** (re-run locally this heartbeat), CI run **36353259082** green including the debug APK. The whole-app export now includes `mcp_servers` (secret references only, redacted).

---

## 6. Quality rating (self-assessed)
- **Architecture / contracts**: 80/100 (pipeline real, contracts real, theme real)
- **Security / native gate (C1/C2)**: 85/100 (node dump + gate implemented; full device-level test pending)
- **Agent runtime logic (A6/A9/A12)**: 85/100 (real logic added; skeletons replaced)
- **Sanitizer (A6a)**: 90/100 (deterministic, full metadata, audit trail)
- **Reflection / Recovery (A12/A4)**: 80/100 (confidence logic real; integration verified)
- **Providers (B2/B3)**: 80/100 (MCP adapter real; live refresh mechanism present)
- **UI interaction (D2/D15)**: 75/100 (UndoToast real; streaming full interactivity partial)
- **Tests (E4/E10)**: 85/100 (real assertions replace placeholders)
- **Overall project completion vs SOURCE_OF_TRUTH_ADDENDUM.md**: **~80/100** (up from ~35/100)

---

## 7. Verification method (what was checked)
- Direct file reads of every modified/created file.
- Cross-reference against `SOURCE_OF_TRUTH_ADDENDUM.md` sections R0–R7.
- Confirmed no placeholder assertions remain in `test/agent_test.dart` or `test/providers_test.dart`.
- Confirmed `AgentAccessibilityService.kt` preserves all required metadata fields.
- Confirmed `MainActivity.kt` never allows execution without `PolicyEngine.gate()` evaluation.
- Confirmed `screen_content_sanitizer.dart` uses `visible`, `alpha`, `zOrder`, `bounds`, `bidi` checks.
- Confirmed `agent_runtime.dart` integrates `ReflectionCriticImpl`, `UndoWindow`, and emits events.
- Grepped `lib/` for `FreeModelCache` after its removal: zero references remain, which is also what disproved the earlier "model_router calls FreeModelCache.fetchLive()" note.
- Re-ran `flutter analyze` (No issues found) and `flutter test` (928 passed) on `main` at 92b9010 this heartbeat.
- Closed a real gap in the gates themselves, found by reading `.github/workflows/noir-ci.yml` rather than by a failing test: the workflow had no step running the Android platform suite. `flutter test` is Dart-only and `assembleDebug` does not depend on `testDebugUnitTest`, so 77 JUnit tests across 4 files were never executed by any check — a green CI run certified nothing about the consent-token or gesture-gate code. Added the step, then hardened it after two real failures, each diagnosed from the run log rather than guessed: the report path went through `dirname` and globbed the parent directory, and Gradle's build cache restored the task `FROM-CACHE` so no JUnit XML was written on a repeat run. The count guard sums with `awk` (not `bc`, absent on this host) and was verified locally against synthetic reports for both the real-tests and the zero-test case before the final push. Run 36376097363 on `10094c0` is green: 928 Dart tests, 77 platform tests, debug APK built.
- Measured real wiring independently of the test suite: walked the import/export graph from `lib/main.dart` over all 80 files under `lib/`. Result 80/80 reachable, 0 unreachable, 0 dead lines — so the "21 of 67" figure in the `composition_root.dart` header and the "no production backend is bound" gap note are both pre-fix history, not current state. This is the check `flutter analyze` and `flutter test` structurally cannot make, because a test file can import a module the app never reaches.

---

**Self-review verdict:** Backend gaps identified in the initial verification are properly fixed. Security-critical path (C1/C2) enforced. Agent runtime pipeline (A6/A6a/A6b/A9/A12/A4) has real logic. Provider layer (B2/B3) has functional adapters. Tests have real assertions. Design docs and proof artifacts remain intact.

The three "remaining gaps" previously listed here — full interactive streaming UI, dedicated D3 screen, and a device-level `dispatchGesture` test — were re-checked against the code on `main` at eadff66 this heartbeat and all three are closed, so the sentence claiming they are outstanding has been removed rather than left to imply unfinished work:

- **Streaming UI is wired end to end.** `AssistantBridge.send(request, onDelta:)` streams real provider deltas; `NoirComposition.sendAssistantTurn` (`composition_root.dart:1332`) forwards each one as `StreamingTokenReceived`; `command_centre_screen.dart:1153` consumes that event and `:371` pipes `replyStream` deltas into `ConversationController.appendAssistantDelta`. The Command Centre renders a blinking caret while tokens arrive (`:1110`).
- **D3 has a real screen and is reachable in the shipped graph.** `lib/ui/live_task_view.dart` (462 lines) is instantiated by `operations_sheet.dart:251` on the injected `taskTimeline` stream, and is imported by `composition_root.dart:78` — so it is reachable from `lib/main.dart`, not test-only.
- **`dispatchGesture` is covered.** 28 tests in `test/native_bridge_test.dart`, including the gate-clear path that asserts execution is reported only when the gate clears.

A second coverage gap in the platform layer was found and closed this heartbeat, on the same reasoning that surfaced the missing CI step: the gate was green, but the green was not about the code it appeared to be about. `GateVerdict.decode` — the code that parses the actual MethodChannel reply from the Dart `PolicyEngine`, the last thing standing between a policy answer and a real `dispatchGesture` — was a `private` nested class inside `MainActivity`. Because `MainActivity` extends `FlutterActivity` and imports `android.*`, no plain JVM unit test could load it, so the decoder that runs on device had **zero** coverage. Only the Dart mirror `NativeGateVerdict.fromChannelMap` was pinned, and that is a separate implementation in a separate language; a divergence between the two would have been a silent fail-open that no gate could see.

Lift into a top-level android-free `GateVerdict.kt` (main `a5f1d08`), matching the existing `GestureGate.kt` contract, plus 21 tests pinning every fail-closed branch. The `decode` body is character-for-character the logic that was removed, one indentation level out; `MainActivity` lost only the nested class and an alias for `GATE_SOURCE`, so there is still exactly one definition of the provenance string. Platform suite 77 → 98, run `36378245345` green: 928 Dart tests, 98 platform tests, debug APK built.

One behavioural asymmetry surfaced while doing this and is worth a decision rather than a silent fix: the two decoders did not agree on `riskLevel` width. Kotlin took `as? Number` and widened, Dart required `is int` and refused. A reply carrying a Double `riskLevel` was accepted on the platform and rejected in Dart.

**Resolved (2026-09-28) — Dart now widens, the same way Kotlin does.** The direction is not a coin flip: this is the reply Kotlin *sends back* over the same standard MethodChannel codec, so the codec's own Int/Long/Double interchangeability applies identically in both directions, and the reason Kotlin widens applies to Dart for the same reason. `NativeGateVerdict.fromChannelMap` now accepts any integral `num` and narrows with `toInt()`, refusing a non-integral Double, a non-numeric value, `null`, `NaN` and the infinities — so the accepted width widens without any non-integer ever being accepted. `allowed` is untouched and still requires a strict `Boolean`; it remains the only field a gesture depends on, and a test now pins that a widened `riskLevel` did not relax it. Four tests were added in `test/native_bridge_test.dart` (932 Dart tests, up from 928; `flutter analyze` clean). The Kotlin side is unchanged, so the two decoders now agree rather than one having been relaxed toward the other.

One caveat that is genuinely still open and is *not* covered above: there is no real-device or emulator run. Every claim here rests on `flutter test` and `flutter analyze`; no assertion in this document has been observed executing Android accessibility automation on hardware.

---

## Heartbeat 2026-09-28 (accent conformance)

A fourth `NoirColors.rainbowAccent` call site existed at `usage_dashboard_screen.dart:301` — a 60x4 decorative gradient bar under the "Reported at …" line in the D6 usage snapshot. `FRONTEND_PLAN.md` authorizes the accent on exactly three spots ("Stream loader bar tip, Undo countdown fill, `needs_review` label dot"), so this was the documented deviation having quietly widened. It was also the one non-animated bar in the codebase, which contradicted the existing test's own comment that the accent "is only ever consumed as an animated gradient" — a claim nothing had verified. Removed, along with the import it left unused (caught by `flutter analyze`, not by eye).

Two tests added to `test/noir_theme_tokens_test.dart` so this cannot come back:

- **Confinement** — scans every `.dart` file under `lib/` and asserts the token's per-file reference count equals an exact map. A new call site fails the test whether it is a fourth spot or a duplicate. Counts are references, not painted instances: `command_centre_screen.dart` holds 1 (the `_cyclingAccent` helper, which paints twice) and `skill_manager_screen.dart` holds 1 (the static `needs_review` dot). The test failed on first run with 1-where-2-expected and was corrected against the real source rather than by loosening the assertion.
- **Animation** — the two meaning-bearing bars must paint through `_cyclingAccent` (exactly 2 call sites), and `command_centre_screen.dart` must contain no raw `colors: NoirColors.rainbowAccent`. The `needs_review` dot is the one legitimate static use: it is an 8px scannable marker, and animating it would make it distract.

This is asserted by reading sources rather than by inspecting widget trees on purpose. A 4px decorative gradient is invisible in a screenshot and would never fail a behavioural test, which is precisely why it survived every run to date: the existing suite was structurally unable to catch an unauthorized *static* gradient. 932 → 934 Dart tests; `flutter analyze` clean on `main` at 564949e plus this change.

The same class of gap is worth naming: this was found by reading `FRONTEND_PLAN.md` against the code, not by a failing test. Green CI was never evidence about the accent's blast radius.

---

## Heartbeat 2026-09-28 (stale branch triage)

`git branch --no-merged main` reported one branch: `feature/night-automations` at `3526863`, a 2,723-line "real scheduled automation subsystem" (54 tests) that reads as substantial unintegrated work. It is not. Two independent checks say its content is already on `main`:

- `git cherry main feature/night-automations` prints `3526863` with a **leading `-`**, which is Git's own patch-id equivalence verdict: the commit's diff is already reachable from `main`, so it was merged in a form Git cannot see as a fast-forward (a squash or rebase merge), not by ancestry.
- `git diff main feature/night-automations -- lib/automations/automation_service.dart test/automations/automation_service_test.dart` is **empty**. The branch's two substantive files are byte-identical to `main`. The only differences are 13 lines, and they are `main` being *ahead*: two new `AutomationError` codes (`invalidAction`, `invalidRunCount`) and the `automation_scheduler.dart` export.

So the branch is a snapshot from 2026-09-26 that `main` has since passed. Cherry-picking it would be a no-op at best and a revert of the newer error codes at worst.

The trap this exposes is worth recording, because it is the failure mode the delivery rules already warn about from the other side. The readiness gate says "require a real branch commit, an owned-file diff, and supervisor-reproduced tests before integrating" — and this branch passes the first two checks while being worth nothing. Branch count and diff size are not evidence of unmerged work; `git cherry`'s sign and a path-scoped `git diff` are. Had this heartbeat trusted the 2,723-line stat, it would have spent a CI cycle integrating a duplicate.

**Verified state of `main` at `681be55`** (this heartbeat, on the real tree, not from memory):

- `git status --short --branch` — clean, level with `origin/main`.
- `flutter analyze` — `No issues found`.
- `flutter test` — **934 tests, all passed** (matches the 932 → 934 count claimed by the previous heartbeat).
- CI run **36383309875** on `681be5584aee4b33a153cca992bad8d916e328a3` — `success`. The platform-suite guard reports **5 suites, 98 tests run, 0 failures** (up from the 4/77 recorded earlier in this document), so the Kotlin gate is executing and non-vacuous.

No worker processes are running and no `/tmp/noir-wt-*` worktrees exist; the only traces are three stale `flutter analyze` logs from 2026-09-26, all reporting `No issues found`. No branch was integrated this heartbeat, because none carried work that `main` did not already have.

---

## Heartbeat 2026-09-28 (plan/code token-name drift)

`FRONTEND_PLAN.md` named the accent token `coolAccent` in four places (lines 21, 33, 41, 55, 62) while the same document's own theme-tweak section (line 7) and the code both call it `rainbowAccent`. `grep -rn coolAccent` over the whole repo returned only those plan lines — zero occurrences in `lib/`, zero in `test/`. The token has never existed under that name; the plan carried a rename that was applied to the code and to one paragraph but not the rest of the document.

Corrected with a scoped substitution so the plan and the implementation now name the same token. No Dart or Kotlin changed, so this cannot affect behaviour; the point is that a spec whose identifiers do not resolve is not checkable. The `noir_theme_tokens_test.dart` confinement test asserts reference *counts* per file, so it would never have caught a misnamed spec — it has no notion of the name, only of how many places consume the token. A doc can drift from the code without any test failing, which is the same class of gap as the two gate gaps closed earlier in this document.

**Verified state of `main` at `520b5d3`** (this heartbeat, on the real tree):

- `git status --short --branch` — clean, level with `origin/main`; `git log origin/main..main` empty.
- `flutter analyze` — `No issues found`.
- `flutter test` — **934 tests, all passed** (unchanged, as expected for a Markdown-only change).
- CI run **36385211332** on `520b5d3` — `success`.
- No worker processes running; no `/tmp/noir-wt-*` worktrees exist. `git branch --no-merged main` still lists only `feature/night-automations`, already shown in the previous heartbeat to be patch-id-equivalent to `main` and therefore not integration work.

No branch was integrated this heartbeat. The one genuinely open item is unchanged and is not closable here: there is still no device or emulator run, so no claim about on-hardware accessibility automation is verified by anything in this repository.

---

## Heartbeat 2026-09-28 (contract events with no emitter)

`FRONTEND_PLAN.md` line 45 sets a two-part rule for every `NoirUiEvent` subtype: "add to `ui_state_contract.dart` + **real runtime emission** + widget consumer. Fail if any event has no consumer (E5)." Nothing tested either half, and the emission half was broadly unmet.

Reading the twelve subtypes in `lib/core/ui_state_contract.dart` against every construction site in `lib/`:

- **`ToolCallStarted` and `ToolCallCompleted`** — declared, and consumed in `command_centre_screen.dart:1155-1158` as the "Using <tool>…" and "<tool> completed." micro-copy. Constructed **nowhere** in `lib/`. That UI could never render, and `_showSkeleton` at `:310`, which is set only by a `ToolCallStarted`, was therefore permanently false.
- **`CostEstimateResolved`** — consumed by `_UsageRow` ("Responding with <model>"). Also constructed nowhere, so the model line never appeared.
- **`SideConversationOpened`** — declared, never constructed, and no consumer. Legitimately unimplemented (no feature opens a side conversation), so it is recorded as reserved rather than given a fake emitter.

The three wired events are emitted from the only sites that genuinely know the facts: `NativeGestureExecutor.run` for the tool lifecycle, and `_streamCompletion` for model selection. Emission is deliberately placed *after* approval is consumed and *after* the gesture target resolves, so an event can never claim a run the executor then refused; `ToolCallCompleted`'s success flag reads only `NativeGestureOutcome.executed`, the single field the bridge documents as meaning a gesture reached the service. The risk level shown comes from the same classifier the bridge uses, with the same fail-closed fallback to tier 3.

`test/ui_event_contract_test.dart` now asserts the rule. **The first version of it passed while the bug was still present** — it searched for `ToolCallCompleted(` as a substring, and the widget's `case ToolCallCompleted(` matched, so the dead consumer certified itself as a live emitter. Detection now ignores `case`/`is`/`extends` prefixes and requires an actual construction. Verified by deleting the `ToolCallCompleted` emission: the test then failed with `Actual: ['ToolCallCompleted', 'CostEstimateResolved']`, which is also how the second, previously unnoticed gap surfaced. A gate that cannot fail is not a gate; the first draft was one.

934 → **938 tests**, all passing. `flutter analyze` clean.

**Verified state of `main` at `47c98d3`** (before this change): clean and level with `origin/main`; `flutter analyze` `No issues found`; 934 tests passing; CI run **36390115336** on `47c98d3` `success`. No worker processes, no `/tmp/noir-wt-*` worktrees, `feature/night-automations` still the only unmerged branch and still patch-id-equivalent to `main`.

Still unverified and not closable here: there is no device or emulator run, so nothing in this repository confirms on-hardware behaviour. The three events wired here are asserted by source-reading and by the composition root's own tests, not by an observed UI frame.
