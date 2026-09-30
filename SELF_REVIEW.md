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

---

## Heartbeat 2026-09-28 (post-push verification of 9433aa6)

The previous heartbeat wrote its section but recorded the pre-change state, so the 938-test claim and the new emissions were unverified by an independent run at the time. This heartbeat runs them.

**Verified state of `main` at `9433aa6`** (this heartbeat, on the real tree):

- `git status --short --branch` — clean, level with `origin/main`; `git rev-list --count origin/main..main` = 0.
- `flutter analyze` — `No issues found! (ran in 1.0s)`.
- `flutter test` — **938 tests, all passed**. This confirms the 934 → 938 delta the previous heartbeat attributed to `test/ui_event_contract_test.dart`; the count matches its claim exactly rather than approximately.
- CI run **36398847802** on `9433aa6` — `success`, 3m23s. The platform guard reports **Suites: 5, 98 run, 0 failures, 0 errors**, so the Kotlin gate is still executing and non-vacuous.
- No worker processes running. The three `/tmp/noir-wt-*` paths are stale `flutter analyze` logs dated 2026-09-26, not worktrees — `git worktree list` shows only the main checkout. Nothing is mid-flight.
- `git branch --no-merged main` still lists only `feature/night-automations` at `3526863`. Re-checked rather than assumed: `git diff 3526863 main -- lib/automations test/automations` shows only `main` being *ahead* (the `automation_scheduler.dart` export, `invalidAction`, `invalidRunCount`, plus the 436-line scheduler and its tests). Nothing on the branch is missing from `main`, so there is still nothing to integrate.

One thing this heartbeat did not do: it did not verify the *emission sites* by hand. The new test is a source-reading gate, so "938 pass" confirms the contract test still catches a removed emission — it does not independently confirm that `ToolCallStarted` fires at a moment when the Command Centre's rows will actually render. That remains a read-the-code judgement, and it is recorded as one.

---

## Heartbeat 2026-09-28 (skeleton loader never cleared after a tool call)

The previous heartbeat left one item open: it had wired `ToolCallStarted` /
`ToolCallCompleted` but had *not* verified "that `ToolCallStarted` fires at a
moment when the Command Centre's rows will actually render", recording that as a
read-the-code judgement. This heartbeat resolved it by reading the code, and the
read turned up a real defect.

`pushRealEvent` (`lib/ui/command_centre_screen.dart:301`) set `_showSkeleton =
true` on `ToolCallStarted` and cleared it **only** on
`ActionCompletedWithUndoWindow`. Those two events do not bracket a tool call.
`AgentRuntimePipeline` awaits `undoWindow.open(5, ...)` *before*
`execute.run(plan)` (`lib/agent/agent_runtime.dart:75-76`), so on a real run the
order is:

```
ActionCompletedWithUndoWindow  -> _showSkeleton = false
ToolCallStarted                -> _showSkeleton = true
ToolCallCompleted              -> nothing at all
```

Nothing after the tool starts ever clears the flag, so the loader animates for
the rest of the session. This is the direct cost of the previous heartbeat's own
work: it made `ToolCallStarted` reachable for the first time, which is what
exposed the state it was setting to a state nothing could turn off. Before that,
`_showSkeleton` was permanently false and the bug was invisible.

Fixed by clearing on `ToolCallCompleted` too. The undo-window clear is kept,
because that is still the only completion signal on paths that never reach a
tool.

`test/ui/command_centre_skeleton_lifecycle_test.dart` pushes events through the
screen's injected `events` stream — the same wire `main.dart:219` connects to
`composition.taskRun.events` — rather than calling the state directly, so it
exercises the production delivery path. It asserts the real production ordering.

**The RED run, because a gate that cannot fail is not a gate:** before the fix,
"a tool call that finishes stops the loader" and "a failed tool call also stops
the loader" both failed, while the two control tests ("the loader is shown while
a tool call is in flight", "the tool micro-copy still renders from the same run")
passed. So the new tests detect this specific bug and are not failing for some
incidental reason. The controls also stop a future "fix" that deletes the loader
outright, and confirm the fix does not cost the micro-copy rows the earlier
heartbeat wired.

`flutter analyze` — `No issues found!`. `flutter test` — **942 tests, all
passed** (938 → 942, exactly the four new ones).

**Verified state of `main` at `0d4fb30`**: clean and level with `origin/main`
(`git rev-list --count origin/main..main` = 0); local `HEAD` and `origin/main`
both `0d4fb3057a7d33c402ca3bdc19c33d6a5266e993`. CI run **36401778033** was
still `in_progress` at the time this section was written; its result is not
claimed here and must be read from the run itself.

No worker processes, no `/tmp/noir-wt-*` worktrees (`git worktree list` shows
only the main checkout; the three `/tmp/noir-wt-*.log` paths are stale
`flutter analyze` logs dated 2026-09-26). `feature/night-automations` remains the
only unmerged branch and remains patch-id-equivalent to `main`: the diff against
`lib/automations` and `test/automations` shows only `main` being ahead (the
`automation_scheduler.dart` export, `invalidAction`, `invalidRunCount`, the
436-line scheduler and its tests). Nothing to integrate.

Still unverified and not closable here: there is no device or emulator run, so
nothing in this repository confirms on-hardware behaviour. This fix is asserted
by a widget test over the real event wire, not by an observed frame on a device.

---

## Heartbeat 2026-09-28 (a refuted defect, and the gap that was real underneath it)

The previous heartbeat closed the open CI question: run **36401778033**
(`0d4fb30`) came back `cancelled`, not green and not red — it was superseded
41 seconds later by run **36401955194** on `77d6330`, which is `success` with
every step green, including `Assert Android platform tests actually ran`. So the
skeleton-loader fix is covered by a completed run; the cancellation was a
superseded duplicate, not a failure.

This heartbeat then went looking for a defect one level below that fix, and
**found none**. The hypothesis was that the emission pair in
`NativeGestureExecutor.run` is not exception-safe:

```
lib/core/agent_wiring.dart:474  publish?.call(ToolCallStarted(...));
lib/core/agent_wiring.dart:476  final outcome = await _bridge.dispatchGesture(...)
lib/core/agent_wiring.dart:488  publish?.call(ToolCallCompleted(...));
```

`dispatchGesture` catches only `MissingPluginException` and `PlatformException`,
so any other throw would skip line 488 and leave the Command Centre's loader
spinning — the same symptom the previous heartbeat just fixed, on a path its
widget test cannot reach. That test pushes events into the screen by hand and
never runs the executor.

**It cannot happen.** Probed directly against the real `NativeBridge`, both of
these came back as a blocked `NativeGestureOutcome` rather than an escaping
throw: a mock handler throwing a raw `StateError`, and a reply whose map has
non-string keys (so `invokeMapMethod<String, dynamic>` cannot cast it). The
`MethodChannel` normalises platform-side failures to `PlatformException` before
the Dart caller sees them, which is exactly the class the bridge already
catches. The only statement left between the two publishes is
`outcome.executed`, and the sink is guarded — `NoirTaskRun.emit` checks
`_events.isClosed`. **No production change was made, because there is no defect
to fix.** `git diff` against `77d6330` is empty for `lib/`.

**What was real is the coverage gap underneath the hypothesis.** Nothing ran
`NativeGestureExecutor`. The Command Centre test supplies events by hand, and
`test/ui_event_contract_test.dart` is a source-reading gate. So if the executor
stopped publishing `ToolCallCompleted` altogether, every existing test would
still pass and the loader would spin forever.

`test/ui/tool_call_completion_emission_test.dart` (4 tests) closes that by
driving the real executor against a mocked platform channel, with a real
`ConsentGate` approval granted through the gate's own `requests` stream rather
than by reaching into its private map. It pins four honest outcomes: dispatched
(→ completed, success), platform refusal (→ completed, failure), platform error
(→ completed, failure, no escaping throw), and refused-before-dispatch (→ no
events at all, so a run that never happened is not claimed).

**The RED run, because a gate that cannot fail is not a gate:** with
`publish?.call(ToolCallCompleted(...))` temporarily disabled at line 488, 3 of
the 4 failed, and — the point of the exercise — `test/ui_event_contract_test.dart`
stayed **green (4 passed)** through the same break. The existing contract gate
never covered the runtime emitter, which is exactly why this file was worth
adding. The break was reverted; `lib/` is unmodified.

`flutter analyze` — `No issues found!`. `flutter test` — **946 tests, all
passed** (942 → 946, exactly the four new ones).

**Verified state of `main` at `77d6330`**: clean and level with `origin/main`;
`git worktree list` shows only the main checkout and no worker processes are
running, so there is no delegated work in flight. `feature/night-automations`
remains the only unmerged branch and remains fully contained: `git diff main
3526863 -- lib/automations test/automations` shows only deletions, i.e. the
branch is `main` minus the scheduler, with nothing branch-only. Nothing to
integrate.

Still unverified and not closable here: no device or emulator run, so nothing
here confirms on-hardware behaviour. The new tests assert a real executor
against a mocked channel, not an observed gesture on a device.

**Delivery, verified after the fact:** commit `34f442f`, pushed to `main`, with
`git ls-remote` returning `34f442f2bf1459007f5719a4a6c8b835ae493aa3` — equal to
the local `HEAD`, not merely a successful push. CI run **36405820660** is
`success` on that exact `headSha`, with all 18 steps green including
`Assert Android platform tests actually ran`, so the Kotlin suite was proven to
execute rather than reporting `FROM-CACHE`.

---

## Heartbeat 2026-09-28 (the confirmation card was a picture of a consent control)

The three previous heartbeats each made a `NoirUiEvent` reachable. This one read
what happens *after* an event arrives, and the answer was that the most
consequential consumer in the app was inert.

`CommandCentreScreen` renders `_ConfirmationCard` for every
`ConfirmationRequired` on the timeline (`command_centre_screen.dart:1170`). That
card drew Confirm and Cancel through `_CardActionButton`, which hardcoded
`enabled: false` and rendered a plain `Container` — no `onTap` anywhere in the
tree. Underneath it printed, verbatim:

> Disabled: no policy gate is wired to this card yet.

**That sentence was false, and the reason it was false is the defect.** The gate
is wired and live in production: `main.dart:225` passes
`confirmations: composition.confirmations` into `OperationsSheet`,
`main.dart:226-231` passes a handler that calls `confirmation.answer(approved)`,
`composition_root.dart:678` is `gate.requests`, and `runAutomation`
(`:1380-1394`) mirrors every gate request into the very `ConfirmationRequired`
this card renders. `OperationsSheet._ConfirmationPrompt` already did the whole
job correctly.

So the user was looking at a confirmation with two dead buttons *while the
request was genuinely waiting on them*, and the only working answer was on
another screen they had to go and find. `FRONTEND_PLAN.md:20` requires working
`Confirm` + `Cancel` on this card, and the card is the timeline's own record of
the request, so the timeline is where the answer belongs. The cost of the
previous heartbeats' work is the point: wiring `ConfirmationRequired` is what
made this card reachable, and reachable-but-inert is worse than unreachable
because it now looks like the app is waiting on the user when it is not.

**One consent path, implemented once.** The screen takes the same
`gate.requests` stream and the same answer handler `OperationsSheet` already
receives, held the outstanding `PendingConfirmation`, and releases it through
`PendingConfirmation.answer` — the only call that can approve a gated action.
`main.dart` now builds one local `answerConfirmation` function and hands it to
both screens, so two copies of the consent lambda cannot drift.

Two screens holding one request is safe for the reason the class already
guarantees: `answer` is first-answer-wins and returns `false` once anything has
answered, so a stale-refusal on rebind cannot cancel a request the other holder
is legitimately showing. The enabled state is *derived* from `isAnswered` and
`canBeApproved` rather than left to that guarantee, so a released request and a
biometric-demanding one both render disabled — a control that looks live and
cannot be is the most expensive lie in a consent prompt.

The false copy is gone. Each state now says something true: where the request is
answered when nothing is connected, that no request is outstanding, that it was
approved once, that it was refused or expired, or that a biometric check is
required and this build cannot perform one.

**RED, verified by the supervisor rather than taken on report.** I reproduced it
independently: setting `_answerable => false` in the worktree, the new file gives
`00:02 +4 -7: Some tests failed` — 7 of the 11 fail, and the 4 that pass are
exactly the controls (the card's own fields render, both controls are disabled
with nothing connected). Restored, the file is `00:01 +11: All tests passed!`.
The gate discriminates; it is not failing for an incidental reason.

`test/ui/command_centre_confirmation_card_test.dart` drives the real screen over
the injected wires `main.dart` uses, and asserts the answer twice on purpose:
once as a spy on the callback, once as `confirmation.answerValue` on the real
`PendingConfirmation`. A callback spy alone would pass against a handler that
took the argument and threw it away — the same failure the dead buttons had.

`flutter analyze` — `No issues found!`. `flutter test` — **957 tests, all passed**
(946 → 957, exactly the eleven new ones; the baseline was measured on the
unmodified worktree before any edit).

Still unverified and not closable here: there is no device or emulator run, so
nothing here confirms on-hardware behaviour. The button's hit target, the white
fill's contrast on the `0xFF1A1A1A` card, and what a screen reader announces are
reasoned from the code and asserted in a widget test, not observed.

Two limitations recorded rather than hidden, both a consequence of
`ConfirmationRequired` carrying no `requestId`:

* `PendingConfirmation` is not a `Listenable`, so an answer given on the
  Operations sheet does not notify the Command Centre. The card re-derives on
  every build and a gated run always emits something after the decision, so the
  window is short — and what actually holds the line is `answer` itself: a tap on
  a stale card cannot approve anything. `OperationsSheet._ConfirmationPrompt` has
  the same window and is strictly looser, since it checks only `canBeApproved`.
* If the timeline holds several `ConfirmationRequired` rows, each is offered the
  same outstanding request. First-answer-wins makes this safe rather than wrong,
  and a released request renders disabled everywhere, but it is a visual
  duplication. Closing it properly needs per-event correlation the event type
  does not carry, and inventing that correlation was the larger risk.

## Heartbeat 2026-09-28 (CI confirmation for 291fbb3)

The previous heartbeat integrated and documented the Command Centre consent
card but recorded no CI run for it. Read from the workflow, not assumed:

- **CI run 36410433712** on `291fbb3` — `success`, `Noir CI`.
- `flutter analyze` — `No issues found!` (9.0s).
- `flutter test` — **957 tests passed**, matching the count the previous
  heartbeat measured locally, so the documented claim and the gate agree.
- Android platform gate — **Suites: 5, 98 run, 0 failures, 0 errors**. The
  workflow still runs its own "refusing a vacuous pass" assertion, and it did
  not trip, so the Kotlin suite is executing rather than being skipped.

**Integration state re-checked, not inherited.** `git branch --no-merged main`
still lists only `feature/night-automations` at `3526863`, and the prior
heartbeat's patch-id claim is reproducible here: `git cherry main
feature/night-automations` prints `3526863` with a leading `-`. The diff
against `lib/automations` and `test/automations` is 814 deletions and 1
insertion in `main`'s favour — the scheduler, its tests, two `AutomationError`
codes and the export. There is nothing on the branch that `main` lacks, so
merging it would be a no-op at best.

`git worktree list` shows only the main checkout, `/tmp/noir-hb-check.sh` finds
no worktree directories under `/tmp/noir-*`, and no `opencode`, `flutter`, or
`gradle` process is running. `main` is level with `origin/main` at `291fbb3` and
the tree is clean. No delegated work is in flight, so this heartbeat integrated
nothing and the previous one should not have been assumed to.

Still unverified and not closable from this host: no device or emulator run, so
no on-hardware accessibility behaviour is confirmed by anything in the
repository. The confirmation card's hit target, contrast and screen-reader
announcement are asserted in a widget test and reasoned from source, not
observed.

## Heartbeat 2026-09-28 (re-verification of 5251061)

- **CI run 36413034501** on `5251061` — `success`, `Noir CI` (3m27s).
- `flutter analyze` — `No issues found!` (1.2s).
- `flutter test` — **957 tests passed** locally, matching the count the previous
  heartbeat recorded for `291fbb3`; the two new commits since are documentation
  only, so the flat count is the expected result rather than a coincidence.
- `git cherry main feature/night-automations` again prints `3526863` with a
  leading `-`, and `git diff main feature/night-automations` over
  `lib/automations` and `test/automations` is 814 deletions / 1 insertion in
  `main`'s favour. `git branch --no-merged main` still lists only that branch,
  so there is again nothing to integrate.
- `git worktree list` shows only the main checkout; no `/tmp/noir-wt-*`
  directories exist; no `opencode`, `flutter`, or `gradle` process was running
  during this check. `main` is clean and level with `origin/main` at `5251061`.

Unchanged and still not closable from this host: no device or emulator run, so
no on-hardware accessibility behaviour is confirmed by anything in the
repository or by CI.

## Heartbeat 2026-09-28 (CI for cafb887, the first gate on this SHA)

The last heartbeat recorded CI for `5251061`. `main` has since advanced to
`cafb887`, and the gate for that SHA was read from the workflow, not assumed:

- **CI run 36413852711** on `cafb887` — `success`, `Noir CI`.
- `flutter analyze` — `No issues found!` (7.5s).
- `flutter test` — exit 0; the run's own expanded log shows only passing cases
  and the workflow's Android step reports **Suites: 5, 98 run, 0 failures,
  0 errors**. The workflow's "refusing a vacuous pass" assertion ran and did
  not trip, so the Kotlin suite executed rather than being skipped.

**Integration state re-measured.** `git branch --no-merged main` still lists
only `feature/night-automations`; `git cherry main feature/night-automations`
prints `- 3526863`, and the diff over `lib/automations` and `test/automations`
is 814 deletions / 1 insertion in `main`'s favour. `gateverdict-tests` and
`feature/streaming-ui` are both 0 ahead of `main`, so they are integrated, not
pending. There is nothing to merge.

**No workers in flight.** `git worktree list` shows only the main checkout at
`cafb887`; the `/tmp/noir-wt-*` matches are stale log files from earlier runs,
not worktree directories; no `opencode`, `flutter`, `dart` or `gradle` process
is running. `main` is clean and level with `origin/main`. This heartbeat
integrated nothing and started nothing.

Unchanged and still not closable from this host: no device or emulator run, so
no on-hardware accessibility behaviour is confirmed by the repository or by CI.

## Heartbeat 2026-09-28 (CI for 4f81007, current main)

`main` advanced to `4f81007` (docs-only self-review commit recording the
`cafb887` gate). Its CI run was read from the workflow log, not assumed:

- **CI run 36416614799** on `4f81007` — `success`, `Noir CI`.
- `flutter analyze` — `No issues found!` (9.0s).
- `flutter test` — `🎉 957 tests passed.`
- Android platform assertion — `Suites: 5`; the vacuous-pass guard did not
  trip, so the Kotlin suite executed rather than being skipped.

**Integration state re-measured.** `git branch --no-merged main` still lists
only `feature/night-automations`; `git cherry main feature/night-automations`
prints `- 3526863`, a leading `-`, i.e. that branch's work is already
represented in `main`. Nothing to merge. `main` is clean and level with
`origin/main` (0/0 after fetch).

**No workers in flight.** `git worktree list` shows only the main checkout.
`/tmp/noir-wt-*` matches are stale `.log` files from earlier runs, not
worktree directories, so the six named branches have no live checkouts. No
`opencode`, `flutter`, `dart` or `gradle` process is running.

This heartbeat integrated nothing and started nothing. Unchanged and still not
closable from this host: no device or emulator run, so no on-hardware
accessibility behaviour is confirmed by the repository or by CI.

## Heartbeat 2026-09-28 (CI for 12dbf6d, current main)

`main` is `12dbf6d`, level with `origin/main` (0/0), working tree clean, one
worktree (the main checkout). Its CI run was read from the workflow log:

- **CI run 36418141104** on `12dbf6d` — `success`, `Noir CI`.
- `flutter analyze` — `No issues found!` (9.1s).
- `flutter test` — `🎉 957 tests passed.`
- Android platform step — `(cd android && ./gradlew testDebugUnitTest
  --no-build-cache)` → `BUILD SUCCESSFUL in 21s`, after the wrapper-executable
  and wrapper-jar presence assertions passed.

**Integration state re-measured.** `git rev-list --left-right --count
main...<branch>` reports every one of the 23 local branches at `0` ahead of
`main` except `feature/night-automations`, which is `1` ahead — and that single
commit is one `main` already represents (`git cherry` shows it as `-`), i.e. it
is a duplicate history, not new work. Nothing to merge.

**No workers in flight.** No `opencode`, `flutter`, `dart` or `gradle` process
is running. The `/tmp/noir-wt-*` entries are stale `.log` files from earlier
runs, not worktree directories, so the six named branches have no live
checkouts.

This heartbeat integrated nothing and started nothing. Unchanged and still not
closable from this host: no device or emulator run, so no on-hardware
accessibility behaviour is confirmed by the repository or by CI.

## Heartbeat 2026-09-28 (CI for 7ba0e04, current main)

`main` is `7ba0e04`, level with `origin/main` (0/0 after fetch), working tree
clean, one worktree (the main checkout). Its CI run was read from the workflow
log:

- **CI run 36418854312** on `7ba0e04` — `success`, `Noir CI`.
- `flutter analyze` — `No issues found!` (9.0s).
- `flutter test` — `🎉 957 tests passed.`
- Android platform step — `(cd android && ./gradlew testDebugUnitTest
  --no-build-cache)` → `BUILD SUCCESSFUL in 20s`, and the vacuous-pass guard
  printed `Suites: 5`, so the Kotlin suite executed rather than being skipped.

Locally re-measured: `flutter analyze` → `No issues found! (ran in 0.8s)`;
`flutter test` → `+957: All tests passed!`

**Integration state re-measured.** `git branch --no-merged main` still lists
only `feature/night-automations`; `git cherry main feature/night-automations`
prints `- 3526863`, a leading `-`, i.e. that branch's single unique commit is
already represented in `main` (the `d5c5ea5` work on `lib/automations/` is the
same subsystem, and `main` additionally carries `automation_scheduler.dart`,
`lib/data/automation_repository.dart` and `lib/core/automation_wiring.dart`).
Nothing to merge.

**No workers in flight.** No `opencode`, `flutter`, `dart` or `gradle` process
is running. The `/tmp/noir-wt-*` entries are stale `.log` files from earlier
runs, not worktree directories, so the six named branches have no live
checkouts.

This heartbeat integrated nothing and started nothing. Unchanged and still not
closable from this host: no device or emulator run, so no on-hardware
accessibility behaviour is confirmed by the repository or by CI.

## Heartbeat 2026-09-28 12:13Z (CI for 577c505, current main) — and a loop to break

`main` is `577c505`, level with `origin/main` (0/0 after fetch), working tree
clean, one worktree (the main checkout).

- **CI run 36419786560** on `577c505` — `success`, `Noir CI` (2m57s).
- `flutter analyze` — `No issues found!` (9.0s).
- `flutter test` — `🎉 957 tests passed.`
- Android platform step — `BUILD SUCCESSFUL in 18s`, vacuous-pass guard printed
  `Suites: 5`, so the Kotlin suite ran rather than being skipped.

**Integration state re-measured.** `git branch --no-merged main` lists only
`feature/night-automations`, and `git cherry main feature/night-automations`
prints `- 3526863` — a leading `-`, so that branch's single unique commit is
already represented in `main`. Nothing to merge.

**No workers in flight.** No `opencode`, `flutter`, `dart` or `gradle` process
is running. The `/tmp/noir-wt-*` entries are stale `.log` files dated
2026-09-26, not worktree directories, so the six named branches have no live
checkouts.

**The loop, stated plainly.** The last seven commits (`291fbb3`..`577c505`) all
touch `SELF_REVIEW.md` and nothing else — `git diff --name-only 5844755..main`
returns that single file. Each heartbeat appended a report, that commit
triggered a CI run, and the next heartbeat recorded the CI run, which
triggered another. Four CI runs in the last hour (11:08, 11:36, 11:51, 11:58,
12:07) verified the same unchanged tree. This is measurement churn, not
progress, and it should stop.

**Recommendation:** suspend the doc-append-per-heartbeat habit. A heartbeat
should either integrate verified work or report that there is none, in the
message it delivers — not by writing a new commit that costs a CI run. Real
remaining work is not documentation: it is a device or emulator run, which this
host cannot provide, so on-hardware accessibility behaviour stays unconfirmed
by both the repository and CI. No further claim about that is made here.

---

## Heartbeat 2026-09-29 00:xx UTC (docs-only CI skip, verified by pushing this file)

**This commit is the experiment.** `de8838f` added
`paths-ignore: ['**/*.md']` to the Noir CI `push` trigger on `main` to stop
the self-review commit → CI run → self-review commit loop. That claim had never
been executed: every run since `de8838f` came from a commit that also touched a
non-Markdown path. A Markdown-only push is exactly the case the filter claims
to skip, so pushing this section is the cheapest possible test — one file
changed, nothing else. If the filter is correct, **no CI run appears for this
commit**. If one does, the filter is wrong and the loop is still live.

State of `main` at `de8838f`, measured rather than inherited:

- `git status --short --branch` — clean, level with `origin/main`;
  `git rev-list --count origin/main..main` = 0.
- `flutter analyze` — `No issues found!` (0.7s, local).
- `flutter test` — **957 tests, all passed** (local). Matches CI exactly, not
  approximately: CI run 36462073637 logged `🎉 957 tests passed.`
- CI run **36462073637** on `de8838f` — `success`, 3m12s; platform guard
  printed `Suites: 5`, so the Kotlin gate ran rather than passing vacuously.
- `git cherry main feature/night-automations` → `- 3526863`. The leading `-` is
  Git's patch-id verdict: that branch's only unique commit is already
  represented in `main`. `git diff --stat 3526863 main -- lib/automations
  test/automations` shows 814 insertions, all of them on the `main` side (the
  365-line `automation_scheduler.dart` and its 436-line test). The branch is a
  snapshot `main` has passed. Nothing to integrate, and cherry-picking it would
  revert the newer error codes.
- No `opencode`/`flutter`/`dart`/`gradle` process running.
  `git worktree list` shows only the main checkout. The six `/tmp/noir-wt-*`
  paths in the heartbeat script's output are stale `.log` files, not worktree
  directories — the script's "worktree missing" line is correct about the
  worktrees and misleading about why.

**Standing gap, unchanged and not closable on this host:** no device or
emulator run. The accessibility bridge is verified by tests against a mocked
channel plus CI, never by an observed gesture on hardware. No claim is made here
that one exists.

---

## Heartbeat 2026-09-29 ~02:20 UTC — docs-only CI skip CONFIRMED; loop closed

**The experiment in `8a7302e` passed.** `8a7302e` touched exactly one path,
`SELF_REVIEW.md` (+40 lines, `git show --stat` confirms: no other file).
`gh run list --commit 8a7302ea0b85f8e343fcdd4f9b9ff5117bcff812` returns
**zero runs** — an empty result, not a truncated one. The newest run in the
workflow is still **36462073637** on `de8838f`, the commit *before* the
experiment.

So the `paths-ignore: ['**/*.md']` filter on the `push` trigger does what
`de8838f` claimed. The self-review → CI → self-review loop, visible in every
run list from 36410433712 through 36462073637, is broken. Future Markdown-only
commits to `main` are free. Code commits are unaffected: they still match no
ignore pattern and still run the full gate (36462073637, 3m12s, `Suites: 5`).

Measured state of `main` this run, not inherited:

- `git status --porcelain` — 0 lines. `git rev-list --count origin/main..main`
  — 0. `main` = `origin/main` = `8a7302e`.
- `git worktree list` — 1 entry, the main checkout. No `/tmp/noir-wt-*`
  worktree exists; the heartbeat script's "worktree missing" lines refer to
  those paths and are correct.
- `pgrep -af "opencode|flutter|dart|gradle"` — 0 matches. No worker is
  running and none has been started by this run.
- Remote branches: `main` only. Every feature/integration branch is local
  residue from previous runs; none is pushed.

Unmerged-branch state re-checked, not assumed:

- `git branch --no-merged main` → **`feature/night-automations`**, one branch.
  This is the same branch flagged in the previous heartbeat and its status is
  unchanged: its only unique commit is already represented in `main` by patch-id
  (`git cherry main feature/night-automations` → `- 3526863`), and the
  `lib/automations` + `test/automations` diff shows all 814 insertions on the
  `main` side. It is a stale snapshot of work `main` has already absorbed.
  Cherry-picking it would revert the newer error codes. **Do not integrate.**

**Nothing was dispatched this heartbeat.** With no branch carrying unique work,
no unmerged commit to review, and no failing gate, the correct supervisor action
is to record the closed loop and stand down — not to manufacture a worker to
look busy. The next real unit of work is a new feature, which needs a scope
decision, not a heartbeat.

**Standing gap, unchanged and not closable on this host:** no device or
emulator run. The accessibility bridge is verified by tests against a mocked
channel plus CI, never by an observed gesture on hardware. No claim is made here
that one exists. This is the one thing a green CI badge does not cover.

---

## Heartbeat 2026-09-29 ~02:35 UTC — idle; last unmerged branch now reconciled

Measured this run, nothing inherited:

- `git status --porcelain` — 0 lines. `main` = `origin/main` = `67a1983`
  ("docs(self-review): confirm the docs-only CI skip and close the doc loop",
  2026-09-29 02:06 UTC).
- `git worktree list` — 1 entry, the main checkout. No `/tmp/noir-wt-*`
  worktree exists; the heartbeat script's six "worktree missing" lines refer
  to those paths and are correct about the worktrees, misleading only about
  the reason.
- `pgrep -af "opencode|flutter|dart|gradle"` — 0 worker matches (the single hit
  is this heartbeat's own shell). No worker running, none dispatched here.
- `gh run list --commit HEAD` — 0 runs. The docs-only `paths-ignore` skip added
  in `de8838f` still holds for a second Markdown-only commit; the newest run in
  the workflow remains **36462073637** on `de8838f`.
- `git branch -r` — `origin/main` only. Every feature/integration branch is
  local residue.

**One state change since the previous heartbeat, and it is a real one:**
`git branch --no-merged main` is now **empty**. The stale
`feature/night-automations` snapshot flagged at ~02:20 reconciles as merged —
`git cherry main feature/night-automations` returns 0 lines, no unique patch
left to absorb. No cherry-pick, no revert risk. Every remaining branch
(`integration/full-runtime`, `integration/night`, `integration/ui-verify`,
`integration/ui-wiring`, `feature/agent-runtime-truth`,
`feature/automation-scheduler`, `feature/data-persistence`, `feature/mcp-wiring`,
`feature/provider-runtime`) is 47–77 commits *behind* `main` and 0 ahead.

**Nothing was dispatched.** With no branch carrying unique work, no unmerged
commit, no dirty tree and no failing gate, manufacturing a worker here would be
activity without evidence. `main` carries 80 `lib/` Dart files and 51 tests.

**Standing gap, unchanged and not closable on this host:** no device or
emulator run. The accessibility bridge is verified by tests against a mocked
channel plus CI, never by an observed gesture on hardware. No claim is made here
that one exists. This is the one thing a green CI badge does not cover.

---

## Heartbeat 2026-09-29 ~11:40 UTC — still idle; main advanced docs-only

Measured this run, nothing inherited:

- `git status --porcelain` — 0 lines. `main` = `origin/main` = `fab4ed2`
  ("docs(self-review): record empty no-merged set and idle dispatch",
  2026-09-29 10:07 UTC). One commit ahead of the `67a1983` recorded at the
  ~02:35 heartbeat; it touches only `SELF_REVIEW.md`.
- `git worktree list` — 1 entry, the main checkout. No `/tmp/noir-wt-*` exists,
  so the script's six "worktree missing" lines are accurate about the worktrees
  and misleading only about the cause.
- `pgrep -af "opencode|flutter|dart|gradle"` — 0 workers; the only hit is this
  heartbeat's own shell.
- `gh run list --commit fab4ed2` — 0 runs. The docs-only `paths-ignore` from
  `de8838f` holds for a third Markdown-only commit; newest workflow run is still
  **36462073637** on `de8838f`.
- `git branch --no-merged main` — empty, unchanged. All 21 local branches are
  1–79 commits *behind* `main` and 0 ahead; `feature/night-automations` remains
  the closest at 1 behind.
- `main` carries 80 `lib/` Dart files and 59 test files.

**Nothing was dispatched.** No branch holds unique work, no unmerged commit, no
dirty tree, no failing gate. A worker here would be activity without evidence.

**Standing gap, unchanged and not closable on this host:** no device or
emulator run. The accessibility bridge is verified by tests against a mocked
channel plus CI, never by an observed gesture on hardware. No claim is made here
that one exists. This is the one thing a green CI badge does not cover.

---

## Heartbeat 2026-09-29 ~14:40 UTC — idle; docs-only CI skip now proven on a 4th commit

Measured this run, nothing inherited:

- `git status --porcelain` — 0 lines. `main` = `origin/main` = `f121ee9`
  ("docs(self-review): record the 11:40 idle heartbeat and unchanged empty
  no-merged set", 2026-09-29 ~11:40 UTC). Ahead/behind vs origin: 0/0.
- `gh run list --commit f121ee9` — 0 runs. The `paths-ignore: '**/*.md'` from
  `de8838f` now holds for a real self-review commit, not just the two that
  proved it deliberately. Newest workflow run is still **36462073637** on
  `de8838f` (success, 3m12s). The doc-commit CI loop is genuinely closed.
- `git worktree list` — 1 entry, the main checkout. No `/tmp/noir-wt-*` dir
  exists; the three `/tmp/noir-wt-*-analyze.log` files are stale artifacts from
  2026-09-26 08:29 and belong to worktrees that no longer exist. The pre-run
  script's six "worktree missing" lines are correct about the worktrees and
  silent about the cause: no work was ever dispatched this cycle.
- `ps -eo cmd | grep -E "opencode|claude|flutter|dart|gradle"` — 0 workers.
- `git branch --no-merged main` — empty. All 23 local branches are 0 ahead;
  `feature/night-automations` is closest at 2 behind, then
  `fix/command-centre-confirmation-card` at 13, `gateverdict-tests` at 26.
  Nothing anywhere holds unique work.
- `main` carries 80 `lib/` Dart files, 51 `*_test.dart` files (59 files under
  `test/`), 12 Kotlin files.

**Nothing was dispatched.** No branch holds unique work, no unmerged commit, no
dirty tree, no failing gate. A worker here would be activity without evidence.

**Correction to the ~11:40 entry:** it attributed the 0-run result to the
`paths-ignore` holding "for a third Markdown-only commit". The mechanism is the
same but the count was off by one — this is the fourth post-`de8838f`
Markdown-only commit to produce 0 runs, and the first one recorded as a
routine heartbeat rather than a deliberate proof.

**Standing gap, unchanged and not closable on this host:** no device or
emulator run. The accessibility bridge is verified by tests against a mocked
channel plus CI, never by an observed gesture on hardware. No claim is made here
that one exists. This is the one thing a green CI badge does not cover.

---

## 2026-09-30 ~04:30 UTC — NOT idle: the D15 Undo control is now real

The five idle heartbeats above are closed. This run dispatched work and
integrated it.

**The gap, found by reading the code rather than the logs:**
`UndoToast` (`lib/ui/command_centre_screen.dart`) rendered `_UndoActionButton`
as a hard-coded disabled box with the literal caption "Disabled: undo is not
wired to an action executor yet." Meanwhile `CountdownUndoWindow.cancel()`
(`lib/core/agent_wiring.dart:403`) already existed and its only caller was
`composition_root.dispose()`. A6b was half-delivered: the runtime could cancel a
window and no press could reach the executor that ran the action.

A second defect in the same path: `CountdownUndoWindow.open()` published
`reversible: outcome == UndoOutcome.cancelled` — the action was announced as
reversible only *after* the user had already cancelled it, and irreversible when
the window merely ran out of time. The flag described the ending, not the action.

**Delivered** (`ecb07d5`, merged `77cdf83`, formatted `485d17f`, all pushed to
`main`):

- `UndoableAction` records the plan, risk, executor and outcome of the action
  that ran; `Compensation` names the inverse as data (a verb plus the text to
  aim at), never a node or a gesture.
- `kActionCompensations` holds exactly one entry, `navigate -> navigate_back`.
  A tap cannot be untapped, so every other verb is irreversible by construction
  and is offered no control rather than a control that could not fire.
- The window now publishes when it **opens**, holds a `LiveUndoWindow` that is
  the only thing a press may act on, and clears it when it closes — which is
  what makes a second press a no-op.
- `NoirComposition.undo(actionId)` is the control's whole implementation: it
  answers against the live window alone, refuses with a reason when there is
  nothing to reverse, and runs the compensation through `runAutomation`, so it
  is planned against the live screen, scored by the same `RiskClassifier`, vetted
  by the same `PolicyEngine` and confirmed by a human through the same
  `ConsentGate`. The original approval is not reused; it was single-use.
- `UndoToast` takes the executor by injection, like `onAnswerConfirmation`. It
  is live when a handler is connected, honest when one is not, and never
  substitutes a local one.

**Evidence, all measured this run:**
- `flutter analyze` on the merged tree: `No issues found!`
- `flutter test` on the merged tree: `1001 passed`, 0 failed.
- CI run **36668899515** on `485d17f`: `success`, 5m09s.
- `grep TODO|FIXME|UnimplementedError` over `lib/`: 0 hits. The only surviving
  mention of the old caption is a doc comment explaining what replaced it.

**One thing worth recording about the process.** The first merge (36668675428)
failed, and it was the worker's fault, not a flake: the `dart format` gate added
in 70c4b7f was never run over its own output. Six files were non-conformant.
Fixed in 485d17f, formatting only, 1001 tests unchanged. The lesson for every
future dispatch: **the format gate is part of "done"**, and a worker that reports
`analyze` clean has not met the bar.

A second process note: the worker's own composition tests were initially
failing for a reason that had nothing to do with the production code — the test
fixture asked for `input: 'maps'` against a dump whose nodes read "Send message"
and "Back", so the executor correctly refused to dispatch a gesture to a node that
was not there, and the test then blamed the feature. The production path was
verified correct against the real bridge before the fixture was corrected. Worth
remembering that a failing new test is evidence about the test until proven
otherwise.

**Standing gap, unchanged and not closable on this host:** no device or emulator
run. The undo path is verified by widget tests plus an end-to-end test against
the real `NativeBridge`, the real `PolicyEngine` and the real `ConsentGate` with
a mocked platform channel — never by an observed press on hardware. No claim is
made here that one exists.

---

## Heartbeat 2026-09-29 ~15:xx UTC — idle; fifth consecutive no-op run

Measured this run, nothing inherited:

- `git status --porcelain` — 0 lines. `main` = `origin/main` = `c2115c8`
  ("docs(self-review): record the 14:40 idle heartbeat and the closed docs-only
  CI loop", 2026-09-29). Ahead/behind vs origin: 0/0.
- `gh run list --commit c2115c8` — 0 runs. Fifth Markdown-only commit since
  `de8838f` to produce 0 runs; newest workflow run is still **36462073637** on
  `de8838f` (success, 3m12s).
- `git worktree list` — 1 entry, the main checkout. The three
  `/tmp/noir-wt-*-analyze.log` files are still the stale 2026-09-26 08:29
  artifacts; no `/tmp/noir-wt-*` worktree directory exists. The pre-run
  script's six "worktree missing" lines are correct and stay unexplained by
  work: nothing was dispatched.
- `ps -eo cmd` grep for `opencode|claude|flutter|dart|gradle` — 0 workers.
- `git branch --no-merged main` — empty. `git rev-list --count --branches
  --not main` — 0. All 23 local branches are 0 ahead; nothing anywhere holds
  unique work.
- `main` carries 80 `lib/` Dart files, 51 `*_test.dart` files, 12 Kotlin files.

**Nothing was dispatched.** No unmerged commit, no dirty tree, no worker, no
failing gate. A worker here would be activity without evidence.

**Standing gap, unchanged and not closable on this host:** no device or
emulator run. The accessibility bridge is verified by tests against a mocked
channel plus CI, never by an observed gesture on hardware.

**Meta-note worth flagging:** the last four `main` commits are heartbeats
about there being nothing to do. This entry is the fifth. Recording idle runs
is no longer producing new information; the next useful run should either
dispatch real work or report only on a state change.

---

## 2026-09-30 — NOT idle: the A4 recovery audit trail is now readable

**The gap, found by reading the code rather than the logs.**
`SanitizingRecoveryEngine.executeReflectionRecovery` built a real audit entry
(`lib/agent/recovery_engine.dart`) and appended it to its own `auditTrail`. A
repo-wide grep found two hits for `auditTrail`, both inside that one class: the
declaration and the `add`. No test, no UI and no other lib file ever read it. The
comment above the call said so — "not yet forwarded anywhere: the Safety Center
(D9) event bus does not exist yet" — and D9 has existed for a while.

Two more facts turned up while closing it, and both were bigger than the audit
entry:

1. **The Safety Center was never given the log at all.**
   `CommandCentreScreen._openSafetyCenter` built `SafetyCenterScreen` with a
   bridge and an MCP wiring but no `log`, so the screen said "No safety log is
   connected." while the graph recorded every blocked gesture, every sanitized
   dump and every confirmation into `composition.safetyEvents()`. `main.dart` now
   hands that stream down, so the log a user reads is the graph's own.
2. **The log could not have been replayed even if it had been wired.**
   `safetyEvents()` published into a `StreamController.broadcast` *synchronously*
   and then returned `.stream` — so the one event that carried the current state
   was added before the caller could subscribe, and a broadcast controller drops
   it. A screen that subscribed a second later got nothing and waited on
   "Reading the safety log…" forever. `safetyEvents()` now returns a per-listener
   feed that queues the log as it stands on attach and then forwards changes, and
   an empty log is published as an empty `SafetyEventAvailable` rather than as
   `SafetyEventLoading` — "connected and empty" is a fact, "still reading" is not.

**Delivered:**

- `RecoveryAudit` (`lib/agent/recovery_engine.dart`) is the typed record: task id,
  confidence, chosen path, whether sanitized content was used, and the moment —
  all read off the recovery that produced them. `auditLog()` still returns the
  same wire-shaped map and `SanitizingRecoveryEngine.auditTrail` is kept; both are
  now two views of one record, so a row cannot carry a different score or a
  different moment than the trail.
- `executeReflectionRecovery` returns the record instead of discarding it, and
  `SanitizingRecoveryEngine` takes an `onAudit` sink. Null is honest and silent —
  no local fallback sink is invented.
- The composition root injects `_logRecovery`, which writes the same
  `SafetyEventKind.recovery` / `blocked` row every other decision goes through.
  The badge is derived from the existing enum, so no colour and no widget was
  added; the row reuses the badge and label the safety log already renders.
- Display-only: no gate, no task transition and no pipeline behaviour changed,
  and the new test asserts the run still ends `RECOVERY_NEEDS_REVIEW` with the
  task in `failed`.

**Evidence, all measured on this branch:**

- `flutter analyze`: `No issues found!`
- `flutter test`: `+1005: All tests passed!` (1001 before this branch, +4 new)
- `dart format --output=none --set-exit-if-changed lib test` — the gate CI runs:
  `Formatted 144 files (0 changed)`, exit 0.
- The new tests have teeth, checked rather than assumed: deleting the one line
  that injects `onAudit` fails both recovery tests and leaves the two empty-state
  tests green.

**One honest limit, recorded because it is not this branch's to fix.**
`AgentRuntimePipeline` only calls `executeReflectionRecovery` when
`ReflectionCritic.computeConfidence` scores below 0.5, and that function can only
get there for an execution outcome that is null or whose `toString()` contains
"failed"/"error". The shipped `NativeGestureExecutor` always returns a
`NativeGestureOutcome`, which has the default `toString` — so with the current
critic the recovery branch is not reachable from `runAutomation`. The new test
drives the graph's own engine directly and says so in its header rather than
faking a pipeline run that cannot happen. Closing that second gap means changing
`ReflectionCritic`, which is a behaviour change to the runtime, not display
plumbing.

**Standing gap, unchanged and not closable on this host:** no device or emulator
run. This is verified by tests against the real composition root, the real
`PolicyEngine` and the real `SafetyCenterScreen` with a mocked platform channel —
never by a person opening the screen on hardware. No claim is made here that one
exists.

---

## 2026-09-30 ~06:20 UTC — NOT idle: the recovery branch is reachable from a real run

**The gap, found by reading the code rather than the logs.**
This is the gap the last entry left open, and it was left open honestly:
`ReflectionCritic.computeConfidence` (`lib/agent/agent_runtime.dart:156` before
this branch) scored an execution with `executed.toString().contains('failed')` or
`.contains('error')`. The only real answer on the automation path is
`NativeGestureOutcome` (`lib/platform/native_bridge.dart:179`), which implements
`ExecutionReport` and carries a structured `bool executed`, a `NativeGateVerdict`
and a `receipt` — and does not override `toString`. So it rendered as
`Instance of 'NativeGestureOutcome'`, the check could not fire, and every real
run scored 0.92. `reflection.confidence < 0.5` was unreachable, so
`executeReflectionRecovery` never ran through the pipeline and the A4 audit trail
added in 73ac4e3/22ed024 only ever grew inside a test that called the engine by
hand.

Two smaller lies were sitting in the same function, found the same way:

1. **The `0.6` branch was dead.** It sniffed
   `sanitizedContent.contains('REASON_')`, and `analyze` was handed
   `sanitized.cleanTextNodes.join('\n')` — the *clean* nodes, which by
   construction cannot contain a `Reason` name. Nothing could ever produce it.
2. **The comment above it claimed a plan-vs-observed comparison.** "compares
   intended outcome (plan) vs observed screen state". `Plan` was never read by
   the function. A repo-wide `grep` for a second screen read inside the pipeline
   finds none: the platform receipt echoes `x`/`y` from the bounds the executor
   itself resolved and sent (`MainActivity.kt` `handleDispatchGesture`), so
   reading it back would be the executor checking its own arithmetic. The
   comparison the comment promised cannot be built out of anything this build
   collects.

**Delivered:**

- `ExecutionSignal` (`lib/agent/agent_runtime.dart`) is a capability interface
  beside `ExecutionReport`, carrying `bool? gateGranted` and `String?
  platformCode`. It is declared on the `lib/agent/` side because that half must
  not import `lib/platform/`, which already imports it. `NativeGestureOutcome`
  implements it; `gateGranted` is a one-line projection of `verdict.allowed`.
  The `Executor`/`RecoveryEngine` boundary stays `dynamic` — the critic narrows
  on the interface instead of widening the signature.
- The critic reads the report's own fields through the existing
  `executionConfirmed` fail-closed rule, and the score comes off a named ladder
  rather than inline literals: no observation `0.10`, not executed `0.20`, not
  executed with a platform code `0.30`, executed over a dump the sanitizer
  stripped something off `0.60`, executed clean `0.92`. Every negative sits under
  the `0.5` the pipeline routes on, asserted as an invariant rather than assumed.
- `analyze` now takes the `SanitizedResult` instead of a joined string, so the
  `0.6` rung reads `stripped.isNotEmpty` and is live: on the real dump this test
  suite uses, a zero-alpha node is stripped and a confirmed run scores 0.60
  instead of 0.92.
- The plan-vs-observed comment is corrected, and says why no such comparison is
  performed rather than just deleting the claim. `Plan` is still taken, because
  the pipeline hands every stage the plan it ran; a test asserts the plan cannot
  move the score, so the absence is pinned rather than trusted.
- Display path untouched: no gate, no task transition, no widget, no Safety
  Center change. The four existing recovery-surface tests are unmodified and
  still pass, and the header of that file — which said the branch was
  unreachable and explained why it drove the engine directly — is corrected to
  say the branch is reachable now and that driving it directly there is a
  deliberate choice about what those tests isolate.

**Evidence, all measured on this branch:**

- `flutter analyze`: `No issues found!`
- `flutter test`: `+1023: All tests passed!` (1005 before this branch, +18 new,
  none removed)
- `dart format --output=none --set-exit-if-changed lib test` — the gate CI runs:
  `Formatted 145 files (0 changed)`, exit 0.
- The new tests have teeth, checked by mutating `lib/` four times rather than
  asserted:
  - deleting the whole negative half of `computeConfidence` — **14 failures**,
    including `a dispatched gesture the platform failed is scored, recovered and
    logged` and every rung test in the new file;
  - collapsing the platform-code rung into the code-less one — **5 failures**;
  - deleting the sanitized-screen rung — **2 failures** (the first run of this
    one produced only 1, so the test asserting `concealed < clean` was added);
  - deleting the `is! ExecutionReport` guard so an unreadable answer falls
    through as a success — **2 failures**.

**One honest limit, recorded because it is not this branch's to fix.**
One pre-existing test changed meaning, and it is worth saying plainly rather
than burying: `a compensation with nothing to aim at reports the real reason`
(`test/composition_root_test.dart`) asserted `(await run)!.blocked, isFalse` and
an undo refusal of `MALFORMED_GESTURE_TARGET`. Both assertions encoded the defect
this branch removes — a compensating run where the executor reported
`executed: false` was being counted as a *successful* run at 0.92 confidence. The
test now expects `RECOVERY_NEEDS_REVIEW` and says why in place. What that costs
is real: the undo now reports the recovery engine's block code instead of the
executor's narrower `MALFORMED_GESTURE_TARGET`, because
`SanitizingRecoveryEngine` returns its own `GateResult` and does not carry the
outcome out with it. Restoring the specific code means changing the recovery
engine's return value or `_undoResult`, and both were out of scope here — the
recovery engine's return feeds the Safety Center's safety log, which 22ed024
owns. Not worked around, not hidden.

**Also deliberately not changed:** `PolicyEngine`, `ConsentGate` and every other
gate; `TaskController`/`NoirTaskRun` transitions (`recovering` → `failed` on
recovery is unchanged); `SanitizingRecoveryEngine`'s return value, its audit row
and the `onAudit` sink; `SafetyCenterScreen` and the row it renders;
`NativeGestureExecutor`'s approval handling and bounds resolution; the
`CountdownUndoWindow` ordering. Two test fixtures that stood in for an execution
answer with a bare string (`_Executor` in `test/agent_runtime_test.dart`, and the
`'sent'` / `'action failed'` values in `test/agent_runtime_truth_test.dart`) were
replaced with the real `NativeGestureOutcome` the shipped executor returns — no
assertion in either file was weakened or deleted, and the test count went up.

**Standing gap, unchanged and not closable on this host:** no device or emulator
run. Java and the Android SDK are both absent here, so nothing in this entry was
observed on hardware. It is verified by tests against the real composition root,
the real `PolicyEngine`, the real `ConsentGate`, the real `NativeGestureExecutor`
and the real `NativeBridge` with a mocked platform channel — never by a person
watching a gesture land. No claim is made here that one exists.

---

## 2026-09-30 ~07:10 UTC — NOT idle: the undo toast now names what went wrong

**The gap, and it is the one the last entry left open on purpose.**
50767f2 made the A4 recovery branch reachable from a real run, and recorded the
cost plainly: `SanitizingRecoveryEngine.executeReflectionRecovery`
(`lib/core/agent_wiring.dart`) receives the real `NativeGestureOutcome` and
returns `RuntimeResult.blocked(GateResult.blocked('RECOVERY_NEEDS_REVIEW'))`,
discarding it. So a compensating run that failed for a specific reason — the
screen had no node to aim at, the gate stopped it, the platform threw — ended a
D15 undo with the blanket code, and
`a compensation with nothing to aim at reports the real reason` had to be
changed to expect `RECOVERY_NEEDS_REVIEW` and say why. The stated reason for
leaving it alone was that the recovery engine's return value also feeds the
Safety Center's safety log, which 22ed024 owns. That caution is respected here:
the reason does not go *into* the return value, it goes beside it.

**Delivered:**

- `RuntimeResult.failureReason` (`lib/agent/agent_runtime.dart`) is the carrier:
  a nullable `String?` on the result, set by
  `RuntimeResult.blocked(policy, failureReason: …)`, null for every success and
  for every block that has nothing specific to say. It travels beside
  `RuntimeResult.result`, not inside it, so the `GateResult` — the code the
  Safety Center's row means, and the whole of what 22ed024 renders — is
  byte-for-byte what it was. `withReflectionEvent` carries it across the
  recovery hop, which is the only hop a real caller reaches the engine through.
- `ExecutionSignal` gains `String? get blockReason`, the "why did this run not
  happen" answer, beside the "what did the platform say" answer it already had.
  `NativeGestureOutcome.blockReason` already existed and is now the
  implementation of it, unchanged. The interface widened rather than a signature,
  for the reason 50767f2 gave: the `Executor`/`RecoveryEngine` boundary stays
  `dynamic` and the reader narrows on the interface instead.
  The two fields are different questions and are documented as such — a gate
  refusal never reaches the platform, so it carries no `platformCode` and the
  gate's own message is the only reason there is. That case is pinned by a test,
  and it is the one a `platformCode`-only reader gets wrong.
- `reportedBlockReason(Object?)` is the one reader, shared by nothing else and
  used by the recovery engine: it narrows on `ExecutionSignal`, reads
  `blockReason` structurally, and returns null unless the signal genuinely
  carries a reason — not a signal, a run the platform *confirmed*, or a blank
  string all report nothing. No `toString()` sniffing is reintroduced anywhere;
  `'action failed'` is asserted to report no reason, which is the assertion that
  would fail if it were.
- `SanitizingRecoveryEngine` returns
  `RuntimeResult.blocked(GateResult.blocked('RECOVERY_NEEDS_REVIEW'),
  failureReason: reportedBlockReason(executed))`. Its audit row, its `onAudit`
  sink, its task transitions and the code it returns are untouched.
- `_undoResult` (`lib/core/composition_root.dart`) prefers `result.failureReason`
  for a blocked run, after the `kUndoNotApproved` check and before the
  `GateResult` message. `kUndoNotApproved` stays first on purpose: nobody
  answering the gate is a fact about the press, not about the run the carried
  reason would describe. The message stays the fallback, so a run with no
  specific reason still reports the stage's own code.

**The pre-existing test whose expectation this reverses, and why.**
`a compensation with nothing to aim at reports the real reason` expects
`kCodeMalformedGestureTarget` again instead of `'RECOVERY_NEEDS_REVIEW'`, and
the reason is written in place: 50767f2 changed that expectation to close the
`executed: false` scoring defect and recorded the loss of the specific code as a
limit of that change. It is not a limit of the app. Both assertions in it still
hold — the run is still `RECOVERY_NEEDS_REVIEW` and the refusal is still a
refusal — and the one that changed now says what the executor said. A second
test in the same group makes the same claim about a *different* failure, so the
assertion cannot be satisfied by one code being hardcoded somewhere: a
compensating gesture the platform then fails reports
`kCodeNativeDispatchFailed`, and a compensating gesture with nothing to aim at
reports `kCodeMalformedGestureTarget`.

**Evidence, all measured on this branch:**

- `flutter analyze`: `No issues found!`
- `flutter test`: `+1034: All tests passed!` (1023 before this branch, +11 new,
  none removed)
- `dart format --output=none --set-exit-if-changed lib test` — the gate CI runs:
  `Formatted 145 files (0 changed)`, exit 0.
- The new tests have teeth, checked by mutating `lib/` five times rather than
  asserted. Each mutation was run against
  `test/agent_runtime_critic_signal_test.dart`, `test/agent_runtime_truth_test.dart`
  and `test/composition_root_test.dart` and then reverted:
  - `withReflectionEvent` dropping `failureReason` (the reason dies at the
    pipeline's own hop) — **4 failures**: both compensation-refusal tests and
    both pipeline-level reason tests;
  - the recovery engine no longer passing `failureReason:` at all — **4
    failures**, the same four;
  - `_undoResult` ignoring the carried reason — **2 failures**, both
    compensation-refusal tests, and the pipeline tests stay green because the
    field is still on the result. That is the point of the two layers being
    asserted separately;
  - the reader reading `platformCode` instead of `blockReason` — **3 failures**:
    the gate-refusal test in each of the two files, plus the
    `MALFORMED_GESTURE_TARGET` compensation test, which is that same case seen
    end to end;
  - the reader dropping its `executionConfirmed` guard — **2 failures**: the
    confirmed-run test and the interface test, i.e. the code would have been
    invented for a run that did not fail.

**Deliberately not changed:** `PolicyEngine` and `ConsentGate`; the A5 task
transitions (`recovering` → `failed` on recovery, and the compensation's own
`failed`); `SanitizingRecoveryEngine`'s audit row, its `onAudit` sink and the
`RECOVERY_NEEDS_REVIEW` code it returns; `SafetyCenterScreen` and every field of
the row 22ed024 renders; the A12 critic's rung scores and what
`ExecutionSignal.gateGranted` means; `NativeGestureExecutor`'s approval handling
and bounds resolution; `RuntimeResult.result`, `reflection` and
`reflectionEvent`. No signature changed, so there was no implementer or caller
to chase: `blocked` takes an optional named argument, every construction site is
unchanged, and the only implementer of `ExecutionSignal` in the app already had
the getter. The `_recordedFailureCode` rung in the critic is left reading
`platformCode` on purpose — it scores *what the platform said*, which is not the
question `_undoResult` asks.

**Two honest limits, recorded rather than smoothed over.** First, a scheduled
automation that fails (`lib/core/automation_wiring.dart`) still reports
`describeAutomationError(result.result)`, so a job's `lastError` will still say
`RECOVERY_NEEDS_REVIEW` where the undo toast now says the specific code. That is
the D15 toast the task names and nothing more; the field is on the result and
one line of that file would read it, but changing what a job's stored error says
is a different surface and is not claimed here. Second, the reason is reported
only when a signal carries one, so a recovery run entered for a reason that is
not an executor failure still falls back to the blanket code — by design, and
asserted rather than assumed.

**Standing gap, unchanged and not closable on this host:** no device or emulator
run. Java and the Android SDK are both absent here, so nothing in this entry was
observed on hardware. It is verified by tests against the real composition root,
the real `PolicyEngine`, the real `ConsentGate`, the real `NativeGestureExecutor`,
the real `NativeBridge` and the real `SanitizingRecoveryEngine` with a mocked
platform channel — never by a person reading a toast on a phone. No claim is
made here that one exists.

## 2026-09-30 ~07:40 UTC — the first limit the 07:10 entry left open is closed

The 07:10 entry closed the undo path and left one thing unclaimed on purpose:
a scheduled automation that fails still recorded
`describeAutomationError(result.result)`, so a job's `lastError` named the
blanket `RECOVERY_NEEDS_REVIEW` where the D15 toast named the specific code.
`d3175c1` is that work. This entry records it and what was re-measured, and
corrects the reader's sense of scale: the case that entry called "one line of
that file" was a defect, and the defect's symptom was not the blanket code at
all.

**The symptom was worse than the limit described.** `ConsentGatedAutomationExecutor`
passed a `GateResult` to `describeAutomationError`, which calls `toString()` on
it. `GateResult` has no `toString` override, so a denied or blocked job wrote
the literal string `Instance of 'GateResult'` into its user-facing `lastError` —
a record that named no reason whatsoever, not even a coarse one. The
`RECOVERY_NEEDS_REVIEW` limit was the best case of a bug whose worst case was
better than useless.

**Delivered in `d3175c1`:**

- `_blockReason(RuntimeResult)` reads the block structurally and in order of
  specificity: the executor's own `RuntimeResult.failureReason` — the field
  2d75ab7 added, now read by a second real caller rather than only by the undo
  window — then the gate's own `GateResult.message`, then the stated absence
  `'BLOCKED'`. A job's `lastError` now names the same specific code the D15
  toast names, which is what the 07:10 entry said was not claimed.
- `executionConfirmed(result.result)` gates the success path, which the previous
  code did not check at all. The executor refused a blocked result and let an
  unblocked result through unconditionally, so a run the platform never
  confirmed was recorded as `succeeded`. "Not blocked" is not "done" — the same
  distinction the A12 critic and the undo window already make from the same
  reader, which is why it is imported from `agent_runtime.dart` rather than
  reimplemented.
- `_unconfirmedReason(Object?)` reads the unconfirmed case through
  `ExecutionSignal` and never off a rendering. The shipped answer is a
  `NativeGestureOutcome`, whose default `toString` is
  `Instance of 'NativeGestureOutcome'` — the identical bug under a different
  class name. The commit records that a probe caught exactly that on the first
  attempt, which is the reason the reader is structural.

**Re-measured on this host at this SHA (d3175c1), not read from the commit
message:**

- `flutter analyze` — `No issues found!`
- `flutter test test/core/automation_executor_honesty_test.dart
  test/integration/scheduled_automation_test.dart` — `+16: All tests passed!`
- `dart format --output=none --set-exit-if-changed lib test` — the gate CI runs:
  `Formatted 146 files (0 changed)`, exit 0.
- CI: `Noir CI` on `d3175c1` concluded **success** (run created
  2026-09-30T07:38:58Z). Every commit on main since `77cdf83` is green; the one
  red run in the recent list, `77cdf83` itself, was the format-gate failure that
  `485d17f` fixed.
- Working tree clean, `main` level with `origin/main` at `d3175c1`. No worker
  processes running, no `/tmp/noir-wt-*` worktrees present — the five files of
  that name under `/tmp` are analyze logs from finished runs, not live trees.

**The reachability caveat is load-bearing and is carried forward, not smoothed
over.** The unconfirmed branch cannot be reached through the shipped A6 pipeline
today: `computeConfidence` scores every unconfirmed run at 0.20 or 0.30, both
under the 0.5 threshold, so such a run is always routed to recovery before the
executor sees it. Its three tests are therefore driven at the executor's
injectable `run` seam, not through the real graph. That branch is a fail-closed
guard against a future implementer, not a path production takes today, and it
should not be read as evidence that the app has been seen recording a false
success. The blocked-reason case, which the pipeline *does* reach, is asserted
in the integration suite against the real composition root.

**The tests have teeth, checked by mutation rather than asserted.** With
`lib/core/automation_wiring.dart` reverted to its pre-commit state, 4 of the 6 new
tests go red — the 3 executor-contract tests and the real-graph blocked-reason
test — while all 10 pre-existing tests in
`test/integration/scheduled_automation_test.dart` stay green, so the new
assertions are not passing on a change that leaves the old behaviour intact
under a different assertion. The committed suite also asserts the absence
directly: `expect(stored.lastError, isNot(contains('Instance of')))` — the
defect named as a symptom rather than described as one.

**Standing gap, unchanged:** no device or emulator run. Java and the Android SDK
are still absent on this host, so nothing in this entry was observed on hardware.
The claim here is narrower than the previous one's and is stated to match: the
unconfirmed-run guard is verified against the executor's own seam with a mocked
platform channel, and the blocked-reason fix is verified against the real
composition root, the real gate and a real dispatch. Neither is a person
watching a job's error field on a phone.

## Heartbeat 2026-09-30 10:54 (re-verification of 5c9e8b3)

The previous heartbeat ended on the code commit `d3175c1` and the docs commit
`5c9e8b3`. Both gates were read, not assumed:

- **CI run 36684913887** on `d3175c1` — `success`, `Noir CI` (3m22s).
- **No CI run exists for `5c9e8b3`, and that is expected rather than a gap.**
  `git show --name-only 5c9e8b3` prints one path, `SELF_REVIEW.md`, and the
  workflow's `paths-ignore: ['**/*.md']` skips a push only when every changed
  path matches, so the docs commit is deliberately not gated. The claim here is
  that the code behind the last green run is unchanged since, not that `5c9e8b3`
  was verified.
- **`flutter analyze` locally** — `No issues found!` (1.2s), on `5c9e8b3`.
- **`flutter test` locally** — exit 0, `🎉 All tests passed!`, final counter
  **1040 tests**. The count is higher than the 957 recorded for `291fbb3`
  because the A4 recovery-audit, A12 critic-signal, D15 undo-reason and
  automation-honesty work landed after it; this run's counter is what was
  actually observed, not a projection.

**Integration state re-measured.** `git branch --no-merged main` prints nothing,
so every local branch is already an ancestor of `main`. `git cherry main
feature/night-automations` also prints nothing: that branch has no unmerged
commit, and `git diff --shortstat` shows it is 316 insertions / 4816 deletions
behind `main`, i.e. `main`'s work supersedes it. There is nothing to integrate.

**No workers in flight.** `git worktree list` shows only the main checkout; the
five `/tmp/noir-wt-*.log` files are stale logs, the newest from 07:07, not
worktree directories; no `opencode`, `claude`, `codex`, `flutter`, `dart` or
`gradle` process is running. `main` is clean and level with `origin/main` at
`5c9e8b3`. This heartbeat integrated nothing and started nothing.

**Model policy.** No coding agent was started this heartbeat, so no model was
selected and no spend occurred. The standing rule — `opencode/space-bunny-free`
only, no paid or OpenRouter route — remains in force for the next dispatch.

**Standing gap, unchanged:** no device or emulator run. Java and the Android SDK
are absent on this host; CI's `assembleDebug` is the only APK evidence, and
nothing here was observed on hardware.

## Heartbeat 2026-09-30 11:41

Re-verified from scratch rather than inheriting the 10:54 numbers:

- **`flutter analyze`** — `No issues found!` (0.9s) on `38a1efa`.
- **`flutter test`** — exit 0, `All tests passed!`, counter **1040**. Same count as
  the previous heartbeat, so no test was added or lost in between.
- **CI** — newest run **36684913887** on `d3175c1`, `success`. Still no run for
  `38a1efa`, and the reason is unchanged: `git show --stat HEAD` is one file,
  `SELF_REVIEW.md`, and the workflow's `paths-ignore: ['**/*.md']` skips a push
  when every changed path matches. The claim is that the Dart code under that
  green run is unchanged since, not that `38a1efa` was gated.

**Integration state.** `git branch --no-merged main` prints nothing and
`git rev-list --left-right --count origin/main...HEAD` prints `0 0`. `main` is
clean at `38a1efa`, level with `origin/main`. Nothing to integrate.

**No workers in flight.** `git worktree list` shows only the main checkout; the
five `/tmp/noir-wt-*.log` paths are log files, not worktrees, and the pre-run
script's "worktree missing" lines for provider/mcp/data/product/ui/android refer
to those absent worktrees. `ps` matched no `opencode`, `claude`, `codex`,
`flutter`, `dart` or `gradle` process. The newest `/tmp/noir-*.jsonl` agent log
was written 2026-09-26, four days stale. This heartbeat started nothing and
integrated nothing.

**Model policy.** No agent dispatched, so no model selected and no spend.
`opencode/space-bunny-free` only remains the rule for the next dispatch.

**Standing gap, unchanged:** still no device or emulator run, and still no
implementation work outstanding from the branches.

---

## Recovery e2e: the A4 audit record is now produced by a real run

Branch `feature/recovery-e2e`, cut from `main` at `373fc58`. Two test files
changed, **no file under `lib/` changed** (`git diff lib/` is empty after the
work, including after the mutations below were reverted).

### The claim, and whether it is true

`test/integration/recovery_audit_surface_test.dart` used to call
`app.recovery.executeReflectionRecovery(Reflection(confidence: 0.3), null)` by
hand, because the A12 critic scored a run with
`executed.toString().contains('failed')` and the shipped executor answers with a
`NativeGestureOutcome`, whose default `toString` says nothing — so
`confidence < 0.5` could not be true on any real run. `50767f2` replaced that
with a named ladder read off the outcome's own fields.

**The production path genuinely reaches recovery, and that was confirmed by
execution before a line of test was written.** A scratch probe
(`test/zz_probe_scratch_test.dart`, run and then deleted) drove a real
`NoirComposition` opened over a real temp workspace, with only the platform
`MethodChannel` stubbed, and printed what the run actually did:

```
PROBE A dispatched=[dispatchGesture]
PROBE A confidence=0.3 degraded=true
PROBE A blocked=true code=RECOVERY_NEEDS_REVIEW failureReason=NATIVE_DISPATCH_FAILED
PROBE A taskState=TaskState.failed auditTrail=[{taskId: task-1, confidenceScore: 30,
        recoveryPath: re-execute-with-sanitized-screen-content,
        sanitizedScreenUsed: true, timestamp: 2026-09-30T12:02:53.059262}]
PROBE A logKinds=[SafetyEventKind.policy, SafetyEventKind.policy,
        SafetyEventKind.confirmation, SafetyEventKind.policy,
        SafetyEventKind.confirmation, SafetyEventKind.recovery]
PROBE A recoveryEvents=[Low-confidence reflection needs review | task task-1,
        confidence 30/100, path re-execute-with-sanitized-screen-content,
        sanitized screen used: true]
PROBE B dispatched=[]   confidence=0.2 blocked=true reason=MALFORMED_GESTURE_TARGET audit=1
PROBE C dispatched=[]   confidence=null blocked=true
        code=Confirmation required: delete_note audit=0
PROBE D dispatched=[dispatchGesture] confidence=0.6 blocked=false
        state=TaskState.completed audit=0
00:05 +4: All tests passed!
```

The gesture really was dispatched (`dispatchGesture` reached the channel), the
platform really failed it, and the record the Safety Center shows came out of
that run. Nothing was faked and the recovery engine was never called by hand.

**One correction to the task's narrative, which was checked rather than
assumed.** It said "a gate refusal or a malformed gesture target produces a
`NativeGestureOutcome` with `executed: false` and a real `platformCode`". Only
half of that is true:

- A `PolicyEngine` refusal (PROBE C, `delete_note` at risk 3) and a
  `ConsentGate` refusal both return `RuntimeResult.blocked` at
  `lib/agent/agent_runtime.dart:60` and `:70`, **before** `execute.run` is ever
  called. The critic is not reached at all — `reflectionEvent` is null and no
  audit entry is produced. A gate refusal does not go to recovery; it is
  already blocked.
- An executor-level refusal — no live approval (`CONFIRMATION_REQUIRED`) or an
  unresolvable target (`MALFORMED_GESTURE_TARGET`, PROBE B) — *does* reach the
  critic, but `NativeGestureExecutor.run` builds those outcomes without a
  `platformCode`, so they score `kConfidenceNotExecuted` (0.20), not 0.30.

The `kConfidencePlatformErrorCode` (0.30) rung is reachable only when the
platform bridge's own `dispatchGesture` fails — a `PlatformException`, a
`MissingPluginException`, or a reply whose `executed` is not `true`
(`lib/platform/native_bridge.dart:464-495`). That is the case the new test
drives, and it is the case that produces a row an operator can act on.

### What changed in the tests

`test/integration/support/noir_test_graph.dart` — added
`failingDispatchDump()` (a two-node screen: one visible node the executor can
resolve a gesture against, one zero-alpha node the A6a sanitizer strips) and
`installFailingDispatchPlatformStub()`, which answers like a connected
accessibility service and then throws the `PlatformException` that
`AccessibilityService.dispatchGesture` produces when the system cancels a
gesture. It returns a `FailingDispatchPlatform` that records the methods the
graph asked for. This is the repo's established platform-substitution pattern,
extended rather than replaced; `installConnectedPlatformStub` is untouched and
still used by the other integration tests.

`test/integration/recovery_audit_surface_test.dart` — the hand-call is gone.
Nothing in the file constructs a `Reflection` or names the recovery engine any
more; every run goes through `app.runAutomation`, the only entry point to the
pipeline, and the only substituted thing beyond the platform is the answer to
the confirmation the `ConsentGate` publishes — which in the app only the UI
holds, and which is answered the way the Command Centre answers it. The new
test asserts:

- the run's confidence is below 0.5, and it is
  `kConfidencePlatformErrorCode` — the rung the ladder names for "did not
  happen, and the platform said why";
- the platform really was asked to dispatch the gesture (so the score cannot be
  an artefact of a run stopped earlier), and the run dispatched exactly once —
  recovery never retries behind the gate;
- the Safety Center's event stream carries a `SafetyEventKind.recovery` event
  subscribed to *before* the run, whose badge, summary, detail, id and moment
  are the recovery's own, and exactly one such event for one run;
- the audit trail entry's fields are the recovery's own: the graph's task id,
  a `confidenceScore` derived from *this run's* reflection and then pinned to
  30, the real recovery path, `sanitizedScreenUsed: true`, and a `timestamp`
  equal to the event's `occurredAt`;
- `result.blocked`, the `RECOVERY_NEEDS_REVIEW` code, `TaskState.failed`, and
  `result.failureReason == kCodeNativeDispatchFailed` — the reason travelling
  beside the code rather than over it.

The Safety Center widget test is now driven by that same real failing run
(run from `setUp`, in the real zone, for the reason the header explains) and
asserts the rendered row plus the audit panel's real A6a finding
(`REASON_ZERO_ALPHA`, the stripped node's text). The "log is still honest when
no recovery has run" group is unchanged, and now runs against a live platform
that would have failed a gesture had one been dispatched.

**The direct-call coverage was removed, and here is why that is a
subsumption rather than a loss.** The hand-driven run and the driven run produce
the same record from the same sources: the same `taskId` (the A5 controller's),
the same `confidenceScore` (0.3 either way), the same `recoveryPath`, the same
`sanitizedScreenUsed`, the same single `timestamp`. The one assertion that
differed was `result.failureReason == isNull` — true only because the test had
handed `executed` as `null`, i.e. it asserted the behaviour of a fixture rather
than of the app. Driven for real it is `NATIVE_DISPATCH_FAILED`, which is the
honest answer and the one the D15 undo toast consumes. The "a recovery run with
nothing to report invents no reason" case is still covered, where it belongs, by
`test/agent_runtime_truth_test.dart:385` ("an answer nothing can read carries no
reason at all") and by `test/agent_runtime_critic_signal_test.dart:345-348`. The
stale justification comment in the header was removed rather than left to
describe a gap that no longer exists.

### Test teeth — two mutations in `lib/`, run, reverted

Both mutations were applied to `lib/agent/agent_runtime.dart`, the full suite
was run for each, and both were reverted. `git diff lib/` is empty.

**Mutation 1 — raise the negative rung above the threshold.**
`kConfidencePlatformErrorCode = 0.30` → `0.80`.

```
01:39 +1032 -9: Some tests failed.

Failing tests:
  test/agent_runtime_critic_signal_test.dart: the threshold keeps its meaning
    every negative signal is under 0.5 and every positive one is over it
  test/agent_runtime_truth_test.dart: ReflectionEvent is real
    a degraded run is marked as such and keeps the event after recovery
  test/agent_runtime_truth_test.dart: the recovery branch is reachable from a real outcome
    a dispatch the platform failed is routed to recovery
  test/agent_runtime_truth_test.dart: the recovery path carries the executor's reason out
    a platform failure is reported under the code the platform wrote
  test/integration/recovery_audit_surface_test.dart: a real failed run reaches the
    Safety Center's event source the A4 audit entry is published on the graph's own safety log
  test/integration/recovery_audit_surface_test.dart: a real failed run reaches the
    Safety Center's event source the run is over before the user is asked anything again
  test/integration/recovery_audit_surface_test.dart: and the Safety Center renders
    what the log holds a user who opens the Safety Center sees the recovery
  test/composition_root_test.dart: a run the platform fails reaches recovery, through
    the pipeline a dispatched gesture the platform failed is scored, recovered and logged
  test/composition_root_test.dart: the undo window is a real control, not a picture of one
    a compensation the platform failed reports the platform's own code
```

**9 failures** (`+1032 -9`). All three of the new file's recovery assertions
failed, with the real mismatch:

```
  Expected: a value less than <0.5>
    Actual: <0.8>
     Which: is not a value less than <0.5>
  test/integration/recovery_audit_surface_test.dart 156:9  main.<fn>.<fn>
  Bad state: No element
  dart:async                                                Stream.firstWhere
```

and, in the widget test,
`Found 0 widgets with text "RECOVERY_BLOCKED": []`.

**Mutation 2 — drop the routing branch itself.**
`if (reflection.confidence < 0.5)` → `if (reflection.confidence < 0.5 && false)`.

```
01:39 +1031 -10: Some tests failed.

Failing tests:
  test/agent_runtime_truth_test.dart: the recovery branch is reachable from a real outcome
    a dispatch the platform failed is routed to recovery
  test/agent_runtime_truth_test.dart: the recovery branch is reachable from a real outcome
    a refusal with no code is routed to recovery as well
  test/agent_runtime_truth_test.dart: the recovery path carries the executor's reason out
    a platform failure is reported under the code the platform wrote
  test/agent_runtime_truth_test.dart: the recovery path carries the executor's reason out
    a gate refusal is reported under the gate's own message
  test/agent_runtime_truth_test.dart: the recovery path carries the executor's reason out
    an answer nothing can read carries no reason at all
  test/integration/recovery_audit_surface_test.dart: a real failed run reaches the
    Safety Center's event source the A4 audit entry is published on the graph's own safety log
  test/integration/recovery_audit_surface_test.dart: a real failed run reaches the
    Safety Center's event source the run is over before the user is asked anything again
  test/integration/recovery_audit_surface_test.dart: and the Safety Center renders
    what the log holds a user who opens the Safety Center sees the recovery
  test/composition_root_test.dart: a run the platform fails reaches recovery, through
    the pipeline a dispatched gesture the platform failed is scored, recovered and logged
  test/composition_root_test.dart: the undo window is a real control, not a picture of one
    a compensation the platform failed reports the platform's own code
```

**10 failures** (`+1031 -10`). Again all three of the new file's recovery
assertions failed:

```
  Expected: true
    Actual: <false>
  test/integration/recovery_audit_surface_test.dart 163:9  main.<fn>.<fn>
  Bad state: No element
  dart:async                                                Stream.firstWhere
```

### Gates, on this branch, before the commit

```
$ flutter analyze
Analyzing noir-wt-recovery-e2e...
No issues found! (ran in 2.7s)

$ flutter test
01:35 +1040: .../test/providers_test.dart: resolveWithFallback walks the chain in
  order, then fails loudly
01:35 +1041: All tests passed!
exit 0

$ dart format --set-exit-if-changed lib test
Formatted 146 files (0 changed) in 0.74 seconds.
exit 0
```

**Test count before: 1040. After: 1041.** The integration file went from 4 tests
to 5 (one driven end-to-end test, one "the run dispatches exactly once", the
widget test kept, and the two empty-log tests kept), so net +1. The baseline was
measured, not assumed: `flutter test --reporter expanded` on the untouched tree
at `373fc58` ended `01:42 +1040: All tests passed!`.

### Found, not fixed

- **A gate refusal still never reaches recovery, and now cannot.** PROBE C shows
  a `PolicyEngine` refusal and a `ConsentGate` refusal are both blocked before
  `execute.run`, so the critic never scores them and no audit record exists for
  them. That is defensible — a run that was refused has not learned anything
  about the screen, and the refusal is already on the safety log as a policy
  event — but it means the recovery branch covers *execution* failures only. Not
  changed here: it is a design question about A4's scope, not a defect, and
  changing it would alter the gate's meaning rather than close a gap.
- **`kConfidenceNotExecuted` (0.20) is reachable but unexercised by this file.**
  The executor-level refusals reach the critic and do route to recovery (PROBE
  B), but no integration test drives one; they are covered at unit level in
  `test/agent_runtime_truth_test.dart`. Adding a second integration case for it
  would be near-duplicate work and was left out deliberately.
- **Still no device or emulator run.** Java and the Android SDK are absent on
  this host, so every claim here is about the Dart composition root against a
  stubbed `MethodChannel`, not about the Kotlin half. The `PlatformException`
  the stub throws is the shape the Kotlin service produces when the system
  cancels a gesture, but that correspondence is asserted from the source, not
  observed on hardware.
- **`test/composition_root_test.dart` still holds its own copy of this
  end-to-end proof** (the group "a run the platform fails reaches recovery,
  through the pipeline"). It is not a duplicate of the new test — that file
  asserts the recovery *branch* and the `failureReason` contract with a bridge
  injected directly, this one asserts the *Safety Center surface* through
  `CommandCentreScreen` — but the two now overlap on the audit row. Not
  deduplicated: the two files answer different questions and removing either
  coverage would lose an assertion.

**Commit.** This section, the integration test and the harness change are one
commit on `feature/recovery-e2e`. Its SHA is reported in the run log rather than
written here, because a commit cannot contain its own SHA; the tree it carries is
the one the three gates above were run on. Not pushed, not merged.

**Model policy.** `opencode/space-bunny-free` only; no other model was used for
any part of this work.

---

## Heartbeat 2026-09-30 12:20

The `feature/recovery-e2e` work this file's last section described as "not
pushed, not merged" is now on `main` as `fe2d491`, merged by `70801a8`. That
line is now stale by construction — the section is kept as the worker's own
record, and this entry is the supervisor's.

**Independently re-verified on `main` at `70801a8`** in a throwaway detached
worktree (`/tmp/noir-verify-main`, removed afterwards), not on the branch:

- `flutter pub get` — dependencies resolved, no version drift beyond the
  pre-existing `vector_math 2.4.2` note.
- `flutter analyze` — `No issues found!` (2.9s).
- `flutter test` — exit 0, `All tests passed!`, counter **1041**. Matches the
  number the worker reported, measured on the merged tree rather than the branch.
- `dart format --set-exit-if-changed lib test` — 146 files, 0 changed, exit 0.

**CI** — run **36713571920** on `70801a8`, `success`, `Flutter verification`
green in 3m44s. This is the first run that gates the recovery-e2e test change;
the earlier heartbeat's "no run for this SHA" caveat does not apply here
because this commit touches Dart files.

**Scope of the merge.** `git diff --stat 373fc58 main` is three files:
`test/integration/recovery_audit_surface_test.dart` (+311/-122 net),
`test/integration/support/noir_test_graph.dart` (+85), and `SELF_REVIEW.md`
(+280). **No file under `lib/` changed**, which is the claim the worker's own
section made and which the merge stat independently confirms.

**Integration state.** `git branch --no-merged main` prints nothing — all 29
local branches are merged, so there is nothing left to integrate and no
patch-id trap to check. `main` is clean and level with `origin/main` at
`70801a8`.

**No workers in flight.** `git worktree list` shows only the main checkout; the
`/tmp/noir-wt-*.log` paths are logs, not worktrees. `ps` matched no `opencode`,
`claude`, `codex`, `flutter`, `dart` or `gradle` process. This heartbeat
dispatched no agent, so no model was selected and no spend occurred;
`opencode/space-bunny-free` remains the only permitted route.

**Standing gap, unchanged:** still no device or emulator run. Java and the
Android SDK are absent on this host, so the `PlatformException` correspondence
between the Dart stub and the Kotlin service is asserted from source, not
observed on hardware. Every claim here is about the Dart composition root.

**Next action:** nothing to do until new work is dispatched. The remaining
known-design-question items recorded in the previous section (gate refusals
never reaching recovery; the 0.20 rung unit-covered only; the overlapping audit
row in `composition_root_test.dart`) are deliberate and were left as-is.

---

## Heartbeat 2026-09-30 13:38

**State.** `main` at `8835b72`, level with `origin/main` (0 ahead), working tree
clean, no stashes, `git branch --no-merged main` empty across 29 local branches.
`git worktree list` shows only the main checkout. `ps` matched no `opencode`,
`claude`, `codex`, `flutter`, `dart` or `gradle` process at inspection time. No
worker is in flight and there is nothing to integrate.

**Re-verified on `main` at `8835b72`** in a throwaway detached worktree
(`/tmp/noir-hb-1338`, removed afterwards):

- `flutter pub get` — resolved; only the pre-existing `vector_math` /
  newer-version constraint note.
- `flutter analyze` — `No issues found!` (3.1s).
- `flutter test` — exit 0, `All tests passed!`, counter **1041**.
- `dart format --set-exit-if-changed lib test` — 146 files, 0 changed, exit 0.

**CI.** Run **36713571920** on `70801a8` is `success` (`Noir CI`, 3m54s). There
is no run for `8835b72`: that commit touches `SELF_REVIEW.md` only
(`git diff --stat 70801a8 HEAD` is one file, +51), so the Dart gates CI would run
are the ones measured above locally.

**Spend.** This heartbeat dispatched no agent and started no long-running
worker; the only processes were the local gates, run by the supervisor itself.
No model was selected and no cost was incurred. `opencode/space-bunny-free`
remains the only permitted route; no paid model and no OpenRouter fallback.

**Standing gap, unchanged:** no device or emulator run. Java and the Android SDK
are absent on this host, so the `PlatformException` correspondence between the
Dart stub and the Kotlin service is asserted from source, not observed on
hardware.

**Next action:** nothing to do until new work is dispatched. The deliberate
design-question items carried forward from earlier entries (gate refusals never
reaching recovery; the 0.20 rung unit-covered only; the overlapping audit row in
`composition_root_test.dart`) remain open by choice.

---

## Heartbeat 2026-09-30 14:24

**State.** `main` at `08af109`, level with `origin/main` after `git fetch`
(both `08af1096262266e0af645ebfaa511a022f961bef`), working tree clean, no
stashes, `git branch --no-merged main` empty. `git worktree list` shows only
the main checkout — the `/tmp/noir-wt-*` paths from earlier workers no longer
exist; the surviving `.log` files under `/tmp` are stale artifacts, newest
mtime `2026-09-30 12:12` (`recovery-e2e`), nothing touched since. `ps` matched
no `opencode`, `claude`, `codex`, `flutter`, `dart` or `gradle` process. No
worker is in flight and there is nothing to integrate.

**Re-verified on `main` at `08af109`**, run by the supervisor directly in the
main checkout (working tree was clean before and after, so this left no trace):

- `flutter analyze` — `No issues found!` (1.0s).
- `flutter test` — exit 0, `All tests passed!`, counter **1041**.

`git diff --stat 8835b72 HEAD` is `SELF_REVIEW.md` only (+39), so the Dart
surface measured above is identical to the 13:38 verification; only the doc
changed since.

**CI.** Latest run is still **36713571920** on `70801a8` (`success`, 3m54s).
`08af109` and `8835b72` touch `SELF_REVIEW.md` only, so they have no CI run of
their own; the Dart gates they would run are the ones measured above.

**Spend.** This heartbeat dispatched no agent and started no long-running
worker; the only processes were the local gates run by the supervisor itself.
No model was selected and no cost was incurred. `opencode/space-bunny-free`
remains the only permitted route; no paid model and no OpenRouter fallback.

**Standing gap, unchanged:** no device or emulator run. Java and the Android SDK
are absent on this host, so the `PlatformException` correspondence between the
Dart stub and the Kotlin service is asserted from source, not observed on
hardware.

**Next action:** nothing to do until new work is dispatched. The deliberate
design-question items carried forward (gate refusals never reaching recovery;
the 0.20 rung unit-covered only; the overlapping audit row in
`composition_root_test.dart`) remain open by choice.

---

## Heartbeat 2026-09-30 14:32

**State.** `main` at `f45fbb0`, level with `origin/main` after `git fetch` (both `f45fbb0ce836b87564b5a97098bf85d4e7f75c15`), working tree clean, no stashes, `git branch --no-merged main` empty. `git worktree list` shows only the main checkout; the `/tmp/noir-wt-*` worktree paths do not exist and only stale `.log` artifacts remain there (newest mtime `2026-09-30 12:26`). `ps` matched no `opencode`, `claude`, `codex`, `flutter`, `dart` or `gradle` process. No worker in flight, nothing to integrate.

**Re-verified on `main` at `f45fbb0`**, run by the supervisor in the main checkout (tree clean before and after):

- `flutter analyze` — `No issues found!` (0.9s).
- `flutter test` — exit 0, `All tests passed!`, counter **1041**.

`git diff --stat 08af109 HEAD` is `SELF_REVIEW.md` only, so the Dart surface measured above is identical to the previous heartbeat.

**CI.** Latest run remains **36713571920** on `70801a8` (`success`, 3m54s). The doc-only commits since it have no CI run of their own.

**Spend.** No agent dispatched, no worker started, no model selected, no cost incurred. `opencode/space-bunny-free` remains the only permitted route; no paid model and no OpenRouter fallback.

**Standing gap, unchanged:** no device or emulator run; Java and the Android SDK are absent on this host, so the Dart/Kotlin `PlatformException` correspondence is asserted from source only.

**Next action:** nothing until new work is dispatched. The carried-forward design questions (gate refusals never reaching recovery; the 0.20 rung unit-covered only; the overlapping audit row in `composition_root_test.dart`) remain open by choice.

---

## Heartbeat 2026-09-30 14:5x

**State.** `main` at `bcf437c`, level with `origin/main` after `git fetch` (both
`bcf437c7ac695f9608d8673d202e8c075d607523`), working tree clean before and
after the gates, no stashes, `git branch --no-merged main` empty.
`git worktree list` shows only the main checkout — the `/tmp/noir-wt-*`
worktree directories do not exist; the six `/tmp/noir-wt-*.log` files are stale
artifacts (newest mtime `2026-09-30 12:12`, `recovery-e2e`). `ps` matched no
`opencode`, `claude`, `codex`, `flutter`, `dart` or `gradle` process. No worker
in flight, nothing to integrate.

**Re-verified on `main` at `bcf437c`**, run by the supervisor in the main
checkout:

- `flutter analyze` — `No issues found!` (1.1s).
- `flutter test` — exit 0, `All tests passed!`, counter **1041** (1m44s).

`git diff --stat f45fbb0 HEAD` is `SELF_REVIEW.md` only, so the Dart surface
measured above is identical to the 14:32 verification.

**CI.** Latest run remains **36713571920** on `70801a8` (`success`, 3m54s). The
doc-only commits since it have no CI run of their own.

**Spend.** No agent dispatched, no worker started, no model selected, no cost
incurred. `opencode/space-bunny-free` remains the only permitted route; no paid
model and no OpenRouter fallback.

**Standing gap, unchanged:** no device or emulator run; Java and the Android SDK
are absent on this host, so the Dart/Kotlin `PlatformException` correspondence is
asserted from source only.

**Next action:** nothing until new work is dispatched. The carried-forward design
questions (gate refusals never reaching recovery; the 0.20 rung unit-covered
only; the overlapping audit row in `composition_root_test.dart`) remain open by
choice.

**Observation for the user:** this file is now ~1900 lines and the last four
entries are byte-for-byte the same shape (idle main, 1041 tests, same CI run,
same standing gap). Recording another one adds noise rather than signal. Consider
gating these entries on actual change — a dirty tree, a new CI run, or a
non-zero diff from the last recorded SHA — and staying silent otherwise.
