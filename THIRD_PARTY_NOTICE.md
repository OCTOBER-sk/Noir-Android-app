# Third-Party Notice

Noir (this repository) is original work by Santhoshkumar S (OCTOBER-sk), licensed under Apache-2.0.

The following third-party projects informed the architecture and design. None of their source code is included in this repository at the time of the V2.1 source-of-truth push. Where code patterns are referenced, they are re-implemented from scratch in Dart/Kotlin under the `com.noir.android` namespace.

| Project | Author | Upstream | License | Use |
|---------|--------|----------|---------|-----|
| `private-agent` (v1.0.2) | orailnoor | github.com/orailnoor/private-agent @ v1.0.2 (commit 2026-07-17) | **No LICENSE file** | Architectural reference only (accessibility service patterns, observe→act→verify loop, recovery engine shape). All Noir code is independently re-implemented. |
| `PrivateAgent` (single commit 2026-09-04) | AbuZar-Ansarii | github.com/AbuZar-Ansarii/PrivateAgent | **No LICENSE file** | Architectural reference only. |
| Hermes Agent concepts | Nous Research | github.com/hermes-agent | MIT (concepts borrowed: layered memory, skill lifecycle, event bus, recovery hierarchy) | No source copied. Concepts re-implemented in pure Dart. |

## Re-implementation policy

Where the V2.1 plan references structures from `orailnoor/private-agent` (e.g. `lib/services/ai_service.dart`, `AgentAccessibilityService.kt`), the Noir codebase will:

1. **Migrate** the package namespace to `com.noir.android` (per V2.1 §0.13).
2. **Re-design** to V2.1 architecture (canonical ToolCall, Tool Gateway, UI_LOCK, policy engine, etc.) — not a 1:1 port.
3. **Remove** any code that doesn't align with V2.1 (e.g. PrivateAgent's brittle JSON-action LLM contract is replaced with canonical ToolCall + adapter translation).
4. **Track** each migrated file in the commit message with a "FROM: orailnoor/private-agent <path>" footer.

## Permissions pending

- Written permission from `orailnoor` to vendor or substantially use upstream code (preferred).
- If no permission lands, the V2.1 plan's reference to `orailnoor/private-agent` is treated as architectural inspiration only, and Noir is built from scratch in `com.noir.android`.
