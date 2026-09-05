Agent: zeus (FRESH session — previous resume was poisoned by a 429-empty-header. Use plain `opencode run --agent zeus` with the message + -f below, NOT `-c`.)

Context: You already wrote 19 files for Noir VS.3+4+5. The files exist on disk. But `flutter analyze` shows 17 ERRORS and 2 test files fail to compile. Your job NOW = read the files, fix the errors, run `flutter analyze` + `flutter test` until green. Do NOT rewrite working code.

# Real file shapes (READ THESE FIRST — do not guess)

- `lib/skill/skill_proposal.dart` defines:
  - `enum SkillRiskLevel { safe, review, dangerous }`
  - `class SkillProposal` with fields `id, name, description, riskLevel, steps` (id auto-generated)
  - `class Skill` with fields `id, name, description, riskLevel, steps, state='candidate', successScore=0.0`
- `lib/memory/layers.dart` defines:
  - `enum MemoryLayer { sensory, shortTerm, episodic, semantic, procedural, meta }`
  - **NO** MemoryItem class in this file — MemoryItem lives in memory_store.dart
- `lib/memory/memory_store.dart` defines `class MemoryItem` with fields `id` (auto-generated), `content`, `source`, `layer`. (Read it to confirm exact ctor.)
- `lib/providers/llm_provider.dart` defines:
  - `class ChatMessage(role, content)`
  - `class Usage(inputTokens, outputTokens, costUsd, latency)`
  - `class LLMProviderCapabilities(streaming, vision, toolUse, contextWindow, costPerMillionInput, costPerMillionOutput)`
  - `abstract class LLMProvider` with `String get name`, `String get model`, `LLMProviderCapabilities get capabilities`, `Stream<String> streamChat(List<ChatMessage> messages)`
- `lib/skill/skill_executor.dart` — its `executeSkill` must throw `StateError` (test asserts `throwsA(isA<StateError>())`). It accepts an `onStep` callback in its ctor (test line 28: `SkillExecutor(repo, onStep: steps.add)`).

# Fix targets (read each file, then patch ONLY what's broken)

1. **`lib/providers/model_router.dart` line 1**: `import '../llm_provider.dart';` → `import 'llm_provider.dart';` (same dir).
2. **`lib/providers/usage_tracker.dart` line 3**: `import '../llm_provider.dart';` → `import 'llm_provider.dart';`. Also line 24: `sum + e.costUsd` is fine; the nullable warning is from `_entries.fold` — change `_entries.fold(0.0, (sum, e) => sum + e.costUsd);` to `_entries.fold<double>(0.0, (sum, e) => sum + e.costUsd);` (explicit type).
3. **`lib/providers/adapters/openrouter_adapter.dart` line 68-69**: 
   ```
   final choices = (decoded['choices'] as List<dynamic>?)?.toList() ?? [];
   ```
   The `?` before `.toList()` is a null-aware access. Dart allows `?.toList()`. But the analyzer says non_bool_condition — likely the `??` chain is misparsed because the file uses some operator that's a typo. **Replace the two lines with**:
   ```dart
   final rawChoices = decoded['choices'];
   if (rawChoices is! List) continue;
   final choices = rawChoices;
   if (choices.isEmpty) continue;
   ```
   Avoid the `as List<dynamic>?` cast entirely.
4. **`lib/skill/skill_repository.dart` line 30-32** (`bool remove(String id)`):
   ```dart
   bool remove(String id) {
     final before = _skills.length;
     _skills.removeWhere((s) => s.id == id);
     return _skills.length < before;
   }
   ```
   (Do NOT use the `> 0` on `removeWhere`'s void return.)
5. **`lib/agent/agent_runtime.dart` line 50**: `MemoryLayer.episodic` is correct — BUT only if `MemoryItem` lives in memory_store.dart and is imported. Read `lib/memory/memory_store.dart` to confirm the `MemoryItem` class is there and its fields. **The ctor in test/memory_test.dart is** `MemoryItem(content: ..., source: ..., layer: ...)` with no `id` — so the ctor must have `id` as auto-generated String. Confirm and adjust agent_runtime.dart line 47-51 if needed.
6. **`lib/skill/skill_executor.dart`** — verify it throws `StateError` (not `Exception`) for unknown id and for non-safe risk level. The test at line 50-51 and 77-78 asserts `throwsA(isA<StateError>())`. If it throws `Exception`, change `throw Exception(...)` → `throw StateError(...)`.

# HARD RULES

- DO NOT add a new package. DO NOT add a `uuid` import.
- DO NOT change tests/test files.
- DO NOT change public API surface.
- DO NOT change Skill or MemoryItem class shapes — they match the tests.
- DO NOT touch lib/core/, lib/main.dart, android/, or any .md file.

# Verification (run yourself)

cd /home/santhosh/projects/Noir-Android-app
export PATH=/home/santhosh/flutter/flutter/bin:/home/santhosh/.local/bin:$PATH
flutter analyze 2>&1 | tail -15
flutter test 2>&1 | tail -20

Both must be green. If still red, fix ONE line at a time. Max 3 patches then report.

# Output
First output = the Read of the first broken file. Then patch. Then run. Report in ≤8 lines.
