Agent: zeus
Repo: /home/santhosh/projects/Noir-Android-app
Source of truth: SOURCE_OF_TRUTH.md (read it, follow V2.1 exactly)
Phase: Vertical Slice — VS.3 (B1 thin) + VS.4 (A1 + A3 thin) + VS.5 (D2 thin) combined into ONE bounded chunk

# Context recap

You are in a Flutter 3.24.3 / Dart 3.5+ project at /home/santhosh/projects/Noir-Android-app.
V2.1 source-of-truth plan lives at ./SOURCE_OF_TRUTH.md — read §0, §1, §2, §3, §B, §A, §D, §12 first.
VS.1 already done: scaffold, package renamed to com.noir.android, monochrome theme (7 colors only:
#000000, #FFFFFF, #121212, #1E1E1E, #2A2A2A, #E5E5E5, #B0B0B0), constants in lib/core/constants.dart,
theme in lib/core/theme/noir_theme.dart. Tests at test/theme_test.dart pass.
VS.2 (AccessibilityService Kotlin) is code-complete but not compile-verified (no JDK on this VPS — ignore).

# Your single bounded job — read V2.1 §12 vertical slice order

Build the Dart half of the vertical slice in ONE pass:

## 1. Providers (V2.1 §B1 thin + 1 adapter)
Files to create:
- lib/providers/llm_provider.dart  (abstract LLMProvider + LLMProviderCapabilities + Usage classes)
- lib/providers/adapters/openrouter_adapter.dart  (OpenRouter, model=poolside/laguna-s-2.1:free, context=262144, $0/$0, streaming, no vision, no toolUse)
- lib/providers/model_router.dart  (trivial pass-through router)
- lib/providers/usage_tracker.dart  (in-memory; ready for DB later)
- test/providers_test.dart  (≥3 tests: instantiation, capabilities, recordUsage with cost=0.0)

Use package:http for the streaming call. Hardcode model constant `openrouterPoolsideFree`
= `poolside/laguna-s-2.1:free`. Read API key from `--dart-define=OPENROUTER_API_KEY=...` at runtime
— NEVER hardcode the key.

## 2. Memory + Skills (V2.1 §A1 + §A3 thin)
Files to create:
- lib/memory/layers.dart  (6-layer enum: sensory, shortTerm, episodic, semantic, procedural, meta + MemoryItem class with id/content/timestamp/source/layer)
- lib/memory/memory_store.dart  (in-memory CRUD per layer; methods add/get/getAll/remove/clear)
- lib/skill/skill_proposal.dart  (SkillRiskLevel enum safe/review/dangerous; SkillProposal + Skill classes)
- lib/skill/skill_repository.dart  (in-memory; methods add/get/getAll/remove/clear)
- lib/skill/skill_executor.dart  (executeSkill(id) — only runs when riskLevel == safe, else throws)
- lib/agent/agent_runtime.dart  (ties memory + skills; processGoal(goal, steps) creates safe skill + episodic memory item; replaySkill(id) delegates to executor)
- test/memory_test.dart  (≥4 tests across layers)
- test/skill_test.dart  (≥4 tests: repository CRUD, executor safe/unsafe/not-found, runtime processGoal+replaySkill)

## 3. UI shell (V2.1 §D2 thin — Command Centre + token counter)
Files to create/modify:
- lib/ui/command_centre_screen.dart  (single screen, monochrome theme, ChatGPT-style: message list + input bar at bottom; no amber/orange/blue; use ONLY the 7 colors from constants.dart)
- lib/ui/token_counter.dart  (small widget that takes (inputTokens, outputTokens, costUsd) and renders in monochrome)
- lib/ui/message_bubble.dart  (role-aware bubble: user on right white-on-black, assistant on left black-on-white-gray)
- lib/main.dart  (wire CommandCentreScreen as home; wrap in MaterialApp(theme: noirTheme, darkTheme: noirThemeDark, home: CommandCentreScreen()))
- test/command_centre_test.dart  (widget test: pumps screen, finds input field, types, verifies it appears in message list)

## Non-negotiable constraints
- ZERO new runtime dependencies beyond what is already in pubspec.yaml. If you need http, add `http: ^1.2.0` to pubspec.yaml.
- ZERO color outside the 7 allowed colors. grep your diff for hex codes before reporting done.
- NO mocks. NO fake data for final verification. The tests above use real classes with in-memory backends.
- dartdoc every public API (one-line /// comment is fine).
- Do NOT touch: android/, any Kotlin file, SOURCE_OF_TRUTH.md, .noir/briefs/*, the existing lib/core/*, the existing test/theme_test.dart.

# Verification (run these yourself, paste real output in your report)
cd /home/santhosh/projects/Noir-Android-app
export PATH=/home/santhosh/flutter/flutter/bin:/home/santhosh/.local/bin:$PATH
flutter pub get
flutter analyze 2>&1 | tail -20
flutter test 2>&1 | tail -30

All tests must be green. Analyze must show zero errors (deprecation infos are OK).

# Mandatory self-review before reporting
- Re-read your own diff (git diff --stat)
- Confirm every test you added actually ran and passed
- Confirm no out-of-scope files were modified
- Confirm no hex code outside the 7 allowed colors
- Report in ≤10 lines: files created, test count (passed/total), analyze error count, any NOT VERIFIED items

# Output discipline
First output = the tool call that creates the first file. Zero commentary.
If you hit a parse or import error, fix it and re-run. Do NOT stop until analyze+test are green.
Report back in ≤10 lines when done.
