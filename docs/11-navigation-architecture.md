# 11. Navigation Architecture

## 11.1 Root Structure

- **`AppRouter`** (`@Observable`, root state machine) resolves at launch:
```
First Launch ──┬── Restore (file → passphrase → validate → success ⇒ Home)
               └── Get Started ⇒ Onboarding (resumable) ⇒ Home
Existing User ───── Home
```
- **Main UI: `TabView` with Walk / Result / You** (`MainShellView`). Superseded the earlier Home / History / Settings recommendation when Figma node 123:914 named the three tabs; the PRD still does not mandate layout, and the node is the design authority. Same three persistent surfaces, different names: Walk is the session surface, Result is history and the clinician summary, You is profile and settings.
- **Session setup roots the Walk tab** rather than opening inside the session cover. Node 123:914 draws the tab bar *under* the setup screen, so choosing a mode and its cues is an ordinary place in the app rather than a step already inside a modal flow. The cover begins at the countdown — see §11.3.
- Onboarding draft persistence makes the router resume mid-wizard, including on the final disclaimer screen pre-tick [PRD §6 AC].

## 11.2 Presentation Modes

| Mode | Used for |
|---|---|
| Root switch (router) | Welcome / Onboarding / Main |
| Full-screen cover | **Session flow** (countdown → recording → processing → result) — a deliberately modal, interruption-free context. **Setup is outside it**: it roots the Walk tab (§11.1), and the cover opens at the countdown, which is the first moment an interruption would cost the user something [PRD OQ-6] |
| Sheets | Export wizard (passphrase), Restore, About/Disclaimer, **Clinician Summary** — a modal sheet from the Result tab's `stethoscope` toolbar action, in its own navigation stack with a close button (decided 2026-09-14, Task 9.2.1). It superseded the earlier push onto History's stack: a sheet leaves the Result tab untouched underneath while the phone is in a clinician's hand |
| Alerts / confirmation dialogs | Plain-language errors; the Restore **conflict dialog** with exactly three actions: Cancel / Export current data first / Replace with backup [PRD §5] |
| Navigation stack | History → a session's Score screen (row chevron, Task 9.1.1). The Settings entry to the Clinician Summary [PRD §5] lands with the You tab |

## 11.3 Session Flow Coordinator

`SessionFlowCoordinator` (`@Observable`) drives the cover with an enum path:

```
countdown → recording → processing → result(score | noisy | failure)
```

`modeSelection` and `audioConfiguration` were the first two stages; both now live in `SessionSetupView` at the root of the Walk tab, which hands `(TestMode, SessionAudioConfig)` to the cover through `onStart`. The coordinator therefore starts at the countdown rather than at a choice.

- State-dependent contents: the setup screen's cue toggle depends on `BaselineState(for: selectedMode)` [PRD §5], read for **both** modes so a mode switch never waits on a query; first-session framing [PRD §5].
- After Processing: route to Noisy or Score — never both, never neither (failure → plain-language error + safe dismissal, session invalid) [PRD §5].
- Dismissal from result returns to Home; History refresh reflects the committed session.

## 11.4 Restore / Import Navigation

- **First-launch path:** failure returns to Welcome with a plain-language message, nothing changed [PRD §5]. Success skips straight to Home (profile exists from archive; onboarding considered complete) [PRD §5].
- **Settings path:** conflict dialog → Cancel (stay in Settings) / Export first (runs Export wizard, then re-presents the same choice [PRD §5]) / Replace (progress → success ⇒ **full state reset event** → rebuild stores, invalidate every in-memory cache/view model, route to Home [REC] | failure ⇒ stay in Settings, existing data untouched, plain-language error) [PRD §5, §7].

## 11.5 Predictability & Testability

- All routing is **enum-driven, value-typed, and pure-ish**: given `(hasProfile, disclaimerAccepted, baselineStates, sessionFlowStage)`, the visible route is a total function — no hidden boolean flags.
- View models receive router/coordinator via injection; navigation logic is unit-testable without rendering (assert: deny Home pre-disclaimer [PRD AC]; assert noisy routing; assert restore-fallback-to-Welcome).
- Post-restore state invalidation is an explicit broadcast event consumed by all long-lived view models — prevents the classic "stale in-memory data after replace" bug, which would violate the PRD's atomic-restore spirit [PRD §7].
