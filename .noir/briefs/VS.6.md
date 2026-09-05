Agent: ambush
Repo: /home/santhosh/projects/Noir-Android-app
Source of truth: SOURCE_OF_TRUTH.md (read it, follow V2.1 exactly)
Phase: Vertical Slice — VS.6 (E thin): test foundation + CI (V2.1 §E)

# Context recap

You are in a Flutter 3.24.3 / Dart 3.5+ project at /home/santhosh/projects/Noir-Android-app.
V2.1 source-of-truth plan lives at ./SOURCE_OF_TRUTH.md — read §0, §1, §2, §3, §E first.
VS.1 done: scaffold, package renamed to com.noir.android, monochrome theme (7 colors only), tests pass.
VS.2 code-written but compile-blocked (no JDK on VPS) — ignore for now.
VS.3+VS.4+VS.5 DONE: providers, memory+skills, agent runtime, UI shell (Command Centre, message bubbles, token counter), all tests passing (15/15).

# Your single bounded job — read V2.1 §E thin

Write tests that give confidence the vertical slice works as a whole.

Files to create/modify:

- test/integration_test.dart  (≥5 tests: end-to-end flows that cross layers)
  Example: processGoal → replaySkill → verify memory item appears
  Example: streamChat with a fake provider → verify token counter updates
  Example: UI pump → type message → send → verify LLM call is attempted (mock adapter)
  Example: skill replay with risk level review/dangerous → expect StateError
  Example: memory store add/get/remove/clear across all six layers
- test/coverage_report.dart  (not a test, but a script that runs `flutter test --coverage` and prints summary)
  Or better: just add a note in README that coverage is tracked via CI; but for thin slice we can add a simple script that runs the tests and prints line coverage via `flutter test --coverage` (requires lcov, but we can just run it and output to console).

Alternatively, we can just ensure the existing test suite is comprehensive and add a few more tests to reach 80%+ line coverage. Since we already have 15 tests, let's aim for 20-25 tests total.

Constraints:
- ZERO new runtime dependencies beyond what is already in pubspec.yaml. If you need mockito or similar, add it to dev_dependencies.
- Use package:flutter_test/flutter_test.dart for all tests.
- Do NOT touch lib/, android/, SOURCE_OF_TRUTH.md, .noir/briefs/*, the existing test/theme_test.dart (unless fixing a typo).
- dartdoc every public test (one-line /// comment is fine).
- All tests must pass when you run `flutter test`.

# Verification (run these yourself, paste real output in your report)
cd /home/santhosh/projects/Noir-Android-app
export PATH=/home/santhosh/flutter/flutter/bin:/home/santhosh/.local/bin:$PATH
flutter pub get
flutter test 2>&1 | tail -30   # expect all green, and note the test count

# Mandatory self-review before reporting
- Re-read your own diff (git diff --stat)
- Confirm every test you added actually ran and passed
- Confirm no out-of-scope files were modified
- Report in ≤8 lines: files created, test count (passed/total), any NOT VERIFIED items

# Output discipline
First output = the tool call that creates the first file. Zero commentary.
If you hit a parse or import error, fix it and re-run. Do NOT stop until test are green.
Report back in ≤8 lines when done.