# 11. Navigation Architecture

## 11.1 Root Structure

- **`AppRouter`** (`@Observable`, root state machine) resolves at launch:
```
First Launch ──┬── Restore (file → passphrase → validate → success ⇒ Home)
               └── Get Started ⇒ Onboarding (resumable) ⇒ Home
Existing User ───── Home
```
- **Main UI [REC]: `TabView` with Home / History / Settings** — matches the PRD's three persistent surfaces; PRD does not mandate layout, so this is a labeled recommendation.
- Onboarding draft persistence makes the router resume mid-wizard, including on the final disclaimer screen pre-tick [PRD §6 AC].

## 11.2 Presentation Modes

| Mode | Used for |
|---|---|
| Root switch (router) | Welcome / Onboarding / Main |
| Full-screen cover | **Session flow** (setup → recording → processing → result) — a deliberately modal, interruption-free context |
| Sheets | Export wizard (passphrase), Restore, About/Disclaimer |
| Alerts / confirmation dialogs | Plain-language errors; the Restore **conflict dialog** with exactly three actions: Cancel / Export current data first / Replace with backup [PRD §5] |
| Navigation stack | History → Clinician Summary (deep link from Settings also possible) |

## 11.3 Session Flow Coordinator

`SessionFlowCoordinator` (`@Observable`) drives the cover with an enum path:

```
modeSelection → audioConfiguration → recording → processing → result(score | noisy | failure)
```

- State-dependent contents: audio step depends on `BaselineState(for: selectedMode)` [PRD §5]; first-session framing [PRD §5].
- After Processing: route to Noisy or Score — never both, never neither (failure → plain-language error + safe dismissal, session invalid) [PRD §5].
- Dismissal from result returns to Home; History refresh reflects the committed session.

## 11.4 Restore / Import Navigation

- **First-launch path:** failure returns to Welcome with a plain-language message, nothing changed [PRD §5]. Success skips straight to Home (profile exists from archive; onboarding considered complete) [PRD §5].
- **Settings path:** conflict dialog → Cancel (stay in Settings) / Export first (runs Export wizard, then re-presents the same choice [PRD §5]) / Replace (progress → success ⇒ **full state reset event** → rebuild stores, invalidate every in-memory cache/view model, route to Home [REC] | failure ⇒ stay in Settings, existing data untouched, plain-language error) [PRD §5, §7].

## 11.5 Predictability & Testability

- All routing is **enum-driven, value-typed, and pure-ish**: given `(hasProfile, disclaimerAccepted, baselineStates, sessionFlowStage)`, the visible route is a total function — no hidden boolean flags.
- View models receive router/coordinator via injection; navigation logic is unit-testable without rendering (assert: deny Home pre-disclaimer [PRD AC]; assert noisy routing; assert restore-fallback-to-Welcome).
- Post-restore state invalidation is an explicit broadcast event consumed by all long-lived view models — prevents the classic "stale in-memory data after replace" bug, which would violate the PRD's atomic-restore spirit [PRD §7].
