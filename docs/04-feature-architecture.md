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
- **Responsibility:** Progressive single-field screens: amputation level → side → time since amputation → device type (optional) → K-level (optional) → disclaimer with required checkbox. [PRD §5, §7]
- **Screens:** field wizard + final disclaimer screen; "Why we ask" microcopy on level/side [PRD AC].
- **State:** `OnboardingDraft` persisted across relaunch (incl. final screen pre-tick) [PRD §6].
- **Models:** `UserProfile` draft, `AmputationLevel`, `AffectedSide`.
- **Validation:** required fields completable without optionals [PRD AC]; level/side consistency (bilateral ⇒ both) [REC].
- **Navigation:** hard gate — no Home without disclaimer tick; no silent failure [PRD §6].
- **Edge cases:** bilateral selection fully supported; force-quit resume.

### 4.4 Home / Dashboard
- **Responsibility:** Empty state ("Run your first Gait Training session") pre-first-session; afterwards latest score + trend snapshot + "Start Gait Training"; export nudge after first baseline established. [PRD §5, §6] *(Home was superseded by Walk / Result / You, §11.1. The export nudge is the Walk tab's one-time backup card: §21 #11, decisions.md entry 43, Task 10.2.3.)*
- **State:** derived from repositories (latest valid scored session per mode, session counts); `emptyState`/`populated`.
- **Dependencies:** `GaitSessionRepository`, `BaselineRepository`; navigation intent into session flow.
- **Error states:** persistence read failure → generic retry state.
- **Edge cases:** latest session invalid → show last *valid* [PRD: history lists valid]; baseline in one mode only → snapshot reflects that mode.

### 4.5 Gait Test Configuration (Session Setup)
- **Responsibility:** Mode selection (Quick 2-min / Full 6-min) [PRD AC]; audio feedback selector whose contents depend on that mode's baseline existence [PRD §5]; first-session "walk normally — there's no target pace" framing [PRD AC]; permission pre-flight; user instructions (straight-line walking; phone placement guidance [REC — placement is OPEN, see §21]).
- **Start action:** the Start Test button **begins the countdown, not the session** [PRD OQ-6]. It hands the selected `TestMode` and `SessionAudioConfig` to §4.6's `countingDown` phase; no `GaitSession` exists until the countdown reaches Go.
- **State:** `baselineState(for: mode)` drives which toggle is shown (Step Feedback pre-baseline; Metronome post-baseline); permission state drives Start-button enabled/degraded copy [PRD AC].
- **Domain models:** `TestMode`, `BaselineState`, `SessionAudioConfig`.
- **Error states:** Motion & Fitness denied → inline explanation, Start disabled-with-reason [PRD AC].

### 4.6 Gait Session Recording
- **Responsibility:** Countdown, then live recording: a 5-second countdown on Start Test [PRD OQ-6], start tone at Go, CMMotionManager + CMPedometer capture, elapsed display, visible Stop button, stop tone on Stop, interruption/suspension handling. [PRD §5, §7]
- **Screens:** full-screen countdown, then full-screen recording cover.
- **State machine:** `countingDown → (cancelled)? → preparing → running → (interrupted → running)* → stopping → handingOffToProcessing`. `countingDown` is the only phase with a non-destructive exit: `cancelled` returns to §4.5 with selections intact, and **no session is created** [PRD §6, §7 AC].
- **Countdown behaviour [PRD OQ-6]:** numerals 5→1 at one per second then "Go"; a haptic tick per numeral with a **perceptibly distinct tick at Go**; a VoiceOver announcement per numeral; an always-reachable Cancel. The visible channel is never suppressed in favour of the haptic one — it is the required fallback, not a redundancy. Sensors prime *during* the countdown; recording, the elapsed clock and the valid-walking timer all begin at **Go (T-0)**, never at the tap.
- **Services:** `SessionRecorder` actor, `AudioFeedbackService` (tones + optional feedback), `HapticFeedbackService` (countdown ticks, stop pulse), `LiveStepDetector`.
- **Edge cases:** phone call/notification, backgrounding/lock, standing still (handled downstream by segmentation), thermal/battery → graceful failure into noisy path [PRD §6]. **During the countdown specifically:** backgrounding or an interruption cancels it (no session, nothing marked invalid); **screen-off does not** — a user locking the phone as they pocket it is the countdown working as intended; haptics unavailable or disabled degrades silently to the visible channel alone, never an error and never a blocked Start.
- **Loading:** sensor priming runs inside the countdown window and must complete before Go ([OPEN], PRD placeholder "[define: priming deadline before zero]"). Priming failure aborts the countdown with a plain-language error **while the screen is still being watched**, rather than failing silently after the phone has been put away [PRD §7 AC].
- **Errors:** sensor failure mid-session → stop cleanly, session invalid, plain-language message.

### 4.7 Motion Data Ingestion Engine *(non-UI subsystem)*
- **Responsibility:** Own sensor lifecycle, timestamps, buffering, gap detection, live step-event stream. Detailed in §7.
- **Testability:** fully protocol-fronted; replayable fixture streams.

### 4.8 Signal Processing & Session Validation *(non-UI subsystem)*
- **Responsibility:** Batch pipeline from raw buffer to `GaitMetrics` + `SessionQualityReport`; noisy/insufficient-data classification. Detailed in §8.

### 4.9 Session Result Presentation (Score & Noisy)
- **Responsibility:** Processing screen (brief, on-device) → route to Noisy or Score. [PRD §5]
- **Noisy screen:** plain-language explanation, no score, session marked invalid, does not count toward baseline. [PRD §5]
- **Score screen states:** pre-baseline "Building your {Quick|Full} Test baseline — Session X of 5", no relative score, raw metrics optional "reference only"; post-baseline relative index (e.g. "112, vs. your baseline of 100"), one-line encouraging summary generated from real same-mode comparisons, tap-to-expand per-signal breakdown (gait consistency, step-time/cadence variability, trunk-motion proxy, asymmetry when present). [PRD §5, §7]
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
- **Responsibility:** List of valid past sessions labeled with mode; mode-relative scores where they exist; Swift Charts trend line, filterable/split by mode; real stored data only. [PRD §5, §7]
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
  - **Trend chart:** the History trend, plotting every scored walk of the mode.
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
