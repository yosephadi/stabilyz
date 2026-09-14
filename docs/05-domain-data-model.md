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

`OnboardingDraft` (Codable, **persisted to UserDefaults** for resume [PRD AC] — it is pre-profile, ephemeral, tiny [REC]) · `AppLaunchPhase` · `SessionFlowState` (machine in §11) · `RecordingViewState` (elapsed, feedback-on indicator) · `ProcessingViewState` (progress) · `ScoreViewState` / `NoisyViewState` · History's selected `TestMode` segment (Quick Test / Full Test, no "All" — §4.13) · `RestoreFlowState` (conflict dialog + stages) · `ExportFlowState`.

**Deliberate non-duplication:** domain `GaitSession`, `Baseline`, `TestMode` serve UI directly via view models; only strata with genuinely different lifetimes (SwiftData entities, wizard drafts, flow machines) get separate types.
