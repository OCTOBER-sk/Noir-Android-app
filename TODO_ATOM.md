# Atom's TODO — Noir Android App

**Repo:** github.com/OCTOBER-sk/Noir-Android-app
**Source of truth:** SOURCE_OF_TRUTH.md (V2.1, 568 lines, authoritative)
**Working dir:** /home/santhosh/projects/Noir-Android-app
**Strategy:** Brief → Dispatch (opencode) → Verify (myself) → Commit → Push. **No hand-coding unless an agent fails twice on a mechanical fix (opencode-workflow skill rule).**

## Vertical Slice Status

| ID | Track | What | Agent | Status | Commit |
|---|---|---|---|---|---|
| VS.1 | 0.1 | Flutter scaffold, package rename, monochrome theme | (manual, no opencode at the time) | ✅ DONE | `1336bd8` |
| VS.2 | C1 thin | AccessibilityService event-driven | (manual + 429-blocked verification) | ⚠️ CODE DONE, COMPILE PENDING | (uncommitted) |
| VS.3 | B1 thin + 1 adapter | LLMProvider + OpenRouter poolside/laguna | Zeus (1st pass) + Atom (6 patches) | ✅ DONE 15/15 tests | `234ef87` |
| VS.4 | A1 + A3 thin | 6-layer memory + safe skill save/replay | Zeus (1st pass) + Atom (factory-ctor fix) | ✅ DONE | `234ef87` |
| VS.5 | D2 thin | Command Centre shell + token counter | Zeus (1st pass) | ✅ DONE | `234ef87` |
| VS.6 | E thin | Integration tests + coverage | Ambush | 🔜 NEXT BRIEF | — |
| VS.7 | C2 + Drift | Native drift DB for memory/skills | Zeus | ⏳ | — |
| VS.8 | D3 + D4 | Live token counter wiring + provider UI | Midas | ⏳ | — |
| VS.9 | A2 + A4 | 7-step recovery + cost estimator | Zeus | ⏳ | — |

## Rules (standing)

- Atom supervises, agents code, no hand-coding unless opencode fails twice on the same fix.
- All briefs ≤4KB, message-first then `-f`. No apostrophes in inline prompts.
- Each phase: ONE commit, conventional message, push to origin, verify remote advanced.
- Poolside 20-RPM bucket: agents fall back to OpenCode Zen free models in their prompt.
- VS.2 Kotlin compile gate: blocked by missing JDK. Re-evaluate after VS.6.

## Open questions for Sandy

1. JDK 17: install in user space (which path?), or skip VS.2 compile-gate and rely on GitHub CI?
2. OpenCode Zen free models — are `muse-spark-1.2-contributor-free` / `mimo-v2.5-free` / `ling-3.0-flash-fin-free` all still in your paid OpenCode plan? (The CLI has them configured; just confirming budget.)
3. VS.6 scope: full integration test suite (≥20 tests across all tracks) or just the highest-risk ones (recovery, skill gate, provider failover)?
