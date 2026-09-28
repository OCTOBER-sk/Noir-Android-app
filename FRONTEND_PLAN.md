# Noir Frontend Plan — Real Build (Brief)

Based on: `SOURCE_OF_TRUTH_ADDENDUM.md` (V2.2 backend) + `SOURCE_OF_TRUTH_ADDENDUM_V2.3_UI.md` (UI spec).

## Theme tweak (user request: "small color tone, feels real")
- Keep 7 monochrome base (`pureBlack` → `pureWhite`).
- Add ONE subtle rainbow-shifting accent: `rainbowAccent` (animated gradient: red→orange→yellow→green→blue→indigo→violet). Used ONLY for the same 3 spots — stream loader bar tip, Undo countdown fill, `needs_review` label dot. Keeps monochrome everywhere else; accent is tiny + moving.
  - Stream loader bar tip, Undo countdown fill (tiny), Skill `needs_review` label dot.
  - Never for errors/urgency (still grayscale weight/size per V2.3).
- Light mode: same tokens inverted, same single accent.

## End-to-end screens (must wire to real `NoirUiEvent` — no fake state)

### D2 — Command Centre Chat (main)
- Empty state: centered 24sp greeting, raised composer (not bottom-pinned).
- Active: sticky footer composer (28px radius, `nearBlack`), message list.
  - User bubble: right-aligned, 22px radius, 70% max, `nearBlack` bg / `pureWhite` text.
  - Assistant: left-aligned, NO bubble, full-width transparent, action bar (Copy, Regenerate, Save as Fact, Propose Skill, thumbs) — wire `Save as Fact` → A2 Memory; `Propose Skill` → A3 lifecycle.
- Streaming (`StreamingTokenReceived`): token reveal, blinking caret `▍` (`textMuted`), Stop button replaces Send. Skeleton loader (`surfaceDark2` bars) ONLY before first token (`planning` / `tool_calling` micro-copy from EventBus).
- Confirmation card (`ConfirmationRequired`): 12px radius, `surfaceDark` bg, 1px `surfaceDark2` border. Shows risk tier (weight only), tool + provenance (`screenContentWasSanitized` flag real from A6a), Confirm (`pureWhite` fill / `pureBlack` text) + Cancel outline. Biometric (`riskLevel >= 2`) on Confirm.
- Undo toast (`ActionCompletedWithUndoWindow`): `nearBlack` bg, `pureWhite` text, 12px radius, 5s countdown bar (`surfaceDark2` → `rainbowAccent` tiny fill), Undo button if `reversible`.

### D3 — Live Task View (timeline)
- Real-time from `TaskController` / `EventBus` — NOT separate UI state.
- Rows: timestamp (`textMuted`), description. Section headers for core states (`planning`, `awaiting_confirmation`, `executing`, `recovering`, `paused`, terminal).
- `recovering` row: `surfaceDark2` bg (darkest non-black) — monochrome signal, no color.

### D6 — Usage Dashboard
- Numeric only (no charts): tokens used today, cost today, current model/provider, RPM headroom (`"12 / 20 req/min"`). Toggle for pipeline micro-copy visibility.

### D7 — Skill Manager
- Full-width rows: name, lifecycle label (`candidate`/`validated`/`draft`/`active`/`disabled`/`degraded`/`needs_review`), `textMuted` timestamp.
- `needs_review`: `textSecondary` weight label + tiny `rainbowAccent` dot (scannable).
- Detail: version history, success/failure counts (plain numbers), Promote/Disable/Delete.

### D9 — Safety Center
- Flat list: timestamp, reason code (`REASON_ZERO_ALPHA`, etc.), raw content behind "Show details" expand.
- Policy toggles: native `Switch`, monochrome-themed (thumb/track use only 7 tokens).

### D15 — Undo Toast (already exists in `command_centre_screen.dart`)
- Verify countdown bar uses `rainbowAccent` sub-fill, text `actionDescription just happened.` + `Undo` / `Irreversible`.

## Contract wiring (critical — no ad-hoc UI state)
- `Stream<NoirUiEvent>` subscription from Agent Runtime → UI.
- New `NoirUiEvent` subtype = add to `ui_state_contract.dart` + real runtime emission + widget consumer. Fail if any event has no consumer (E5).
- `TaskController.state` drives `TaskStateChanged`. `StreamingTokenReceived` drives stream reveal. `ConfirmationRequired` drives card. `ActionCompletedWithUndoWindow` drives D15. `CostEstimateResolved` drives D6 model line.

## Tests (E5 UX gates)
- Assert every `NoirUiEvent` subtype has a widget consumer in D2/D3/D6/D9.
- Assert `screenContentWasSanitized` flag renders the provenance note when true.
- Assert `reversible` false shows "Irreversible action completed." (no Undo button).
- Assert skeleton loader appears before streaming, removed after first token.

## Not missing anything from V2.3
- Zero accent colors except single `rainbowAccent` dot/fill (user-approved deviation).
- Assistant messages = no bubble. User = bubble. Composer = full width - 16px horizontal.
- Micro-copy sourced from EventBus (`"Reading screen…"`, `"Checking policy…"`, `"Using <tool>…"`, `"Responding with <model>…"`).
- Disclaimer: Noir-specific (on-device actions) — not ChatGPT copy.
- No avatar, no illustration.

## Next step
Implement D2 full interactive (stream + skeleton + confirmation + action bar), D3 timeline, D6 numbers, D7 rows, D9 list, with `rainbowAccent` applied minimally. Confirm with user before build.
