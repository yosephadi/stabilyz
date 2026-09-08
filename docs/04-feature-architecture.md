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
- **Responsibility:** Empty state ("Run your first Gait Training session") pre-first-session; afterwards latest score + trend snapshot + "Start Gait Training"; export nudge after first baseline established. [PRD §5, §6]
- **State:** derived from repositories (latest valid scored session per mode, session counts); `emptyState`/`populated`.
- **Dependencies:** `GaitSessionRepository`, `BaselineRepository`; navigation intent into session flow.
- **Error states:** persistence read failure → generic retry state.
- **Edge cases:** latest session invalid → show last *valid* [PRD: history lists valid]; baseline in one mode only → snapshot reflects that mode.

### 4.5 Gait Test Configuration (Session Setup)
- **Responsibility:** Mode selection (Quick 2-min / Full 6-min) [PRD AC]; audio feedback selector whose contents depend on that mode's baseline existence [PRD §5]; first-session "walk normally — there's no target pace" framing [PRD AC]; permission pre-flight; user instructions (straight-line walking; phone placement guidance [REC — placement is OPEN, see §21]).
- **State:** `baselineState(for: mode)` drives which toggle is shown (Step Feedback pre-baseline; Metronome post-baseline); permission state drives Start-button enabled/degraded copy [PRD AC].
- **Domain models:** `TestMode`, `BaselineState`, `SessionAudioConfig`.
- **Error states:** Motion & Fitness denied → inline explanation, Start disabled-with-reason [PRD AC].

### 4.6 Gait Session Recording
- **Responsibility:** Live recording: start tone on Start, CMMotionManager + CMPedometer capture, elapsed display, visible Stop button, stop tone on Stop, interruption/suspension handling. [PRD §5, §7]
- **Screens:** full-screen recording cover.
- **State machine:** `preparing → running → (interrupted → running)* → stopping → handingOffToProcessing`.
- **Services:** `SessionRecorder` actor, `AudioFeedbackService` (tones + optional feedback), `LiveStepDetector`.
- **Edge cases:** phone call/notification, backgrounding/lock, standing still (handled downstream by segmentation), thermal/battery → graceful failure into noisy path [PRD §6].
- **Loading:** sensor priming must complete within the start-latency target ([OPEN], PRD placeholder "[define: e.g. 1 second]").
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
- **State:** `HistoryFilter { all, quick, full }`.
- **Empty state:** defined for no sessions and per-mode emptiness.
- **Edge cases:** mode with no baseline shows sessions without relative scores [OPEN: whether calibration sessions get retroactive scores — see §21].

### 4.14 Clinician Summary
- **Responsibility:** Single screen: current baseline(s), last N sessions' scores, trend chart; both modes clearly separated; defined empty/partial states per mode. [PRD §5, §7]
- **Entry points:** from History and Settings [PRD §5]. N is [OPEN].

### 4.15 Settings
- **Responsibility:** Container for Export My Data, Restore from previous export, disclaimer/About access (post-onboarding disclaimer visibility [PRD AC]).
- **Dependencies:** navigation to Backup features; document persistence.

### 4.16 Data Export
- **Responsibility:** Passphrase set + confirm with unrecoverable warning; generate encrypted archive (profile, valid sessions, both baselines, preferences, versions, timestamp, integrity check); share via system share sheet; explicit user action only. [PRD §5, §7, OQ-2]
- **State machine:** `passphraseEntry → confirming → warningAck → generating → sharing → done | failed(clean)`.
- **Detailed in §13.**

### 4.17 Data Restore / Import (Settings path)
- **Responsibility:** Same file+passphrase flow as first launch, but existing local data is always present → conflict flow with exactly three choices: **Cancel** (nothing changes) / **Export current data first** (runs Export, then re-presents choice) / **Replace with backup** (validate → decrypt → atomic replace). [PRD §5, OQ-2]
- **Hard invariant:** wrong passphrase / failed validation / interrupted write ⇒ local DB untouched, no crash. [PRD §6, §7]
- **Post-restore:** full in-memory state invalidation and navigation reset (§11, §13).
