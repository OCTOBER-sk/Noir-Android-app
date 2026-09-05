Agent: zeus
Repo: /home/santhosh/projects/Noir-Android-app
Source of truth: SOURCE_OF_TRUTH.md (read it end-to-end, follow V2.1 exactly)
Phase: Vertical Slice — VS.6 (Track E1 thin): CI foundation + integration tests (V2.1 §11 E1, §12 step 5)

# Context recap

You are in a Flutter 3.24.3 / Dart 3.5+ project at /home/santhosh/projects/Noir-Android-app.
V2.1 plan is the single source of truth at ./SOURCE_OF_TRUTH.md — read §0 (rules), §11 (Track E1), §12 (vertical slice), §13 (definition of done) first.
Already-done: VS.1 (scaffold, package com.noir.android, monochrome theme), VS.2 (AccessibilityService Kotlin — code-only, no compile), VS.3 (LLMProvider + OpenRouter poolside/laguna-s-2.1:free adapter), VS.4 (6-layer memory + safe skill save/replay), VS.5 (Command Centre shell + token counter). 15/15 flutter tests green, 0 flutter analyze errors. Latest commit 234ef87 on origin/main.

OpenRouter poolside primary may rate-limit (20 RPM shared bucket) — fall back to opencode Zen free models (muse-spark-1.2-contributor-free → mimo-v2.5-free → ling-3.0-flash-fin-free) per your agent prompt.

# Your single bounded job — V2.1 §E1 thin: CI + integration tests

Two deliverables, both must end with `flutter test` green and `flutter analyze` clean.

## Deliverable 1: GitHub Actions CI workflow (Track E1)

Create `.github/workflows/noir-ci.yml` with these jobs (YAML, no apostrophes in any string):
- Trigger on: push to main, pull_request to main, manual workflow_dispatch
- Single job `ci` on `ubuntu-latest` with these steps:
  1. `actions/checkout@v4`
  2. `subosito/flutter-action@v2` with `flutter-version: '3.24.3'` and `channel: stable`
  3. `flutter pub get`
  4. `flutter analyze` (non-fatal — continue even if there are infos; only fail on errors)
  5. `flutter test --coverage`
  6. `flutter build apk --debug --no-pub` (this is the Kotlin compile gate V2.1 §0.5 — fails CI if the AccessibilityService does not compile)
  7. Upload coverage as artifact: `actions/upload-artifact@v4` with name `coverage`, path `coverage/lcov.info`

Hard rules:
- ZERO new files in the repo workdir besides the workflow file (unless the Dart analysis step tells you a missing piece).
- Do NOT touch lib/, android/, test/, pubspec.yaml, any .md.
- Do NOT add a job matrix, do NOT add caching beyond what subosito/flutter-action provides.
- The workflow file must be a single YAML, valid syntax (no tabs, 2-space indent, proper `|`/`>` block scalars).

## Deliverable 2: Integration test file (Track E1 thin)

Create `test/integration_test.dart` with these 5 tests (use real classes from lib/, no mocks except where the spec explicitly allows):

1. `processGoal round-trip writes to memory and skill repository` — create AgentRuntime, call processGoal('open Settings', ['find app', 'tap icon']), then assert: (a) skills.get('open Settings') is non-null with riskLevel=safe, state='active', (b) memory.getAll(MemoryLayer.episodic) has exactly one item whose content contains 'open Settings'.

2. `replaySkill is gated by risk level` — processGoal('safe thing', ['s1']), then replaySkill('safe thing') should complete. Then add a Skill with riskLevel=review directly via runtime.skills.add(Skill(id:'risky', name:'risky', description:'x', riskLevel: SkillRiskLevel.review, steps:[])) and call replaySkill('risky') — expect throwsA(isA<StateError>()).

3. `UsageTracker records and streams` — create UsageTracker, record a Usage(inputTokens:10, outputTokens:5, costUsd:0.0, latency:Duration(milliseconds:200)), assert entries has length 1 and totalCost == 0.0. Subscribe to onUpdated before recording a second Usage — expect the stream to emit a List<Usage> with length 2 within 1 second.

4. `OpenRouter adapter has the right model + capabilities` — instantiate OpenRouterAdapter(apiKey:'test'), assert name contains 'openrouter', model == 'poolside/laguna-s-2.1:free', capabilities.streaming is true, capabilities.vision is false, capabilities.toolUse is false, capabilities.contextWindow >= 100000, capabilities.costPerMillionInput == 0.0, capabilities.costPerMillionOutput == 0.0.

5. `CommandCentreScreen end-to-end: type a message, see it in the list` — pump the widget, find the TextField, enterText('hello noir'), tap the send button, pump, then expectFinder to find a Text with 'hello noir' in the widget tree.

Hard rules:
- ZERO new runtime dependencies in pubspec.yaml.
- ZERO mocks except `apiKey:'test'` for the OpenRouter adapter (real key never in tests).
- Use only what already exists in lib/ (LLMProvider, OpenRouterAdapter, UsageTracker, AgentRuntime, Skill, SkillRiskLevel, MemoryLayer, CommandCentreScreen, etc.). READ THE FILES FIRST — get the exact class/field names right. If a test fails because a field name is wrong, FIX THE TEST not the lib/.
- All 5 tests must pass under `flutter test`.

## Verification (run yourself, paste real output)

cd /home/santhosh/projects/Noir-Android-app
export PATH=/home/santhosh/flutter/flutter/bin:/home/santhosh/.local/bin:$PATH
flutter test 2>&1 | tail -20    # expect: All tests passed!, total = previous 15 + 5 new = 20+
flutter analyze 2>&1 | tail -10  # expect: 0 errors

# Mandatory self-review
- Re-read your diff (git diff --stat)
- Confirm workflow YAML is valid (no syntax errors, uses `|` for multi-line shell, etc.)
- Confirm all 5 integration tests pass
- Confirm no out-of-scope files were modified
- Report in ≤8 lines: files created, test count (passed/total), workflow job names, any NOT VERIFIED items

# Output discipline
First output = the tool call that creates .github/workflows/noir-ci.yml. Then test/integration_test.dart. Then run flutter test. Then report.
