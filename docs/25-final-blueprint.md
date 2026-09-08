# 25. Final Technical Blueprint

```text
                    ┌────────────────────────────┐
                    │      SwiftUI Views         │
                    │  (Session, Score, History, │
                    │   Clinician, Settings, …)  │
                    └─────────────┬──────────────┘
                                  ↓
                    ┌────────────────────────────┐
                    │  Feature State (@Observable│
                    │  VMs + AppRouter +         │
                    │  SessionFlowCoordinator)   │
                    └─────────────┬──────────────┘
                                  ↓
                    ┌────────────────────────────┐
                    │  Domain (pure)             │
                    │  entities · validity rules │
                    │  baseline rules · scoring  │
                    │  contracts · errors        │
                    └──────┬───────────────┬─────┘
                           ↓               ↓
        ┌────────────────────┐   ┌─────────────────────────┐
        │ SessionRecorder    │   │ SessionProcessor (actor)│
        │ (actor)            │   └────────────┬────────────┘
        │  motion stream ·   │                ↓
        │  pedometer · gaps ·│   ┌─────────────────────────┐
        │  live step events  │   │ Algorithms (pure,       │
        └───┬──────────┬─────┘   │ versioned)              │
            ↓          ↓         │ preprocess → segment →  │
      CoreMotion   AudioFeedback │ quality → features →    │
      CMPedometer  (AVAudioEngine│ metrics → normalize →   │
                    tones/ticks/ │ composite score         │
                    metronome)   └────────────┬────────────┘
                                           ↓
                              ┌─────────────────────────┐
                              │ Repositories (SwiftData)│
                              │ sessions · baselines ·  │
                              │ profile (mode-keyed)    │
                              └────────────┬────────────┘
                                           ↓
                              Score → History/Trends → Clinician
                                           ↕
                              SecureArchive (PBKDF2 + AES-GCM)
                              encrypted export ↔ atomic restore
```

### Recommended Architecture

SwiftUI + `@Observable` MVVM, feature-first and strictly layered: thin views over per-feature observable view models; all gait science in a pure, versioned `Algorithms` module executed by a background actor over a frozen session buffer; per-mode baselines and validity enforced in a framework-free domain layer and a mode-keyed SwiftData persistence layer; hardware (Core Motion, AVFoundation) and crypto (CryptoKit + CommonCrypto) isolated behind protocols at a single composition root; enum-driven navigation making the PRD's state-dependent routing (first-launch/restore, disclaimer gate, baseline states, noisy routing) an explicit, testable state machine; encrypted self-describing export archives with staged validation and transactional, snapshot-backed atomic restore.

### Core Technologies

| Technology | Role |
|---|---|
| iOS 17+ / Swift 5.10 (strict concurrency) | Platform & language floor [PRD] |
| SwiftUI + Observation | UI + feature state |
| SwiftData (+ UserDefaults for onboarding draft) | Persistence |
| Swift Charts | History/trend/clinician charts |
| Core Motion (MotionManager, Pedometer, Activity) | Sensor acquisition |
| Accelerate/vDSP | DSP (filtering, autocorrelation) |
| AVFoundation / AVAudioEngine | Tones, Step Feedback, Metronome |
| CryptoKit (AES-GCM) + CommonCrypto (PBKDF2) | Export encryption |
| os (Logger/OSSignposter) | Observability |
| XCTest / XCUITest | Testing |
| Third-party dependencies | **None** |

### Core Modules

| Module | Responsibility |
|---|---|
| `App` | Composition root, router, lifecycle |
| `Features/*` | Nine feature modules (§4) |
| `Domain` | Entities, rules, contracts, errors — pure |
| `Algorithms/GaitAnalysis` | DSP → metrics → scoring pipeline — pure, versioned |
| `Services/Motion+Recording` | Sensor abstraction, recorder actor, live step detection |
| `Services/Processing` | Pipeline orchestration actor |
| `Services/Audio` | Feedback/tones/metroome engine |
| `Services/Archive+Crypto` | Export/import/restore, encryption |
| `Persistence` | SwiftData entities, repositories, mode-keyed queries |
| `DesignSystem`, `Utilities` | Shared UI kit, clock/file/random abstractions |

### Most Important Technical Decisions

1. Algorithms/domain are framework-free and versioned — the PRD's open formula and tunable thresholds stay swappable.
2. Recording is an actor over protocol-fronted sensor streams with explicit gap policy — no silent clean scores.
3. Baselines are mode-keyed, frozen after 5 valid same-mode sessions — segregation is compile-time + store-level enforced.
4. Export is a self-describing PBKDF2 + AES-GCM envelope; restore validates fully before touching data and replaces transactionally with snapshot recovery — atomicity is a tested hard requirement.
5. Audio feedback is fully decoupled from and incapable of altering the batch scoring path.
6. Zero third-party dependencies; manual DI at a composition root.

### Implementation Starting Point (first 10 tasks)

1. Project skeleton + folder structure + CI (Epic 1.1).
2. Service protocol set + `AppDependencies` composition root (1.2).
3. `TestMode` + versioned `SessionPolicy`/`AlgorithmConfiguration` (2.1.1).
4. Domain entities: `GaitSession`/`SessionOutcome`/`GaitMetrics`/`Baseline`/`BaselineState` (2.1.2–2.1.4).
5. SwiftData entities, mapping, mode-keyed repositories + in-memory test backing (3.1, 3.2).
6. `MotionSensorService`/`PedometerService` protocols, CoreMotion implementations, fixture format + first fixtures (4.1).
7. `SessionRecorder` actor with time anchors, gap detection, buffer freeze (4.2).
8. `GaitScoringAlgorithm` contract + `SessionProcessor` actor skeleton with progress events (5.1).
9. `AppRouter` + onboarding wizard with draft persistence and disclaimer hard gate (8.1).
10. Baseline-state machine + calculation service with mode-segregation tests (2.2.1, 6.1.1) — locking the PRD's most safety-critical invariant in before any scoring code exists.

---

*End of Technical Design Document. All [OPEN] items in §21.3 should be confirmed with the product owner (per PRD convention, "Adi") before or during the corresponding implementation phase; none have been silently resolved in this document.*
