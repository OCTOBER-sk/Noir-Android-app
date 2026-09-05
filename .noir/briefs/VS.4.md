# VS.4 — Track A1 + A3 thin: 6-layer memory schema and safe skill save/replay (V2.1 §A1, §A3)

**Goal:** Implement the core memory structures (6-layer memory) and the skill lifecycle (proposal, save, replay) for safe skills only.

**Files to create/modify:**
- `lib/memory/memory_store.dart`
- `lib/memory/layers.dart` (defining the 6 layers: sensory, short-term, episodic, semantic, procedural, meta)
- `lib/skill/skill_proposal.dart`
- `lib/skill/skill_repository.dart`
- `lib/skill/skill_executor.dart` (with safety gates for safe skills)
- `lib/agent/agent_runtime.dart` (tying memory and skills together)

**Acceptance Criteria:**
1. The 6-layer memory model is defined and can be instantiated.
2. Memory store supports basic CRUD operations for each layer (we'll start with in-memory implementations).
3. A skill proposal can be created from a natural language goal (for now, a simple data class).
4. Safe skills (those with risk level 0) can be saved to the skill repository and replayed deterministically.
5. The agent runtime can load the memory store and skill repository and coordinate them.
6. Unit tests pass for the memory store and skill repository.

**Verification Steps:**
- Run `flutter test test/memory_test.dart` and `flutter test test/skill_test.dart` and expect all tests to pass.
- Run `flutter analyze` on the modified files and expect no new errors (only existing deprecation warnings are allowed).

**Self-checklist:**
- [ ] 6-layer memory layers are defined with clear responsibilities.
- [ ] Memory store uses the layers appropriately.
- [ ] Skill proposal includes goal, steps, risk level, and provider/token usage estimates.
- [ ] Skill repository saves and loads skills by ID.
- [ ] Skill executor only runs skills with risk level 0 (safe) in this thin slice.
- [ ] Agent runtime initializes memory and skills and can process a simple goal (for now, just saving a skill).
- [ ] All tests pass.
- [ ] No hardcoded secrets; use `[REDACTED]` if any placeholder is needed.
- [ ] UI remains black-and-white (not applicable for this Dart-only track, but ensure no accidental color imports).