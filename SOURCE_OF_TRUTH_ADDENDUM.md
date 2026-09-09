# SOURCE_OF_TRUTH — Addendum V2.2 (Research-Backed Hardening & UX Uplift)

**Purpose:** This addendum is written to be merged into `SOURCE_OF_TRUTH.md`. It does not
replace V2.1 — it adds new tracks/tasks, revises a few existing tasks with sharper
acceptance criteria, and cites *why*, based on a September 2026 research pass across:
on-device Android automation, LLM tool-calling/provider routing, Flutter AI-app UX, and
GUI-agent prompt-injection security. Every claim below reflects verified, dated sources —
no invented APIs or numbers.

**How to apply:** Treat each section as a patch to the numbered section of the same name
in SOURCE_OF_TRUTH.md. Where a task ID already exists (e.g. A6, B3, D2), this *revises*
that task's acceptance criteria — don't create a duplicate task ID.

---

## R0. Why this addendum exists (agent-readable rationale)

Four things changed the calculus since V2.1 was planned:

1. **AccessibilityService gesture injection is now a documented live attack pattern**, not
   a theoretical risk. Security researchers demonstrated automated permission-dialog
   clicking in ~2.4 seconds using the exact `dispatchGesture()` + tree-walk pattern this
   app's TaskExecutor uses for legitimate automation. This means Noir's own execution path
   is functionally identical to a malware capability, and the *only* differentiator is the
   Policy Engine / confirmation / biometric gate sitting in front of it. Treat that gate as
   the single most security-critical code path in the app.
2. **GUI-agent prompt injection has moved to the visual channel.** 2026 papers (MIRAGE,
   SnapGuard, WebSentinel) show injected instructions increasingly arrive via rendered
   screen content — off-screen coordinates, zero-opacity/zero-font-size views, CDATA-style
   concealment — not just plain visible text. Text-level taint tagging (already in V2.1's
   PromptBuilder zones) is necessary but not sufficient.
3. **OpenRouter's free tier is stricter and less stable than a hardcoded model ID assumes.**
   20 req/min is a hard ceiling regardless of spend; which models carry `:free` rotates
   without notice. A hardcoded single free model will silently break.
4. **2026 AI-app UX baseline has moved.** Users now expect output-shaped skeleton loaders
   (not generic spinners), visible confidence/provenance signals on tool-derived claims,
   and a short undo window on autonomous actions — cheap to add, high perceived-quality
   payoff, and directly synergizes with your existing Confirmation Cards (D2) and Policy
   Engine (A6).

---

## R1. Track A revisions — Agent Runtime

### A6 — Planner + RiskClassifier + Policy Engine (REVISED acceptance criteria)

Add to the existing pipeline:

```
LLM / Planner
  → proposed ToolCall
  → RiskClassifier (0–3)
  → Screen-Content Sanitizer (NEW — only for tools whose input includes screen/OCR text)
  → Policy Engine (rules, blacklist, budget, UI_LOCK, biometric requirement)
  → User confirmation if required
  → Biometric if required
  → Execute via Tool Gateway
  → Undo window (NEW — 5s, cancellable, for any action classified riskLevel ≥ 1)
```

**New sub-task A6a — Screen-Content Sanitizer:**
- Before untrusted screen/accessibility-tree text enters Zone 6 (UNTRUSTED SCREEN TEXT) of
  the prompt, run a pass that strips/flags: nodes with zero alpha or zero bounds, text
  positioned fully outside the visible viewport, and character sequences matching known
  concealment patterns (zero-width Unicode, direction-override characters).
- Log (locally, structured) any stripped content with reason code — never silently drop
  without an audit trail, since the Safety Center (D9) needs to show injection-attempt
  history.
- This sanitizer is deterministic code, not a model call — do not rely on the LLM to
  "notice" concealed content.
- **Rationale:** rendered-content injection (MIRAGE, SnapGuard 2026) bypasses text-only
  taint tagging because the malicious instruction never appears in a way a human glancing
  at the screen would see, but an accessibility-tree dump captures it anyway.

**New sub-task A6b — Undo Window:**
- Any executed ToolCall with `riskLevel >= 1` gets a 5-second cancellable undo toast
  surfaced to Command Centre (D2) before the action's side effects are considered final
  where the action type supports reversal (e.g. draft not yet sent, navigation not yet
  confirmed). Where truly irreversible (e.g. a tap already delivered to another app),
  the toast becomes a "this just happened" notice instead of an undo — still show it.
- **Rationale:** identified as a 2026 baseline UX expectation for autonomous AI actions;
  also gives the Audit Log (A8) a natural user-visible complement.

**Acceptance criteria addition:** Policy Engine test suite (E10) must include cases where
sanitizer-stripped content is the *only* thing that would have triggered an unsafe
ToolCall — verifying the sanitizer, not just the classifier, blocks it.

### A9 — Cost Estimator (REVISED)

Confirm handling of the researched free-tier facts as explicit constants, not
assumptions baked into code paths:

- `OPENROUTER_FREE_RPM_CAP = 20` (fixed regardless of account funding level).
- `OPENROUTER_FREE_DAILY_CAP_UNFUNDED = 50`, `OPENROUTER_FREE_DAILY_CAP_FUNDED = 1000`
  (funded = lifetime $10+ credit purchase; the raised cap persists even if balance
  later drops to $0).
- The list of which model IDs currently carry `:free` **must be fetched live** (via
  OpenRouter's models endpoint) on a cache-with-TTL basis, not hardcoded — free-model
  availability rotates without warning.
- Cost Estimator must support a **fallback array** of 2–3 free model IDs per request
  (not a single hardcoded ID), falling through on 429, consistent with B3 below.

### NEW A12 — Reflection/Critic Step (adds to Track A)

- After `Act → Verify`, add an explicit lightweight critic pass: before marking a task
  step "verified success," compare intended outcome vs. observed post-action screen
  state and produce a confidence score, not just a boolean pass/fail.
- Low-confidence verifications route into Hierarchical Recovery (A4) rather than being
  silently accepted.
- **Rationale:** current SOTA GUI-agent frameworks (Mobile-Agent-v3 / GUI-Owl,
  AndroidWorld 73.3%) attribute a meaningful share of their benchmark gains over prior
  approaches to trajectory-level verification/reflection, not just better grounding —
  i.e., checking your own work is now a first-class architectural component, not an
  afterthought bolted onto recovery.

---

## R2. Track B revisions — Providers, Tools, Web Search

### B2 — Provider Adapters (REVISED)

Add **MCP (Model Context Protocol) client support** as a first-class adapter type,
alongside OpenAI/Anthropic/Gemini/Ollama/CustomHttp:

- MCP is now adopted by Anthropic, OpenAI, Google, and Microsoft as the de facto
  standard for agent-to-tool connectivity (JSON-RPC 2.0 based, three primitives:
  Tools, Resources, Prompts).
- Treat an MCP server as a `backgroundSafe` or `uiBound` tool source depending on what
  it exposes — classify per-tool, not per-server.
- This lets Noir consume any MCP-compatible external tool server a user configures
  (e.g. a personal Notion/Gmail MCP server) without Noir having to hand-write an
  adapter for every such service — directly serves the "wide range of use cases" goal.
- Security note: MCP servers are an additional untrusted-content and untrusted-tool-
  output surface. Tool results from MCP servers enter Zone 5 (TOOL RESULTS, UNTRUSTED)
  exactly like any other tool — no special trust.

### B3 — Model Router + Free-tier / Budget Guard (REVISED)

- Confirmed pattern from research: request a **fallback array** in the provider call
  (e.g. `models: [modelA, modelB, modelC]` style routing) rather than hardcoding one
  model and catching failure yourself — this is the standard resilience pattern for
  free-tier usage in 2026 and reduces user-visible failures when a given free model is
  rate-limited or rotated out.
- Model Router should treat "free model list changed since last cache refresh" as a
  normal, expected event — not an error state requiring user intervention.

---

## R3. Track C revisions — Android Native Layer

### C1 — Enhanced AgentAccessibilityService (REVISED acceptance criteria)

Add an explicit note tying this to the security posture in R1/A6a:

- The accessibility tree dump produced here is the **primary raw input** the Screen-
  Content Sanitizer (A6a) operates on. C1's node-dump implementation must preserve
  bounds, alpha/visibility, and z-order metadata for each node — not just text content
  — because the sanitizer needs that metadata to detect concealment (off-screen
  coordinates, zero-alpha nodes). If C1 only extracts visible text, A6a cannot function.

### C2 — Full Action Set via MethodChannel (REVISED)

- Every gesture-dispatching action executed here must be preceded, in the runtime,
  by the Policy Engine gate — never call `dispatchGesture` reachable from a code path
  that bypasses A6. Given that gesture injection via AccessibilityService is
  functionally indistinguishable from real touch (no OS-level flag differentiates
  it — confirmed from Android's own gesture dispatch documentation and 2026 security
  research on the same primitive), this gate is Noir's only defense against its own
  automation being misused by an injected instruction. Treat any refactor that could
  create a bypass path as a release-blocking regression.

---

## R4. Track D revisions — Flutter UI

### D2 — Command Centre Chat (REVISED)

Add to acceptance criteria, reflecting 2026 AI-app UX baseline:

- **Skeleton loaders must match the shape of expected output**, not use a generic
  spinner — e.g. a message-shaped skeleton for chat replies, a card-shaped skeleton
  for a tool-result card, a list-shaped skeleton for search results.
- **Micro-copy during "thinking" states** should reflect actual pipeline stage
  (e.g. "Reading screen…", "Checking policy…", "Calling <tool>…") rather than a
  static "Thinking…" — this also gives the user real visibility into the Cost
  Estimator / Policy Engine pipeline stages already defined in A6/A9, satisfying the
  "token/cost/provider/model visibility is a first-class surface" principle from
  Section 1 of the original plan.
- **Confirmation cards must show provenance**, not just the proposed action: which
  tool, which risk tier, and — where the proposed action was informed by screen
  content — a note if any content was sanitized/stripped by A6a before reaching the
  model, so the user can see that something suspicious was filtered.

### NEW D15 — Undo/Just-Happened Toast

- Companion UI for A6b. A dismissible toast anchored to the bottom of Live Task View
  (D3) and Command Centre, showing the action just taken, a 5-second countdown, and
  (where applicable) an Undo button. Must remain monochrome per the existing theme
  constraint (Section 2 of original plan) — no color-coded urgency; use weight/size
  and the existing grayscale palette to convey urgency instead.

---

## R5. Track E revisions — Tests, Hardening, Release

### E4 — Prompt-injection matrix (REVISED)

Expand the matrix beyond text-based injection (already implied by V2.1's taint zones)
to explicitly include **visual/rendered-content injection** test cases, since this is
now a documented distinct attack class (2026 research: MIRAGE, SnapGuard, WebSentinel):

- Off-screen-positioned instruction text (negative or out-of-viewport coordinates).
- Zero-alpha / zero-size accessibility nodes carrying instruction text.
- Zero-width Unicode / bidi-override character sequences embedded in otherwise
  normal-looking screen text.
- Confirm each case is caught by A6a (Screen-Content Sanitizer) before reaching
  Zone 6 of the prompt, and confirm the Safety Center (D9) surfaces the block event.
- Target: 100% pass, consistent with the existing E4 bar for text-based injection.

---

## R6. New use-case surface (informs Track D / Skill Manager, non-blocking)

Concrete, real-world task categories worth prioritizing when building example Skills
(A3) and onboarding suggestions (D1), based on what similar on-device/agentic products
ship today:

- **Message triage & drafting**: summarizing a long thread, drafting a reply in the
  user's tone, without the raw content leaving the device unless a cloud provider is
  explicitly enabled.
- **Form-filling across apps**: repetitive multi-field forms (delivery addresses,
  recurring bookings) as a natural Skill-candidate case — this is exactly the
  candidate→active lifecycle A3 already models.
- **Cross-app workflows**: "take this photo, extract the text, put it in a note" style
  chains that exercise Tool Gateway's mixture of `uiBound` and `backgroundSafe` tools.
- **Scheduled/background digests**: WorkManager-driven (C3) daily or weekly summaries
  (e.g. notification digest, unread-message rollup) that never require UI_LOCK.
- **Scam/phishing screen checks**: on-device pattern checks on suspicious screens
  (e.g. a fake permission dialog, a suspicious payment page) — directly reuses the
  Screen-Content Sanitizer's concealment-detection logic (A6a) for a user-facing
  safety feature, not just internal defense.

These are suggestions for Skill examples and onboarding copy — they do not change any
Track A–C architecture and are not acceptance-blocking.

---

## R7. Sources consulted (for traceability, not for citation in-app)

- Android AccessibilityService `dispatchGesture` official reference (developer.android.com)
- 2026 security research on AccessibilityService gesture-injection attack chains
- Mobile-Agent-v3 / GUI-Owl technical report (arXiv 2508.15144) — AndroidWorld/OSWorld SOTA
- OpenRouter free-tier rate limit documentation and 2026 third-party summaries
- Model Context Protocol overview and 2026 ecosystem/adoption guides
- MIRAGE (visual-channel GUI-agent prompt injection), SnapGuard, WebSentinel — 2026 papers
- 2026 AI-app UX trend/mistake analyses (streaming, skeleton loaders, undo affordances)
- Gemini Nano / on-device SLM landscape (for future offline-fallback consideration only —
  not adopted into V2.1/V2.2 architecture, which remains provider-adapter based)

**End of Addendum V2.2**
