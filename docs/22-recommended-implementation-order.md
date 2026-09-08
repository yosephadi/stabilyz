# 22. Recommended Implementation Order

Dependency-aware ordering — algorithm and data-contract work precedes UI polish; the pipeline is buildable against fixtures before any hardware validation.

**Phase 1 — Project Foundation**
Objective: skeleton that builds, runs, logs, and injects.
Tasks: Xcode project + folder structure (§16) · DI composition root + protocols skeleton · LogService + signposts · DesignSystem tokens · CI running unit tests.
Dependencies: none. Output: runnable shell. DoD: app launches to placeholder; test target green. Risks: none material.

**Phase 2 — Domain Models & Policies**
Objective: the PRD data contract as compilable types.
Tasks: `TestMode` + `SessionPolicy` (90 s/240 s) · `GaitSession`/`SessionOutcome`/`GaitMetrics`/`Baseline`/`BaselineState` · `SessionAudioConfig` · error taxonomy · unit tests for validity/baseline-state rules.
Dependencies: Phase 1. DoD: domain layer compiles with zero Apple-framework imports (except Accelerate reserved for Algorithms); rule tests green.

**Phase 3 — Persistence**
Tasks: SwiftData entities + mapping + repositories with mode-keyed APIs · schema version stamp · in-memory test backing · unique-baseline-per-mode constraint test.
Dependencies: Phase 2. DoD: repository round-trip + segregation invariant tests green.

**Phase 4 — Sensor Abstraction & Recording Engine**
Tasks: `MotionSensorService`/`PedometerService` protocols + CoreMotion implementations · time-anchor + gap detection · `SessionRecorder` actor + buffer + scratch file · `FixtureSensorService` + fixture format · interruption/lifecycle observation · start-tone/stop-tone audio service basics.
Dependencies: Phase 2. DoD: recorder produces a frozen `RawSessionBuffer` from fixtures incl. scripted gaps; latency budget instrumented.

**Phase 5 — Session Flow UI (with placeholder processing)**
Tasks: session flow coordinator + setup screen (mode, audio selector states, permission pre-flight) · recording cover · processing screen with stub outcome · noisy/score stub screens · onboarding wizard + draft persistence + disclaimer gate · root router.
Dependencies: Phases 3–4. DoD: full human flow runnable with fixture sensor; onboarding resume test passes.

**Phase 6 — Signal Processing Pipeline**
Tasks: preprocessing (filter/resample/orientation) · walking-segment detector · signal-quality validation (mode minimums + noise threshold config) · feature extraction (step peaks, autocorrelation Ad1/Ad2, trunk RMS) · metric assembly incl. optional asymmetry · golden-file tests.
Dependencies: Phase 4 (buffer contract). DoD: fixture sessions produce metrics + correct valid/invalid classification; stage signposts recorded.

**Phase 7 — Baseline & Scoring**
Tasks: `BaselineCalculationService` · baseline commit-on-5th-valid flow · SD-floor normalization · composite scorer v0 with provisional weights [OPEN-flagged] · relative-index mapping v0 · `algorithmVersion` stamping everywhere · encouraging-summary generator v0.
Dependencies: Phases 3, 6. DoD: 5-valid-then-6th integration test shows "X of 5" → baseline → relative index; segregation tests green.

**Phase 8 — Audio Feedback**
Tasks: `AudioFeedbackService` on AVAudioEngine · `LiveStepDetector` + confidence/refractory · Step Feedback wiring (off by default, first-session framing) · Metronome engine (baseline BPM) · route/interruption handling · spy tests.
Dependencies: Phases 4, 7 (metronome needs baseline). DoD: PRD audio ACs pass in tests; scoring independence asserted.

**Phase 9 — Home, History, Trends, Clinician Summary**
Tasks: Home states + nudge · history list + filtering + Charts trend (mode-separated series) · clinician summary with per-mode empty/partial states · real-data-only assertions.
Dependencies: Phases 3, 5, 7. DoD: ACs for history/trend/clinician screens pass against seeded store.

**Phase 10 — Export / Import / Encryption / Restore**
Tasks: crypto wrappers (PBKDF2 + AES-GCM) · envelope format + DTOs + schema version + migrations · export wizard + passphrase warning + share sheet · import paths (first-launch + Settings) + conflict dialog · **atomic restore + snapshot + kill-point tests** · post-restore state invalidation.
Dependencies: Phases 2, 3 (DTO contract, store). DoD: PRD crypto/restore ACs pass, including atomicity failure injection.

**Phase 11 — Testing Hardening & Observability Pass**
Tasks: full UI-test suite · integration matrix · log-audit sweep (no sensitive data) · error-copy audit.
Dependencies: Phases 5–10. DoD: all AC-mappable tests automated.

**Phase 12 — Device Validation & TestFlight**
Tasks: physical-device session campaign incl. prosthetic-user testers if available · threshold tuning (noise/floor/valid-walking — feed back into `AlgorithmConfiguration`, not code) · KDF calibration · audio latency/route testing · TestFlight build + loop AC verification (no crash end-to-end) [PRD §2, §7].
Dependencies: all. DoD: PRD "Define Success" criteria met.
