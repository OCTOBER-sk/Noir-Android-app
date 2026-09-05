Agent: zeus  (resume last session with -c)
Context: You already wrote 19 files for Noir VS.3+4+5. Files physically exist. But `flutter analyze` shows 17 ERRORS and 2 test files fail to compile. Poolside rate-limited you before you could verify. Your job NOW = fix these errors and re-verify, nothing else.

# Root cause (already investigated, do NOT re-investigate)

1. lib/agent/agent_runtime.dart — `import 'skill_proposal.dart'` is MISSING. Add it.
2. lib/providers/model_router.dart line 1 — uses `import '../llm_provider.dart'` but the file is at `lib/providers/llm_provider.dart` so from `lib/providers/model_router.dart` the import should be `import 'llm_provider.dart';` (same dir, NOT `../`). Same fix for usage_tracker.dart line 3.
3. lib/providers/adapters/openrouter_adapter.dart line 69 — there's a string with unescaped quotes. Find the line, replace `"${...}"` with `'${...}'` OR escape the inner quotes. The `authHeaders ?? <String,String>{}` thing looks like a typo — just remove the null-coalesce and use `<String,String>{}` directly.
4. lib/skill/skill_repository.dart line 31 — `removeWhere` returns void, not int. Replace `_skills.removeWhere((s) => s.id == id) > 0;` with `final existed = _skills.remove(id) != null;` then `return existed;`. Better: `bool remove(String id) => _skills.remove(id) != null;`
5. lib/skill/skill_repository.dart line 31 is inside the `remove` method — make sure the method returns `bool`, not `void`.

# HARD RULES (do not deviate)

- DO NOT rewrite any other file. Only fix the 4 files above (agent_runtime.dart, model_router.dart, usage_tracker.dart, openrouter_adapter.dart, skill_repository.dart).
- DO NOT change test files. Tests are already correct; compile errors are upstream.
- DO NOT add any new dependency.
- DO NOT change public API surface — keep class names, method signatures, field names.
- ZERO color codes anywhere (this is Dart, so this is a non-issue, but keep it that way).

# Verification (run yourself, paste real output in your report)

cd /home/santhosh/projects/Noir-Android-app
export PATH=/home/santhosh/flutter/flutter/bin:/home/santhosh/.local/bin:$PATH
flutter analyze 2>&1 | tail -10
flutter test 2>&1 | tail -20

Both must be green. If still red after fixes, re-read the compile error and fix ONLY the new line. Do NOT loop indefinitely — 2 fix passes max, then report.

# Output discipline
First output = the Read of the first broken file. Then patch. Then run. Report in ≤8 lines when done.
