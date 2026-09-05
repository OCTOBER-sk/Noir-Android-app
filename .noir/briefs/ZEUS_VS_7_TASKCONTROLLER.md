Agent: zeus
Repo: /home/santhosh/projects/Noir-Android-app
Source of truth: SOURCE_OF_TRUTH.md (read §0, §4, §5, §7 A5+A6, §8 B4, §12 step 3, §13.5)
Phase: Vertical Slice — VS.7 (Track A5 + A6 thin + B4 thin): Minimal TaskController + 1 UI tool (V2.1 §12 step 3)

# CRITICAL: model routing

The previous opencode run hit poolside 429 after 3 file reads and wrote nothing. This time, use the OpenCode Zen free models in your fallback chain FIRST, NOT poolside. Your configured primary is openrouter/poolside/laguna-s-2.1:free, but if it 429s or errors, fall back IMMEDIATELY to:
1. opencode/muse-spark-1.2-contributor-free
2. opencode/mimo-v2.5-free
3. opencode/ling-3.0-flash-fin-free

Sandy pre-approved all three Zen free models on 2026-09-05. They are NOT paid — no plan needed. Just use them. If your primary model returns an empty body or a 429 within the first 2 minutes, switch immediately without further prompts. Do NOT poll the primary.

# Context recap

V2.1 plan at ./SOURCE_OF_TRUTH.md. Read §0 (rules), §4 (architecture), §5 (UI_LOCK + uiBound/backgroundSafe), §7 A5 (TaskController) + A6 (RiskClassifier + Policy Engine), §8 B4 (Tool Registry + Tool Gateway), §12 step 3, §13.5 before coding.

Already-done and committed (origin/main = db47356): VS.1 (scaffold, theme, package), VS.2 (AccessibilityService Kotlin — CI will verify compile), VS.3 (OpenRouter adapter), VS.4 (memory+skills+agent runtime), VS.5 (Command Centre UI), VS.6 (CI workflow + 5 integration tests, 20/20 green).

# Critical gap this slice closes

V2.1 §12 step 3: "Minimal TaskController + one UI tool — End-to-end task". AgentRuntime currently saves skills but cannot execute an end-to-end task (observe -> act -> verify). After this slice the vertical slice is truly end-to-end.

# Your single bounded job — V2.1 §A5 thin + §A6 thin + §B4 thin

Three deliverables. Files only under `lib/agent/`, `lib/safety/`, `lib/tools/`. ZERO new runtime deps. dartdoc every public API.

## Deliverable 1: TaskController (~80 LOC)

File: `lib/agent/task_controller.dart`

Class `TaskController` with:
- enum `TaskState { idle, planning, awaitingConfirmation, executing, recovering, paused, terminal }` per V2.1 §7 A5
- enum `TaskOutcome { completed, failed, cancelled }`
- Final fields: `TaskState state`, `String? activeTaskId`, `DateTime? startedAt`, `DateTime? endedAt`, `TaskOutcome? outcome`
- `Stream<String> get events` backed by `StreamController<String>.broadcast()` that emits state-transition tags like "idle->planning", "planning->awaitingConfirmation", etc.
- Methods (all `Future<void>`):
  - `startTask(String goal, List<String> steps)` — sets state to planning, emits event
  - `requestConfirmation(String message)` — if state==awaitingConfirmation, returns the message; else throws StateError
  - `confirmTask()` — awaitingConfirmation -> executing, emits event
  - `pauseTask(String reason)` — executing -> paused, emits event
  - `resumeTask()` — paused -> executing, emits event
  - `recoverTask(String reason)` — executing -> recovering, emits event
  - `completeTask(TaskOutcome outcome)` — sets state=terminal, records outcome, emits event
- `factory TaskController()` that wires up the broadcast stream.

## Deliverable 2: RiskClassifier + PolicyEngine + 1 UI tool stub (~120 LOC)

Files:
- `lib/safety/risk_classifier.dart` — class `RiskClassifier` with method `int classifyRisk(String toolName, Map<String, dynamic> args)`. Returns 0-3 per V2.1 §7 A6. Hardcode: `readScreen` -> 0, `tap` -> 1, `sendMessage` -> 2, `makePayment` -> 3. Unknown -> 2.
- `lib/safety/policy_engine.dart` — class `PolicyEngine` with method `PolicyDecision evaluate({required int risk, required String executionClass, required List<String> requiredPermissions, required bool biometricAvailable})`. Returns `PolicyDecision` (fields: `bool allowed`, `bool requiresConfirmation`, `bool requiresBiometric`, `String? reason`). Rules: risk 0 always allowed, no gates. Risk 1 requires confirmation if executionClass==uiBound. Risk 2 always requires confirmation. Risk 3 always requires confirmation + biometric. If biometricRequired but not available, allowed=false, reason "biometric unavailable".
- `lib/tools/tool_call.dart` — class `ToolCall` (canonical) with final fields `String name`, `Map<String, dynamic> arguments`, `String executionClass` ('uiBound' or 'backgroundSafe'), `List<String> requiredPermissions`, `int riskLevel` (0-3).
- `lib/tools/tool_registry.dart` — class `ToolRegistry` with `register(String name, ToolCall Function() factory, int riskLevel, String executionClass, List<String> requiredPermissions)` and `ToolCall? lookup(String name)`. Use a `Map<String, ToolCall Function()>`. Register 1 stub tool only: `readScreen` with executionClass='uiBound', requiredPermissions=['accessibility'], riskLevel=0. Its factory returns a ToolCall with name='readScreen', arguments={}, executionClass='uiBound', requiredPermissions=['accessibility'], riskLevel=0.
- `lib/tools/tool_gateway.dart` — class `ToolGateway` with final `ToolRegistry registry` and final `PolicyEngine policy`. Method `Future<String> execute(ToolCall call)` that:
  1. Calls `policy.evaluate(risk: call.riskLevel, executionClass: call.executionClass, requiredPermissions: call.requiredPermissions, biometricAvailable: true)` to get a PolicyDecision
  2. If `decision.allowed` is false: throw `StateError(decision.reason ?? 'policy denied')`
  3. If `decision.requiresConfirmation` is true: throw `StateError('user confirmation required; not yet implemented in thin slice')`
  4. If `decision.requiresBiometric` is true: throw `StateError('biometric required; not yet implemented in thin slice')`
  5. Otherwise: return "tool:${call.name} executed (stub, no real side effect in thin slice)"

## Deliverable 3: Tests (8 tests)

File: `test/agent_test.dart`:
1. `TaskController transitions idle -> planning on startTask`
2. `TaskController emits state events on the broadcast stream`
3. `TaskController terminal state has correct outcome`
4. `RiskClassifier maps tool names to correct risk levels` (parametrize: readScreen=0, tap=1, sendMessage=2, makePayment=3)
5. `PolicyEngine allows risk 0 without confirmation`
6. `PolicyEngine denies risk 3 when biometric is unavailable`
7. `ToolGateway dispatches a safe uiBound tool to a stub executor`
8. `ToolGateway throws StateError when policy denies`

All 8 must pass under `flutter test`.

## Hard rules (V2.1 §0)

- ZERO new runtime deps. ZERO mocks except `apiKey:'test'`.
- ZERO color codes anywhere.
- Use only what already exists in lib/ for imports. READ the files first to get exact names.
- dartdoc every public API.
- Do NOT touch lib/main.dart, lib/ui/*, lib/core/*, lib/providers/*, lib/memory/*, lib/skill/*, android/, .github/, any test file other than the new test/agent_test.dart.

## Verification (run yourself, paste real output)

cd /home/santhosh/projects/Noir-Android-app
export PATH=/home/santhosh/flutter/flutter/bin:/home/santhosh/.local/bin:$PATH
flutter test 2>&1 | tail -25
flutter analyze 2>&1 | tail -10

Both must be green. Total test count should be 28 (20 + 8 new).

## Self-review
- Re-read your diff (git diff --stat)
- Confirm all 8 tests pass
- Confirm TaskController broadcasts events on the stream (use StreamSubscription in the test)
- Confirm no out-of-scope files touched
- Report in ≤8 lines: files created, test count, analyze error count, any NOT VERIFIED

## Output discipline
First output = the Read of the first new file's location. Then Write. Then `flutter test`. Then report. Do NOT poll for output mid-run.
