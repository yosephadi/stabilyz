# Decisions Ledger

A running record of decisions that the PRD and TDD leave open, or that required
choosing between two defensible readings of them. New decisions are **appended**;
existing entries are amended in place only when the decision itself changes.

Each entry records what was decided, why, and what would change it.

---

## 1. AlgorithmConfiguration v1 — provisional tunables

**Date:** 2026-09-09 · **Task:** 5.1.2 · **Status:** Provisional

Every `[OPEN]` algorithm parameter in docs/08 §8.2 is given a value so the
pipeline can be built and measured. **All of these are provisional and pending
device validation (Phase 12).** They live only in
`Algorithms/AlgorithmConfiguration.swift`; no other file declares one.

| Parameter | Value | Notes |
|---|---|---|
| Sample rate | 100 Hz | docs/07 §7.2 recommendation, unvalidated |
| Noise metric | power above 8 Hz ÷ total power, on acceleration magnitude | Walking energy sits below the cutoff |
| Noise threshold | 0.35 | Above this ⇒ `excessiveNoise` |
| SD floor | `max(observedSD, 0.05 × abs(baselineMean), absoluteFloor)` | Floor itself is PRD-required [PRD §7 AC]; the value is not |
| Absolute SD floors | Ad1 0.02 · Ad2 0.02 · cadenceMean 2.0 · stepTimeCV 0.01 · trunkML 0.05 · trunkVT 0.05 · asymmetry 0.02 | Catches a baseline mean near zero |
| Composite weights | Ad1 0.25 · Ad2 0.25 · stepTimeCV 0.25 (inverted) · trunkProxy 0.25 (inverted, ML+VT z averaged) | Equal quarters |
| Relative index | `round(100 + 100 × compositeZ)`, clamped `[0, 200]` | Baseline = 100 [PRD §7]; clamp stops one wild session breaking the trend chart |
| Trunk proxy | Per-axis RMS (ML, VT) over steady-state walking | Kept as two values so both stay inspectable |
| Orientation | Vertical from the gravity vector; ML/AP split by dominant horizontal variance; recomputed per session | No assumed phone placement |
| Asymmetry index | `(P1 − P2) / (P1 + P2)` from autocorrelation half-stride peaks | Unilateral profiles only, both peaks prominent, side label from profile |
| Minimum valid strides | 15 | docs/08 cites 15–20 as a tuning reference, not a spec |
| Step-feedback confidence | 0.5 | Replaces the earlier `placeholderConfidenceThreshold` |
| Refractory window | 300 ms | docs/10 §10.3 `[REC]` |
| Gap tolerance | 3 × **observed median** sample interval | Median, not nominal rate — see entry 4 |

**What would change these:** real-device sessions in Phase 12, especially with
prosthetic-limb users. Changing one is a configuration edit plus a version bump;
sessions and baselines record the version they were computed under, so old data
stays interpretable (docs/09 §9.6).

---

## 2. Asymmetry is displayed, not scored — a chosen reading

**Date:** 2026-09-09 · **Task:** 5.1.2 · **Status:** Decided (interpretation)

**The two readings.** [PRD §4] describes the score as computed "from several
independent signals — gait consistency, step-time/cadence variability, and an
acceleration-based trunk-motion proxy — **plus**, for unilateral users where a
sound side is identifiable, a secondary limb-specific timing-asymmetry feature."
Read on its own, "plus" could mean asymmetry is a fourth score input.

[PRD §7] is narrower: the asymmetry feature is "distinct… not merged into a
single number", and docs/08 §8.2 restates it as "never merged into the composite
as a hidden term".

**What we chose.** The narrower §7 reading. `stepTimeAsymmetry` is computed,
stored and displayed on its own; it is **not** a `CompositeTerm` and contributes
no weight to the relative index.

**Why.** If asymmetry entered the composite, the score would mean something
structurally different for unilateral and bilateral users — a bilateral user's
index would be built from four terms and a unilateral user's from five. Scores
would not be comparable across amputation types, and a user whose side stopped
being reliably identifiable would see their index shift for a reason unrelated to
their walking. Keeping it separate preserves one consistent composite for
everyone, which is also what makes the "never fabricated for bilateral users"
rule [PRD §7, OQ-1] cost nothing.

**This is a chosen interpretation, not a silent resolution.** If the §4 reading
was intended, the change is a new `CompositeTerm`, a weight, and a decision about
what the composite means for bilateral users.

---

## 3. Metrics with no decided direction

**Date:** 2026-09-09 · **Task:** 5.1.2 · **Status:** Decided — no directions in v1

`cadenceMean` and `stepTimeAsymmetry` are standardised against a baseline and get
SD floors, but carry **no** `MetricID.Direction` in the configuration.

Neither contributes to the composite, and neither has an obvious sign: a faster
cadence is not self-evidently better, and asymmetry is signed by which side leads.
Asserting a direction would let the UI label a change "better" or "worse" on a
judgement nobody has made.

Cadence is a value, not a verdict. Asymmetry's sign is meaningful — it says which
side leads — but not better or worse.

**Consequence:** the breakdown shows these two as values, never as improvements
or regressions.

---

## 4. Gap tolerance is relative to observed delivery

**Date:** 2026-09-09 · **Task:** 5.1.2 · **Status:** Decided

The gap threshold is `3 × median observed sample interval`, not `3 ÷ nominal
sample rate`.

Thermal throttling and background pressure make real delivery slower than
requested. Measured against the nominal rate, a throttled-but-continuous stream
would be reported as an unbroken run of dropouts and could push a sound session
onto the noisy path.

Below three intervals there is no meaningful median — with one interval the
median *is* that interval, so nothing could exceed a multiple of itself and a
lone dropout would go unreported. In that case the requested rate is the fallback.

A single dropped sample going unreported is **accepted**: preprocessing resamples
onto a uniform grid regardless, and a real suspension is seconds long, not one
sample.

---

## 5. Deferred decisions

**Date:** 2026-09-09 · **Status:** Open

| Decision | Owner | Why deferred |
|---|---|---|
| Which `InvalidReason` a **cancelled** processing run persists | Task 8.2.3 | docs/14 §14.3 requires a cancelled run to leave an invalid session, but none of the four PRD reason codes covers cancellation. `SessionProcessor` surfaces `processing(.cancelled)`; the session flow decides what to store. |
| **Phone-placement** guidance copy | EPIC 8 | The orientation policy assumes no fixed placement, but the Session Setup screen still has to tell the user something. Wording is a product decision, not an algorithm one. |
| **Device validation** of every value in entry 1 | Phase 12 | Simulators cannot produce realistic prosthetic gait (docs/19 §19.4). |
| Algorithm-version **mismatch** handling | Post-v1 | docs/09 §9.6 — v1 ships one version so the case cannot arise; the data model already stamps versions. |
| Score screen renders **asymmetry as a signed, side-labelled value**, never better/worse | EPIC 8 | Follows from entry 3: asymmetry has a meaningful sign but no direction. |

---

## 6. Preprocessing tunables

**Date:** 2026-09-09 · **Task:** 5.2.1 · **Status:** Provisional

Discovered while implementing pipeline stage 2. All live in
`PreprocessingPolicy` inside `AlgorithmConfiguration`, each marked
**PROVISIONAL — pending device validation (Phase 12)**.

| Parameter | Value | Reasoning |
|---|---|---|
| `targetSampleRateHz` | 100 | Matches acquisition, so resampling interpolates between neighbours rather than changing rate |
| `highPassCutoffHz` | 0.5 | Removes drift and residual gravity; below a slow walk's stride frequency, so no gait content is attenuated |
| `lowPassCutoffHz` | 20 | Above gait harmonics. Deliberately above the noise metric's 8 Hz cutoff — this one *cleans* the signal, that one *judges* it |
| `gravityEstimationCutoffHz` | 0.5 | Only used for accelerometer-only captures with no gravity vector |
| `minimumSegmentDuration` | 2 s | A shorter fragment between two dropouts carries no usable gait and only contributes filter edge artefacts |
| `filterEdgePaddingCycles` | 3 | Cycles of the high-pass cutoff to reflect-pad with; ~3 time constants is where an IIR has settled |
| `zeroPhaseFiltering` | true | Forward-backward, so peaks stay where they happened |

**Two non-tunable implementation decisions worth recording:**

- **Zero-phase filtering.** Step times are measured off this signal. A one-sided
  filter delays every peak equally — harmless for intervals between peaks, but it
  would misplace them against the pedometer stream and the gap record, which sit
  on the untouched timeline. Forward-backward filtering costs a second pass and
  removes the question.

- **Mean removal and reflect-padding before filtering.** Both were added after
  tests caught real artefacts: a large DC offset made the high-pass start from a
  step and ring for roughly a second, and the un-padded filter's start-up
  transient landed on real gait data at both ends. Neither is a tuning choice;
  handing an IIR a step and then measuring the ringing is simply wrong.

**Filter form:** second-order Butterworth biquads (Q = 1/√2), written out rather
than taken from Accelerate. The filter is the part of the pipeline most worth
being able to read and check by hand, and at 36k samples the cost is irrelevant.
