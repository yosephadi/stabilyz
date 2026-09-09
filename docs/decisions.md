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

---

## 7. Hand-written biquad instead of vDSP

**Date:** 2026-09-09 · **Task:** 5.2.1 · **Status:** Decided

docs/08 lists Accelerate/vDSP as stage 2's dependency. The band-pass is written
out as second-order Butterworth biquads in plain Swift instead.

**Why.** Zero-phase filtering is not a single vDSP call anyway — `filtfilt` is
forward pass, reverse, second pass, reverse, so the framework would carry only
the inner loop. The filter is scientific-core code: it decides what the rest of
the pipeline sees, and being able to read and check it by hand is worth more here
than the loop speed. Its behaviour is pinned by tests against synthetic signals
with known frequency content, so a later swap has a safety net.

**Precision:** the coefficients and filter state are `Double` throughout. At this
scale single precision buys nothing and a band-pass accumulating error across a
forward-backward pass is not worth the risk.

**Swap trigger:** profiling ever showing filter cost matters. It will not at 36k
samples, but if the window count or a v2 algorithm changes that, the biquad has a
test suite ready to validate a vDSP replacement against.

---

## 8. Noise must be measured before the cleaning low-pass

**Date:** 2026-09-09 · **Task:** 5.1.2 → binding on 5.2.3 · **Status:** Decided

The noise ratio (power above 8 Hz ÷ total power) must be computed on the **raw or
resample-only** signal, **before** the 20 Hz cleaning low-pass in
`PreprocessingPolicy`.

Measuring it after filtering would judge noise on a signal whose noise has just
been removed: a session recorded against high-frequency vibration would come back
looking clean, and would then be scored as if it were a good walk. The two cutoffs
exist for different purposes — 20 Hz cleans the signal, 8 Hz judges it — and the
judging has to happen first.

**Binding on Task 5.2.3:** the ordering must be explicit in the code and covered
by a test that a high-frequency-vibration session is rejected rather than cleaned
into apparent validity.

---

## 9. Walking-detection tunables

**Date:** 2026-09-09 · **Task:** 5.2.2 · **Status:** Provisional

Discovered while implementing pipeline stage 3. All live in
`WalkingDetectionPolicy` inside `AlgorithmConfiguration`, each marked
**PROVISIONAL — pending device validation (Phase 12)**.

| Parameter | Value | Reasoning |
|---|---|---|
| `activityWindow` | 1 s | About two strides, so one footfall cannot open a bout and one quiet moment between steps cannot close one |
| `verticalRMSThreshold` | 0.05 g | Standing registers near zero after the band-pass; walking trunk acceleration is an order of magnitude larger |
| `maximumBridgedPause` | 0.5 s | Hesitating at a kerb is one walk, not two |
| `initiationTrim` | 1 s | Gait initiation is not steady-state gait [PRD OQ-1, Tura note] |
| `terminationTrim` | 1 s | Gait termination, likewise |
| `minimumBoutDuration` | 3 s | What remains after trimming must be long enough to measure |
| `plausibleCadenceRange` | 30–200 spm | Only for judging pedometer agreement, never for overriding it |

**Pedometer is a hint, not authority.** The accelerometer decides where walking
is; the pedometer result is recorded as `PedometerAgreement` — implied cadence,
whether that cadence is plausible, and whether the two disagree about walking
being present at all. Disagreement is recorded and the session proceeds on the
accelerometer's evidence. A pocket carry can under-count steps while the trunk
signal is perfectly good, and treating the pedometer as authoritative would throw
away a valid session.

**Deliberately deferred: spectral walking validation.** Stage 3 separates movement
from stillness by amplitude, not by whether the movement is periodic at walking
frequencies. A vehicle ride could clear the RMS threshold. That case is caught
downstream — the noise ratio (entry 8) flags road vibration, and step detection
in Task 5.2.4 requires plausible step peaks. Adding a cadence-band test here would
duplicate stage 5's work with a second set of thresholds. Revisit if device data
shows non-gait movement surviving both downstream gates.

**Accounting:** every clean sample lands in exactly one of walking, transient, or
excluded, and a test asserts the three sum to the session length. Nothing
disappears silently between stages.

---

## 10. Signal quality validation

**Date:** 2026-09-09 · **Task:** 5.2.3 · **Status:** Decided

**No new tunables.** Stage 4 reuses `NoisePolicy` (8 Hz cutoff, 0.35 threshold)
and `SessionPolicy` (90 s / 240 s) from entry 1. The dominant-frequency
diagnostic derives its search band from `plausibleCadenceRange` (30–200 spm ⇒
0.5–3.33 Hz) rather than declaring one of its own.

**Entry 8 is now structural, not just documented.** `PreprocessedSegment` carries
`preFilterMagnitude` — acceleration magnitude after resampling, mean-removed,
before the 20 Hz cleaning band-pass. The noise ratio is computed from that field
and no other. A test proves the ordering matters rather than asserting it
indirectly: on a session with a 35 Hz vibration component, the ratio measured on
the pre-filter signal exceeds the threshold while the same calculation on the
cleaned channels falls below it.

**Noise ratio is implemented as a filter, not a transform.** `variance(highPass(x))
÷ variance(x)` expresses the same quantity as a spectral power ratio and is O(n).
The high-pass is not a brick wall, so the ratio is an estimate — which is all a
threshold comparison needs.

**Noise is measured over the walking intervals**, not the whole session. Noise
during a pause says nothing about whether the walking can be scored. When no
walking was found, the whole clean signal is used so the report still carries a
value instead of a misleading zero.

**Reason precedence when both gates fail:** insufficient walking is reported, per
entry 1's ordering — it is the plainer explanation. Both facts stay in the
report (`walkingShortfall` and `exceededNoiseLimit` are independent), so the
noisy screen can mention noise even when duration is the headline.

**Dominant-frequency diagnostic** (per-walking-interval, in Hz) is recorded and
never gates. It is the evidence Phase 12 needs to decide whether entry 9's
deferred spectral validation is ever required: a vehicle ride and a walk look
different here even when both clear the amplitude threshold.

**Autocorrelation uses the biased estimator** — divide by the full window length,
not the overlap. A periodic signal correlates just as well at twice its period,
so the unbiased estimator leaves fundamental and harmonics tied and lets a
subharmonic win, reporting half the true frequency. This was caught by a test
expecting 1.8 Hz and is worth carrying into Task 5.2.4, where Ad1/Ad2 depend on
exactly this distinction.

---

## 11. Feature extraction — lag anchoring and windowing

**Date:** 2026-09-09 · **Task:** 5.2.4 · **Status:** Provisional (values) / Decided (method)

New tunables in `FeatureExtractionPolicy`, each marked **PROVISIONAL — pending
device validation (Phase 12)**.

| Parameter | Value | Reasoning |
|---|---|---|
| `analysisWindowDuration` | 10 s | Holds well over the ~3.5 strides Tura reports as sufficient for Ad2 once transients are excluded [PRD OQ-1], while several windows still fit in a Quick Test |
| `minimumAnalysisWindowDuration` | 5 s | A trailing window this long is still worth analysing rather than discarding the end of every walk |
| `stepPeakProminenceSDs` | 0.5 | Low enough not to miss the weaker side of an asymmetric gait, high enough to ignore ripple between steps |
| `lagSearchTolerance` | 0.15 | Fractional window around an expected lag when reading an autocorrelation peak |

**The step lag comes from detected footfalls, not from the strongest
autocorrelation peak.** This is the load-bearing decision of the stage. In an
asymmetric gait the stride peak can be *stronger* than the step peak, so
anchoring on "whichever correlation is biggest" is exactly how Ad1 and Ad2 end up
swapped — and a swapped pair still looks entirely plausible in the output. The
step period is taken as the median detected step interval, cross-checked against
`plausibleCadenceRange`; the stride lag is twice it. Both peaks are then read
within `lagSearchTolerance` of their own expected lag. **The search is never
free.**

**The swap test is verified to have teeth.** With the two anchors deliberately
exchanged, `unequalHalfCyclesGiveStrideRegularityAboveStepRegularity` and
`eachAdIsReadAtItsOwnLagAndTheStrideLagIsTwiceTheStepLag` both fail. A test that
would pass either way would be worse than no test here.

**Ad values are clamped to [0, 1].** A negative correlation at a lag means the
pattern does not repeat there — that is zero regularity, not a negative amount of
it.

**Windows are non-overlapping.** Overlapping windows would count strides twice,
and the stride total gates the session at the minimum-strides check. The trailing
partial window is kept only if it reaches the minimum.

**Profile blindness is structural.** `FeatureExtraction.extract` takes no
`UserProfile` and nothing in the stage branches on amputation level or side, so
Ad1/Ad2 are computed identically for every user [PRD OQ-1, §7 AC]. The test
constructs a unilateral and a bilateral profile to make the invariant explicit
and to fail loudly if a profile parameter is ever added; the one profile-dependent
feature, sound-vs-prosthetic asymmetry, belongs to stage 6.

**Stage boundary held.** Stage 5 emits per-window facts — step times, Ad1, Ad2,
per-axis trunk RMS. Aggregating those into session `GaitMetrics` is Task 5.2.5.
Collapsing them here would destroy the across-window variability that step-time
CV is computed from.
