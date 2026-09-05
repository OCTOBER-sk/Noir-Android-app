Agent: zeus
Repo: /home/santhosh/projects/Noir-Android-app
Source of truth: SOURCE_OF_TRUTH.md (read §0, §7 A4, §7 A9, §12 step 5, §13.5)
Phase: Vertical Slice — VS.8 (Track A4 thin + A9 thin): Hierarchical Recovery + Cost Estimator

# Model routing

Use opencode/muse-spark-1.2-contributor-free (this run is pinned to it). poolside 429s — do NOT switch back. Fall back IN ORDER to opencode/mimo-v2.5-free then opencode/ling-3.0-flash-fin-free.

# Context recap

V2.1 plan at ./SOURCE_OF_TRUTH.md. Read §0 (rules), §7 A4 (Hierarchical Recovery), §7 A9 (Cost Estimator), §12 step 5 (verification + basic recovery), §13.5.

Already-done and committed (origin/main = 87d1f60):
- VS.1: scaffold, theme, package
- VS.2: AccessibilityService Kotlin (CI verifies compile)
- VS.3: OpenRouter adapter (poolside/laguna-s-2.1:free)
- VS.4: 6-layer memory + safe skill save/replay
- VS.5: Command Centre UI
- VS.6: GitHub Actions CI + 5 integration tests (20/20 green)
- VS.7: TaskController + RiskClassifier + PolicyEngine + 1 UI tool stub + ToolGateway (8 new tests, 28/28 green)

# Your single bounded job — V2.1 §A4 thin + §A9 thin

Two deliverables, both in `lib/agent/`. ZERO new runtime deps. dartdoc every public API.

## Deliverable 1: Hierarchical Recovery (~120 LOC)

File: `lib/agent/recovery_engine.dart`

Per V2.1 §7 A4, the recovery engine is a 7-step ladder. Thin slice implements the first 4 steps; later slices add the rest.

Class `RecoveryEngine` with:
- enum `RecoveryStep { retryOnce, rePlan, askUser, restart, failPermanently, deferBackground, abortAndCleanup }` (all 7 per spec, even if some are stubs)
- Final fields: `TaskController controller` (injected), `int maxRetries` (default 2)
- Method `Future<RecoveryStep> handleError(Object error, {String? toolName, Map<String, dynamic>? args})` that:
  1. Tracks an internal `int _attempts` per (toolName) in a `Map<String, int>`. Initialize to 0 on first call.
  2. Increment attempts.
  3. If attempts <= maxRetries (2): return `RecoveryStep.retryOnce`. (Steps 1-2 of the ladder.)
  4. Else if attempts == maxRetries + 1: return `RecoveryStep.rePlan`. (Step 3.)
  5. Else: return `RecoveryStep.askUser`. (Step 4.) Steps 5-7 are stubbed (return askUser with reason "not yet implemented").
- Method `void reset(String toolName)` to clear the attempt counter for a tool.
- `factory RecoveryEngine(TaskController controller, {int maxRetries = 2})`

## Deliverable 2: Cost Estimator (~80 LOC)

File: `lib/agent/cost_estimator.dart`

Per V2.1 §7 A9: "Before model selection: Task -> Cost estimator (tokens / $ / free-tier budget) -> budget remaining? -> model selection / fallback -> call"

Class `CostEstimator` with:
- Final fields: `UsageTracker tracker`, `int dailyCap` (default 1000000 tokens), `double dollarCap` (default 0.0 since we run free-only)
- Method `CostEstimate estimate(String model, int inputTokens, int outputTokens)` that returns a value class with fields:
  - `double costUsd` (0.0 for free models; computed from `LLMProviderCapabilities.costPerMillionInput`/`Output` if non-zero)
  - `int totalTokens` (= inputTokens + outputTokens)
  - `bool wouldExceedDailyCap` (true if `tracker.entries.fold(0, sum + e.inputTokens+e.outputTokens) + totalTokens > dailyCap`)
  - `bool wouldExceedDollarCap` (true if `tracker.totalCost + costUsd > dollarCap`)
- Method `bool canAfford(String model, int inputTokens, int outputTokens)` — returns false if either `wouldExceed*` is true, true otherwise.
- `factory CostEstimator(UsageTracker tracker, {int dailyCap = 1000000, double dollarCap = 0.0})`

Class `CostEstimate` (in the same file) with final fields and a `const` constructor.

## Deliverable 3: Tests (6 tests)

File: `test/recovery_test.dart`:
1. `RecoveryEngine returns retryOnce on first call`
2. `RecoveryEngine returns rePlan after maxRetries+1 calls`
3. `RecoveryEngine returns askUser after that`
4. `RecoveryEngine.reset clears attempt counter`
5. `CostEstimator.canAfford returns true for free model under cap`
6. `CostEstimator.canAfford returns false when daily token cap would be exceeded`

All 6 tests must pass.

## Hard rules (V2.1 §0)
- ZERO new runtime deps. ZERO color codes. ZERO mocks except for UsageTracker (use a real one).
- Use only what already exists in lib/. READ existing files (TaskController, UsageTracker) first to get exact names.
- dartdoc every public API.
- Do NOT touch lib/main.dart, lib/ui/*, lib/core/*, lib/providers/*, lib/memory/*, lib/skill/*, lib/safety/*, lib/tools/*, android/, .github/, any test file other than test/recovery_test.dart.

## Verification (run yourself, paste real output)
cd /home/santhosh/projects/Noir-Android-app
export PATH=/home/santhosh/flutter/flutter/bin:/home/santhosh/.local/bin:$PATH
flutter test 2>&1 | tail -25
flutter analyze 2>&1 | tail -10

Both must be green. Total test count should be 34 (28 + 6 new).

## Self-review
- Re-read your diff
- Confirm all 6 tests pass
- Confirm no out-of-scope files touched
- Report in ≤8 lines: files created, test count, analyze error count, NOT VERIFIED

## Output discipline
First output = the Read of the first new file's location. Then Write. Then `flutter test`. Then report. Do NOT poll for output mid-run.