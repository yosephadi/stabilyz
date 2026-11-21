# 16. Project / Folder Structure

```text
Stabilyz/                       # app source (Stabilyz/Stabilyz/ in the repo)
├── App/                        # Composition root, app lifecycle, router root
│   ├── StabilyzApp             # Entry point; builds AppDependencies
│   ├── AppDependencies (+Export, +Restore, UnwiredDependencies)  # DI container
│   └── AppRouter               # Root phase state machine
├── Features/                   # One folder per feature (§4 boundaries)
│   ├── Welcome/ + Splash/      # First launch (welcome, restore entry) and splash
│   ├── Onboarding/             # Wizard, disclaimer gate, draft persistence
│   ├── Main/                   # MainShellView: the Walk / Result / You tabs
│   ├── Session/                # Setup, Countdown, Recording, Processing, Result (Score/Noisy)
│   ├── History/                # Session list + trend chart
│   ├── ClinicianSummary/       # Single summary screen
│   ├── Settings/               # The You tab: Settings + About/Disclaimer access
│   ├── Backup/                 # Export wizard, Restore flow, export nudge
│   └── Shared/                 # DisclaimerText, ErrorPresenter
├── Domain/                     # Pure Swift — no Apple frameworks (Foundation only)
│   ├── Models/                 # GaitSession, TestMode, GaitMetrics, UserProfile, MetronomeCue,
│   │                           # RawSessionBuffer + sample-series value types (§3)
│   ├── Baseline/               # BaselineCalculationService, BaselineState, state machine
│   ├── Scoring/                # GaitScoringAlgorithm contract, score and summary types
│   ├── Policies/               # SessionPolicy, CountdownPolicy and other tunable value types
│   └── Errors/                 # StabilyzError taxonomy
├── Algorithms/                 # Pure Swift (Accelerate permitted, not used) — the gait science
│   ├── GaitAnalysis/           # Ingestion, SessionLeadIn, Preprocessing, WalkingSegmentDetector,
│   │   │                       # SignalQualityValidation, FeatureExtraction, MetricAssembly, pipeline
│   │   └── Scoring/            # BaselineNormalization, CompositeScorer, IntrinsicScorer
│   └── AlgorithmConfiguration  # Versioned tunables (thresholds, floors, weights)
├── Services/                   # Protocol-fronted Apple framework adapters
│   ├── Motion/                 # CoreMotion sensor + pedometer services, LiveStepDetector
│   ├── Recording/              # SessionRecorder actor, sample buffer, interruption observer
│   ├── Processing/             # SessionProcessor actor (orchestrates Algorithms)
│   ├── Audio/                  # AudioFeedbackService (tones, step ticks, metronome)
│   ├── Haptics/                # HapticFeedbackService (UIKit tick, CoreHaptics Go/Stop)
│   ├── Archive/                # Export/import/restore, archive format and schema
│   ├── Crypto/                 # KDF + AEAD wrappers (CommonCrypto + CryptoKit)
│   ├── Watch/                  # WatchSessionService + WatchConnectivityService (Phase 3)
│   ├── LiveActivity/           # ActivityKit wrapper for the watch nudge (Phase 3)
│   ├── Logging/                # LogService, redaction
│   └── System/                 # Build info, system settings link, hardware benchmark
├── Persistence/                # SwiftData layer
│   ├── Entities/               # Entities (profile, session, baseline) + store payloads
│   ├── Repositories/           # Profile/session/baseline repositories (protocol + SwiftData)
│   └── StoreContainer, StoreReader, StoreWriter, StoreReplacing, EntityMapping, …
├── DesignSystem/               # Colors, typography, spacing, motion, chart tokens, shared styles
├── Utilities/                  # Clock, FileIO, RandomSource, security-scoped access, countdown ticker
└── Debug/                      # Diagnostics view, UI-test launch hooks, debug reset
```

Tests are separate targets beside the app folder, not a `Tests/` folder inside it: `Stabilyz/StabilyzTests/` (flat, with a `Goldens/` folder of regression fixtures) and `Stabilyz/StabilyzUITests/` (flow tests, §19.3).

**Phase 3 targets (watch companion, docs/04 §4.18).** Siblings of `Stabilyz/Stabilyz/`, created by the user in Xcode (the project file is never edited by hand):

```text
Stabilyz/
├── StabilyzWatch Watch App/    # watchOS app target: the five screens, state machine,
│                               # extended runtime session, haptics (WatchKit lives here only)
├── StabilyzWatch Watch AppTests/ and StabilyzWatch Watch AppUITests/
├── StabilyzLiveActivityExtension/  # widget extension target: the Live Activity's UI
└── StabilyzShared/
    └── WatchSync/              # versioned Codable message contract, Foundation only,
                                # member of both the iOS app and the watch target
```

Watch tests live with the watch target; SourceGuardTests scans these folders too.

**Future extraction into local Swift Packages (in order of value):**
1. `GaitAnalysisKit` (Algorithms) — the scientific core; pure, ideal package boundary, reusable in tooling for offline threshold tuning.
2. `SecureArchiveKit` (Crypto + Archive DTOs) — self-contained crypto/serialization contract.
3. `PersistenceKit` — store + repositories behind protocols.
4. `DesignSystem` — shared UI kit.
Feature folders stay app-internal until a second consumer exists [PRD Rule 13: no premature abstraction].
