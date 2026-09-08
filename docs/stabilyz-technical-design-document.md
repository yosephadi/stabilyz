# Stabilyz — Technical Design Document

**iOS Application for Self-Directed Gait Stability Measurement in Prosthetic Limb Users**

**Status:** Draft v1.0 — for engineering implementation
**Source of truth:** *Stabilyz PRD (stabilyz-prd.md)*
**Target:** TestFlight, physical iPhone, iOS 17+

---

## Document Conventions

| Marker | Meaning |
|---|---|
| **[PRD]** | Directly required by the PRD — non-negotiable |
| **[REC]** | Technical recommendation / assumption where the PRD leaves implementation open |
| **[OPEN]** | Deliberately unresolved by the PRD — must not be silently closed by engineering |

The PRD references in this document use `PRD §n` for numbered PRD sections and `PRD OQ-n` for the resolved Open Questions at the end of the PRD.

---

# 1. Product & Technical Context

## 1.1 Purpose

Stabilyz is a **local-only, offline, single-user iOS app** that lets a lower-limb prosthetic user run self-directed walking tests (2-minute Quick Test / 6-minute Full Test) using iPhone motion sensors, and receive a **relative stability index against their own per-mode baseline** (baseline = 100). The product's core value is converting subjective gait perception into an objective number. [PRD §1, §4]

## 1.2 Primary & Secondary Users

| User | Interaction model |
|---|---|
| Primary: self-directed lower-limb prosthetic user (transtibial / transfemoral / bilateral; ambulatory; wide age range; not assumed tech-savvy) | Owns the device, runs all flows personally |
| Secondary: prosthetist / PT | Never uses the app; views the single Clinician Summary screen in person |

No accounts, no login, no backend, no automatic cloud sync. Data is local by default; a manual encrypted export is the only backup/transfer mechanism. [PRD §3]

## 1.3 Core Product Loop

```
Onboard (or Restore)
   → Start Gait Training → pick mode (Quick / Full) → optional audio opt-in
   → Record 2/6-min walk (CMMotionManager + CMPedometer)
   → Stop → on-device processing
   → Noisy path (invalid, no score)  OR  Score
        ├── Sessions 1–5 of mode: "Building baseline — X of 5"
        └── Session 6+: relative index vs. that mode's baseline
   → Saved to History (mode-tagged) → Trends → Clinician Summary
   → Periodic encrypted export (user-initiated) for backup / device transfer
```

## 1.4 Major Features (from PRD §5)

Onboarding wizard (resumable, disclaimer hard-gate) · First-launch Restore · Home/Dashboard · Mode selection · Step Feedback (pre-baseline, opt-in, off by default) · Metronome cue (post-baseline, baseline cadence) · Session recording with start/stop tones · On-device processing · Noisy/insufficient-data path · Relative score screen with per-signal breakdown · Per-mode 5-session baseline calibration · History + Swift Charts trend (mode-separated) · Clinician Summary · Settings · Encrypted export · Passphrase-validated atomic restore.

## 1.5 Major Technical Capabilities Required

| Capability | PRD source |
|---|---|
| High-rate accelerometer (trunk) sampling + pedometer co-recording | §5 Session In Progress |
| Real-time, confidence-gated step detection (for Step Feedback) with refractory debounce | §6 Step Feedback edge cases; OQ-4 |
| Offline batch DSP: walking-segment detection, signal-quality validation, autocorrelation (Ad1/Ad2), variability, trunk-motion proxy, optional unilateral asymmetry | §7 Scoring & baseline ACs |
| Per-mode baseline statistics with SD floor; relative index scoring | §7; OQ-5 |
| Encrypted portable archive: PBKDF2 + unique salt + AES-GCM + embedded version/KDF metadata | §5 Settings; OQ-2 |
| Atomic restore (replace, never merge) with pre-validation | §6 Data & storage; OQ-2 |
| Resumable onboarding incl. pre-checkbox quit | §6 Onboarding |
| Interruption/suspension handling that never yields a fake-clean score | §6 Session recording |
| Motion & Fitness permission degradation on Start button | §6, §7 |

## 1.6 In Scope vs. Out of Scope

**In scope [PRD §5, §7]:** everything in §1.4 above; both test modes; bilateral as fully supported (minus the unilateral secondary asymmetry feature); export nudge after first baseline; disclaimer accessible post-onboarding.

**Explicitly out of scope for v1 [PRD §5]:** HealthKit passive tracking · threshold-based recommendations · turn detection · socket-fit tagging · cohort benchmarking · structured clinician export (PDF) · automatic merge on import · recalibration/re-baselining · cloud sync / backend / accounts · clinical validation · App Store polish. **No technical architecture below should assume any of these exist.**

## 1.7 Product Constraints

- iOS 17+, physical iPhone, TestFlight distribution. [PRD §7 Build/deployment]
- All processing on-device, no network call during session processing. [PRD §5]
- No custom cryptography. [PRD §7 Data export & import]
- Composite score is **not** calibrated for real-world percentage claims — relative index only. [PRD §7]
- The composite formula, noise thresholds, and several algorithm parameters are deliberately open in the PRD and must remain swappable. [PRD OQ-1, OQ-3]

## 1.8 Edge Cases with Architectural Impact

| Edge case | Architectural implication |
|---|---|
| Backgrounding/lock mid-session | Suspension creates an un-backfillable sensor gap → gap policy + session flagging; never silent clean score [PRD §6] |
| Call/notification interruption | Pause-with-gap-exclusion or invalidate; recording must not produce corrupted "clean" data [PRD §6] |
| Standing still mid-session | Non-walking segments detected and excluded from valid-walking duration and from scoring [PRD §6] |
| Mostly-turns session | User instruction only (no turn detection v1); copy lives in session setup [PRD §6] |
| Bluetooth audio drop | Audio degrades silently to speaker or stops; session recording unaffected [PRD §6] |
| Wrong passphrase / corrupted / future-version export | Distinguish where possible; existing local DB untouched; no crash [PRD §6] |
| One mode baselined, other mode never run | Per-mode baseline state machine; "Session 1 of 5" restart per mode [PRD §6 Baseline] |
| Bilateral user | No asymmetry metric fabricated; score from the three universal signals only [PRD §7] |
| Onboarding quit on disclaimer screen | Persisted onboarding draft incl. disclaimer step [PRD §6] |

## 1.9 Acceptance Criteria with Direct Architectural Implications

These ACs are hard constraints on the architecture (full list is in PRD §7; these are the ones that shape structure):

1. **Atomic restore is a hard requirement** — failure at any stage (decrypt, validate, write) leaves local data byte-identical.
2. **Mode segregation is systemic** — baselines, session counts, and trend data never blend Quick/Full; a `mode` key exists on both session and baseline entities [PRD OQ-5].
3. **Crypto envelope is self-describing** — salt, nonce, KDF params, schema/crypto version embedded in the export file.
4. **Decryption → validation → data-touch ordering** on every restore.
5. **Relative index only post-baseline** — score presentation is baseline-state-driven, per mode.
6. **Noisy sessions never scored, never baseline-counted, never in history list, never exported.**
7. **Score is multi-signal** — gait consistency is one input, never the sole basis; trunk-motion proxy stays independent of regularity computation [PRD OQ-1].
8. **Terminology enforcement** — user-facing "gait consistency"; "asymmetry" reserved strictly for the unilateral limb comparison [PRD OQ-1].
9. **Start-button permission degradation** — Motion & Fitness state must be checkable before session start.
10. **Onboarding resumability** across relaunch.
11. **Start latency** is a PRD placeholder `[define: e.g. 1 second]` — treated as an [OPEN] tuning target, not a fixed number.

---

# 2. Recommended Architecture

## 2.1 Selection

**SwiftUI + `@Observable` MVVM, feature-first, layered, with actor-isolated subsystems and a pure-Swift algorithms module.**

- **UI:** SwiftUI views, thin, rendering-only.
- **Feature/state:** one `@Observable` view model per feature, holding view state and intent methods only.
- **Domain:** pure Swift models, baseline logic, session lifecycle rules, scoring *interfaces*.
- **Algorithms:** a separate, Apple-framework-free (except Accelerate) pipeline module for DSP, feature extraction, metrics, and composite scoring — pure, synchronous, versioned, unit-testable without mocks.
- **Services:** protocol-wrapped adapters over Core Motion, CMPedometer, AVFoundation, SwiftData, CryptoKit/CommonCrypto, file system.
- **Subsystems as actors:** `SessionRecorder` (sensor lifecycle), `SessionProcessor` (batch analysis), `SecureArchiveService` (export/import).

## 2.2 Why This Fits This Product

1. **The app is sensor-pipeline-heavy, not state-graph-heavy.** The hard engineering is DSP, baseline math, and crypto — all of which want *pure, deterministic, testable modules*, not UI-coupled state machines. MVVM-`@Observable` keeps views thin while the pipeline lives in framework-free code.
2. **iOS 17 minimum [PRD §7]** makes the `@Observable` macro available: fine-grained observation (no `ObservableObject` publish storms during a live session timer), and clean constructor injection without environment-object gymnastics.
3. **The PRD demands algorithm evolvability** (composite formula open, thresholds tunable, algorithm version stamped into exports). This demands a *versioned, swappable algorithm boundary* — which is an architecture concern, not a UI concern.
4. **Minimal dependencies is an explicit PRD posture** (no backend, vetted platform crypto only). A hand-rolled DI + Apple-only stack matches it.

## 2.3 Why Alternatives Are Less Suitable

| Option | Assessment |
|---|---|
| **TCA (Composable Architecture)** | Strong fit for complex interactive state graphs and time-travel debugging. Here, the dominant complexity is *pipeline throughput and correctness*, not UI state combinatorics. TCA adds a third-party dependency, reducer boilerplate for every screen, and its effect/dependency system duplicates what protocols + actors already give us. Rejected for v1; the layered design leaves room to adopt per-feature later if UI state grows. |
| **Full Clean Architecture (Use-case layer for everything)** | The domain logic here is small in count (baseline calc, scoring, validity rules) and is already isolated as pure modules. A formal use-case-per-action layer would be ceremony without benefit at this scale. Adopted *in spirit* (algorithms/domain are framework-free), not in full onion form. |
| **VIPER / coordinator-heavy patterns** | Massive per-screen ceremony for a ~15-screen app; testability is already achieved via view-model injection. Rejected. |
| **Classic MVC / ObservableObject MVVM** | ObservableObject's objectWillChange is coarse; a live session (timer, sensor events, audio state) would invalidate views excessively. `@Observable` is strictly better on iOS 17. Rejected. |

## 2.4 How the Architecture Answers the Required Questions

- **Responsibility division:** Views render; view models adapt domain/session state for display and forward intents; actors own subsystem lifecycles; pure modules compute; repositories persist; protocols isolate Apple frameworks.
- **State flow:** Unidirectional. Sensors/services → actor events → view-model `@Observable` state → views. User intents travel the opposite direction as method calls. No view ever mutates shared state directly.
- **Business logic separation:** All gait math, baseline math, and validity rules live in `Domain` and `Algorithms`, which import neither SwiftUI nor Core Motion. View models may not contain DSP or scoring logic [PRD Rule 12].
- **Dependency injection:** Constructor injection at a single composition root (§12). No global singletons.
- **Async:** Swift Concurrency exclusively. Sensor callbacks are bridged to `AsyncStream`s; heavy work runs in actors off the main actor; UI hops are `@MainActor`-bound (§14).
- **Error propagation:** Typed error enums thrown from services/domain, translated by a single presentation mapper into plain-language strings at the view-model boundary — technical errors never reach the user raw [PRD §6].
- **Testing:** Pure modules test with plain inputs; hardware boundaries are protocols with deterministic fakes (recorded sensor fixtures, scripted pedometer, in-memory store, fake clock) (§19).
- **Scaling without complexity:** Feature folders are independent; `Algorithms`, `SecureArchive`, and `Persistence` are structured to be extractable into local Swift Packages later (§16) without rewrites.

---

# 3. Application Layer Architecture

```text
┌────────────────────────────────────────────────────────┐
│ Presentation — SwiftUI Views (render only)             │
├────────────────────────────────────────────────────────┤
│ Feature / State — @Observable ViewModels, Router       │
├────────────────────────────────────────────────────────┤
│ Domain — entities, baseline logic, validity rules,     │
│           scoring interfaces, error taxonomy           │
├────────────────────────────────────────────────────────┤
│ Algorithms (pure) — DSP, segmentation, features,       │
│           metrics, composite scoring (versioned)       │
├────────────────────────────────────────────────────────┤
│ Services — Motion, Pedometer, Audio, SecureArchive,    │
│           Export/Import, Logging (protocol-fronted)    │
├────────────────────────────────────────────────────────┤
│ Persistence — SwiftData models, repositories, mapping  │
├────────────────────────────────────────────────────────┤
│ Apple Frameworks — CoreMotion, AVFoundation, CryptoKit,│
│           CommonCrypto, SwiftData, Charts, Accelerate  │
└────────────────────────────────────────────────────────┘
```

| Layer | Responsibility | May depend on | Must NOT depend on | Examples |
|---|---|---|---|---|
| Presentation | Render state; forward user intents | Feature layer, DesignSystem | Domain internals, Services, Persistence | `ScoreScreen`, `RecordingView`, `OnboardingFieldView` |
| Feature / State | View state, navigation state, intent orchestration, error presentation | Domain, service **protocols**, DesignSystem | Concrete Apple framework types (except SwiftUI), raw sensor types | `SessionFlowViewModel`, `AppRouter`, `ScoreViewModel` |
| Domain | Entities, value types, session validity rules, baseline rules, scoring *contracts*, error taxonomy | Stdlib only | SwiftUI, CoreMotion, SwiftData, any service | `GaitSession`, `Baseline`, `TestMode`, `SessionValidity`, `GaitScoringAlgorithm` protocol |
| Algorithms | Pure computation: preprocessing, segmentation, quality, features, metrics, composite | Stdlib, Accelerate/vDSP | SwiftUI, CoreMotion, SwiftData, AVFoundation | `PreprocessingStage`, `WalkingSegmentDetector`, `AutocorrelationFeatures`, `CompositeScorer` |
| Services | Wrap Apple frameworks behind protocols; own hardware/lifecycle behavior | Domain, Algorithms (as inputs), Apple frameworks | Presentation, Feature, other Services (cross-talk via actors) | `CoreMotionSensorService`, `CMMotionPedometerService`, `AudioFeedbackService`, `SecureArchiveService` |
| Persistence | Store/fetch domain data; map entities↔domain; schema versioning | Domain, SwiftData | Presentation, Feature, Algorithms | `GaitSessionRepository`, `BaselineRepository`, `UserProfileRepository`, `StoreContainer` |
| Apple Frameworks | Platform capability | — | — | (the actual APIs) |

**Explicit boundary rules:**

1. `Algorithms` and `Domain` compile with **zero Apple-framework imports** except `Accelerate` — this is what makes the gait science independently testable and evolvable.
2. Only `Services` and `Persistence` import CoreMotion / AVFoundation / SwiftData / CryptoKit.
3. `Presentation` never imports a Service or Persistence type.
4. Crossing layers uses domain value types or protocols — never leaks framework objects upward (e.g., a `CMSample`-like raw type from CoreMotion is converted to a domain `SensorSample` at the service boundary).

---

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

---

# 5. Domain & Data Model

Three model strata, deliberately **not** duplicated where a single type serves all layers:

## 5.1 Domain Models (pure Swift — the canonical model)

### `TestMode`
| Aspect | Specification |
|---|---|
| Purpose | Distinguishes the two modes everywhere; segregation key [PRD OQ-5] |
| Cases | `quickTest`, `fullTest` |
| Properties | `advertisedDuration` (120 s / 360 s) [PRD §5]; `minimumValidWalkingDuration` (90 s / 240 s) [PRD OQ-3 — v1 product-quality thresholds, tunable]; display name |
| Persistence | Persisted as raw value on session & baseline entities |
| Note | Thresholds live in a versioned `SessionPolicy` config so they can be tuned without schema changes [REC] |

### `UserProfile`
| Property | Type | Required | Notes |
|---|---|---|---|
| `id` | UUID | yes | |
| `amputationLevel` | enum `transtibial/transfemoral/bilateral` | yes | [PRD §5] |
| `side` | enum `left/right/both` | yes | Validation: `bilateral ⇒ both`; `unilateral ⇒ left/right` [PRD AC; consistency rule REC] |
| `timeSinceAmputation` | duration value (months) [REC — input format OPEN] | yes | |
| `prosthesisType` | free text | no | optional field [PRD AC] |
| `kLevel` | enum `k0…k4` | no | optional field [PRD AC] |
| `disclaimerAcceptedAt` | Date | yes (before Home) | hard gate [PRD §7] |
| `createdAt` | Date | yes | |
| Lifecycle | Created at onboarding completion; immutable except future edits (out of scope v1) | | |
| Persistence | `UserProfileEntity` (single row) | | |

### `GaitSession`
| Property | Type | Required |
|---|---|---|
| `id` | UUID | yes |
| `mode` | `TestMode` | yes [PRD AC: stored with session] |
| `startedAt` / `endedAt` | Date | yes |
| `advertisedClockElapsed` | Duration | yes |
| `validWalkingDuration` | Duration | yes (computed in pipeline) |
| `outcome` | `SessionOutcome` | yes |
| `metrics` | `GaitMetrics?` | valid sessions only [PRD §7] |
| `score` | `SessionScore?` | only when mode baseline existed at session commit [PRD §7: "from the 6th valid session onward"] |
| `audioConfig` | `SessionAudioConfig` | yes (transparency [REC]) |
| `algorithmVersion` / `appVersion` | String | yes [PRD export requires app/algorithm version] |
| `deviceModel` | String | [REC] for future diagnostics |
| `interruptionCount` / `gapInfo` | value | [REC] to explain noise/validity decisions |

**`SessionOutcome`** enum:
- `valid`
- `invalid(reason: InvalidReason)` where `InvalidReason ∈ {insufficientValidWalking, excessiveNoise, unrecoverableInterruption, sensorFailure}` [PRD §5 noisy path: "data too noisy, or session ended short of that mode's minimum"]

**Lifecycle:** created at recording start (in-memory), committed to persistence only after processing completes (valid or invalid). Invalid sessions are persisted locally for diagnostics/validity-counting transparency but excluded from History, baseline counting, and export [REC — PRD requires exclusion from those three; whether invalid sessions are retained locally at all is unspecified → REC: retain].

### `GaitMetrics` (value type; per-session, mode-tagged via session)
| Metric | Purpose | PRD source |
|---|---|---|
| `stepRegularity` (Ad1) | Autocorrelation-derived step regularity | §7; OQ-1 — universal, all users |
| `strideRegularity` (Ad2) | Autocorrelation-derived stride regularity | §7; OQ-1 — universal |
| `cadenceMean` (steps/min) | Mean cadence over valid walking | §7; also feeds Metronome baseline |
| `stepTimeCV` / cadence variability | Step-time/cadence variability | §7 — independent signal |
| `trunkMotionProxy` (ML RMS + VT RMS during steady-state walking) | Acceleration-based trunk-motion proxy — *specific computation, not a "balance" label* | §7 — independent signal; exact formulation (RMS vs variance, per-axis vs combined) [OPEN, RMS recommended] |
| `stepTimeAsymmetry` | Sound-vs-prosthetic step-time asymmetry | §7; OQ-1 — **optional, unilateral only, when side reliably identifiable; never fabricated for bilateral** |
| `steps`, `distance` (from CMPedometer) | Context/reference | [REC] |
| `validStrideCount`, `windowCount` etc. | Analysis provenance | [REC] |

Each baseline-standardizable metric carries a stable `MetricID` and a `direction` (higher-better vs lower-better) defined in the algorithm configuration [OPEN — sign convention is part of the unwritten algorithm spec; the data model must carry it].

### `Baseline`
| Property | Type | Required | Notes |
|---|---|---|---|
| `id` | UUID | yes | |
| `mode` | `TestMode` | yes | **mode field on Baseline is PRD-locked [OQ-5]** |
| `stats` | `[BaselineMetricStat]` | yes | one per core metric (asymmetry stat only for unilateral users with the feature available) |
| `cadenceBPM` | Double | yes | Metronome tempo source [PRD §5]; derivation (mean of 5 calibration cadences) [REC] |
| `algorithmVersion` | String | yes | baseline is only comparable under its algorithm version |
| `establishedAt` | Date | yes | |
| `sourceSessionIDs` | [UUID] ×5 | yes | audit trail |
| Lifecycle | Created exactly once per mode, when that mode's 5th **valid** session commits; **frozen in v1** (no recalibration [PRD §6]) | | |

**`BaselineMetricStat`:** `metricID`, `mean`, `sd`, `n`, `sdFloorApplied` (bool). The **minimum-SD floor is PRD-required** [§7 AC]; floor *value* is [OPEN] (config-driven).

### `BaselineState` (derived value, per mode)
`notStarted` · `building(validCount: 1…4)` · `established(Baseline)` — drives Score screen, audio selector, Home, Clinician Summary [PRD §5, §7].

### `SessionScore`
| Property | Type | Notes |
|---|---|---|
| `relativeIndex` | Int | baseline = 100; example 112 [PRD §7]; mapping formula [OPEN] |
| `breakdown` | `[MetricBreakdown]` | per-metric raw value, standardized value, direction-adjusted contribution — for tap-to-expand and clinician screen |
| `algorithmVersion` | String | |
| `summaryLine` | String | generated from real same-mode comparisons [PRD §7 — generation rules OPEN, engine in Domain] |

### `SessionAudioConfig`
`feedbackKind: none | stepFeedback | metronome` (+ metronome BPM used) — which opt-in the user enabled, if any. Presence/shape per PRD §5 (Step Feedback only pre-baseline; Metronome only post-baseline).

### `Preferences` (v1 minimal)
Whether the post-baseline export nudge has been shown/dismissed [PRD §6 edge case]; history filter default [REC]. Kept as a small Codable value.

## 5.2 Persistence Models (SwiftData) — mapping, not duplication

| Entity | Strategy |
|---|---|
| `UserProfileEntity` | Flat attributes mirroring `UserProfile` |
| `GaitSessionEntity` | **Scalar columns** for everything queried: `id`, `mode`, `startedAt`, `validity`, `relativeIndex` (nullable), `algorithmVersion`. **Codable JSON blob** for `GaitMetrics`, `MetricBreakdown` list, `SessionAudioConfig`, gap info [REC — query needs are narrow (mode/date/validity/score); blobs avoid a 30-column table and keep metric evolution schema-light. Trade-off: metrics are not individually queryable — acceptable: no PRD requirement queries them] |
| `BaselineEntity` | `mode` (unique), scalar `cadenceBPM`/`establishedAt`/`algorithmVersion`, JSON blob for `stats`, `sourceSessionIDs` |
| `PreferencesEntity` or UserDefaults | see §6 |

Repositories map Entity ↔ Domain and enforce invariants (e.g., unique `mode` on BaselineEntity; validity-filtered queries).

## 5.3 UI State Models (ephemeral, per feature)

`OnboardingDraft` (Codable, **persisted to UserDefaults** for resume [PRD AC] — it is pre-profile, ephemeral, tiny [REC]) · `AppLaunchPhase` · `SessionFlowState` (machine in §11) · `RecordingViewState` (elapsed, feedback-on indicator) · `ProcessingViewState` (progress) · `ScoreViewState` / `NoisyViewState` · `HistoryFilter` · `RestoreFlowState` (conflict dialog + stages) · `ExportFlowState`.

**Deliberate non-duplication:** domain `GaitSession`, `Baseline`, `TestMode` serve UI directly via view models; only strata with genuinely different lifetimes (SwiftData entities, wizard drafts, flow machines) get separate types.

---

# 6. Persistence Architecture

## 6.1 Technology Selection

| Store | Chosen for | Contents |
|---|---|---|
| **SwiftData** | Structured, relationship-light, versioned, queryable app data | Profile, sessions (valid + invalid), baselines, preferences |
| **UserDefaults** | Trivial, non-sensitive, ephemeral prefs | Onboarding draft (resume), minor UI prefs |
| **File system (app container)** | Export archives, temp processing scratch | `.stabilyz` exports [REC extension], temp files (encrypted-only for exports) |
| **Keychain** | **Not used** | No secrets exist: passphrase is never stored [PRD OQ-2 explicitly rejected keychain-synced approach]; no accounts |
| **Codable archives** | Used *inside* SwiftData blobs and the export payload | Metrics/stats serialization |

## 6.2 Why SwiftData over the alternatives

- **vs. Core Data:** SwiftData is the native Swift-first successor with macro models, `ModelActor` concurrency, and `@Query` for SwiftUI. PRD's iOS 17 floor makes it fully available. Data complexity is low (3 entities, no deep relationships), which sits inside SwiftData's comfort zone. Trade-off acknowledged: SwiftData's migration tooling is younger than Core Data's — mitigated by (a) deliberately narrow schema with blob-based metric storage, (b) the encrypted export archive acting as a data portability escape hatch, (c) schema version discipline (§13.6).
- **vs. file/Codable-only:** History, trend, and per-mode validity counting are real queries (date-ordered, mode-filtered, validity-filtered, count-limited) — reimplementing them over flat files invites the exact cross-mode mixing bugs the PRD forbids [OQ-5].
- **vs. SQLite directly:** unnecessary boilerplate; no query needs exceed SwiftData.

## 6.3 Store Design

- Single default store under Application Support; container built at composition root.
- **Writes** (session commit, baseline creation, restore) go through a background `ModelActor`; **reads** for UI via main context/`@Query`.
- Schema carries a persistent `schemaVersion` value for migration gating [REC].
- **Uniqueness invariants:** one profile; one baseline per mode (enforced + repository-level assertion, belt and braces) — a structural guarantee of PRD OQ-5.

## 6.4 Data Volume

Raw sensor data is **not persisted long-term** [REC]: a 6-minute session at ~100 Hz ≈ 36 k samples (~0.5 MB in memory) — trivially processed in memory; persisted session rows are metrics-only (KB-scale). Raw samples exist only in the recorder buffer and a scratch temp file for the duration of a session [REC: crash-recovery scratch], deleted at commit. This keeps the store tiny and the export archive portable. [PRD never requires raw-sensor retention; export scope is metrics/scores/baselines/profile/settings.]

---

# 7. Motion & Sensor Architecture

## 7.1 Frameworks and Their Roles

| Framework | Role |
|---|---|
| **CoreMotion / CMMotionManager** | High-rate accelerometer (and device-motion attitude/gravity) streaming — the primary trunk-acceleration signal [PRD §5] |
| **CoreMotion / CMPedometer** | Steps, cadence, pace, distance — co-recorded live [PRD §5], cross-check input for segmentation & step detection |
| **CoreMotion / CMMotionActivityManager** | [REC] Coarse walking/stationary classification to assist non-walking segment exclusion [PRD §6 "user stands still"] |
| **AVFoundation** | Tones & feedback (see §10) — listed here only for completeness of the session stack |

## 7.2 Structure — Strictly Separated Stages [PRD Rule 10]

1. **Sensor collection (Service):** `MotionSensorService` and `PedometerService` protocols. Concrete implementations wrap `CMMotionManager` (accelerometer + deviceMotion updates) and `CMPedometer` (live updates). They emit typed `SensorSample { deviceTimestamp, wallClockAnchor, accelerationX/Y/Z, gravityX/Y/Z }` and `PedometerEvent { steps, cadence, pace, timestamp }` as **AsyncStreams**. Sampling rate: **[OPEN/REC: 100 Hz accelerometer]** — sufficient for autocorrelation at typical cadences and pedometer-grade step peaks, cheap on battery; must be validated empirically (§21).
2. **Recording orchestration (Actor):** `SessionRecorder` actor owns start/stop lifecycle: primes sensors (within the start-latency target), stamps a **time-anchor pair** at start, buffers samples into a bounded in-memory ring + optional temp scratch file, tracks gaps, detects suspension/resumption, exposes a `SessionRecordingEvent` stream (elapsed, gapDetected, interruption, sensorError) to the UI, and emits a `LiveStepEvent` stream (from the `LiveStepDetector`) for audio feedback. On `stop()` it flushes a frozen, immutable `RawSessionBuffer` to the processing subsystem.
3. **Signal processing:** §8 — batch, pure, off the recorder.
4. **Metric extraction / scoring:** §8 — pure functions in the Algorithms module.
**Nothing above stage 1 lives in a ViewModel, and no ViewModel contains DSP** [PRD Rule 12].

## 7.3 Start / Stop

- Start: `SessionRecorder.begin(mode:audioConfig:)` → start accelerometer + deviceMotion + pedometer updates → confirm first samples arriving → signal readiness → play start tone [PRD AC]. If priming exceeds the latency target, fail fast into a plain-language error (no silent failure [PRD §6 permission analog]).
- Stop: user Stop button (always visible [PRD §5]) → stop tone → stop sensor updates → freeze buffer → hand off to `SessionProcessor`.

## 7.4 Timestamps

- **Primary clock:** CoreMotion sample timestamps (`CMLogItem.timestamp`, device uptime seconds) — monotonic, gap-revealing.
- **Anchor:** at start, capture `(Date(), uptimeNow())` once; every sample's wall-clock time = anchor + (deviceTimestamp − anchorUptime). This survives wall-clock changes mid-session and makes gap detection arithmetic trivial.
- Pedometer events mapped onto the same timeline.
- All durations (`validWalkingDuration`, elapsed) computed from device timestamps, never from Date arithmetic [REC].

## 7.5 Sampling / Configuration Abstraction

A `MotionAcquisitionPolicy` value (rate, axes, deviceMotion on/off) and a `SessionPolicy`/`DataQualityPolicy` (thresholds: valid-walking minimums 90 s / 240 s [PRD OQ-3], noise threshold [OPEN], confidence thresholds, refractory) live in a **versioned configuration** owned by the Algorithms module so tuning never touches call sites.

## 7.6 Availability & Permissions

- `CMAuthorizationRequirement`/`CMPedometer.authorization` checked in Session Setup before Start; state drives the degraded Start button copy [PRD AC].
- Sensor availability (accelerometer exists) verified on device at launch of the session flow; simulator absence → deterministic mock in dev.

## 7.7 Interruptions & Backgrounding

- App observes `UIApplication` lifecycle (will-resign-active / did-enter-background / suspend) and `AVAudioSession` interruption events during a session.
- **Policy [REC within PRD's allowed space]:** any suspension produces a sensor gap (CMMotionManager delivers nothing while suspended). The recorder marks the gap; walking analysis excludes it; the session carries an `interruptionCount`/gap record; validity is then determined by the normal pipeline (if remaining valid walking ≥ mode threshold → still scoreable — this is PRD-permitted "pause/resume cleanly"; else → invalid/noisy path). A CMPedometer historical query across the gap verifies continuity context [REC].
- **Never:** continue as if nothing happened and emit a clean score [PRD §6 — "must not silently produce a corrupted 'clean' score"].
- **Screen lock prevention [REC]:** disable idle timer during a session; on backgrounding, surface a clear message per PRD ("prevent backgrounding during a session with a clear message" is one of PRD's two sanctioned options). No background motion mode is added in v1.
- Thermal/battery throttling: sensor rate drops or gaps → same gap/quality machinery → graceful noisy failure, never a crash [PRD §6].

## 7.8 Non-Walking Periods & Noisy Classification (detection home)

- Non-walking detection is a **pipeline stage** (`WalkingSegmentDetector`, §8.3): standing still, pauses, setup time are excluded segments and do not count toward the valid-walking requirement [PRD §6, §7 AC].
- Noisy classification = `SignalQualityValidation` stage (§8.4): excessive noise (threshold [OPEN]) OR valid-walking duration below the mode minimum → `SessionOutcome.invalid` → noisy screen [PRD §5].
- The classification *consumes* gap/quality metadata produced by the recorder — single source of truth for validity.

## 7.9 Testability Without a Device

- `MotionSensorService`/`PedometerService` protocols + **fixture replay**: a `FixtureSensorService` streams recorded captures (JSON/binary fixture files with known gait parameters: cadence, SNR, inserted pauses, gaps).
- A **debug-only capture tool** (internal builds only, never TestFlight public builds [REC — privacy]) records real device sessions into fixtures.
- `SessionRecorder` is testable against fixtures including scripted gaps/interruptions; `LiveStepDetector` testable with synthetic footfall signals.

---

# 8. Signal Processing & Scoring Pipeline

```text
RawSessionBuffer (accel + pedometer + gap metadata)
    ↓ 1. Ingestion & Synchronization
Preprocessed Series (uniform rate, gravity-separated, time-aligned)
    ↓ 2. Preprocessing (filter, resample, windowing, orientation estimate)
Walking Segments (intervals of detected steady walking)
    ↓ 3. Walking Segment Detection
SessionQualityReport (valid-walking duration, noise metrics, gaps)
    ↓ 4. Signal Quality Validation  ── fail ──► SessionOutcome.invalid(reason)
Per-Window Features (step peaks, step times, autocorrelation lags, RMS)
    ↓ 5. Feature Extraction
GaitMetrics (Ad1, Ad2, cadence mean, step-time CV, trunk proxy, optional asymmetry)
    ↓ 6. Metric Calculation
Baseline Normalization (per-metric z with SD floor)
    ↓ 7. Baseline Normalization  ── pre-baseline: skip, raw metrics only
Composite Score → Relative Index (baseline = 100)
    ↓ 8. Composite Scoring
SessionResult → persist → Score Screen
```

| # | Stage | Input | Output | Responsibility | Dependencies | Failure conditions | Sync/Async | Execution context |
|---|---|---|---|---|---|---|---|---|
| 1 | Ingestion & Sync | Raw buffer | Time-aligned sample series | De-duplicate, order, merge pedometer events, expose gap intervals | — (recorder output) | Empty buffer → invalid `sensorFailure` | Async (streamed during recording) | Recorder actor |
| 2 | Preprocessing | Sample series | Clean series (gravity-removed/resampled axes incl. vertical & mediolateral estimates) | Filtering, uniform resampling, orientation estimate, gait transient windowing | Accelerate/vDSP | Dropouts beyond tolerance → quality flag | Async (chunked) | `SessionProcessor` actor — **never main actor** |
| 3 | Walking Segment Detection | Clean series + pedometer + activity hints | `[WalkingInterval]` | Exclude non-walking, pauses, setup, standing [PRD §6]; exclude gait initiation/termination transients per Tura note [PRD OQ-1] | Algorithm config | Zero walking intervals → invalid | Async | Processor actor |
| 4 | Signal Quality Validation | Segments + noise/gap metadata | `SessionQualityReport` → go/no-go | Enforce mode minimums (90 s / 240 s [PRD OQ-3]); noise threshold [OPEN] | SessionPolicy config | Insufficient valid walking or excessive noise → **invalid, never scored** [PRD AC] | Async | Processor actor |
| 5 | Feature Extraction | Segments + series | Per-window features | Step-peak detection, step times, autocorrelation (Ad1/Ad2 per Tura method), trunk RMS (ML/VT) during steady-state | vDSP | Too few strides (reference: ~15–20 strides whole-signal [PRD OQ-1, tuning reference not hard spec]) → quality penalty/invalid | Async | Processor actor |
| 6 | Metric Calculation | Features | `GaitMetrics` | Aggregate to per-session metrics; unilateral asymmetry only when side reliably identifiable [PRD §7; method OPEN] | — | — | Async | Processor actor (pure functions) |
| 7 | Baseline Normalization | Metrics + `Baseline` (same mode) | Standardized per-metric values | z with **SD floor** [PRD AC; floor value OPEN] | Baseline repo | Baseline absent → skip (raw metrics, "reference only") | Async | Processor actor |
| 8 | Composite Scoring | Standardized metrics | `SessionScore` (relative index + breakdown) | Combine **independent** signals into composite; map to baseline=100 index | Composite config [formula OPEN] | — | Async | Processor actor (pure function) |

## 8.1 Where the Algorithm Lives

The entire pipeline (stages 2–8) lives in the **`Algorithms/GaitAnalysis` module**: pure Swift + Accelerate, no SwiftUI/CoreMotion/SwiftData imports. Entry contract: a single `GaitScoringAlgorithm` protocol describing "raw buffer + baseline (optional) → `SessionAnalysisOutcome`", stamped with `algorithmVersion` [PRD export requires algorithm version]. The `SessionProcessor` actor is the *only* caller. View models never see the pipeline internals.

## 8.2 Specified vs. Unspecified (PRD-honest inventory)

**Specified by the PRD [do not deviate]:**
- Autocorrelation-based Ad1/Ad2 computed **identically for every user regardless of amputation type** [PRD OQ-1, §7].
- Step-time/cadence variability and the acceleration-based trunk-motion proxy are **independent inputs**, never derived from regularity; the trunk proxy must be a *specific computation* (e.g., RMS/variance of ML + vertical acceleration during steady-state walking) [PRD §7, OQ-1].
- Sound-vs-prosthetic step-time asymmetry is a **separate, secondary, labeled** feature — unilateral only, when side is reliably identifiable; never merged into the composite as a hidden term; never fabricated for bilateral users [PRD §7, OQ-1].
- Gait consistency is **never the sole basis** of the score [PRD §7].
- Minimum-SD floor on each metric's baseline standardization [PRD §7].
- Relative index (baseline = 100), not a percentage claim [PRD §7].
- Valid-walking minimums 90 s / 240 s as v1 product-quality thresholds [PRD OQ-3].
- Internal names *step regularity/stride regularity*; user-facing *gait consistency* [PRD OQ-1].

**Deliberately unspecified — [OPEN], kept swappable, not invented here:**
- The composite **formula and weights** (how metrics combine, index scaling — e.g. how a composite z maps to "112").
- The **noise threshold** (PRD: "define threshold").
- The **SD floor values**.
- Exact trunk-proxy formulation (RMS vs variance; per-axis vs combined).
- The asymmetry computation and the definition of "side reliably identifiable."
- Axis/orientation derivation method and phone-placement assumptions.
- Stride-count sufficiency tuning (15–20 strides is a reference point [PRD OQ-1], not a spec).

**Evolution interface:** every open parameter lives in a versioned `AlgorithmConfiguration`; the pipeline is stage-composable behind the `GaitScoringAlgorithm` contract, so a v2 algorithm is a new implementation + version string, with baseline/session records carrying the version they were computed under (§9.6).

---

# 9. Baseline Architecture

## 9.1 Entity

`Baseline` (domain) / `BaselineEntity` (SwiftData) — one per mode, unique on `mode` [PRD OQ-5: mode field on Baseline]. Contents: per-metric `BaselineMetricStat` (mean, sd, floor flag), `cadenceBPM` (metronome source), `algorithmVersion`, `establishedAt`, 5 `sourceSessionIDs`.

## 9.2 Calculation Service

`BaselineCalculationService` — **pure domain service**: input = metrics of the **first 5 valid sessions of that mode** (in chronological order); output = `Baseline`. Responsibilities: per-metric mean/SD, cadence reference aggregation [REC: mean of the 5 session cadence means], algorithm-version stamping. Unit-tested with synthetic metric sets; no persistence knowledge.

## 9.3 Repository

`BaselineRepository`: `baseline(for mode:)`, `countValidSessions(for mode:)`, `establish(baseline:)` (create-only; uniqueness on mode enforced). **All APIs require an explicit `TestMode` parameter** — there are no mode-less baseline queries, making cross-mode mixing a compile-time impossibility rather than a convention [PRD OQ-5 hard rule].

## 9.4 State & Calibration Lifecycle (per mode)

```
notStarted ──valid session #1──► building(1) ──…──► building(4)
     building(4) ──5th valid session commits──► established(Baseline)
     established: FROZEN for v1 (no recalibration, no updates from later sessions) [PRD §6]
     invalid sessions never advance the counter [PRD §6, §7]
```

- The counter is derived from persisted valid-session count per mode — recomputed, not a mutable field, so a failed/rolled-back commit cannot corrupt it [REC].
- `BaselineState` is exposed to features via a lightweight read model; Score screen, audio selector, Home, Clinician Summary all consume the same derivation — one source of truth [PRD §5, §7].

## 9.5 Scoring Coupling

- Session 5 (the establishing session) itself: metrics only, "building" presentation [PRD §5].
- Session 6+ valid: normalized against that mode's frozen baseline; score persisted on the session [PRD §7].
- A session is compared **only** with the baseline of the same mode [PRD OQ-5] — enforced by passing `TestMode` through every call chain (repository → processor → scorer).

## 9.6 Validity & Versioning

- A baseline is valid iff derived from ≥5 valid same-mode sessions and its `algorithmVersion` matches the algorithm used to produce the sessions' metrics.
- **[OPEN] algorithm-version mismatch handling** (future app updates changing the algorithm): v1 ships a single algorithm version so the case cannot arise; the data model stamps versions now so the future policy (re-baseline prompt, coexistence, migration) is a product decision, not a schema migration. Do not silently resolve.

## 9.7 Anti-Mixing Enforcement (summary of guarantees)

1. `TestMode` required parameter on baseline queries and scoring calls (compile-time).
2. Unique `mode` constraint on `BaselineEntity` (store-level).
3. Valid-session counting always filtered by mode + validity (query-level).
4. Integration test asserting: 3 valid Quick + 2 valid Full ⇒ both modes `building(3)` / `building(2)`, no baseline exists. [PRD §6 edge case]

---

# 10. Audio Feedback Architecture

## 10.1 Two Distinct Engines, One Service Front

| Component | Kind | Trigger | Timing model |
|---|---|---|---|
| **Step Feedback** (pre-baseline, sessions 1–5) | Reactive event sound | `LiveStepEvent` with confidence ≥ threshold, passing refractory gate | Event-driven; must **never** anticipate or imply a tempo [PRD §7, OQ-4] |
| **Metronome cue** (session 6+) | Scheduled periodic tick | Interval = 60 / `Baseline.cadenceBPM` for that mode [PRD §5] | Steady, pre-scheduled timeline [REC: audio-timeline scheduling, not `Timer`, for jitter] |
| Session tones | One-shot | Start / Stop taps | Immediate, distinct sounds [PRD AC] |

## 10.2 Audio Service Abstraction

`AudioFeedbackService` protocol: `playStartTone()`, `playStopTone()`, `playStepTick()`, `startMetronome(bpm:)` / `stopMetronome()`, `suspend()/resume()`, plus interruption/route event callbacks. Concrete implementation over **AVAudioSession + AVAudioEngine with preloaded player nodes** [REC — lowest-latency, sample-accurate scheduling; AVAudioPlayer per tick would add jitter]. Category: playback; ducking off.

## 10.3 Requirements Mapping

- **Enable/disable:** per-session opt-in captured in `SessionAudioConfig`; Step Feedback **off by default**; first-ever session in a mode shows "walk normally — no target pace" framing instead of defaulting the toggle on [PRD §5, §7, OQ-4].
- **Availability gating:** Metronome offered only when that mode's baseline exists — driven by `BaselineState` in Session Setup [PRD §5, §7].
- **Confidence gating:** only detector-confident steps fire a sound — raw spikes must never create an accidental rhythm [PRD §6, OQ-4]. Confidence threshold in versioned config [OPEN value].
- **Debounce/refractory:** a refractory window after each tick prevents double/triple beeps from one footfall [PRD §6, §7]. Typical step interval ≈ 0.5–0.7 s ⇒ refractory ≈ 300 ms, tunable [REC; value OPEN].
- **Latency:** sound-to-footfall must feel connected [PRD §7] ⇒ preloaded buffers, hardware-adjacent playback, no main-thread hops on the tick path [REC].
- **Bluetooth / route changes:** `AVAudioSession` route-change and interruption notifications → re-route to device speaker silently or stop feedback cleanly; **never crash, never freeze the session** [PRD §6].
- **Session lifecycle:** audio is torn down with the recorder; stop tone plays before teardown.

## 10.4 Separation from Scoring (hard architectural rule)

- Audio **subscribes** to the recorder's `LiveStepEvent` stream; it never writes to the sample buffer, never calls the pipeline, and holds no references into processing.
- Scoring runs on the **frozen batch buffer only** — it is mathematically impossible for the audio layer to alter it; additionally, neither Step Feedback nor the Metronome may block or delay the batch scoring computation at Stop [PRD §7 AC].
- The metronome *does* influence the user's gait — that is the PRD-sanctioned intentional influence [PRD OQ-4], and is why `SessionAudioConfig` is persisted with the session [REC: transparency/interpretation], but feedback state never enters the scoring math.
- Failure isolation: any audio error is logged, surfaced only as silent degradation, and **cannot** fail the session [PRD §6].

---

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

---

# 12. Dependency Injection

## 12.1 Strategy

**Manual constructor injection with a single composition root.** `AppDependencies` (a plain struct) is built once in the app entry point and passed to feature initializers; a thin SwiftUI `EnvironmentValue` exposes only view-facing conveniences. No third-party DI framework — the dependency graph is small (~15 nodes), fully static, and compile-time-checked; a framework would add build risk for zero leverage [PRD posture: minimal dependencies].

## 12.2 Protocol Boundaries and Implementations

| Abstraction (protocol) | Production | Test double | Preview |
|---|---|---|---|
| `MotionSensorService` | CoreMotion accelerometer/deviceMotion stream | Fixture replay service | Fixture replay |
| `PedometerService` | CMPedometer live updates | Scripted event sequence | Static values |
| `AudioFeedbackService` | AVAudioEngine player | Spy (records ticks/tones, injects route events) | Silent spy |
| `SessionRecorder` (actor) | Concrete, consuming the above | Driven by fixture services | Same |
| `GaitScoringAlgorithm` | Versioned pipeline (Algorithms module) | Deterministic stub with fixed outputs | Stub |
| `BaselineCalculation` | Pure domain service | Pure (no double needed) | — |
| `UserProfileRepository` / `GaitSessionRepository` / `BaselineRepository` | SwiftData-backed | In-memory store backing (SwiftData in-memory config) | In-memory |
| `SecureArchiveCoding` (crypto) | CryptoKit AES-GCM + CommonCrypto PBKDF2 | Deterministic KDF w/ fixed salt/iterations + real AES-GCM (still vetted — never fake crypto) | — |
| `ExportService` / `RestoreService` | File-based, share-sheet presentation | Temp-directory + fake share presenter | — |
| `Clock` | System date/uptime | Fixed clock (deterministic timestamps) | Fixed |
| `FileIO` | FileManager | Temp sandbox | — |
| `LogService` | os.Logger wrappers | Capturing log sink | — |

Randomness (salts, nonces) abstracted behind a `RandomSource` so crypto tests are deterministic [REC].

## 12.3 Wiring Rules

- Only the composition root knows concrete types.
- View models take protocols + value types; features never reach global state.
- Actor dependencies (`SessionRecorder`, `SessionProcessor`) are created once and shared; they are restarted per session via lifecycle methods, not recreated ad hoc.

---

# 13. Data Export, Encryption & Restore Architecture

All items marked **[PRD]** in this section are hard requirements from PRD §5/§6/§7 and OQ-2 — not recommendations.

## 13.1 Export Format & Archive Structure

**[PRD]** archive contents: profile, **all valid sessions** (both modes, mode-tagged), **both modes' baselines**, settings/preferences, app version, algorithm version, schema version, export timestamp, integrity check.

```
Stabilyz Export File (.stabilyz [REC extension])
┌───────────────────────────────────────────────┐
│ HEADER (plaintext, needed to decrypt):        │
│  magic "STBLYZ" + envelope format version     │
│  crypto suite id (e.g. PBKDF2-SHA256+AESGCM)  │
│  KDF params: salt (≥16 B random, per export), │
│              PRF id, iteration count          │
│  nonce (12 B random)                          │
│  key-check value [REC — see 13.4]             │
├───────────────────────────────────────────────┤
│ CIPHERTEXT (AES-GCM, tag appended):           │
│  JSON payload:                                │
│   schemaVersion, appVersion, algorithmVersion │
│   exportedAt, payload SHA-256 digest          │
│   profile, validSessions[], baselines[≤2],    │
│   preferences                                 │
└───────────────────────────────────────────────┘
```

- **Serialization [PRD]**: metadata + data in one archive; JSON chosen [REC] for debuggability and migration simplicity; payload is small (metrics-only sessions).
- **Salt/nonce/KDF params/version stored within the file [PRD]** — the header is the self-describing envelope.
- **Integrity [PRD]**: AES-GCM authentication tag + inner payload digest [REC double-check, satisfying "integrity check (e.g. checksum)"].

## 13.2 Encryption Flow (Export)

1. User sets + confirms passphrase in the Export wizard; the **unrecoverable-passphrase warning is shown before generation [PRD]**.
2. Passphrase normalized (Unicode NFC [REC]), converted to bytes, held only in memory for the operation [PRD: never written to disk; no recovery].
3. **KDF [PRD]:** PBKDF2-HMAC-SHA256 via CommonCrypto `CCKeyDerivationPBKDF` (Apple's vetted implementation; CryptoKit does not provide PBKDF2), **unique 16-byte random salt per export [PRD]** (SecRandomCopyBytes), iteration count calibrated on-device (~200–500 ms; starting point ~300k [REC], stored in header so old exports stay decryptable).
4. **AEAD [PRD]:** AES-256-GCM via CryptoKit, random 12-byte nonce, seal the serialized payload.
5. Write **ciphertext only** to a temp file (no plaintext temp file ever exists [REC — serialize in memory]), present via the **system share sheet [PRD]** (destination is the user's choice; explicit user action only, never automatic), then delete the temp file.
6. **No custom cryptographic primitives anywhere [PRD]** — CryptoKit + CommonCrypto only.

## 13.3 Passphrase & Secure Memory

- Never stored, never logged, never sent anywhere [PRD OQ-2].
- Held as a mutable byte buffer during KDF and cleared after key derivation where possible [REC — Swift `String` cannot be zeroed; the byte-buffer approach bounds exposure; realistic residual risk accepted and documented].
- Minimum length policy [REC: 8+ chars; PRD does not specify — flagged as a product decision].

## 13.4 Import Flow & Validation Order

**[PRD] order is fixed:** passphrase prompt → **decrypt before schema/version/integrity validation** → validate **before any local data is touched**.

1. Pick file (system document picker, both first-launch and Settings paths [PRD]).
2. Parse envelope header. Unknown magic/envelope version → "file isn't a Stabilyz export" plain-language error; nothing touched.
3. Derive key from entered passphrase + header params; attempt AES-GCM decrypt. **Key-check value [REC]:** a small GCM-sealed known constant inside the envelope lets the app distinguish "wrong passphrase" (check fails) from "corrupted data" (check passes, payload/tag fails) — satisfying the PRD's "distinguishing … where possible" requirement. Without it, both collapse into one message.
4. Post-decrypt validation [PRD]: payload digest; `schemaVersion` vs. supported range — older ⇒ run DTO migration chain; newer than supported ⇒ plain-language incompatibility error, nothing touched [PRD §6]; log app/algorithm versions; verify archive completeness (profile, disclaimer accepted, both baseline entries mode-distinct).
5. Only after full validation does any local data path begin.

## 13.5 Atomic Restore (hard requirement [PRD])

**Design [REC implementation of a PRD hard requirement]:**

1. All decryption/validation completes **before** any local mutation (per 13.4) — the primary guarantee.
2. Snapshot the current store file(s) (copy).
3. Perform the replace inside the live SwiftData container as a **single background-context transaction** (delete all entities → insert migrated domain objects → one atomic save). Failure ⇒ transaction rollback ⇒ store unchanged.
4. Catastrophe net: if the container is left inconsistent (process kill mid-save), the pre-restore snapshot replaces the store on next launch; snapshot deleted only after verified success.
5. On success: publish the **state-invalidation event** (§11.4), rebuild in-memory view models, navigate.
6. **Import is a restore, not a merge [PRD OQ-2]** — no duplicate resolution, no baseline merging, ever in v1.

Failure-recovery matrix:

| Failure | Result |
|---|---|
| Wrong passphrase | Plain-language message; nothing changed [PRD] |
| Corrupted / tampered file | Detected via GCM tag/digest; nothing changed [PRD] |
| Incompatible (future) schema | Plain-language incompatibility message; nothing changed [PRD] |
| Interruption mid-restore | Transaction rollback or snapshot recovery; store consistent [PRD: "no partially-restored or corrupted intermediate state"] |

## 13.6 Versioning & Migration Strategy

- **Envelope format version** (crypto structure) and **payload schemaVersion** are independent; both live in the file [PRD embeds version identifiers].
- v1 supports schemaVersion 1 (and only envelope v1); the DTO layer has a sequential migration pattern (`schema N → N+1`) so future versions can read old exports [PRD: "so a future app version can correctly decrypt and migrate an older export"].
- SwiftData store schema versioning is tracked separately (§6) with lightweight-migration intent; the export archive is the cross-version data contract.

---

# 14. Concurrency & Async Architecture

## 14.1 Model

Swift Concurrency end-to-end: `async/await`, actors, structured tasks, AsyncStreams. No completion-handler bridges except where Apple APIs force them (CoreMotion/AVFoundation callbacks → stream continuation bridging).

## 14.2 Placement Rules

| Component | Isolation | Rationale |
|---|---|---|
| All SwiftUI views & view models | `@MainActor` | UI state |
| `SessionRecorder` | Actor | Serializes sensor lifecycle; owns streams |
| `SessionProcessor` (pipeline stages 2–8) | Actor + CPU-bound work in nonisolated pure functions invoked from actor context | Keeps heavy math off the main actor; pure functions parallelizable if needed |
| Live step detection | Runs in recorder actor on the sample stream | Must be cheap per-sample; audio reacts via main-actor hop for state only |
| SwiftData writes | Background `ModelActor` | Session commit/baseline creation/restore never block UI |
| SwiftData reads for `@Query` | Main context | SwiftUI integration |
| Audio render/scheduling | AVAudioEngine's own threads; events hop to main | Latency-critical, never main |
| Export/import tasks | Structured `Task`s (userInitiated) with cancellation | Long-ish, observable, cancellable |
| `SecureArchiveService` | Actor | Serializes crypto operations; KDF (~300 ms) explicitly off-main |

## 14.3 Data Volume & Non-Blocking Guarantees

- 6-min @ ~100 Hz ≈ 36 k samples — memory-trivial, but autocorrelation over lags × windows is the heaviest compute in the app: it runs entirely in the processor actor with **chunked progress reporting** to the Processing screen; the UI thread never executes DSP [PRD Rule 12; PRD: processing is "brief"].
- Bounded recorder buffer: if live consumers lag, the buffer flushes to the scratch file — recording (the irreplaceable data) is never dropped due to slow consumers [REC].
- Backpressure: the pipeline only runs at Stop (batch) — live load is limited to step detection, by design.
- Cancellation: Stop-button and view dismissal cancel dependent tasks cleanly; a cancelled processing run marks the session invalid rather than half-processed.

---

# 15. Error Handling Strategy

## 15.1 Representation

One `StabilyzError` domain enum with categories; thrown from services/domain; **translated at the view-model boundary** by a single `ErrorPresenter` mapper into plain-language, non-technical strings. Technical messages are logged, never shown [PRD Rule: "Do not expose technical errors directly to the user"].

| Category | Examples | Handled at | Logged | User sees | Recoverable | State-unchanged guarantee |
|---|---|---|---|---|---|---|
| Permission | Motion & Fitness denied | Session Setup (pre-flight) | Info | Inline explanation on Start button; link to Settings | Yes (user grants) | n/a |
| Sensor | Unavailable, priming timeout, mid-session failure | Recorder + session flow | Error | "Couldn't record — try again" | Yes | No partial session persisted |
| Recording | Interruption/gap policy outcomes | Pipeline | Warning + gap metadata | Only if invalid (noisy screen) | n/a | — |
| Processing | No walking detected, too few strides, noise | Pipeline → validity | Warning | Noisy/insufficient-data screen (plain-language, no score) [PRD] | Re-run session | Invalid session recorded, never baseline-counted |
| Persistence | Save failure, store corruption | Repositories + app-level recovery | Error | Generic retry message | Retry / relaunch | Failed commit rolled back (transactional writes) |
| Export | KDF/file/share failure | Export flow | Error | "Export didn't complete — nothing was changed" | Yes | **No temp plaintext; temp ciphertext deleted; store untouched** |
| Import/decryption | Wrong passphrase, corrupted, bad header | Restore flow | Error (no key material) | Distinct plain-language messages where possible [PRD] | Yes | **Hard: existing DB byte-identical** [PRD] |
| Schema compatibility | Future schema, unsupported envelope | Restore flow, pre-data-touch | Warning | Incompatibility message | Upgrade path suggested | **Untouched** [PRD] |
| Audio | Route loss, interruption, engine failure | Audio service (silent degradation) | Warning | Nothing (fail to speaker or stop cleanly) [PRD §6] | Automatic | Session recording unaffected |
| Crypto | Tag verification failure, RNG failure | SecureArchive service | Error | Mapped to import/export messages | No | Untouched |

## 15.2 Principles

- Every user-visible failure string is non-technical, action-oriented, and calm (PRD's plain-language posture throughout §6).
- Never log passphrases, keys, salts, raw sensor data, or metric values (§20).
- Any operation with a PRD atomicity guarantee (restore, export temp, session commit) must be implemented so the failure path is exercised in tests (§19).

---

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
│   ├── Models/                 # GaitSession, Baseline, TestMode, GaitMetrics, UserProfile…
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
│   ├── Recording/              # SessionRecorder actor, RawSessionBuffer, gap policy
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

---

# 17. Technology Stack & Deployment Target

| Item | Choice | Notes |
|---|---|---|
| Minimum iOS | **17.0** [PRD §7] | Enables `@Observable`, SwiftData, modern Charts APIs |
| Swift | 5.10+ toolchain; **strict concurrency checking enabled from day one**, Swift 6 language mode adopted when stable [REC] | PRD concurrency posture demands early data-race safety |
| UI | SwiftUI + Observation | |
| Persistence | SwiftData | §6 |
| Charts | Swift Charts | Trend lines [PRD §5] |
| Sensors | Core Motion (CMMotionManager, CMPedometer, CMMotionActivityManager [REC]) | §7 |
| DSP | Accelerate / vDSP | Filtering + autocorrelation; justified: hand-rolled FFT/convolution in pure Swift would be slower and riskier; Apple-native |
| Audio | AVFoundation / AVAudioEngine | §10 |
| Crypto | **CryptoKit (AES-GCM) + CommonCrypto (PBKDF2)** | §13; both platform-vetted [PRD: vetted platform crypto only] |
| Files | FileManager, UniformTypeIdentifiers, SwiftUI fileImporter / share sheet | |
| Logging | os (Logger + OSSignposter) | §20 |
| Testing | XCTest, XCUITest | §19 |
| SPM (external) | **None** | |

**Third-party dependencies: none.** Justification per the required framing: every needed capability (UI, persistence, charts, sensors, DSP, audio, AEAD, PBKDF2, file exchange, logging, testing) has a sufficient, Apple-supported implementation. Each external package would add supply-chain risk, App-Store-review surface, and binary bloat with no capability gap closed. (The one place a third-party library is often suggested — Argon2 — is unnecessary: PBKDF2-HMAC-SHA256 with per-export salt and calibrated iterations is a PRD-sanctioned option available via CommonCrypto.)

---

# 18. Security & Privacy Architecture

| Requirement | Design |
|---|---|
| Local-only, no backend, no auto cloud sync [PRD §3, OQ-2] | No networking code exists; no push/background-transfer entitlements; the app itself performs zero network requests. Share-sheet destinations are OS-level, user-chosen [PRD §5] |
| Sensitive health/mobility data | Data minimization: store only profile fields the PRD collects, per-session derived metrics, and provenance metadata. No raw sensor retention (§6.4) |
| Permissions | Motion & Fitness only; no other permission prompts anywhere in v1. Pre-flight check + degraded Start [PRD AC] |
| Export security | Passphrase + PBKDF2 + AES-GCM per §13 [PRD] — the export is protected independently of device state (deliberate PRD design: no iCloud dependency [OQ-2]) |
| Passphrase handling | Memory-only during the operation; never persisted, logged, or transmitted; clear warnings at export [PRD]; unrecoverable by design |
| Temporary files | Export temp file contains ciphertext only; deleted after share; session scratch deleted at commit [REC]; all files use iOS data protection (.complete default) |
| Logging | No sensor payloads, metric values, profile fields, or crypto material in logs; counts/durations/status only (§20) |
| Crash reporting | No third-party crash SDK [PRD posture]; TestFlight's Apple-provided crash reports (metadata-level) are the only crash signal in v1 [REC] |
| Data deletion | App deletion removes all local data (local-only store). **[OPEN/REC]:** an explicit "Erase all data" control in Settings is *not* specified by the PRD — recommend raising as a product decision; architecture reserves a repository `wipeAll()` for it |
| Device-level protections | Standard iOS sandbox + file data protection; nothing extra to do; documented so no one "adds" a cloud backup of the store |

---

# 19. Testing Strategy

## 19.1 Unit Tests

| Area | Approach |
|---|---|
| Domain | `TestMode` thresholds; `SessionOutcome` rules; profile validation; baseline-state machine transitions |
| Algorithms (bulk of effort) | Synthetic signals with known parameters: generated footfall waveforms at known cadence/SNR → assert Ad1/Ad2 values, step-time CV, trunk RMS within tolerance; injected pauses/gaps → segmentation excludes; noise-injected → quality stage flags; too-short → invalid. Golden-file regression per algorithm version |
| Baseline calculation | Mean/SD correctness; **mode-segregation invariant tests** (3 Quick + 2 valid Full ⇒ no baseline anywhere) [PRD §6]; SD-floor behavior; frozen-after-5 rule; invalid-session exclusion |
| Scoring | Direction handling per metric; floor clamp; relative index centers baseline at 100; multi-signal requirement (composite never reducible to Ad1/Ad2 alone — a test asserting the input set) |
| Crypto/archive | Export→import round-trip; tampered ciphertext rejected (GCM); mutated header → corrupted-file error; wrong passphrase → passphrase error (key-check value); future-schema payload → incompatibility error; salt/nonce uniqueness across exports; params embedded correctly; DTO schema migration chain N→N+1 |

## 19.2 Integration Tests

- **Session pipeline end-to-end:** fixture sensor stream → recorder → processor → repository → baseline at 5th valid → score at 6th → history query correctness (valid-only, mode-tagged).
- **Persistence:** in-memory SwiftData container; entity↔domain mapping; unique-mode baseline constraint; transactional commit rollback on injected failure.
- **Restore flow:** export → import on populated store → conflict decision matrix (cancel / export-first / replace) → **kill-point injection during restore** (fail at decrypt, validate, mid-transaction) asserting the store is byte-identical after failure [PRD hard requirement — this test is mandatory].
- **State invalidation:** post-restore, no stale in-memory session/baseline data observable.

## 19.3 UI Tests (XCUITest, deterministic doubles injected)

Onboarding completion incl. hard disclaimer gate and optional-field skipping; relaunch-mid-onboarding resume; permission-denied Start degradation (simulator state); full session flow with fixture recorder (valid → score; noisy → noisy screen; building-baseline "X of 5"); history rendering & mode filtering; Settings restore conflict dialog's three outcomes; export wizard happy path.

## 19.4 Hardware-Dependent (physical iPhone only)

Simulators cannot produce realistic prosthetic-gait motion. Must be validated on device:
- Real-world noise levels vs. quality thresholds (drives the [OPEN] threshold tuning)
- Walking-segment detection robustness on actual amputee-gait captures
- CMPedometer vs. accelerometer step-detection agreement
- Suspension/lock behavior during recording (gap policy reality)
- Audio: step-tick latency perception, Bluetooth route drops, interruption during call
- Thermal/battery throttling behavior
- PBKDF2 iteration calibration on target devices
- Export → Files/AirDrop → restore round-trip

**Determinism for hardware services:** every hardware boundary is a protocol (§12); fixtures replay recorded captures; the fake clock fixes timestamps; scripted pedometer drives interruption tests; the audio spy asserts refractory/confidence gating without producing sound.

---

# 20. Observability, Logging & Diagnostics

**Tooling:** `os.Logger` with per-subsystem categories (`app`, `session`, `motion`, `processing`, `baseline`, `audio`, `backup`, `persistence`) + `OSSignposter` intervals for pipeline stages.

| Event | Level | Logged content |
|---|---|---|
| Session start/stop | Info | mode, advertised vs. valid-walking duration, sample counts, gap count |
| Validity outcome | Info | valid/invalid + reason category (no data) |
| Processing stage timings | Debug + signposts | stage durations, window/stride counts |
| Baseline established | Info | mode, algorithm version (no metric values) |
| Audio degradation | Warning | route/interruption category |
| Export/import outcomes | Info | envelope/schema versions, success/failure category (no key material) |
| Errors | Error | category + technical message |

**Never logged:** passphrases, keys, salts, nonces, raw sensor samples, metric values, profile fields. Metric *values* are treated as sensitive health data — counts and statuses only [REC consistent with PRD sensitivity].

**Production debugging without sensitive data:** signpost-based performance traces; validity reasons recorded *on the session record* (structured, local) so a tester's "bad session" is self-explanatory in History-adjacent diagnostics; TestFlight feedback channel for qualitative reports. No analytics infrastructure — the PRD contains no analytics requirement, and none is added [PRD Rule: no invented backend/analytics].

---

# 21. Technical Risks & Unknowns

## 21.1 Known Requirements (locked by PRD — engineering must not alter)

Two test modes with 90 s / 240 s valid-walking minimums · per-mode 5-valid-session baselines, frozen in v1 · autocorrelation Ad1/Ad2 universal for all amputation types · multi-signal composite with SD floor · asymmetry secondary/unilateral-only/never fabricated · relative index not percentage · noisy sessions never scored/counted/exported · mode segregation everywhere · Step Feedback (off-by-default, confidence-gated, debounced, no tempo) vs. Metronome (post-baseline, baseline cadence) · encrypted export with PBKDF2/unique-salt/AES-GCM/self-describing metadata · restore-not-merge · **atomic restore** · no custom crypto · no backend/accounts/cloud · disclaimer hard gate · onboarding resume · permission degradation · TestFlight iOS 17+.

## 21.2 Technical Decisions (engineering-owned; decide before/during build)

Sensor sampling rate (rec: 100 Hz) · orientation/axis derivation for ML/VT axes · trunk-proxy formulation (RMS rec) · walking-segment detection method · live step-detector design + confidence threshold · refractory duration (rec: ~300 ms) · KDF iteration count (rec: calibrate 200–500 ms) · export file extension/UTType · onboarding-draft storage (rec: UserDefaults) · invalid-session local retention (rec: retain, exclude) · metrics-as-JSON-blob persistence · PBKDF2 via CommonCrypto (forced: CryptoKit lacks PBKDF2) · TabView layout · atomic-restore mechanism (transaction + snapshot, rec).

## 21.3 Open Questions (PRD-intentional; do not close silently)

1. **Composite formula & weights** — completely unspecified; algorithm version 1 must be built with provisional weights and stamped as such [PRD OQ-1 context].
2. **Noise threshold** — PRD literally says "(define threshold)".
3. **Start latency target** — PRD placeholder "[define: e.g. 1 second]".
4. **SD floor values** — required to exist; values unspecified.
5. **Phone placement** — PRD never specifies where the phone is carried; trunk-proxy and autocorrelation quality depend on it. Recommend product-level guidance (e.g., waist-level pocket) — flagged, not assumed.
6. **"Side reliably identifiable"** definition for the asymmetry feature.
7. **Relative-index mapping/scale** (how composite deviation becomes e.g. 112).
8. **Whether the 5 calibration sessions later receive retroactive scores** in History ("History lists … with their mode-relative baseline scores (once that mode's baseline exists)" vs. "from the 6th valid session onward" — recommend *no* retroactive scoring; needs product confirmation).
9. **N for "last N sessions"** on clinician summary and encouraging-summary comparisons.
10. **Encouraging-summary copy rules** (PRD: generated from real same-mode comparisons; templates unspecified).
11. **Export-nudge cadence** beyond "after baseline is first established" ("periodically" unspecified).
12. **Algorithm-version mismatch policy for future app updates** (§9.6).

## 21.4 Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Algorithm validity on real prosthetic gait (validated for unilateral transfemoral via Tura; not bilateral; composite unvalidated) | High | Versioned algorithm; early device data collection; PRD explicitly accepts non-validated v1 [PRD §2]; documented research gap [OQ-1] |
| Walking-segment/step detection false positives creating accidental audio rhythm | High | Confidence gating + refractory + integration tests on fixtures |
| Backgrounding policy gaps on real devices | Medium-High | Gap-detection architecture; device test matrix; PRD-sanctioned instruction-first approach |
| SwiftData maturity (container rebuild after restore, migration tooling) | Medium | Transactional restore + store snapshot; narrow schema; export archive as portability hedge |
| Mostly-turn sessions producing misleading scores (no turn detection in v1) | Medium | PRD-sanctioned user instruction; quality threshold may flag; documented limitation |
| PBKDF2 UX (export/import delay) | Low-Medium | Calibrated iterations; progress UI |
| iOS 17.0 `@Observable`/SwiftData early-adopter bugs | Low-Medium | Pin to latest 17.x toolchain; regression suite |

## 21.5 Research / Validation Required (before hard-coding assumptions)

Empirical threshold tuning on real walks (noise, SD floor, valid-walking minimums — PRD says these "will be empirically validated and tuned using real-world session data" [OQ-3]) · autocorrelation reliability at variable cadence and real phone-placement orientations · pedometer/accelerometer agreement rate · audio-tick latency acceptability · stride-count sufficiency (15–20 strides reference [OQ-1]) · KDF timing on target devices. **Architectural enabler:** an internal, debug-only fixture-capture build path so real-device walks become test fixtures (§7.9).

---

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

---

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
    Task 8.2.3 Processing screen + routing to Score/Noisy                   → dep: 5.1.1
    Task 8.2.4 Score screen (building/relative states, expandable signals)  → dep: 6.2.3
    Task 8.2.5 Noisy screen (plain-language, invalid, no score)
  Feature 8.3 Home
    Task 8.3.1 Home empty/populated + trend snapshot + export nudge         → dep: 8.2.4

EPIC 9 — History & Clinician
  Feature 9.1 History
    Task 9.1.1 Session list (valid-only, mode-labeled, filter)              → dep: 3.2.1
    Task 9.1.2 Swift Charts trend (mode-separated series)                   → dep: 9.1.1
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

---

# 24. Architecture Decision Records

**ADR-001 — Architecture Pattern**
Context: SwiftUI app, iOS 17+, sensor-heavy, ~15 screens, PRD demands testability and algorithm evolvability.
Options: TCA · full Clean Architecture · VIPER · classic MVC/ObservableObject MVVM · **SwiftUI + @Observable MVVM with layered feature-first modules**.
Chosen: the last.
Why: dominant complexity is pipeline correctness, not UI state graphs; `@Observable` (iOS 17) removes ObservableObject drawbacks; keeps third-party dependency count at zero.
Trade-offs: no built-in time-travel/state replay (mitigated by view-model unit tests); discipline required to keep logic out of view models (enforced by layer import rules).

**ADR-002 — State Management**
Context: live session state, baseline states, multi-screen derived state.
Options: single global store · per-feature `@Observable` view models + actor-owned subsystem state.
Chosen: per-feature `@Observable` + actors; derived read models (e.g., `BaselineState`) computed from repositories.
Why: state locality matches feature boundaries; actors serialize the truly shared, concurrent things (recorder, processor, restore).
Trade-offs: cross-feature consistency relies on repository-derived reads + explicit invalidation events rather than one reactive store — accepted at this scale.

**ADR-003 — Navigation**
Context: state-dependent root (first launch / onboarding / main), modal session flow, restore flows.
Options: ad-hoc NavigationStack paths · **enum-driven router + coordinator**.
Chosen: `AppRouter` phase machine + `SessionFlowCoordinator` enum path + TabView root + full-screen session cover.
Why: PRD routing is inherently state-dependent (baseline existence, restore outcomes, disclaimer gate); enums make it a total, unit-testable function.
Trade-offs: slightly more boilerplate per destination than free-form NavigationLink.

**ADR-004 — Persistence**
Options: Core Data · SwiftData · Codable files · raw SQLite.
Chosen: **SwiftData** (+ UserDefaults for onboarding draft; files for exports).
Why: iOS 17 floor; native Swift models and ModelActor concurrency; query needs (mode/validity/date/count) exceed flat files; Core Data offers more maturity but more boilerplate for the same result at this schema size.
Trade-offs: younger migration tooling — mitigated by narrow schema, JSON metric blobs, and the export archive as the cross-version data contract.

**ADR-005 — Dependency Injection**
Options: third-party DI (Resolver/Swinject) · SwiftUI environment-only · **manual constructor injection + composition root**.
Chosen: manual.
Why: ~15-node static graph; compile-time safety; zero dependencies [PRD posture].
Trade-offs: manual wiring churn as features are added — acceptable; one file to touch.

**ADR-006 — Motion Data Collection**
Options: business logic in a ViewModel recording sensor callbacks · **protocol-wrapped CoreMotion services streaming into a SessionRecorder actor**.
Chosen: the latter.
Why: PRD demands suspension/gap/interruption correctness and testability without hardware; actor serializes lifecycle; fixtures replace sensors deterministically.
Trade-offs: stream-bridging boilerplate; live detector must be kept cheap.

**ADR-007 — Processing Architecture**
Options: process inside the recording flow / on main · **frozen batch buffer → staged pure pipeline in a versioned Algorithms module executed by a SessionProcessor actor off-main**.
Chosen: batch, pure, staged, versioned.
Why: PRD keeps the formula and thresholds open and tunable — a pure, config-driven, versioned module is the only shape that supports empirical tuning and evolution; testable without mocks.
Trade-offs: no live score (not required); pipeline contract must stay stable while algorithm evolves (hence the single `GaitScoringAlgorithm` contract).

**ADR-008 — Baseline Architecture**
Options: rolling/updated baseline · baseline-as-query · **frozen per-mode baseline created from exactly the first 5 valid same-mode sessions, mode-keyed entities and mode-required APIs**.
Chosen: frozen, mode-keyed.
Why: PRD: no recalibration in v1; modes never blend [OQ-5]; "X of 5" counters are per-mode valid counts.
Trade-offs: gait drift after refit is unhandled (documented PRD limitation, not solved); frozen baselines make the future re-baseline UX a v2 product decision.

**ADR-009 — Export/Import Architecture**
Options: merge on import · direct store overwrite · **self-describing encrypted envelope + DTO payload + staged validation + transactional atomic replace with store snapshot**.
Chosen: the latter.
Why: PRD hard requirements: restore-not-merge; decrypt → validate → touch ordering; atomicity under all failures; future-version detection before data is touched.
Trade-offs: full archive rewrite per export (trivial at v1 data volume); no partial restores by design.

**ADR-010 — Encryption Strategy**
Options: custom crypto · plain SHA-256 key · third-party crypto libs · **PBKDF2-HMAC-SHA256 (CommonCrypto) + AES-256-GCM (CryptoKit), per-export salt/nonce, all params embedded**.
Chosen: platform vetted pair.
Why: PRD mandates a real KDF, authenticated encryption, embedded parameters, and no custom primitives; CryptoKit provides AEAD but not PBKDF2, hence CommonCrypto for the KDF — both Apple-vetted.
Trade-offs: PBKDF2 is weaker than Argon2 against GPU attacks (no native Apple Argon2 — adding a dependency is rejected); mitigated by calibrated iterations, high-entropy requirement being user-passphrase reality, and the local threat model (offline guessing by whoever obtains the file, which the KDF slows).

---

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