# 16. Project / Folder Structure

```text
Stabilyz/
├── App/                        # Composition root, app lifecycle, router root
│   ├── StabilyzApp             # Entry point; builds AppDependencies
│   ├── AppDependencies         # DI container (concrete wiring only here)
│   └── AppRouter               # Root phase state machine
├── Features/                   # One folder per feature (§4 boundaries)
│   ├── FirstLaunch/            # Welcome + first-launch restore flow
│   ├── Onboarding/             # Wizard, disclaimer gate, draft persistence
│   ├── Home/                   # Dashboard, empty state, export nudge
│   ├── Session/                # Setup (mode+audio), Recording, Processing, Result (Score/Noisy)
│   ├── History/                # Session list + trend chart + filtering
│   ├── ClinicianSummary/       # Single summary screen
│   ├── Settings/               # Container + About/Disclaimer access
│   └── Backup/                 # Export wizard, Restore flow, conflict dialog
├── Domain/                     # Pure Swift — no Apple frameworks
│   ├── Models/                 # GaitSession, Baseline, TestMode, GaitMetrics, UserProfile,
│   │                           # RawSessionBuffer + sample-series value types (§3: the
│   │                           # pipeline contract names them, so they cannot sit in Services)
│   ├── Baseline/               # BaselineCalculationService, BaselineState
│   ├── Scoring/                # GaitScoringAlgorithm contract, score types
│   ├── Policies/               # SessionPolicy / DataQualityPolicy value types (tunable)
│   ├── Errors/                 # StabilyzError taxonomy
│   └── Export/                 # Archive DTOs, schema versions, migration contracts
├── Algorithms/                 # Pure Swift + Accelerate — the gait science
│   ├── GaitAnalysis/
│   │   ├── Preprocessing/      # Filtering, resampling, orientation
│   │   ├── Segmentation/       # Walking segment detector
│   │   ├── Quality/            # Signal quality validation
│   │   ├── Features/           # Step detection, autocorrelation (Ad1/Ad2), trunk RMS
│   │   ├── Metrics/            # GaitMetrics assembly, variability, asymmetry
│   │   └── Scoring/            # Baseline normalization, composite, versioning
│   └── AlgorithmConfiguration  # Versioned tunables (thresholds, floors, weights)
├── Services/                   # Protocol-fronted Apple framework adapters
│   ├── Motion/                 # CoreMotion sensor + pedometer services, LiveStepDetector
│   ├── Recording/              # SessionRecorder actor, sample buffer, interruption observer
│   ├── Processing/             # SessionProcessor actor (orchestrates Algorithms)
│   ├── Audio/                  # AudioFeedbackService (tones, step ticks, metronome)
│   ├── Archive/                # SecureArchiveService (export/import/restore orchestration)
│   ├── Crypto/                 # KDF + AEAD wrappers (CommonCrypto + CryptoKit)
│   └── Logging/                # LogService, signposts
├── Persistence/                # SwiftData layer
│   ├── Entities/               # UserProfileEntity, GaitSessionEntity, BaselineEntity
│   ├── Repositories/           # Profile/session/baseline repositories + mappers
│   └── StoreContainer          # Container setup, schema version, background ModelActor
├── DesignSystem/               # Colors, typography, shared components, accessible styles
├── Utilities/                  # Clock, FileIO, RandomSource, time anchors, extensions
└── Tests/  (+ UITests target)
    ├── UnitTests/              # Domain, Algorithms, Crypto, Policies
    ├── IntegrationTests/       # Persistence, session pipeline, restore atomicity
    ├── Fixtures/               # Recorded/synthetic sensor captures
    └── UITests/                # Flow tests (§19.3)
```

**Future extraction into local Swift Packages (in order of value):**
1. `GaitAnalysisKit` (Algorithms) — the scientific core; pure, ideal package boundary, reusable in tooling for offline threshold tuning.
2. `SecureArchiveKit` (Crypto + Archive DTOs) — self-contained crypto/serialization contract.
3. `PersistenceKit` — store + repositories behind protocols.
4. `DesignSystem` — shared UI kit.
Feature folders stay app-internal until a second consumer exists [PRD Rule 13: no premature abstraction].
