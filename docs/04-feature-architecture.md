# 4. Feature Architecture

Feature boundaries derived from the PRD flows (§5), not from the template list. Non-UI subsystems are included as first-class "features" because they own requirements.

### 4.1 App Launch & Root Routing
- **Responsibility:** Resolve first-launch vs. existing-user; drive root screen. [PRD §5]
- **Screens:** none (state machine only).
- **State:** `AppLaunchPhase { resolving, firstLaunch, onboarding, main }`.
- **Models:** `UserProfile` existence, onboarding-draft existence, disclaimer flag.
- **Dependencies:** `UserProfileRepository`, onboarding draft store.
- **Navigation:** owns the root; see §11.

### 4.2 First-Launch Restore
- **Responsibility:** Offer "Restore from a previous export" at first launch; file pick, passphrase prompt, decrypt, validate, full restore, skip straight to Home; on failure, plain-language error and return to Welcome with nothing altered. [PRD §5]
- **Screens:** Welcome (choice), file picker (system), passphrase entry sheet, progress/failure states.
- **Services:** `SecureArchiveService` (import path), document picker.
- **State transitions:** `picking → passphraseEntry → decrypting/validating → restoring → success(→Home) | failure(→Welcome)`.
- **Error states:** wrong passphrase / corrupted / incompatible — plain-language, distinguish where possible [PRD §6].

### 4.3 Onboarding
- **Responsibility:** Progressive single-field screens: amputation level → side → time since amputation (optional, skippable) → device type (optional) → K-level (optional) → disclaimer with required checkbox. All five questions stay in onboarding; the three optional ones can be edited later in Settings. [PRD §5, §7; decisions.md entry 53]
- **Screens:** field wizard + final disclaimer screen; "Why we ask" microcopy on level/side [PRD AC].
- **State:** `OnboardingDraft` persisted across relaunch (incl. final screen pre-tick) [PRD §6].
- **Models:** `UserProfile` draft, `AmputationLevel`, `AffectedSide`.
- **Validation:** required fields (level, side) completable without the three optionals [PRD AC]; level/side consistency (bilateral ⇒ both) [REC].
- **Navigation:** hard gate — no Home without disclaimer tick; no silent failure [PRD §6].
- **Edge cases:** bilateral selection fully supported; force-quit resume.

### 4.4 Home / Dashboard
- **Responsibility:** Empty state ("Run your first Gait Training session") pre-first-session; afterwards latest score + trend snapshot + "Start Gait Training"; export nudge after first baseline established. [PRD §5, §6] *(Home was superseded by Walk / Result / You, §11.1. The export nudge is the Walk tab's one-time backup card: §21 #11, decisions.md entry 43, Task 10.2.3.)*
- **State:** derived from repositories (latest valid scored session per mode, session counts); `emptyState`/`populated`.
- **Dependencies:** `GaitSessionRepository`, `BaselineRepository`; navigation intent into session flow.
- **Error states:** persistence read failure → generic retry state.
- **Edge cases:** latest session invalid → show last *valid* [PRD: history lists valid]; baseline in one mode only → snapshot reflects that mode.

### 4.5 Gait Test Configuration (Session Setup)
- **Responsibility:** Mode selection (Quick 1:30 / Full 3:00 [PRD AC]; phone segment labels "Quick (1:30)" and "Full (3:00)", watch labels "Quick Test · 1:30" and "Full Test · 3:00"); audio feedback selector whose contents depend on that mode's baseline existence [PRD §5]; first-session "walk normally — there's no target pace" framing [PRD AC]; permission pre-flight; user instructions (straight-line walking; phone placement guidance [REC — placement is OPEN, see §21]).
- **Start action:** the Start Test button **begins the countdown, not the session** [PRD OQ-6]. It hands the selected `TestMode` and `SessionAudioConfig` to §4.6's `countingDown` phase; no `GaitSession` exists until the countdown reaches Go.
- **State:** `baselineState(for: mode)` drives which toggle is shown (Step Feedback pre-baseline; Metronome post-baseline); permission state drives Start-button enabled/degraded copy [PRD AC].
- **Domain models:** `TestMode`, `BaselineState`, `SessionAudioConfig`.
- **Error states:** Motion & Fitness denied → inline explanation, Start disabled-with-reason [PRD AC].
- **Watch (Phase 3, §4.18):** one line, "Timer will show on your watch", while the watch app is reachable; nothing otherwise. The Live Activity nudge follows the Walk tab, which holds this screen; the main tab view runs it (§4.18) [PRD §8].

### 4.6 Gait Session Recording
- **Responsibility:** Countdown, then live recording: a 5-second countdown on Start Test [PRD OQ-6], start tone at Go, CMMotionManager + CMPedometer capture, elapsed display, visible Stop button, stop tone on Stop, interruption/suspension handling. [PRD §5, §7]
- **Screens:** full-screen countdown, then full-screen recording cover.
- **State machine:** `countingDown → (cancelled)? → preparing → running → (interrupted → running)* → stopping → handingOffToProcessing`. `countingDown` is the only phase with a non-destructive exit: `cancelled` returns to §4.5 with selections intact, and **no session is created** [PRD §6, §7 AC].
- **Countdown behaviour [PRD OQ-6]:** numerals 5→1 at one per second then "Go"; a haptic tick per numeral with a **perceptibly distinct tick at Go**; a VoiceOver announcement per numeral; an always-reachable Cancel. The visible channel is never suppressed in favour of the haptic one — it is the required fallback, not a redundancy. Sensors prime *during* the countdown; recording, the elapsed clock and the valid-walking timer all begin at **Go (T-0)**, never at the tap.
- **Services:** `SessionRecorder` actor, `AudioFeedbackService` (tones + optional feedback), `HapticFeedbackService` (countdown ticks, stop pulse), `LiveStepDetector`.
- **Edge cases:** phone call/notification, backgrounding/lock, standing still (handled downstream by segmentation), thermal/battery → graceful failure into noisy path [PRD §6]. **During the countdown specifically:** backgrounding or an interruption cancels it (no session, nothing marked invalid); **screen-off does not** — a user locking the phone as they pocket it is the countdown working as intended; haptics unavailable or disabled degrades silently to the visible channel alone, never an error and never a blocked Start.
- **Loading:** sensor priming runs inside the countdown window and must complete before Go ([OPEN], PRD placeholder "[define: priming deadline before zero]"). Priming failure aborts the countdown with a plain-language error **while the screen is still being watched**, rather than failing silently after the phone has been put away [PRD §7 AC].
- **Errors:** sensor failure mid-session → stop cleanly, session invalid, plain-language message.
- **Watch (Phase 3, §4.18):** the haptic owner is fixed when the countdown starts counting; a watch Stop arrives through the same `stop()` as the capsule; losing the watch is never an interruption [PRD §8].

### 4.7 Motion Data Ingestion Engine *(non-UI subsystem)*
- **Responsibility:** Own sensor lifecycle, timestamps, buffering, gap detection, live step-event stream. Detailed in §7.
- **Testability:** fully protocol-fronted; replayable fixture streams.

### 4.8 Signal Processing & Session Validation *(non-UI subsystem)*
- **Responsibility:** Batch pipeline from raw buffer to `GaitMetrics` + `SessionQualityReport`; noisy/insufficient-data classification. Detailed in §8.

### 4.9 Session Result Presentation (Score & Noisy)
- **Responsibility:** Processing screen (brief, on-device) → route to Noisy or Score. [PRD §5]
- **Noisy screen:** plain-language explanation, no score, session marked invalid, does not count toward baseline. [PRD §5]
- **Score screen states:** pre-baseline "Building your {Quick|Full} Test baseline — Session X of 5", no relative index yet — sessions 1–5 instead show a provisional 0–100 score on its own labelled scale, derived from unvalidated `[OPEN]` placeholder anchors and clearly labelled provisional (decisions.md entry 52), raw metrics optional "reference only"; post-baseline relative index (e.g. "112, vs. your baseline of 100"), one-line encouraging summary generated from real same-mode comparisons, tap-to-expand per-signal breakdown (gait consistency, step-time/cadence variability, trunk-motion proxy, asymmetry when present). [PRD §5, §7]
- **Domain models:** `SessionScore`, `MetricBreakdown`, `BaselineState`.
- **Edge cases:** unilateral vs. bilateral breakdown contents [PRD §7]; score language must not imply the baseline is permanently authoritative [PRD §6].

### 4.10 Scoring & Baseline Calibration *(non-UI subsystem)*
- **Responsibility:** Per-mode valid-session counting; baseline creation on the 5th valid session; per-metric stats; SD floor; relative index computation for session 6+. Detailed in §9. [PRD §7, OQ-5]

### 4.11 Step Feedback (Pre-Baseline Audio)
- **Responsibility:** Reactive tick on confidently-detected steps only; off by default; refractory debounce; never implies tempo; low latency. [PRD §5, §7, OQ-4]
- **Detailed in §10.**

### 4.12 Metronome Cue (Post-Baseline Audio)
- **Responsibility:** Steady ticks at interval derived from that mode's baseline cadence; toggle pre-session; only offered session 6+. [PRD §5, §7]
- **Detailed in §10.**

### 4.13 Session History & Trends
- **Responsibility:** List of valid past sessions labeled with mode; mode-relative scores where they exist; Swift Charts trend line, filterable/split by mode; real stored data only. A session recorded with the Metronome Cue on is shown as a distinct marker and left out of the trend line (decisions.md entry 49). [PRD §5, §7]
- **State:** the selected mode — a Quick Test / Full Test segment (`TestMode`), with no "All" (Task 9.1.1). Figma node 64:7837 draws two segments, and the baseline card and trend that share the control are per-mode by nature, so an "All" view would put two baselines under one heading [PRD OQ-5]. Until the user picks a segment, History opens on the mode walked most recently.
- **Empty state:** defined for no sessions and per-mode emptiness.
- **Edge cases:** mode with no baseline shows sessions without relative scores [OPEN: whether calibration sessions get retroactive scores — see §21].

### 4.14 Clinician Summary
- **Responsibility:** Single screen: current baseline(s), last N sessions' scores, trend chart; both modes clearly separated; defined empty/partial states per mode. [PRD §5, §7]
- **Entry point:** the You tab's **Clinician Summary** row [PRD §5: "accessible from History or Settings"] (Task 8.3.1), presented as a modal sheet (§11.2). It is the **only** entry point: the Result tab carries none (decisions.md entry 44).
- **Settled specification (2026-09-14, Task 9.2.1):**
  - **Mode isolation:** a segmented Quick Test / Full Test picker. Each segment shows only that mode's baseline, sessions and trend; every read names its mode [PRD OQ-5].
  - **Current baseline:** establishment date and **μ ± σ** (the stored, floored SD — marked when the floor was applied, with its n) for the metrics with physical units only: cadence (spm), step-time variability (% CV) and step-time asymmetry (%). "Not established" where the baseline carries no stat. No better/worse markers — metric sign conventions are [OPEN].
  - **Last N sessions:** N = 5 **scored** sessions (walk 6 onward), newest first, calibration walks never counted (§21 #9, closed for this screen). Each shows date and time, relative index, signed delta, and the three measured values.
  - **Trend chart:** the History trend, plotting every scored walk of the mode except Metronome Cue sessions, which appear as a distinct marker and are left out of the trend line (decisions.md entry 49).
  - **Objective only:** no provisional scores and no user-facing summary lines.
  - **Empty/partial states per mode:** not started; "Calibrating: X of 5 walks completed"; and a refused baseline, stated cause-neutrally — "Baseline could not be established from the first 5 calibration walks." (decisions.md entry 17).

### 4.15 Settings
- **Responsibility:** Container for Export My Data, Restore from previous export, disclaimer/About access (post-onboarding disclaimer visibility [PRD AC]).
- **Dependencies:** navigation to Backup features; document persistence.
- **Built — the You tab (Task 8.3.1, decisions.md entry 42):** a native inset-grouped list. **Clinician Summary** (sheet) · **Backup & Data:** Export My Data (sheet), Restore from Backup (document picker, then Restore your data full-screen, with the overwrite choice of Task 10.3.3) · **About & Legal:** app name, version and build, and Disclaimer (pushed; `DisclaimerText.body`, verbatim). A store replacement dismisses everything the tab presented, and the router rebuilds the shell around the new store.

### 4.16 Data Export
- **Responsibility:** Passphrase set + confirm with unrecoverable warning; generate encrypted archive (profile, valid sessions, both baselines, preferences, versions, timestamp, integrity check); share via system share sheet; explicit user action only. [PRD §5, §7, OQ-2]
- **State machine:** `passphraseEntry → confirming → warningAck → generating → sharing → done | failed(clean)`.
- **Detailed in §13.**

### 4.17 Data Restore / Import (Settings path)
- **Responsibility:** Same file+passphrase flow as first launch, but existing local data is always present → conflict flow with exactly three choices: **Cancel** (nothing changes) / **Export current data first** (runs Export, then re-presents choice) / **Replace with backup** (validate → decrypt → atomic replace). [PRD §5, OQ-2]
- **Hard invariant:** wrong passphrase / failed validation / interrupted write ⇒ local DB untouched, no crash. [PRD §6, §7]
- **Post-restore:** full in-memory state invalidation and navigation reset (§11, §13).

### 4.18 Watch Companion (Phase 3)
- **Responsibility:** show the session timer on the wrist, play the session haptics when the watch owns them, and offer Stop. Display + haptics + Stop only: no sensing, no scoring, no history [PRD §8].
- **Targets:** a watchOS app target (its own folder, not under `Stabilyz/Stabilyz/`); the phone side lives in `Services/Watch`. The message contract is shared by both targets from `StabilyzShared/WatchSync/` (§16). Nothing watch-related lives in `Domain/` or `Algorithms/`.
- **Screens (watch):** Waiting · Countdown · Running · Stopped · Disconnected, as specified in [PRD §8]. 15 pt minimum text, dark background, navy primary, VoiceOver labels, a VoiceOver announcement per countdown numeral.
- **Watch state machine:** `waiting → countingDown → running ⇄ disconnected → stopped → waiting`; `countingDown → waiting` on cancel. Disconnected is entered from `running` only, keeps the local timer running from T-0, and hides Stop. A reconnect re-syncs to the phone's current state, which may skip straight to `stopped`. **Catch-up** (on launch and on reconnect, from the application context, which keeps the latest `countdownStarted` beside the latest session state; and while connected, when a stored update stays ahead of the watch for 2 s because the live message was lost — a live message within the 2 s wins): rejoins at the current numeral, re-syncs a running walk to `t0`, or shows Stopped; plays no cue for what already happened but every cue after; never moves a session backwards or revives one the watch saw end; ignores a session more than 5 minutes past its planned end. At 00:00 while disconnected the watch moves to `stopped` on its own.
- **Phone side — `WatchSessionService` (protocol, `Services/Watch`):** a reachability stream (also read by §4.5 for the indicator), send of the contract's messages, and an inbound stream of stop requests. `WatchConnectivityService` is the live implementation over `WCSession`; a mock and a silent double (no paired watch) back the tests and the degraded graph. Wired at the composition root like every other service (§12).
- **Messages (versioned, Codable, phone → watch unless noted):** `setupSelection(mode, durationSeconds)` from the setup screen, for Waiting; `countdownStarted(sessionID, mode, duration, plannedGoAt, hapticOwner, hapticsEnabled)` when the countdown starts counting (after priming); `started(sessionID, t0)` at Go with the real anchor; `stopped`, `cancelled`, `hapticsChanged(enabled)`; and `stopRequest(sessionID)` watch → phone. The wire enums are the contract's own and are mapped to `TestMode` inside `Services/Watch`.
- **Haptic ownership:** decided once, from reachability at the moment counting begins, and held by `CountdownCoordinator` for the session. The owner plays the ticks, Go, the Stop pulse and the cancel pulse; the other plays no haptics. Audio is never affected. **Exceptions:** the phone plays the Stop pulse if the owning watch is unreachable at Stop, or if it was reachable but did not confirm `stopped` within the 750 ms reply timeout (a late confirmation can mean two Stop buzzes — accepted as intended); at 00:00 while disconnected the watch also plays `.stop` locally, and the double buzz is accepted; the phone plays the Go pulse if the owning watch did not confirm `started`, so a late confirmation can mean two Go buzzes — accepted as intended. The Start & Stop Haptics setting governs both devices.
- **Stop from the watch:** `stopRequest` is routed into `ActiveSessionViewModel.stop()`, the same entry point as the capsule and the clock reaching 00:00, which already acts once and ignores the rest. A request whose `sessionID` doesn't match the running session is dropped. On the watch, a Stop tap sends one request and disables Stop until the phone answers; with no answer it re-enables after 3 s, or as soon as the phone becomes reachable again, so the user can retry.
- **Keep-alive:** a `WKExtendedRuntimeSession` (physical therapy type, kept; the App Review notes state the rehab/gait-assessment purpose — PRD OQ-7a, decisions.md entry 54). It can only start while the app is active, so it starts at the first chance: when the watch app becomes active on any screen except Stopped, or, while active, when a countdown begins, a walk is joined late, or the phone comes back mid-walk. It ends after Stopped → Done, or once Stopped has sat for 5 minutes without Done. Expiry or invalidation by the system never touches the walk; a new one starts at the next chance.
- **Live Activity nudge:** `Services/LiveActivity` wraps ActivityKit; the activity's UI lives in a widget extension target. It follows the Walk tab: it shows while the Walk tab is in front and the watch app is installed but not reachable, and ends when the watch becomes reachable, when the user leaves the Walk tab, or when the walk stops or the countdown is cancelled or fails. Leaving and returning to the Walk tab shows it again; after a walk or a cancel it waits for that return. It never starts during a walk, and Start never waits on it. Leftovers from an earlier launch are ended at launch. Two activity types, by iOS version: `WatchNudgeAttributes` on iOS 17 (Lock Screen and Dynamic Island, phone only) and `WatchNudgeSmartStackAttributes` on iOS 18 and later, which adds the watch Smart Stack — a widget bundle can't pick between two layouts of one type by OS version. Local only — no push, no notification, no new permission ([OPEN] PRD OQ-7b for watch-side behaviour).
- **Edge cases:** no paired watch / app not installed (no indicator, no nudge, v1 behaviour); unreachable at countdown start (phone owns for the session); drop and reconnect mid-walk; duplicate or late Stop; screen-off and wrist-down on the watch [PRD §6].
