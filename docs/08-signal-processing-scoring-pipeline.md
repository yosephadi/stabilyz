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
    ↓ 7. Baseline Normalization  ── pre-baseline: skip; provisional intrinsic 0–100 score instead (entry 52)
Composite Score → Relative Index (baseline = 100)
    ↓ 8. Composite Scoring
SessionResult → persist → Score Screen
```

| # | Stage | Input | Output | Responsibility | Dependencies | Failure conditions | Sync/Async | Execution context |
|---|---|---|---|---|---|---|---|---|
| 1 | Ingestion & Sync | Raw buffer | Time-aligned sample series | De-duplicate, order, merge pedometer events, expose gap intervals. Receives only at-or-after-T-0 samples: admission is enforced upstream at the buffer boundary [PRD OQ-6], never re-filtered here | — (recorder output) | Empty buffer → invalid `sensorFailure` | Async (streamed during recording) | Recorder actor |
| 2 | Preprocessing | Sample series | Clean series (gravity-removed/resampled axes incl. vertical & mediolateral estimates) | Filtering (hand-written biquad, decisions.md entry 7), uniform resampling, orientation estimate, gait transient windowing | Accelerate not used | Dropouts beyond tolerance → quality flag | Async (chunked) | `SessionProcessor` actor — **never main actor** |
| 3 | Walking Segment Detection | Clean series + pedometer + activity hints | `[WalkingInterval]` | Exclude non-walking, pauses, standing [PRD §6]; exclude gait initiation/termination transients per Tura note [PRD OQ-1]. Pre-walk setup is **not** this stage's problem — the T-0 admission gate keeps the countdown out of the buffer entirely [PRD OQ-6], so what remains here is non-walking *after* T-0 | Algorithm config | Zero walking intervals → invalid | Async | Processor actor |
| 4 | Signal Quality Validation | Segments + noise/gap metadata | `SessionQualityReport` → go/no-go | Enforce mode minimums (60 s / 135 s [PRD OQ-3]); a manual Stop (phone or watch) drops the final 3 s first, `manualStopTailTrim` `[OPEN]` placeholder, and the floor is evaluated after the trim; a timer end keeps its tail, and the end reason is derived (recorded clock reached the advertised length = timer), not stored (decisions.md entry 51); noise threshold [OPEN] | SessionPolicy config | Insufficient valid walking or excessive noise → **invalid, never scored** [PRD AC] | Async | Processor actor |
| 5 | Feature Extraction | Segments + series | Per-window features | Step-peak detection, step times, autocorrelation (Ad1/Ad2 per Tura method, **unbiased** estimator for Ad1/Ad2; the half-stride peak-splitting search for step-time asymmetry stays on the biased estimator; a window is discarded when the largest stride-search lag exceeds `maximumLagFractionOfWindow` = 0.5 of the window, `[OPEN]` placeholder; decisions.md entry 48), trunk RMS (ML/VT) during steady-state | Hand-written loops (Accelerate not used) | Too few strides (reference: ~15–20 strides whole-signal [PRD OQ-1, tuning reference not hard spec]) → quality penalty/invalid | Async | Processor actor |
| 6 | Metric Calculation | Features | `GaitMetrics` | Aggregate to per-session metrics; unilateral asymmetry only when side reliably identifiable [PRD §7; method OPEN] | — | — | Async | Processor actor (pure functions) |
| 7 | Baseline Normalization | Metrics + `Baseline` (same mode) | Standardized per-metric values | z with **SD floor** [PRD AC; floor value OPEN] | Baseline repo | Baseline absent → skip the relative index; sessions 1–5 carry a provisional intrinsic 0–100 score from unvalidated `[OPEN]` placeholder anchors (decisions.md entries 50, 52) | Async | Processor actor |
| 8 | Composite Scoring | Standardized metrics | `SessionScore` (relative index + breakdown) | Combine **independent** signals into composite; map to baseline=100 index | Composite config [formula OPEN] | — | Async | Processor actor (pure function) |

## 8.1 Where the Algorithm Lives

The entire pipeline (stages 2–8) lives in the **`Algorithms/GaitAnalysis` module**: pure Swift (Accelerate is permitted here but not currently used), no SwiftUI/CoreMotion/SwiftData imports. Entry contract: a single `GaitScoringAlgorithm` protocol describing "raw buffer + baseline (optional) → `SessionAnalysisOutcome`", stamped with `algorithmVersion` [PRD export requires algorithm version]. The `SessionProcessor` actor is the *only* caller. View models never see the pipeline internals.

## 8.2 Specified vs. Unspecified (PRD-honest inventory)

**Specified by the PRD [do not deviate]:**
- Autocorrelation-based Ad1/Ad2 computed **identically for every user regardless of amputation type** [PRD OQ-1, §7].
- Step-time/cadence variability and the acceleration-based trunk-motion proxy are **independent inputs**, never derived from regularity; the trunk proxy must be a *specific computation* (e.g., RMS/variance of ML + vertical acceleration during steady-state walking) [PRD §7, OQ-1].
- Sound-vs-prosthetic step-time asymmetry is a **separate, secondary, labeled** feature — unilateral only, when side is reliably identifiable; never merged into the composite as a hidden term; never fabricated for bilateral users [PRD §7, OQ-1].
- Gait consistency is **never the sole basis** of the score [PRD §7].
- Minimum-SD floor on each metric's baseline standardization [PRD §7].
- Relative index (baseline = 100), not a percentage claim [PRD §7].
- Valid-walking minimums 60 s / 135 s as provisional product-quality thresholds, not research-validated [PRD OQ-3; decisions.md entry 47].
- Internal names *step regularity/stride regularity*; user-facing *gait consistency* [PRD OQ-1].

**Deliberately unspecified — [OPEN], kept swappable, not invented here:**
- The composite **formula and weights** (how metrics combine, index scaling — e.g. how a composite z maps to "112").
- The **noise threshold** (PRD: "define threshold").
- The **SD floor values**.
- Exact trunk-proxy formulation (RMS vs variance; per-axis vs combined). The pre-baseline trunk anchors are g-scale placeholders (ML poor 0.25 / good 0.05; VT poor 0.40 / good 0.10), still `[OPEN]`; the golden walks read ML 0.127–0.131 and VT 0.232–0.303, inside the range (decisions.md entry 50). Algorithm version is `1.2.0-provisional`.
- The asymmetry computation and the definition of "side reliably identifiable."
- Axis/orientation derivation method and phone-placement assumptions.
- Stride-count sufficiency tuning (15–20 strides is a reference point [PRD OQ-1], not a spec).

**Evolution interface:** every open parameter lives in a versioned `AlgorithmConfiguration`; the pipeline is stage-composable behind the `GaitScoringAlgorithm` contract, so a v2 algorithm is a new implementation + version string, with baseline/session records carrying the version they were computed under (§9.6).
