# 23. Engineering Task Breakdown

```
EPIC 1 — App Foundation
  Feature 1.1 Project & CI
    Task 1.1.1 Create Xcode project, targets (app, unit, UI), folder structure (§16)
    Task 1.1.2 Set up CI running tests on simulator
  Feature 1.2 Dependency Injection
    Task 1.2.1 Define service protocols (motion, pedometer, audio, repos, crypto, clock, file, random)
    Task 1.2.2 Build AppDependencies composition root
  Feature 1.3 Observability
    Task 1.3.1 LogService categories + signposter scaffolding

EPIC 2 — Domain & Data Contract
  Feature 2.1 Core Types
    Task 2.1.1 TestMode + SessionPolicy (90s/240s, versioned)
    Task 2.1.2 GaitSession/SessionOutcome/InvalidReason
    Task 2.1.3 GaitMetrics + MetricID registry + direction metadata
    Task 2.1.4 Baseline/BaselineMetricStat/BaselineState
    Task 2.1.5 UserProfile + validation (level/side consistency)          → dep: 2.1.2
  Feature 2.2 Rules & Tests
    Task 2.2.1 Baseline-state machine + tests (5-valid, mode-segregated)
    Task 2.2.2 Error taxonomy + ErrorPresenter mapping

EPIC 3 — Persistence
  Feature 3.1 Store
    Task 3.1.1 Entities + JSON-blob mapping + schema version
    Task 3.1.2 Background ModelActor write path
  Feature 3.2 Repositories
    Task 3.2.1 GaitSessionRepository (mode+validity-filtered queries)      → dep: 3.1.1, 2.1.2
    Task 3.2.2 BaselineRepository (mode-required APIs, unique constraint)  → dep: 3.1.1, 2.1.4
    Task 3.2.3 UserProfileRepository
    Task 3.2.4 In-memory test backing + segregation integration test

EPIC 4 — Motion & Recording
  Feature 4.1 Sensor Services
    Task 4.1.1 MotionSensorService (CoreMotion) → AsyncStream of SensorSample
    Task 4.1.2 PedometerService → AsyncStream of PedometerEvent
    Task 4.1.3 FixtureSensorService + fixture file format + sample fixtures
  Feature 4.2 Recorder
    Task 4.2.1 Time anchors + gap detection                                 → dep: 4.1.1
    Task 4.2.2 SessionRecorder actor lifecycle (begin/stop, priming budget)
    Task 4.2.3 Interruption observation (lifecycle + audio session events)
    Task 4.2.4 RawSessionBuffer freeze + scratch-file behavior
  Feature 4.3 Live Step Detection
    Task 4.3.1 LiveStepDetector (confidence + refractory, config-driven)   → dep: 4.2.1

EPIC 5 — Processing & Algorithms
  Feature 5.1 Pipeline Skeleton
    Task 5.1.1 SessionProcessor actor + GaitScoringAlgorithm contract + version stamping
    Task 5.1.2 AlgorithmConfiguration (all tunables) + DataQualityPolicy
  Feature 5.2 Stages
    Task 5.2.1 Preprocessing (filter, resample, orientation)                → dep: 5.1.1
    Task 5.2.2 WalkingSegmentDetector                                       → dep: 5.2.1
    Task 5.2.3 SignalQualityValidation (mode minimums, noise flag)          → dep: 5.2.2
    Task 5.2.4 Feature extraction: step peaks, step times, autocorrelation, trunk RMS → dep: 5.2.2
    Task 5.2.5 Metric assembly + optional unilateral asymmetry              → dep: 5.2.4
  Feature 5.3 Golden Tests
    Task 5.3.1 Synthetic gait fixtures + golden regression suite            → dep: 5.2.5

EPIC 6 — Baseline & Scoring
  Feature 6.1 Baseline
    Task 6.1.1 BaselineCalculationService (pure) + tests                   → dep: 5.2.5
    Task 6.1.2 Commit-on-5th-valid flow (repo + state broadcast)           → dep: 6.1.1, 3.2.2
  Feature 6.2 Scoring
    Task 6.2.1 SD-floor normalization + direction handling                  → dep: 6.1.1
    Task 6.2.2 Composite scorer v0 + relative index (provisional weights [OPEN])
    Task 6.2.3 MetricBreakdown + encouraging-summary generator v0
    Task 6.2.4 Score persistence on session commit                          → dep: 3.2.1

EPIC 7 — Audio
  Feature 7.1 Tones & Engine
    Task 7.1.1 AVAudioEngine service: start/stop tones, session config
    Task 7.1.2 Route-change/interruption silent degradation
  Feature 7.2 Feedback
    Task 7.2.1 Step Feedback wiring (confidence/refractory, off by default) → dep: 4.3.1, 7.1.1
    Task 7.2.2 Metronome engine (baseline BPM scheduling)                  → dep: 7.1.1, 6.1.2
    Task 7.2.3 Scoring-independence test                                    → dep: 7.2.1/7.2.2

EPIC 8 — Core Flows UI
  Feature 8.1 Routing & Onboarding
    Task 8.1.1 AppRouter phases + tests
    Task 8.1.2 Onboarding wizard + draft persistence + disclaimer gate + resume → dep: 8.1.1, 3.2.3
  Feature 8.2 Session Flow
    Task 8.2.1 Setup screen (mode, audio selector, permission pre-flight, first-session framing) → dep: 6.1.2
    Task 8.2.2 Recording cover (elapsed, stop, tones)                       → dep: 4.2.2, 7.1.1
      ↳ carries EPIC 7 audit finding 2: swap `EngineAudioFeedbackService` into
        `AppDependencies.live()` (and `.storeUnavailable()`), replacing
        `SilentAudioFeedbackService`, and own its `prepare()`/`teardown()`
        lifecycle around the session. Until this lands the app is silent: the
        whole audio epic is unreachable from the production graph, and the suite
        is green only because every audio test constructs the engine directly.
        Do not swap the slot without the lifecycle — `prepare()` activates an
        `AVAudioSession` and something must deactivate it. Delete the stale
        "Task 7.1.1 replaces this" comment at the same time.
    Task 8.2.3 Processing screen + routing to Score/Noisy                   → dep: 5.1.1
    Task 8.2.4 Score screen (building/relative states, expandable signals)  → dep: 6.2.3
      ↳ carries EPIC 6 audit ACs 7/9/10: the building state, the
        "vs. your baseline" rendering, and the provisional framing.
        Screen-level, so unverifiable until this screen exists.
    Task 8.2.5 Noisy screen (plain-language, invalid, no score)
  Feature 8.3 Home
    Task 8.3.1 Home empty/populated + trend snapshot + export nudge         → dep: 8.2.4

EPIC 9 — History & Clinician
  Feature 9.1 History
    Task 9.1.1 Session list (valid-only, mode-labeled, filter)              → dep: 3.2.1
    Task 9.1.2 Swift Charts trend (mode-separated series)                   → dep: 9.1.1
      ↳ carries EPIC 6 audit: trend independence — the two modes render as
        separate series and never share a line [PRD OQ-5].
  Feature 9.2 Clinician Summary
    Task 9.2.1 Summary screen (baselines, last N [OPEN], trend, per-mode empty/partial states) → dep: 9.1.2

EPIC 10 — Backup (Export/Import/Restore)
  Feature 10.1 Crypto & Format
    Task 10.1.1 KDF wrapper (CommonCrypto PBKDF2) + RandomSource            → dep: 2.1.1
    Task 10.1.2 AES-GCM seal/open wrapper (CryptoKit) + key-check value
    Task 10.1.3 Envelope format + Export DTOs + schemaVersion + migration chain → dep: 10.1.2
  Feature 10.2 Export
    Task 10.2.1 Export wizard (passphrase set/confirm, unrecoverable warning)
    Task 10.2.2 Archive generation + share sheet + temp cleanup             → dep: 10.1.3
      ↳ TEST REQUIREMENT, from the EPIC 6 audit: the "never exported" limb of
        the invalid-session rule. An archive built from a store containing
        invalid sessions must contain none of them. The other three limbs
        (never scored, never baseline-counted, never shown in history) are
        covered; this one cannot be tested before an archive exists.
  Feature 10.3 Restore
    Task 10.3.1 Import validation order (decrypt → validate → touch)        → dep: 10.1.3
    Task 10.3.2 First-launch restore path + fallback                        → dep: 10.3.1, 8.1.1
    Task 10.3.3 Settings conflict flow (Cancel/Export-first/Replace)        → dep: 10.2.2
    Task 10.3.4 Atomic replace + snapshot + rollback + state invalidation   → dep: 10.3.1, 3.1.2
    Task 10.3.5 Kill-point atomicity test suite                              → dep: 10.3.4

EPIC 11 — Validation & Release
  Feature 11.1 Test Hardening
    Task 11.1.1 UI-test suite (AC-mapped)
    Task 11.1.2 Integration matrix + log-audit + error-copy audit
  Feature 11.2 Device & TestFlight
    Task 11.2.1 Device campaign + threshold tuning into AlgorithmConfiguration
    Task 11.2.2 KDF calibration + audio latency validation
    Task 11.2.3 TestFlight build + end-to-end no-crash loop verification
```
