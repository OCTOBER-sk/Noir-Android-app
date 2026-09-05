# Noir — Private On-Device Android AI Agent

> **Your phone, handled.**

Noir is a private, on-device Android AI agent. ChatGPT-class command-centre UI, pure monochrome, event-driven observation, layered memory + separately stored procedural skills, multi-provider LLM with cost guards, hierarchical recovery, and a Policy Engine that runs before every consequential action.

**Status:** V2.1 source-of-truth loaded. Awaiting Sandy "go" on vertical slice.
**Source of truth for the build:** [SOURCE_OF_TRUTH.md](./SOURCE_OF_TRUTH.md) (V2.1)
**Atom's execution checklist:** [TODO_ATOM.md](./TODO_ATOM.md)
**Repo:** github.com/OCTOBER-sk/Noir-Android-app
**License:** Apache-2.0 (Noir code); see `THIRD_PARTY_NOTICE.md` for upstream attribution.

---

## What this is

A production-grade Android AI agent that:
- Observes the screen **event-driven** only while a task is active
- Owns the foreground UI under a single **UI_LOCK**
- Maintains persistent layered memory + separately stored Skills
- Replays learned Skills deterministically when all safety conditions hold
- Supports scheduled/background work clearly separated from UI-bound work
- Streams responses, shows live token/cost, branches into side conversations
- Defends against prompt injection with zone separation + taint tracking
- Ships as a signed APK (Android 8.0+ / API 26+) with CI green, tests, demo GIF, and docs

## Read first

1. **[SOURCE_OF_TRUTH.md](./SOURCE_OF_TRUTH.md)** — the complete V2.1 plan. AI agents (and humans) building Noir must read this end-to-end before any work.
2. **[TODO_ATOM.md](./TODO_ATOM.md)** — Atom's execution checklist derived from the source of truth. Tracks every track, every task, every verification gate.

## Non-negotiable constraints

- **UI Theme**: True black `#000000`, pure white `#FFFFFF`, neutral grays only. No accent colors.
- **Privacy**: No data leaves the device except through user-enabled providers/integrations.
- **OpenRouter Free Tier**: Prefer `:free` models. Never silently call paid endpoints. Respect shared RPM bucket.
- **Credential Handling**: Android Keystore only for secrets.
- **No Mock Data** for final verification.
- **Vertical slice first** (V2.1 §12) — no broad parallel work until the slice is green.

## Tech

- Flutter 3.24+ / Dart 3.5+
- Kotlin Accessibility Service (Android 8.0+ / API 26+)
- Drift (SQLite) for memory + skills stores
- WorkManager for background-safe scheduling
- Android Keystore for secrets
- MethodChannel for Dart ↔ Kotlin
- Hermes-inspired architecture (concepts adapted; runtime reimplemented in Dart)

## Build (after vertical slice)

```bash
git clone git@github.com:OCTOBER-sk/Noir-Android-app.git
cd Noir-Android-app
flutter pub get
flutter analyze
flutter test --coverage
flutter build apk --debug
```

## Credits

Built on architectural inspiration from `orailnoor/private-agent` (tag v1.0.2) and `AbuZar-Ansarii/PrivateAgent` (single commit 2026-09-04). See [THIRD_PARTY_NOTICE.md](./THIRD_PARTY_NOTICE.md).

## License

Apache-2.0. See [LICENSE](./LICENSE).
