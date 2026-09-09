# SOURCE_OF_TRUTH — Addendum V2.3 (ChatGPT-Class Monochrome UI Spec)

Purpose: buildable, pixel-level UI/UX spec for Track D (Flutter UI). Monochrome only (7 tokens: pureBlack #000, nearBlack #121, surfaceDark #1E1E, surfaceDark2 #2A2A, textMuted #B0B, textSecondary #E5E5, pureWhite #FFF). Zero accent colors.

Wired to backend state via single Stream<NoirUiEvent> (see Section 3 contract). Every UI state must map to a named TaskController/EventBus/PolicyEngine/CostEstimator/A6b event. Never invent UI-only state.

Screen specs (wired):
- 2.1 Command Centre Chat (D2): empty state, active state, message list (user bubble 22px radius/right-aligned/70% max, assistant full-width/no bubble), streaming state (word-by-word + blinking caret + cancellable Stop button), 2.1a pre-stream skeleton loader shaped like output + real pipeline micro-copy (planning/tool_calling/model-resolved), confirmation cards (action desc + risk tier as text-weight only + tool/provenance + screen-content-sanitized note + Confirm/Cancel + biometric for riskLevel>=2), 2.1b Undo toast (D15, grayscale countdown bar, bottom-anchored).
- 2.2 Live Task View (D3): vertical timeline, core state headers, recovering state uses surfaceDark2.
- 2.3 Skill Manager (D7): full-width rows, lifecycle labels, needs_review scannable badge.
- 2.4 Usage Dashboard (D6): plain numeric readouts, RPM headroom "12/20" format, toggle for model-name visibility.
- 2.5 Safety Center (D9): flat injection-attempt list (reason codes, raw behind expand), Policy toggles as Switch rows.
- Section 3: literal Dart contracts (TaskStateChanged, StreamingTokenReceived, ToolCallStarted/Completed, SideConversationOpened, ConfirmationRequired with screenContentWasSanitized bool, CostEstimateResolved, ActionCompletedWithUndoWindow).
- Section 4: what NOT to copy from ChatGPT (no OpenAI mark, no accent color, no GPT-4o badge, own disclaimer text).
