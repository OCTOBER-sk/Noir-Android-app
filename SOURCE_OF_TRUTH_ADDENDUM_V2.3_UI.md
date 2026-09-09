# SOURCE_OF_TRUTH — Addendum V2.3 (ChatGPT-Class Monochrome UI Spec)

**Purpose:** This is a buildable, pixel-and-state-level UI/UX spec for Track D
(Flutter UI). It exists because "make it ChatGPT-style" is not implementable as
written — this addendum turns that into exact colors, radii, spacing, component
states, and — critically — the exact backend state each UI element is wired to,
so the coding agent cannot drift into a UI that looks right but doesn't reflect
what the Agent Runtime (Track A) is actually doing.

**Rule for the agent:** Every visual state in this document maps to a named state
already defined in SOURCE_OF_TRUTH.md (TaskController states, EventBus events,
RiskClassifier tiers, etc.). If you build a UI state that has no backend state to
bind to, stop and flag it — do not invent a fake loading state that isn't backed
by a real pipeline stage.

---

## 1. Design tokens (extends Section 2's 7-color constraint — do not add colors)

Reference: 2026 ChatGPT web/app interface conventions (assistant-ui ChatGPT clone
spec, GPThemes theming analysis).

```
// lib/core/theme/noir_theme.dart — token names, not new colors
NoirColors.pureBlack     = #000000   // dark mode app background
NoirColors.nearBlack     = #121212   // dark mode elevated surface (composer, cards)
NoirColors.surfaceDark   = #1E1E1E   // dark mode secondary surface (assistant bubble bg = transparent, but cards use this)
NoirColors.surfaceDark2  = #2A2A2A   // dark mode borders, dividers, hover states
NoirColors.textMuted     = #B0B0B0   // timestamps, disclaimers, placeholder text
NoirColors.textSecondary = #E5E5E5   // secondary text, icons at rest
NoirColors.pureWhite     = #FFFFFF   // dark mode primary text, light mode background

// Light mode is the same 7 tokens, inverted role (light mode background = #FFFFFF,
// primary text = #000000, elevated surface = #E5E5E5, etc.) — same palette, no new hex.
```

**Non-negotiable:** zero accent colors, anywhere, ever — including risk indicators,
confirmation cards, and error states. Urgency/hierarchy is conveyed with weight,
size, opacity, and spacing only. This is stricter than ChatGPT itself (which uses
some accent color) — Noir's brand constraint from Section 2 overrides the reference.

### Typography
- System font (Roboto on Android via Flutter default) — do not bundle a custom font,
  it adds APK weight for no brand requirement stated anywhere in the plan.
- Chat body text: 16sp, weight 400, line-height 1.5.
- Empty-state heading (D2 welcome screen): 24sp, weight 400 — matches the reference
  spec's "24px/400 heading" convention exactly.
- Timestamps / disclaimers: 12sp, `textMuted`.
- Code blocks: monospace (`RobotoMono` or platform default mono), 14sp, on
  `surfaceDark` background with 8px radius.

### Shape language
- Composer (input bar): 28px corner radius, matching the reference spec's
  `rounded-[28px]` composer convention. Full-width minus 16px horizontal margin.
- User message bubble: 22px corner radius, right-aligned, max-width 70% of screen,
  high-contrast fill (`nearBlack` bg / `pureWhite` text in dark mode).
- Assistant messages: **no bubble** — full-width, transparent background, left-
  aligned, matches ChatGPT's actual convention (assistant text is not bubbled;
  only the user's is). This is a deliberate deviation from generic "chat bubble"
  packages — do not use a symmetric bubble-for-both-sides layout.
- Cards (tool results, confirmation cards, skill cards): 12px corner radius,
  `surfaceDark` background, 1px `surfaceDark2` border.
- Buttons/icon controls: 36px circular tap targets in the composer row, 32px in
  the assistant action bar — matches reference spec exactly, and clears Android's
  48dp recommended touch target when combined with adequate padding (verify in E5).

---

## 2. Screen-by-screen spec, wired to backend state

### 2.1 Command Centre Chat (D2) — the main screen

**Empty state (no messages yet):**
- Centered composer, raised above vertical center (not pinned to bottom) — matches
  ChatGPT's actual empty-state layout, not a generic chat app's bottom-anchored bar.
- 24sp/400 greeting text above the composer (e.g. "What are we handling today?").
- No avatar, no illustration — stay minimal per the monochrome brand.
- Bound to: `TaskController.state == idle` AND message list is empty.

**Active conversation state:**
- Composer drops to a sticky footer, full width minus margin, same 28px radius.
- Below composer: a single line of `textMuted` 12sp disclaimer text — reuse this
  slot for something Noir-specific and truthful, e.g. "Noir can take real actions
  on your device. Review confirmations carefully." (do not copy ChatGPT's literal
  disclaimer text — write Noir's own, but keep the placement/weight convention).
- Bound to: `TaskController.state != idle` OR message list is non-empty.

**Message list:**
- User bubble: right-aligned, `nearBlack` fill, `pureWhite` text, 22px radius,
  70% max width. On tap-and-hold (or hover on larger screens): reveal Copy + Edit
  actions below the bubble, matching the reference spec's interaction pattern.
- Assistant message: left-aligned, no bubble, full width, `pureWhite`/`E5E5E5`
  text depending on hierarchy. Below every completed assistant message: a
  32px-tall action bar — Copy, Regenerate, Save as Fact, Propose Skill, thumbs
  up/down (feedback only, not a rating system) — 8px radius per button, zero gap
  between buttons, background-only hover (no border), tooltip on every action.
  This action bar is not decorative: "Save as Fact" writes to Memory (A2),
  "Propose Skill" invokes the Skill Lifecycle candidate path (A3) — wire these for
  real, not as stubs.

**Streaming state (the actual "smooth streaming" requirement):**
- Bound to: EventBus `streaming` event active on the current assistant message.
- Token-by-token (or word-by-word) reveal — no full-block dump-then-display.
- A soft blinking caret (▍, `textMuted`) at the end of the growing text, removed
  the instant the stream completes.
- No skeleton loader once streaming has started — skeletons are only for the gap
  *before* the first token arrives (see 2.1a).
- Must be cancellable mid-stream: a Stop button replaces Send in the composer
  while `streaming` is active, bound to the same cancellation token infra defined
  in Section 0.3 (Cancel Tokens).

**2.1a — Pre-stream loading state (the "thinking" gap):**
- Do NOT use a generic spinner. Use a skeleton shaped like what's about to render:
  a few 16sp-height gray (`surfaceDark2`) bars of varying width, left-aligned,
  no bubble — literally previewing "a paragraph is about to appear here."
- Alongside the skeleton, show real pipeline-stage micro-copy, sourced directly
  from EventBus, not invented copy:
  - `planning` state → "Thinking…"
  - `tool_calling` event active → "Using <tool name>…" (real tool name from the
    ToolCall, not a placeholder)
  - Cost Estimator (A9) has resolved a model → "Responding with <model name>…"
    (only if the person has debug/model-visibility on — see 2.4)
- This directly satisfies Section 1's "token/cost/provider/model visibility is a
  first-class surface" requirement — the loading state itself is that surface,
  not just the dashboard.

**Confirmation cards (risk/policy-gated actions):**
- Bound to: Policy Engine (A6) emitting `awaiting_confirmation` with a required
  confirmation.
- Card style: 12px radius, `surfaceDark` bg, 1px `surfaceDark2` border, full width
  inline in the message list (not a modal/dialog — keep it in the conversational
  flow).
- Card contents, top to bottom:
  1. Action description in plain language (e.g. "Tap 'Send' in WhatsApp").
  2. Risk tier shown as text weight/label only — e.g. "Standard" / "Sensitive" /
     "High risk" in increasing weight, never color. (RiskClassifier tiers 0–3 map
     to: 0=no card shown/auto, 1=Standard, 2=Sensitive, 3=High risk.)
  3. Tool + provenance line: which tool, and — if A6a's Screen-Content Sanitizer
     stripped anything from the input that produced this proposed action — a
     visible note: "Some on-screen content was filtered as unsafe before this was
     proposed." This is not optional cosmetic text — it's the user-facing half of
     the security addendum (R1/A6a in Addendum V2.2) and must reflect a real flag
     from the sanitizer, not a static string.
  4. Two buttons: "Confirm" (36px, `pureWhite` fill / `pureBlack` text — the one
     place a filled high-contrast button is allowed, since this is the single
     most important tap target in the app) and "Cancel" (outline only, same size).
  5. If `riskLevel >= 2`, biometric prompt (A8) fires on Confirm tap before the
     action executes — the card does not claim success until biometric clears.

**Undo / just-happened toast (D15, from Addendum V2.2):**
- Bottom-anchored, above the composer, `nearBlack` bg, `pureWhite` text, 12px
  radius, auto-dismiss after 5s with a thin countdown bar (grayscale, not color)
  along its bottom edge.
- Bound to: any executed ToolCall with `riskLevel >= 1` completing.
- Text: "<Action> just happened." + "Undo" button if reversible, otherwise no
  button — just the notice.

### 2.2 Live Task View (D3)

- A vertical timeline of the current task's EventBus events, each row: icon-free,
  text-only, `textMuted` timestamp on the left, event description on the right.
- Core states rendered as section headers (not every micro-event gets a header):
  `planning`, `awaiting_confirmation`, `executing`, `recovering`, `paused`,
  terminal (`completed`/`failed`/`cancelled`).
- `recovering` state gets a distinct visual treatment: same monochrome palette,
  but the row background uses `surfaceDark2` (the darkest available non-black
  surface) to signal "something needed correction" without using color.
- This view must be a real-time reflection of `EventBus` + `TaskController` state
  — not a separately-maintained UI state machine. If Track A's state changes and
  D3 doesn't reflect it within one frame, that's a bug, not a UI polish item.

### 2.3 Skill Manager (D7)

- List of skills as full-width rows (no cards) — name, current lifecycle state
  as plain text label (`candidate`/`validated`/`draft`/`active`/`disabled`/
  `degraded`/`needs_review`), last-used timestamp in `textMuted`.
- Tapping a skill opens its detail: version history, success/failure counts (plain
  numbers, no bar charts needed — this is a utility screen, not a dashboard), and
  a Promote/Disable/Delete action row.
- `needs_review` skills get a `textSecondary`-weight badge-style label (text only,
  no color) at the front of the row so they're scannable in a long list — this is
  the one place a "badge" pattern is justified because A3 explicitly says
  `needs_review` items must never be silently hidden.

### 2.4 Usage Dashboard (D6)

- Plain numeric readouts, not gauges/donut charts — tokens used today, cost today
  (if any paid provider active), current model, current provider, RPM headroom
  against `OPENROUTER_FREE_RPM_CAP` (from Addendum V2.2/A9) shown as "12 / 20 req
  this minute" style text, not a progress ring.
- A toggle here controls whether the pipeline-stage micro-copy in 2.1a shows model
  names — respects a privacy-conscious user who doesn't want provider details
  cluttering every response.

### 2.5 Safety Center (D9)

- Injection-attempt log (from A6a's audit trail, Addendum V2.2) rendered as a
  flat list: timestamp, what was stripped (reason code, not raw stripped content
  by default — raw content behind a "Show details" expand, since displaying raw
  injection payloads by default is itself a minor risk surface).
- Policy Engine toggles (blacklist entries, confirmation thresholds) as plain
  list-with-switch rows — Android's native `Switch` widget, monochrome-themed
  (thumb/track use only the 7 approved tokens).

---

## 3. Backend ↔ Frontend contract (the "in sync" requirement)

This is the part that makes "backend and frontend in sync" concrete rather than
aspirational. The coding agent must implement this as literal Dart contracts, not
prose:

```dart
// lib/core/ui_state_contract.dart
// Every UI-visible state MUST originate from one of these — no ad-hoc UI state.

sealed class NoirUiEvent {}

// Maps 1:1 to TaskController core states (Section 7, A5)
class TaskStateChanged extends NoirUiEvent {
  final TaskState state; // idle | planning | awaiting_confirmation | executing
                          // | recovering | paused | completed | failed | cancelled
}

// Maps 1:1 to EventBus secondary events (Section 7, A5)
class StreamingTokenReceived extends NoirUiEvent { final String delta; }
class ToolCallStarted extends NoirUiEvent { final String toolName; final int riskLevel; }
class ToolCallCompleted extends NoirUiEvent { final String toolName; final bool success; }
class SideConversationOpened extends NoirUiEvent { final String parentMessageId; }

// Maps 1:1 to Policy Engine / Cost Estimator (A6, A9)
class ConfirmationRequired extends NoirUiEvent {
  final String actionDescription;
  final int riskTier; // 0-3, from RiskClassifier
  final String toolName;
  final bool screenContentWasSanitized; // from A6a — drives the provenance note
}
class CostEstimateResolved extends NoirUiEvent {
  final String provider; final String model; final int estimatedTokens;
}

// Maps 1:1 to A6b (Undo Window, Addendum V2.2)
class ActionCompletedWithUndoWindow extends NoirUiEvent {
  final String actionDescription; final bool reversible; final Duration window;
}
```

**Rule:** the Flutter UI layer subscribes to a single `Stream<NoirUiEvent>`
exposed by the Agent Runtime (Track A). It never polls, never maintains a
duplicate state machine, and never fabricates an event the backend didn't emit.
If the UI needs a new visual state, the correct fix is adding a new `NoirUiEvent`
subtype backed by a real runtime transition — not adding local UI-only state.

**Verification (add to E5 — UX gates):** a test that walks every `NoirUiEvent`
subtype and asserts a corresponding widget/visual treatment exists in D2/D3/D6/D9.
Fail the build if a UI event has no consumer, or a UI state has no emitting event.

---

## 4. What NOT to copy from ChatGPT

To keep this "professional" rather than a literal skin:
- No OpenAI logo/wordmark/icon shapes — original Noir mark only.
- No accent color anywhere (ChatGPT itself uses some) — Noir stays strictly
  monochrome per Section 2's non-negotiable constraint.
- No "GPT-4o" style model-name-as-brand-flex UI — Noir's model/provider info lives
  in the Usage Dashboard and optional pipeline micro-copy, not as a status-symbol
  badge in the header.
- Disclaimer text must be Noir's own words about Noir's own real capabilities
  (on-device action-taking), not a reworded copy of ChatGPT's disclaimer.

**End of Addendum V2.3**
