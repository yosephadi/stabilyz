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

---

## 12. Metric assembly — aggregation statistics and the asymmetry reading

**Date:** 2026-09-09 · **Task:** 5.2.5 · **Status:** Decided (statistics) · asymmetry formula superseded by entry 13

### Aggregation choices

Per-window features become one session's metrics. Each choice, and why:

| Metric | Statistic | Reasoning |
|---|---|---|
| Ad1, Ad2 | **Median** across windows | A window that caught a turn, a kerb or a stumble is an outlier, not a correction. Averaging lets one such window drag the session. |
| `cadenceMean` | **60 ÷ median pooled step time** | The metronome takes its tempo from this. A handful of long steps at a turn must not slow the pace the user is later asked to walk to. The field name is the docs/05 §5.1 name; the statistic is a robust centre. |
| `stepTimeCV` | CV **within** each window, then **median** across windows | CV is short-term variability, which is a within-window quantity. Pooling all step times first would fold between-window drift into it and inflate every session with more than one bout. |
| Trunk ML / VT RMS | **Median** across windows | Same outlier reasoning as Ad1/Ad2. |
| `steps`, `distance` | **Max** of pedometer events | Cumulative counters; the last reading is the total. Context only — a test asserts they change no measurement. |
| `validStrideCount` | **Sum** | Windows are non-overlapping (entry 11), so summing cannot double-count. |
| `observedStepPeriod`, `observedStrideLag` | **Median** | Provenance; carries the entry-11 tripwire to the metric level. |

Median uses the average of the two central values for even counts, so a
two-window session is not silently biased toward the later window.

### The profile enters here and only here

Stage 5 is profile-blind by construction; stage 6 is where the
unilateral/bilateral distinction legitimately lives, because whether a
sound-vs-prosthetic comparison is *meaningful* depends on the user having a
sound side. A test asserts that changing the profile changes only the asymmetry
value and its label — every other metric is byte-identical.

### Absence is a result, not a gap

`stepTimeAsymmetry` is nil — never zero — for bilateral profiles, for sessions
with no profile, and for walks whose peaks are not prominent enough to contrast.
Zero would claim perfect symmetry was *measured* [PRD §7]. Tests assert absence
explicitly, including `!= 0`, for each case.

`asymmetryAffectedSide` is added to `GaitMetrics` so the value is *labelled*, as
[PRD §7] requires. It comes from the profile, never from guessing at the signal.

### The concrete reading of the formula — SUPERSEDED

This section proposed reading `P1`/`P2` as the autocorrelation peaks *at* one and
two half-strides, making the index arithmetic on Ad1 and Ad2. **That reading was
rejected in review — see entry 13.**

### New tunable

| Parameter | Value | Reasoning |
|---|---|---|
| `AsymmetryPolicy.minimumPeakProminence` | 0.2 | **PROVISIONAL — pending device validation (Phase 12).** Normalised autocorrelation a peak must reach for its position to mean anything. Supersedes entry 1's note that no separate prominence threshold would be needed. |

---

## 13. Step-time asymmetry is a timing comparison — reading 2

**Date:** 2026-09-09 · **Task:** 5.2.5 (revised) · **Status:** Decided

Supersedes the asymmetry formula in entry 12.

### The decision

`asymmetryIndex = (τ2 − τ1) / (τ1 + τ2)`, where τ1 < τ2 are the **positions** of
the two autocorrelation peaks flanking the nominal half-stride. Unequal step
durations split that peak; equal durations leave one, giving τ1 = τ2 and an index
of exactly zero.

### Why reading 2, on the ledger's own grounds

[PRD OQ-1] reserves the name "step time asymmetry" for the literal
sound-vs-prosthetic limb comparison, and requires the feature be presented as
distinct from gait consistency. Reading 1 made the index arithmetic on Ad1 and
Ad2 — a monotone function of the two regularity metrics. Under that reading
"distinct from gait consistency" is **unsatisfiable**: the feature would be a
restatement of the thing it is supposed to be distinct from. Between two readings
of an ambiguous formula, the one that keeps a stated requirement non-vacuous wins.

A test now pins the independence directly: the amplitude-asymmetric fixture and
the timing-asymmetric fixture both show Ad2 above Ad1, yet only the second
reports asymmetry. Under reading 1 that test could not have separated them.

### Recorded: the ambiguity was an authoring error

The entry 12 formula ("(P1 − P2)/(P1 + P2) from autocorrelation half-stride
peaks") did not say whether P1 and P2 were peak *values* or peak *positions*, and
the two readings measure different phenomena. The Task 5.2.5 test requirement
compounded it by naming the Task 5.2.4 **amplitude**-asymmetric fixture as the
case that must yield nonzero asymmetry — which is only satisfiable under the
wrong reading. Caught in review. The lesson for later stages: when a formula and
its acceptance test are written together, an ambiguity in one can be laundered
into apparent correctness by the other.

### Reliability gate — "side reliably identifiable", provisional

Asymmetry is reported only when **mediolateral polarity alternates consistently**
across detected footfalls, at or above `minimumPolarityAlternationRate`.
Consecutive footfalls are opposite limbs, so a trunk that leans one way then the
other is evidence the two half-cycles are distinguishable at all. Without it, a
difference in step durations cannot honestly be attributed to limbs that were
never told apart.

**Prominence gates; split-ness does not** (architect's confirmation). The
instruction listed "split peaks present" as a gate condition while also
specifying that a single unsplit peak is a genuine ≈0 measurement; those conflict
literally. Confirmed reading: the gate is *peak structure prominent enough to
locate*, one peak or two. One prominent peak gives zero; no prominent peak gives
nil. Whether the peak splits determines the value, never the availability.

`AsymmetryUnavailability` records which gate failed — bilateral profile, no
profile, peaks not prominent, or side not reliably identifiable — so absence is a
result with a cause rather than a blank.

### Sign convention, and why limb attribution is [OPEN]

The index is **longer-step minus shorter-step**, so it is non-negative and says
how unequal the two step durations are. It does **not** say which limb is which.

The obstacle is concrete: the mediolateral axis is derived per session by PCA
(entry 1), and a principal component's sign is arbitrary — there is no world-frame
anchor to say which direction is the user's left. Polarity *alternation* is
sign-independent and therefore usable; absolute polarity is not. The profile's
`side` is carried as **context only**.

**[OPEN] — Phase 12 candidates for absolute limb attribution:** binding ML
polarity under a known phone placement, or a one-time calibration step that
anchors the axis. Neither is attempted in v1.

### New tunables

| Parameter | Value | Reasoning |
|---|---|---|
| `AsymmetryPolicy.halfStrideSearchTolerance` | 0.35 | **PROVISIONAL — pending device validation (Phase 12).** Fraction of the nominal half-stride searched either side; bounds the largest detectable asymmetry |
| `AsymmetryPolicy.minimumPolarityAlternationRate` | 0.8 | **PROVISIONAL — pending device validation (Phase 12).** Fraction of consecutive footfalls whose ML polarity must flip |

`usesHalfStridePeakRatio` is renamed `usesHalfStridePeakPositions`, so the policy
name states which reading is in force.

---

## 14. Cadence comes from the stride period

**Date:** 2026-09-09 · **Task:** 5.3.1 · **Status:** Decided · supersedes entry 12's cadence row

`cadenceMean = 120 / median(strideLag)`, not `60 / median(pooled step times)`.

**Why it changed.** A golden case caught the old form reporting **120 spm** for a
walk that is analytically **109.09** — half-cycles of 0.50 s and 0.60 s, a 1.10 s
stride. Pooling step times and taking their median is parity-unstable when step
durations alternate: the median lands on the shorter duration, the longer one, or
their average depending only on how many steps happened to be detected at window
boundaries. Alternating step durations are exactly the asymmetric gait this app
exists to measure, and the metronome takes its tempo from this value.

A stride contains exactly two steps by definition, so deriving cadence from the
stride period is parity-free. The entry 12 reasoning — a robust centre, not the
mean — still holds; the median is now taken over stride lags.

**Found by the golden suite, not by the unit tests.** The stage tests only
exercised cadence on a *symmetric* walk, where both forms agree. This is what
end-to-end goldens are for.

---

## 15. Golden regression suite

**Date:** 2026-09-09 · **Task:** 5.3.1 · **Status:** Decided

Ten end-to-end cases in `StabilyzTests/Goldens/`, run through
`GaitAnalysisPipeline` via `SessionProcessor`. Protocol in
`StabilyzTests/Goldens/README.md`.

### Regeneration protocol

Goldens are **never auto-updated**. A failing golden has exactly two
explanations and no third: a regression to fix in the code, or an intended
algorithm change requiring explicit approval plus a ledger entry recording what
moved and why. Regeneration is gated behind
`TEST_RUNNER_STABILYZ_REGENERATE_GOLDENS=1` and never runs in a normal test pass.
Widening a tolerance to make a golden pass is a regeneration in disguise and
needs the same approval.

### Derived versus recorded expectations

Each case stores both. **Derived** values follow from the signal parameters —
cadence is `120 / stride`, asymmetry is `|Δhalf| / stride` — and are asserted
against physics *as well as* against the file, so a golden that drifts away from
the signal it describes fails twice. **Recorded** values (Ad1, Ad2, CV, trunk
RMS) have no closed form and are pure regression anchors. The distinction is what
makes review possible: a regenerated file that nobody compared against the
signal's known parameters is a recording, not a golden.

### Measured sensitivity — an honest limit

The suite was probed by perturbing configuration values and re-running:

| Change | Goldens that failed |
|---|---|
| `lowPassCutoffHz` 20 → 12 | 1 of 10 |
| `stepPeakProminenceSDs` 0.5 → 1.4 | 0 of 10 |

The synthetic fixtures are clean, sharp footfall pulses, so step detection is
robust to its threshold and most of the signal energy sits well below either
cutoff. Both changes are therefore genuinely small *for these signals* — but the
suite should not be described as a tight net around every tunable. It pins the
pipeline's structural behaviour (validity decisions, reason codes, asymmetry
presence-versus-absence, cadence, gap and pause accounting) far better than it
pins the numeric sensitivity of the filters and thresholds.

**Phase 12 follow-up:** recorded device captures will exercise threshold
sensitivity in a way synthetic pulses cannot, and are the right basis for
tightening this.

### New production code this task required

The task was scoped as tests only, but two pieces of production code were
missing and the requirement could not be met without them:

- `GaitAnalysisPipeline` — the `GaitScoringAlgorithm` conformance composing
  stages 2–6. Task 5.1.1 defined the contract and 5.2.x built the stages, but
  nothing had ever wired them together. Stages 7–8 remain EPIC 6, so a valid
  session currently returns metrics with no score — the same shape a pre-baseline
  session has permanently.
- `profile` added to `GaitScoringAlgorithm.analyze` and
  `SessionProcessor.process`. Asymmetry is profile-dependent (entry 13) and
  stage 6 cannot run without it; the 5.1.1 contract had no way to pass it.

---

## 16. Baseline calculation — where the SD floor is applied, and how

**Date:** 2026-09-09 · **Task:** 6.1.1 · **Status:** Decided (method) / Provisional (values)

### The SD floor is applied at baseline creation, not at scoring time

`BaselineMetricStat.sd` stores the **floored** value; `sdFloorApplied` records
that it was raised. Task 6.2.1 will divide by the stored `sd` directly and must
not re-apply the floor.

Three reasons:

1. **docs/09 §9.1** describes the stat as "mean, sd, floor flag". A flag stored
   at rest only means something if the floor was already applied to produce the
   stored value.
2. **The baseline is frozen** [PRD §6]. Applying the floor at scoring time would
   let a later `AlgorithmConfiguration` change silently alter what an existing
   frozen baseline means — two sessions scored under different app builds would
   be incomparable despite carrying the same `algorithmVersion`.
3. **The divisor becomes inspectable.** It is exported and shown in the clinician
   summary as a fixed number, not a value recomputed on the fly.

### Sample standard deviation, not population

Divide by `n − 1`. The five calibration sessions are a *sample* of how this user
walks, not the whole of it, so the Bessel-corrected estimator is the unbiased one
for the underlying spread. At n = 5 the two forms differ by about 12%, which
materially changes every later z-score, so this is not a rounding-level choice.
A test pins the exact closed form and asserts the population value is *not* what
comes out.

### `cadenceBPM` is the arithmetic mean of the five session cadences

docs/09 §9.2 [REC]. An arithmetic mean is right here where a median was right
within a session (entry 14): these five values are already robust per-session
summaries, so there are no outlier samples left to defend against, and five
values have no stable median anyway.

### Asymmetry stat requires at least three of five

**PROVISIONAL — pending device validation (Phase 12).**
`BaselinePolicy.minimumAsymmetrySessions = 3`.

Asymmetry is the one metric that can legitimately be missing from some sessions
(entry 13). Below the minimum the stat is **absent**, not zero and not a mean of
whatever happened to be there — the same absence-versus-fabrication rule as the
metric itself [PRD §7]. `n` records how many sessions actually contributed, so a
thin stat is visible rather than indistinguishable from a well-supported one at
every later comparison.

### Refusals — defence in depth

The service refuses a wrong count, a session from another mode, an invalid
session, missing metrics, non-chronological or simultaneous sessions, duplicates,
and **sessions computed under different algorithm versions** (docs/09 §9.6).

Every one is a caller bug rather than a user-facing condition. They are checked
anyway because a baseline built from the wrong sessions is silently wrong
forever: every later score is measured against it, and v1 never recalibrates.
Same stance as `SessionProcessor`'s baseline-mode check [PRD OQ-5].

### Freezing is structural

There is no update, merge or recalculate entry point, and every `Baseline`
property is a `let`. A second calculation produces a *new* baseline and cannot
alter an existing one; `StoreWriter.establish` then refuses to store it
(Task 3.2.2). Freezing [PRD §6] holds at both layers without anyone having to
remember a rule.

### Version stamped from the sessions, not the configuration

The baseline carries the `algorithmVersion` its source sessions were computed
under, not whatever the current build is. Stamping the current version would
produce a baseline claiming comparability it does not have.

---

## 17. Baseline refusal on the fifth valid session

**Date:** 2026-09-09 · **Task:** 6.1.2 · **Status:** Decided

### What happens

Five valid same-mode sessions exist, but `BaselineCalculationService` refuses to
build a baseline from them — in practice because they were computed under
different algorithm versions (docs/09 §9.6).

The session is **committed alone**. It is a valid walk and the user's data; a
calculation problem is no reason to discard it. The count stands at five,
`BaselineState` reads `building(5)`, and `BaselineCommitOutcome.refused` carries
the reason.

**No silent fallback and no auto-restart.** No substitute baseline is invented
from four sessions or from a different five, and calibration is not reset to
"1 of 5" — a user who has walked five times has walked five times, and quietly
restarting their progress would be both wrong and unexplainable. A later session
retries against the same first five and refuses again, which is stable rather
than oscillating.

### The flag stays ephemeral — decided

The refusal is returned in `SessionCommitResult` and logged. It is **not**
persisted, and does not need to be.

**The stuck state is already persisted structurally:** five valid sessions of a
mode with no baseline row. That is derivable from the store, survives relaunch,
and travels in the EPIC 10 export archive with no new DTO field, because the
archive already carries valid sessions and baselines. The refusal *reason* is
recomputed on retry from the same inputs, so storing it would duplicate something
the data already determines.

Schema for docs/09 §9.6's version-mismatch policy — re-baseline prompt,
coexistence, or migration — lands **with that policy when it is decided**, not
before. v1 ships one algorithm version so the case cannot arise in practice; the
refusal path exists so that it fails visibly rather than silently if it ever
does.

### Ordering: compute, then write

The pure calculation runs before anything is persisted, so a set that cannot
produce a baseline is discovered while the store is untouched. The observable
consequence, and what the test asserts, is that **no baseline row is ever created
and then rolled back** on the refusal path.

### Atomicity: session and baseline commit together

`StoreWriter.commit(_:establishing:)` writes both in one transaction, with the
create-only check *inside* it. Writing them separately would leave a window where
the fifth valid session is stored and its baseline is not: the derived count
would read five with nothing established, and the next commit would try to
establish from a set that now includes a sixth session.

A test forces the failure by pre-establishing a baseline, then asserts the store
is byte-stable — no session row, no second baseline.

### The counter stays derived

Recounted from persisted valid sessions on every commit, never incremented
(docs/09 §9.4). A test writes a session behind the service's back and confirms
the next commit still counts correctly, which an accumulated counter could not.

---

## 18. Composite scoring and the relative index

**Date:** 2026-09-09 · **Task:** 6.2.2 · **Status:** Decided

### No renormalisation when a term is missing

If any of the four composite terms lacks a standardized value, **no score is
produced at all** — the session stays valid with raw metrics and
`ScoreUnavailability.missingCompositeTerm` is recorded.

Spreading the missing term's weight across the survivors was considered and
rejected. It would present a three-term score on the same 100-centred scale as a
four-term one: the number would look identical and mean something different, and
nothing on screen could distinguish them. A missing term also means half a trunk
proxy is not a trunk proxy — both ML and VT are required for that term.

The path is defensive in v1. Every valid session carries all six standardizable
metrics, and a baseline that reached five sessions has stats for all of them.

### Version validity

A session and baseline computed under different algorithm versions produce no
score, recorded as `algorithmVersionMismatch`. Same class as the baseline's own
mixed-version refusal (entry 17) and defensive for the same reason: v1 ships one
version, and a cross-version comparison would yield a number that looks fine and
means nothing (docs/09 §9.6).

### The score records the baseline's version

Not the session's. The comparison is only meaningful within the version the
baseline was built under, so that is what travels with the result.

### Stages 7 and 8 wired into the pipeline

`GaitAnalysisPipeline` now runs normalization and scoring when a same-mode
baseline is supplied. Before that it returns metrics with no score, which is
both the pre-baseline shape [PRD §7] and what every existing golden asserts —
they were re-verified as byte-identical after the change.

### Golden extension

`scored-sixth-session-quick` builds a real baseline from five calibration walks
through the same services the app uses, then scores a sixth. It pins two things:

- **Derived:** a calibration session scored against its own baseline gives
  **exactly 100** — every metric equals its own mean, so every z is zero.
- **Recorded:** the sixth session's index (102) and composite. A signal-level
  deviation has no closed form through the full DSP, so this is a regression
  anchor.

All ten pre-existing golden files were verified unchanged by the regeneration.

---

## 19. Simulator flakiness — re-run before diagnosing

**Date:** 2026-09-09 · **Task:** 6.2.2 (retrospective) · **Status:** Decided

### The signature

A run fails with a large number of tests reported failed at **0.000 seconds**,
often with `Early unexpected exit, operation never finished bootstrapping` or
`Failed to create a bundle instance representing …StabilyzTests.xctest`. The
attributed crash symbol is **arbitrary** — it names whichever test function was
nearest, and it changes between runs on identical code. The set of "failed" tests
also changes between runs.

That is the fingerprint of infrastructure, not a defect: a real crash reproduces
in the same place.

### The policy

**Re-run once before diagnosing.** A failure that reproduces is real and gets
investigated. A one-off is infrastructure and is discarded.

**No code change may result from a non-reproducing failure.** Bisecting against
an unstable simulator produces conclusions that are noise — a bisect step that
"passes" may simply have got a good run.

### Why this is written down

It was learned the expensive way during Task 6.2.2: a run reported 131 failures
at 0.000 s, and four bisection runs were spent chasing it through new code. The
same code then passed twice in a row, and the already-committed tree reproduced
the same symptom class. Nothing was wrong with the code, and no change came out
of the detour — but the time did.

### Escalation

If the frequency grows, investigate the simulator setup itself — clone count,
device state, DerivedData staging — rather than absorbing it as a per-run cost.

---

## 20. MetricBreakdown and the encouraging summary

**Date:** 2026-09-09 · **Task:** 6.2.3 · **Status:** Decided (structure and rules) / Provisional (values)

### The breakdown is per *signal*, not per metric

docs/04 §4.9 lists what the user sees: gait consistency, step-time/cadence
variability, trunk-motion proxy, asymmetry when present. Two of those rest on
more than one metric — consistency on Ad1 and Ad2, the trunk proxy on ML and VT.

The breakdown carries **both components** rather than collapsing them, because
whether they present as one number or two is EPIC 8's call, and a domain type
that collapsed them would take that decision away. `SignalID` raw values are
stable keys; `provisionalLabel` is explicitly EPIC 8's to replace.

"Gait consistency" is *not* provisional. [PRD OQ-1] fixes it, and a test asserts
no signal label except the asymmetry one may contain "symmetr".

### Absence vocabulary carried forward unchanged

`MetricAvailability` is `standardized` / `rawOnly` / `unmeasured` — 6.2.1's
distinctions, kept intact so the Score screen and the clinician summary describe
absence the same way the pipeline did. A signal with nothing on either side is
omitted rather than shown empty.

### Cadence and asymmetry carry values, never verdicts

Neither has a decided direction (entry 3), so neither gets a
`directionAdjustedZ` and neither can ever produce an improvement claim in the
summary. Tests assert both — including that a large cadence move with weak
recent history still yields no claim.

### Summary v0 — every template has a predicate

[PRD] requires the summary be "generated from real metric comparisons within the
same mode, not a static string". Each of the six claims is reachable only when
its evidence exists, and every predicate is tested **both ways**: a claim that
can appear without its data is the failure mode worth guarding, because it is
invisible in the output.

Three hard rules, each with a test:

- **No percentage claim** [PRD §5, §7] — the composite is not calibrated to
  support "12% more stable". A guard asserts no `%` and no "percent" across
  every branch, with a companion test proving those cases reach all six claims,
  so the guard cannot silently stop covering them.
- **No improvement claim without an improvement**, and a signal only counts if
  *every* metric behind it improved — half a trunk proxy improving is not the
  trunk proxy improving.
- **Nothing implying the baseline is permanent** [PRD §6], and no medical
  language. Both are keyword-audited.

A below-baseline session is stated plainly and paired with "walking varies day to
day", so an honest result is not delivered as a failure.

### Same-mode filtering happens inside the engine

The generator takes raw history and filters to valid same-mode sessions itself,
rather than trusting the caller. A test passes Full Test sessions that would look
like a large improvement mixed with flat Quick Test history and asserts they are
ignored [PRD OQ-5].

### New tunables

| Parameter | Value | Reasoning |
|---|---|---|
| `SummaryPolicy.recentSessionCount` | 3 | **PROVISIONAL — [OPEN].** [PRD] says "vs. last N sessions of that mode" without fixing N. Three is more than the previous walk and still means "lately". |
| `SummaryPolicy.minimumNoticeableChange` | 0.25 SD | **PROVISIONAL.** Below this, a difference is indistinguishable from ordinary session-to-session variation, and calling it a change would be a claim the data does not support. |
| `SummaryPolicy.aroundBaselineIndexMargin` | 3 points | **PROVISIONAL.** Index points either side of baseline that still count as "about usual". |

### Handoff: the summary cannot run inside the pipeline

`GaitAnalysisPipeline` is pure and has no history, so it cannot generate a
summary. `SessionScore` is therefore left carrying `relativeIndex`, `compositeZ`
and `algorithmVersion` only; attaching `breakdown` and `summaryLine` belongs to
**Task 6.2.4**, at commit time, where the repository can supply recent same-mode
sessions.

---

## 21. Score completion is structural

**Date:** 2026-09-09 · **Task:** 6.2.4 · **Status:** Decided

Entry 20 established that the pure pipeline cannot produce a complete score: the
summary line needs recent same-mode history, and the pipeline has none. That
boundary is now enforced by the type system rather than by discipline.

### Two types, one direction

- **`PartialSessionScore`** — what the pipeline computes: index, composite,
  algorithm version, and the breakdown (pure, needing only the standardization
  and the session's own metrics). Deliberately **not `Codable`**. There is no
  encoder for it, so it cannot reach the store.
- **`SessionScore`** — the persisted result. Its **only** initializer is
  `init(completing:summaryLine:)`, so a stored score always carries everything
  the Score screen and clinician summary need.

`GaitSession.score` accepts only the complete type, and `GaitSession.scored(_:)`
is the single path that attaches one after the fact — it returns nil for an
invalid session, so "invalid sessions are never scored" [PRD AC] is enforced at
the one place that could break it.

The split proved itself immediately: every existing `SessionScore(relativeIndex:)`
call site stopped compiling, which is exactly the accident the requirement was
guarding against.

### Scoring eligibility is the baseline-existence check

A score is completed and stored only when the mode's baseline existed **before**
this commit. That is the same condition that makes a session the sixth or later,
so the [PRD §7] rule needs no separate counter: the fifth valid session
establishes the baseline and carries no score, and pre-baseline sessions store
metrics only.

### The summary is frozen at commit

It records what was true when the session was committed. Regenerating it later
against different history would rewrite the past — the same reasoning that
freezes the baseline [PRD §6]. A test adds three further sessions afterwards and
asserts the stored line is unchanged.

### Compute before write, and filter twice

History is read and the summary generated before anything is persisted. The
reader excludes the session being committed — otherwise it could improve against
itself — and fetches one extra row so the exclusion cannot leave the caller
short. The generator then filters by mode and validity again: defence in depth,
because a comparison reaching across modes is what [PRD OQ-5] forbids.

### Persistence shape

`relativeIndex` is the scalar column History and the trend chart query;
`breakdown` and `summaryLine` ride in the JSON blob (docs/05 §5.2). A test reads
the raw entity to confirm the column is populated for the scored session and null
for every other.

---

## 22. Foundation is permitted in Domain and Algorithms

**Date:** 2026-09-09 · **Task:** EPIC 6 close-out · **Status:** Decided

CLAUDE.md and docs/03 rule 1 previously said `Domain/` and `Algorithms/` import
**no** Apple frameworks. Both now read: no Apple frameworks **except Foundation**
(Accelerate additionally allowed in `Algorithms/`).

### Why the original wording could not hold

docs/05 specifies the domain model in terms of `Date` (`startedAt`, `endedAt`,
`establishedAt`, `disclaimerAcceptedAt`, `createdAt`), `UUID` (every entity id,
`sourceSessionIDs`) and `Duration`. `Date` and `UUID` live in Foundation and have
no stdlib equivalent, so the two documents contradicted each other: the layering
rule forbade exactly what the data model required.

This was flagged when it first bit, in Task 1.2.1, and Foundation has been
imported in those layers ever since. The amendment makes the written rule match
both the specification and the code, rather than leaving a rule that every file
in the layer visibly breaks — a rule nobody can follow teaches people to ignore
rules.

### What the rule still excludes, unchanged

SwiftUI, CoreMotion, AVFoundation, SwiftData, CryptoKit and CommonCrypto. That is
the intent that matters: the gait science stays independently testable, and no
UI, hardware or persistence type can leak into it. Foundation carries no such
coupling.

### Now enforced, not just written

`ImportHygieneTests` scans every `.swift` file under `Domain/` and `Algorithms/`
and fails naming the file and the offending import. The rule is checked by the
suite rather than by reviewer memory.

---

## 23. AVAudioEngine tones service

**Date:** 2026-09-09 · **Task:** 7.1.1 · **Status:** Decided (design) / Provisional (the sounds)

### One owner for AVAudioSession

`EngineAudioFeedbackService` is the only component that configures, activates or
observes `AVAudioSession` (docs/10 §10.2). The interruption observer from
Task 4.2.3 consumes this service's `events` stream instead of observing the
session itself, so the category and active state have a single writer and there
is no ordering question between two components managing it.

Enforced by a source scan, not by convention: a test walks every `.swift` file
under the app source and fails naming any file outside the owner that references
`AVAudioSession` in code (comments excepted).

### Tones are synthesised, not shipped

A sine burst with a linear fade is a handful of lines, diffable in review, and
avoids carrying audio files whose provenance and licensing would need tracking
for a two-tone app. The fade exists because a hard edge on a sine burst clicks,
which reads as a defect rather than a cue.

**The sounds themselves are PROVISIONAL.** Pitch, length and envelope are
placeholders pending device listening (Phase 12). What [PRD AC] actually requires
— that start and stop are *distinct* — is asserted by test on both frequency and
duration.

### Latency by construction

Buffers are synthesised and nodes attached once during `prepare()`, with one
player per tone so a step tick never waits behind a stop tone. Playing is then a
`scheduleBuffer` on an already-running node: no allocation, no file I/O, no main
actor hop [PRD §7 — the sound must feel connected to the step].

### Degradation is the only failure mode

Every method is non-throwing and every failure path logs and continues silently
(docs/10 §10.4). A tone requested before `prepare`, after `teardown`, or while
suspended is dropped rather than queued — a tick arriving after an interruption
ended would be worse than no tick. A walk is measured perfectly well in silence.

### Suspend and resume are separate from teardown

An interruption is temporary, and rebuilding the engine for one would cost the
latency the preload bought. `suspend`/`resume` stop and restart playback while
keeping the nodes and buffers; Task 7.1.2 drives them from the event stream. A
failed resume stays suspended, which is silence rather than a crash.

### What the simulator cannot verify

Buffer contents, engine state transitions, idempotence and the drop-when-suspended
behaviour are all verifiable off-device and are tested. **Audible output, real
route changes, Bluetooth behaviour and actual sound-to-footfall latency are not**
— they require a device and belong to Phase 12 (docs/19 §19.4).

---

## 24. Audio degradation on route change and interruption

**Date:** 2026-09-09 · **Task:** 7.1.2 · **Status:** Decided

### The state machine, and why it is separately callable

`handle(_ event:)` applies an audio-session event to the engine. The
`AVAudioSession` notification observers call it *and* publish the event; tests
call it directly.

That separation exists because a simulator cannot be made to change audio route.
Without it the entire degradation path would be untestable and would first run in
front of a user whose AirPods went flat mid-walk.

- **Interrupted** → suspend. Stop cleanly rather than fight for the session.
- **Interruption ended** → resume, or degrade. Never a third state.
- **Route changed** → rebuild the engine against the new route. A route change
  can change the output sample rate, which invalidates the existing connections
  and buffers; reconnecting and re-synthesising is cheap and happens between
  tones. Failing to rebuild degrades to silence rather than leaving nodes wired
  to a format that no longer exists.

### Degradation is terminal, silent, and logged

Once degraded the service stays silent for the rest of the session: no alert, no
error screen, no interruption to the walk [PRD §6], with a log trail for
diagnosis. `ErrorPresenter` has returned nil for every audio error since
Task 2.2.2; a test restates it here, because 7.1.2 is where audio starts actually
failing.

### Drop-don't-queue survives the interruption boundary

7.1.1 drops tones requested while suspended. This task adds the second half:
they are not replayed on resume either. `scheduledToneCount` makes that
observable — a tick that arrives after the interruption has ended is worse than
no tick, because it lands against a footfall that already happened.

### The 4.2.3 decision stands, now pinned end to end

Audio route changes and audio interruptions **do not** increment
`interruptionCount`; only `didEnterBackground` does. Three tests hold the line:
audio events alone leave the count at zero, a backgrounding among them still
counts exactly one, and the recorder's own event stream carries no `.interrupted`
for audio trouble — the Recording screen must not report an interruption because
someone's headphones disconnected.

Recorder isolation is asserted by comparison rather than by inspection: the same
fixture is recorded twice, once with audio events fired throughout, and the
sample count, gap info, gap list and interruption count are identical.

### What the simulator cannot verify

Real Bluetooth disconnection, real route switching, actual rerouting to the
device speaker, and audible continuity across a route change. The *policy* is
tested; the hardware behaviour is Phase 12 (docs/19 §19.4).

---

## 25. Audio is requested, never awaited — the data path is independent of it

**Date:** 2026-09-09 · **Task:** EPIC 7 close-out (audit finding 1) · **Status:** Decided

**Supersedes the Start/Stop ordering in docs/07 §7.3**, which has been amended
to match.

### What changed

`SessionRecorder` no longer awaits any `AudioFeedbackService` call. The start
tone, the metronome start, the metronome stop and the stop tone are handed to a
separate task via `requestAudio`; the data path runs on regardless:

```
begin: permission → sensors → confirm delivery → .ready → [request tone + metronome]
stop:  disarm feedback → [request stop tone] → stop sensors → drain → freeze → handoff
```

### Why

The EPIC 7 audit (docs/audits/epic-7.md, finding 1) recorded that scoring was
provably independent of audio while *Stop* was not. `stop()` awaited
`stopMetronome()` and `playStopTone()` before freezing the buffer, so a wedged
audio layer could delay — in principle indefinitely — the batch that [PRD §7 AC]
says audio must never block or alter. The shipped engine cannot block there, but
"our implementation happens not to" is a weaker guarantee than the AC deserves,
and it is not the kind of property that survives a future maintainer.

The ordering it replaced was not itself a PRD requirement. The PRD requires two
behaviours — a session records, and distinct start and stop tones play — not any
particular internal sequencing between them. Ordering is still preserved where
it is observable: the tone is requested *after* readiness is signalled and after
the feedback engines are disarmed, so a tone can never precede its recording nor
sound over a beat that should already have stopped.

### What this costs

Under a dead or wedged audio layer the tone is lost rather than delayed. That is
the same best-effort treatment every other sound already gets (docs/10 §10.4:
audio failure is surfaced only as silent degradation and can never fail a
session). A walk measured in silence is a complete measurement; a walk that
never freezes because a tone never returned is not.

### What would change it

A PRD requirement that the stop tone be *guaranteed* audible before the session
ends — which would mean bounding the wait rather than removing it, since an
unbounded wait can never be a guarantee anyway.

### Verification

`theDataPathNeverAwaitsAudio` records, stops, freezes and scores a session
against an audio layer where **every** call stalls for thirty seconds, bounding
each recorder call so a regression fails rather than hangs. The result is
byte-identical to a clean run and every audio call is still in flight at the
end. Mutation-verified: restoring `await audioFeedback.playStopTone()` to the
critical path fails the test at its bound.

---

## 26. Liquid Glass by progressive enhancement, deployment target stays 17.0

**Date:** 2026-09-10 · **Task:** 8.1.5 · **Status:** **Reversed 2026-09-11**

> **Reversed.** Liquid Glass is not adopted, and `DesignSystem/GlassStyle.swift`
> is deleted — both `adaptiveGlass(_:in:)` and the `GlassSurface` vocabulary
> with it. The app's one translucent surface is `.ultraThinMaterial`, applied
> directly at its two call sites: the back chip, and the primary button in its
> disabled state.
>
> Two reasons. Over `bg-base` (`#F7F7F7`) the iOS 26 material renders as a pale
> low-contrast disc barely distinguishable from the flat white fill it was
> supposed to replace, so the enhancement bought nothing on the screens that
> used it. And the abstraction existed to serve a primary button that has since
> stopped wanting a translucent surface when it is enabled (§27) — with the
> button gone, `adaptiveGlass` had one caller, and a two-branch OS fork
> maintained for one circle is not an abstraction, it is an unused one.
>
> **The deployment target is unaffected.** It was already 17.0 and stays there;
> `.ultraThinMaterial` is available on it, which is why the fallback branch
> worked in the first place. What is gone is the *branching*, not the material.
>
> The original decision is kept below because the reasoning still holds for what
> it decided — if Liquid Glass is revisited on a darker surface where it has
> contrast to work with, this is the shape that adoption should take.

iOS 26's Liquid Glass is adopted where the OS provides it and falls back to
`.ultraThinMaterial` where it does not. `IPHONEOS_DEPLOYMENT_TARGET` stays
**17.0** — the same target docs/17 sets — so no user loses the app to get the
material.

### What changed

`DesignSystem/GlassStyle.swift` adds two modifiers, and they are the only place
in the app that names a glass API:

- `.adaptiveGlass(_ surface: GlassSurface, in: some Shape)` — `glassEffect` on
  iOS 26, `.background(.ultraThinMaterial, in:)` below it.
- ~~`GlassCapsuleButtonStyle` (`.glassCapsule` / `.glassCapsuleHero`) — the
  primary button's surface, built on `adaptiveGlass` rather than on a system
  prominent style.~~ **Reverted 2026-09-11: deleted.** The primary button is a
  stock `.borderedProminent` capsule with `.buttonBorderShape(.capsule)`,
  tinted `primary-600`. The custom style had reimplemented four things iOS
  already does — surface, press animation, disabled dimming, and a hairline to
  keep the translucent version from dissolving into `bg-base` — and the
  approximations of the first two read as uncanny rather than neutral. Its full
  history: it began as `.adaptiveGlassButtonStyle(tint:)` wrapping
  `.glassProminent` / `.borderedProminent`, became bespoke glass on 2026-09-10
  (Task 8.1.6) to match the onboarding designs' translucent button, and is now
  the system control again.

`adaptiveGlass` branches on `if #available(iOS 26.0, *)`. `GlassSurface` still
distinguishes `.button` (interactive glass, reacts to touch), `.card` and
`.chrome`; the back chip is the only caller today.

**The progressive-enhancement decision below is unchanged by the reversal.** It
governs how a glass surface is obtained, not which controls are glass.

### Why

Progressive enhancement rather than a version fork. Both branches produce a
translucent surface **in the same shape**, so layout, hit-testing, Dynamic Type
and contrast are identical either way and only the material differs. That is
what makes it safe to apply without maintaining two designs: there is no iOS 17
layout and an iOS 26 layout, there is one layout that is glass where glass
exists.

Confining the availability check to two modifiers is the other half. A
`#available` at each call site would spread OS-version knowledge across every
screen and make the fallback something each view remembered separately; here a
view asks for a glass surface and the design system decides what that means on
this OS.

`primary-600` stays the brand tint wherever a control is tinted (§8).

### What this costs

The fallback is not a visual match. `.ultraThinMaterial` is a blur, not glass:
no specular edge, no refraction, no interactive response to touch. An iOS 17
user gets a coherent translucent design, not a facsimile of the iOS 26 one, and
that is the accepted trade.

Glass is applied to chrome and buttons, not to the onboarding answer card. The
screen designs draw that card as an opaque white panel, and the design wins over
reflexively glassing every surface.

### What would change it

Raising the deployment target to 26.0, which would make the fallback branch dead
code and let the modifiers collapse to direct `glassEffect` calls. Not worth
doing for the material alone.

### Verification

The four APIs used (`glassEffect(_:in:)`, `Glass.regular.interactive()`,
`.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`) were compiled against
the iOS 26.4 SDK before the modifiers were written. The app builds for both
Debug and Release at deployment target 17.0.

---

## 27. The onboarding card is built from primitives, not from `List`

**Date:** 2026-09-10 · **Task:** 8.1.7 · **Status:** Settled

The wizard's answer card is a `VStack` in a `RoundedRectangle`, not a
`List(.insetGrouped)`. §5's component law is unchanged and unbroken: every
control is still stock SwiftUI.

### What changed

`DesignSystem/OnboardingCard.swift` adds `OnboardingCard`, `ChoiceCard`,
`ChoiceRow` and `CardRow`. The wizard's five answer screens use them; §5 now
reserves `.insetGrouped` for full-screen scrolling surfaces — Settings, History,
session detail — and defines the onboarding card as its own primitive.

### Why

`.insetGrouped` is a full-screen surface, not a card. It brings its own
horizontal margins, its own background and its own scroll view, and none of
them can be switched off cleanly. Inside a wizard step that already has a 24pt
container margin and its own scroll view, that produced a card inset twice over
and a scroll view nested in a scroll view. Cancelling the scroll inset with
`contentMargins` addressed half of it and left the section inset behind.

The earlier reading of §5 — "no custom card view is built" — treated `List` as
the only native way to draw a card. That was too narrow. `VStack`,
`RoundedRectangle`, `Divider` and `Button` are exactly as stock as `List`, and
composing four of them is not a custom control; it is the ordinary way to build
a container that is not a full-screen list. The law is about not hand-rolling
*controls*, and none is hand-rolled here.

### What this costs

The selected-state accessibility that `Picker` provided for free is now written
out: each row carries `.isSelected` alongside its `checkmark`. That is a real
obligation rather than a nicety — the checkmark is what a sighted user reads,
and without the trait it would be the only thing announcing the answer. It is
one line per row and `ChoiceRow` is the only place it can be forgotten.

### What would change it

A native container that is a card rather than a screen. `List` is not it, and
`Form` is the same surface with more opinions.

### Verification

The existing onboarding suite covers selection through the same bindings the
rows now drive, so behaviour is pinned independently of the container. The
inset problem itself was visual and is not test-covered; §5 now states the rule
that prevents its return.

---

## 27. The primary button is a custom capsule, for its disabled state only

**Date:** 2026-09-11 · **Status:** Settled

`PrimaryCapsuleButtonStyle` (`.primaryCapsule` / `.primaryCapsuleHero`) draws
the app's primary button: a full-width `Capsule` at 55pt on single-decision
screens.

| State | Fill | Edge | Label |
|---|---|---|---|
| Enabled | `primary-600` | none | `on-primary`, 17 Semibold |
| Disabled | `.ultraThinMaterial` | 1px `ink-200` | `ink-400`, 17 Semibold |
| Pressed | as above at 85% opacity, 0.15s ease-out | | |

### Why

This control has now been through three forms, and the third is settled because
it is the first one chosen for a reason that is about the *disabled* state.

The **enabled** half is exactly `.borderedProminent` tinted `primary-600`, and
if that were the whole control it would be the system's. It is not: the disabled
half is the problem. `.borderedProminent` dims its own fill into an opaque grey
slab that ends up heavier on the page than the enabled button it replaces — the
loudest element on a screen where the user has not yet done anything. Onboarding
opens on that state five times out of six, so it is not an edge case, it is the
first thing the user sees.

`.ultraThinMaterial` inverts that: the page shows through, and the button reads
as unavailable by being *lighter* rather than greyer. The hairline is
load-bearing rather than decorative — the material has almost no edge against
`bg-base`, and without it the capsule loses its shape.

This is **not** a return to `GlassCapsuleButtonStyle` (§26), which was
translucent in both states and so never looked pressable at all. Here
translucency is what "not yet" means, and the enabled button is a solid navy
capsule.

### What this costs

The press animation and the disabled dimming are ours again, so they can drift
from iOS. Both are one line each in a single style, and the enabled appearance
is deliberately identical to the system's — if a future iOS changes what a
filled capsule looks like, this is the one file to reconcile.

### The part that is not about looks

The sizing and `contentShape(Capsule())` are applied to `configuration.label`
**inside** the style. That is what makes the whole capsule tappable. Applied
outside a `Button`, `maxWidth: .infinity` stretches the control while its hit
area stays wrapped around the word "Next" — a ~30pt target on a 354pt button,
and the failure this user base would hit hardest. Putting it in the style means
no caller can get it wrong.

---

## 28. The session starts at Go, not at the tap

**Date:** 2026-09-12 · **Task:** PRD OQ-6 (pre-8.2.6) · **Status:** Decided (behaviour) / Provisional (the 5 seconds)

**Amends** PRD §5, §6, §7 and OQ-3; docs/04 §4.5-4.6; docs/07 §7.1, §7.3, §7.4,
§7.7, §7.8; docs/23 EPICs 4, 5, 7, 8. All have been updated to match.

### What changed

Tapping Start Test no longer begins recording. It begins a **5-second countdown**,
and recording — including the valid-walking-data timer — begins at the final tick
("Go"):

```
tap Start Test → prime sensors, count 5 4 3 2 1 → Go: stamp T-0, open buffer, start tone
Stop           → instant, no countdown
```

The countdown is **both visible and haptic, not one or the other**: numerals on
screen for the user still looking at the phone, a haptic tick per second for the
user who has already pocketed it, a perceptibly distinct tick at Go so haptics
alone can separate "1" from "go", and a VoiceOver announcement per numeral. The
five counting ticks play no tone; the existing start tone sounds once, at Go.

### Why

Two reasons, and the second is the load-bearing one.

The obvious one is that a user cannot tap Start and be walking in the same
instant — they have to stow the phone first, and that fumble was previously
recorded.

The one that matters more: the spec excluded "setup time" from valid-walking-data
without ever defining where setup ended. The final tick now defines that boundary
precisely. Everything before Go is **outside the session** rather than recorded and
then filtered — `RawSessionBuffer`'s first sample is the first at or after the T-0
anchor, and persisted `startedAt` is T-0, not the tap.

This does **not** retire `WalkingSegmentDetector`. A user still takes a few steps
to get going and still stops at crosswalks; those segments are still excluded
after Go. The narrower, true claim is that phone-stowing has left the recording,
not that non-walking exclusion is solved.

### Why visible *and* haptic

Haptic-only would fail any user who cannot perceive haptic feedback, so the
on-screen numerals are the **required fallback channel, not a redundancy** — the
countdown is never gated on haptic hardware being present or enabled, and degrades
silently when it isn't. The VoiceOver announcement closes the converse gap: a
VoiceOver user with the phone already pocketed would otherwise have had neither
channel until the tone at Go.

### Why Stop stays instant

The delay at Start buys something real — time to get situated — that has no
equivalent at Stop, where the user has already finished walking. The asymmetry is
deliberate and should not be "fixed" into symmetry by a later reading. Stop keeps
its single haptic pulse and its existing distinct stop tone, unchanged.

### What this costs

A new Apple-framework dependency (CoreHaptics), which per the layer rules means a
new protocol-fronted `HapticFeedbackService` in `Services/` — Task 7.3.1, and the
reason EPIC 7 is now "Audio & Haptics" rather than "Audio". A new screen (8.2.6)
with its own cancellation semantics. And a new failure mode to defend against:
priming that fails *at* Go, after the phone is pocketed, would be a silent failure
of exactly the kind [PRD §6] forbids — hence priming runs inside the countdown
window and aborts while the screen is still being watched.

### The alternative considered and rejected

**Proximity sensor + accelerometer stability detection** — auto-firing the start
haptic once the phone was detected as "settled" in a pocket, instead of counting
down a fixed interval. Rejected: it is a heuristic with real misfire modes (phone
in a bag rather than a pocket, wrong orientation, a user who carries the phone in
hand, a pocket loose enough that it never settles), and every misfire either starts
a session the user isn't ready for or hangs without starting one at all. That is a
new failure class and meaningful engineering risk for an uncertain payoff over a
fixed countdown the user can see, feel and count on. **Not to be reintroduced.**

### What would change it

Device sessions showing 5 seconds is the wrong duration — in which case **the
constant moves; it does not become a user preference**. Per-mode or user-set values
were considered and rejected: the countdown is a setup affordance, not a measurement
parameter, and making it adjustable would add a settings surface and a second
setup-time definition for no measurement benefit.

### Still open

`[define: priming deadline before zero]` — how long priming may take inside the
countdown window before the abort fires. Replaces the old
`[define: e.g. 1 second]` start-latency placeholder, which the countdown reframes
rather than resolves. Due with the device campaign (11.2.2), alongside audio
latency validation.

---

## 29. One admission gate, at the buffer boundary

**Date:** 2026-09-12 · **Task:** 5.1.1 · **Status:** Decided

Implements the T-0 contract from entry 28. `SampleAdmission` (Domain) states the
rule; `SessionSampleBuffer` is the single place that applies it.

### What changed

`SessionSampleBuffer` is now armed rather than open: `arm(at:)` sets T-0,
`append` returns whether the sample was admitted, and an unarmed buffer admits
nothing. `freeze()` rehydrates against the anchor it was armed with rather than
one passed in at freeze time, so the gate and the thaw cannot disagree.
`RawSessionBuffer.honoursAdmissionContract` asserts the result.

`SessionRecorder.ingest` gates by asking the buffer:

```
guard sampleBuffer?.append(sample) == true else { return }
```

### Why one gate and not two

The first cut had the recorder check `SampleAdmission` itself and *then* hand
the sample to the buffer, which also checked. Both were correct and the tests
still passed — but the recorder's early return meant the buffer never saw a
rejected sample, so the buffer's rejection counter read zero on a real session
and the drop went unlogged. A test asserting the logged count is what caught it.

That is the general shape of the problem with two gates: they do not disagree
about the verdict, they disagree about everything *around* the verdict —
counters, logs, and which component's rejection is the one that happened.
Asking the buffer keeps one rule, one count, one log line.

The cost is that buffering moved ahead of gap detection and step detection in
`ingest`. Nothing observable changed — a rejected sample must not move the gap
cursor or fire a footfall either — and the ordering that docs/10 §10.4 actually
requires (detection after buffering, so feedback can never delay the recording)
is strengthened, not weakened.

### Why the buffer and not the recorder

The buffer is the boundary the samples cross. Gating at the recorder would leave
the buffer independently appendable, so a future caller — a replay tool, a
capture harness — could fill it with pre-T-0 samples and nothing would object.

### What would change it

Priming moving out of the recorder entirely (Task 4.2.2 splits `prime()` from
`begin()`). The gate stays at the buffer; what changes is who arms it and when.

### Verification

32 tests across three files. `SampleAdmissionTests` holds the rule, including
that the boundary is closed on the session's side and that it is anchored to
uptime rather than wall clock. `SessionSampleBufferTests` holds the buffer,
including that rejected samples never reach the scratch file and that the gate
survives degraded spilling. `SessionRecorderTests` drives 500 samples of
lead-in through the real recorder and asserts the frozen buffer honours the
contract, that the lead-in produces no phantom gap, and that it does not stretch
the recorded span.

**A float note, since it cost a test.** At an uptime of 1000 the representable
gap is ~1.1e-13, so `uptime - .ulpOfOne` rounds straight back to `uptime`: the
"just before T-0" case was silently testing *at* T-0 and passing for the wrong
reason. Boundary tests use `nextDown`, which is the real predecessor at whatever
magnitude the anchor happens to sit at.

---

## 30. The recorder primes, begins and aborts as three separate calls

**Date:** 2026-09-12 · **Task:** 4.2.2 · **Status:** Decided

Implements the lifecycle docs/07 §7.3 describes. `SessionRecorder` gains
`prime(mode:audioConfig:)`, `begin(at: TimeAnchor)` and `abort()`; states run
`idle → priming → primed → running → idle`.

### What changed

Everything that can fail moved into `prime`: permission, hardware availability,
sensor start, delivery confirmation. `begin(at:)` does nothing that can throw
except refuse an unprimed recorder — it arms the buffer at T-0 and starts
draining. `abort()` ends a countdown without a session.

### Why every failure belongs in priming

At Go the phone may already be in a pocket. A failure discovered there is a
failure nobody sees: the user walks two minutes and gets an error screen at the
end of it. Priming runs while the screen is still being watched, so the same
failure costs a retry instead of a walk. That is the whole reason for the split
— not tidiness.

The recorder does **not** impose its own priming timeout. `CoreMotionSensorService`
already enforces the budget and throws `sensor(.primingTimeout)` if the first
sample never arrives, so `start` returning means the sensor is genuinely
delivering. A second timer here would be one budget in two places, which is two
budgets. The recorder adds only the check the service cannot make for it:
`isAvailable`, so a countdown never starts against absent hardware.

### The lead-in is held, not drained

The first cut consumed samples during the countdown, letting the unarmed buffer
turn them away as they arrived. It had a race. `begin(at:)` must await
`stepFeedback.start` and the interruption observer, and every await lets the
consumer run — so a sample genuinely at-or-after T-0 could be read while the
buffer was still unarmed and be rejected, punching a hole in the recording
exactly at its start. It also broke fixture replay, where the whole capture is
yielded before `start` returns and would have been consumed and discarded before
Go ever arrived.

Both streams are unbounded, so the countdown's samples now accumulate and are
drained at Go, after arming. The timestamp decides every sample's fate, which is
what the admission contract is for (entry 29). "Dropped at admission" is about
*where* they are dropped, not when.

### Why `begin` does not prime for you

It would put a variable, multi-hundred-millisecond sensor spin-up *after* the
instant the session claims to have started — the exact ambiguity the countdown
was introduced to remove. `begin(at:)` on an unprimed recorder is
`recording(.notPrimed)`.

`begin(mode:audioConfig:)` survives as a convenience for a start with no
countdown in front of it, but it is strictly `prime` then `begin(at:)` — one
lifecycle, so the two entry points cannot drift.

### Why the anchor is passed in

The countdown stamps T-0 at its final tick, so T-0 is the instant the user was
shown and felt rather than whenever `begin` happened to be scheduled.

### Why `abort()` refuses a running session

`stop()` is the only exit past T-0 and the only place the `AVAudioSession` is
released (entry 25). An abort that obeyed while running would hold the audio
route after the walk and bin a real recording. It logs and declines instead.
`abort()` is non-throwing on purpose: cancellation paths are the last place that
should have to handle an error.

### There is no `stopped` state

A recorder is reused across sessions (docs/12 §12.3), so the only thing a
terminal state could mean is "ready for the next session" — which `idle`
already means. Adding one would be a state with no behaviour of its own.

### Verification

21 tests. Priming starts sensors with zero admitted samples and holds there for
the length of a countdown; `begin(at:)` arms at the anchor it was given and the
frozen buffer carries that anchor and honours the contract; `abort()` releases
the sensor, restores the screen, opens no audio session, leaves no scratch file
and leaves the recorder reusable; priming timeout, absent hardware and denied
permission each surface at prime and reset the recorder. Two drive the full
shape Task 8.2.6 will use — prime, five seconds of countdown, Go — and assert
the lead-in was rejected and reported rather than silently binned.

---

## 31. Haptics are feedback generators, not a haptic engine

**Date:** 2026-09-13 · **Task:** 7.3.1 · **Status:** Decided

`Services/Haptics/` gains `HapticFeedbackService`, `LiveHapticFeedbackService`,
and `Mock`/`Silent` doubles, wired into both production graphs.

### What changed

Five calls: `prepare`, `playCadenceTick`, `playSessionStart`, `playSessionStop`,
`teardown`. Taps come from `UIImpactFeedbackGenerator` — `.light` per numeral,
`.heavy` at Go, `.medium` at Stop.

### Why UIKit and not CoreHaptics

The PRD asks for three taps of three weights, with the Go tap *perceptibly
distinct* from the counting ticks so a user reading the countdown through a
pocket can tell "1" from "go" [PRD OQ-6]. `light → heavy` is the widest contrast
the generators offer, and they respect the user's System Haptics setting for
free. `CHHapticEngine` would buy custom envelopes nobody asked for, at the cost
of an engine lifecycle, a reset handler and a stopped-handler to get wrong.

CoreHaptics is still imported, for one line: `capabilitiesForHardware()
.supportsHaptics` is the correct hardware probe even when the taps come from
UIKit.

### What the capability check does not cover

**There is no public API for the System Haptics toggle.** When it is off the
generators simply do nothing. That is the right outcome and indistinguishable
from here, so the setting needs no detection — what it needs is that nothing
downstream depends on a tap having happened, which the protocol already
guarantees by never reporting success or failure.

### Silent, but not invisible

"No Taptic Engine" and "haptics broken" look identical from outside. One
`.info` line per service instance — not per countdown, since `prepare()` runs
every time the countdown screen appears — keeps them distinguishable without
filling the log with a non-fault.

### Isolation

`UIFeedbackGenerator` must be used from the main thread, but the protocol is
`nonisolated` and `Sendable`, and a `@MainActor` type cannot witness it under
this project's default isolation. So the generators live in a `@MainActor`
box and the service is a nonisolated façade that hops to it. The isolation sits
with the UIKit objects that need it rather than being spread across the
protocol.

### What this deliberately does not do

Nothing calls any of it yet. The countdown screen (8.2.6) owns the cadence —
how many ticks, and firing Go alongside the start tone. Building the caller
here would mean guessing at a screen that does not exist.

### Verification

14 tests. The double proves the countdown's shape — five ticks then exactly one
Go, Go never collapsing into a tick, an aborted countdown taps no Go. The live
service is exercised on the simulator, where `supportsHaptics` is false: every
method is a no-op that returns, repeated `prepare`/`teardown` are safe, a tap
without a prepare still works, and the log assertion branches on
`isSupported` so it stays true when the suite runs on a phone. One test holds
both production graphs to carrying the real service — the EPIC 7 audit caught
exactly that omission for audio, where the engine was built, tested, and
reachable from nothing.

---

## 32. The countdown is a coordinator with an injected cadence

**Date:** 2026-09-13 · **Task:** 8.2.6 (logic) / 7.2.3 (silence) · **Status:** Decided

`Features/Session/Countdown/CountdownCoordinator.swift` drives the countdown:
`idle → priming → counting(n) → running`, with `cancelled` and `failed` as the
other two outcomes. `Domain/Policies/CountdownPolicy` holds the five seconds;
`Utilities/CountdownTicker` holds the waiting.

### Why the cadence is injected

A countdown that slept on the real clock could only be tested by waiting five
seconds — slow, flaky on a loaded machine, and still unable to say *when*
cancellation landed. `CountdownTicker` is one method, `waitForTick(_:)`. The
test double parks each tick until released, which is what makes "cancel at T-1"
a precise claim rather than a hopeful one: the countdown is provably sitting on
the last numeral when cancel arrives.

### Why `start` is not `async`

`cancel()` has to interrupt a tick that is already sleeping — a user who taps
Cancel must not wait out the rest of a second they have already decided
against. That needs a task to cancel, so `start` stores one and returns.
`waitUntilFinished()` exists for tests and for a caller that wants the outcome.

### Task 7.2.3, twice over

Neither cue may sound before Go: a metronome under a haptic countdown is
directly confusable with it, and would pace gait across a window that is not
being measured. That is already true structurally — only `begin` arms a cue,
never `prime` — and the coordinator adds an unconditional `stopMetronome()`
before counting, so a beat left running by an earlier flow is silenced rather
than counted over. It is a no-op when nothing is running.

**Mutation-verified.** Sounding a cue inside the countdown loop fails
`noCueSoundsAtAnyPointDuringTheCountdown` and
`stepFeedbackIsEquallySilentBeforeGo`. Without that check the two tests would
have been indistinguishable from tests that assert nothing.

### Why cancel refuses a running session

Past T-0 there is a real walk in progress and ending it is `stop()`'s job —
the same reason `SessionRecorder.abort()` refuses there (entry 30). The
coordinator logs and declines rather than silently doing nothing.

### The countdown length

`CountdownPolicy` sits beside `SessionPolicy` in `Domain/Policies`, versioned
for the same reason: five seconds is **provisional and tunable** [PRD OQ-6],
and a tunable value belongs in one declared place rather than in a view. There
is deliberately no `length(for: TestMode)` and no stored setting behind it —
[PRD OQ-6] settles it as a single fixed constant, not a preference.

### What this deliberately does not do

There is no SwiftUI screen yet. The numerals, the Cancel button, the VoiceOver
announcement per numeral and the backgrounding/auto-lock wiring are the
remaining half of 8.2.6. This is the part that can be tested without rendering,
which is where docs/11 §11.5 wants the rules to live anyway.

### Verification

19 tests. The full sequence idle → priming → counting(3, 2, 1) → running, with
haptics recorded as three ticks then exactly one Go; T-0's anchor surviving into
the frozen buffer; cancellation at T-1 halting the ticks, aborting the recorder
and starting no session; priming failure landing on `.failed` with the real
error, having counted nothing; and silence across the whole countdown under both
cue configurations.

---

## 33. The session setup copy matrix lives in the view model

**Date:** 2026-09-13 · **Task:** 8.2.1 · **Status:** Decided

`Features/Session/Setup/` — `SessionSetupViewModel` decides every string,
`SessionSetupView` draws Figma node 123:914 with design tokens.

### Where the Figma node and the PRD disagree

The node is the authority on layout. It is **not** the authority on defaults,
and three things in it are settled the other way:

- **The audio cue toggle is drawn ON.** [PRD §7 AC] says off by default — "the
  user must explicitly opt in for any audio during baseline-establishing
  sessions", because even a footfall-triggered sound can nudge step timing in
  the sessions that define the reference point. Off, in every state.
- **"Start & Stop Haptics" is drawn OFF.** The task spec says on by default,
  and that is right: unlike the audio cues, haptics do not influence gait —
  they mark when the measurement starts and stops [PRD OQ-6]. On.
- **The node's first toggle reads "Audio Walking Cues".** The task's copy
  matrix specifies "Metronome Cue" post-baseline and "Audio Step Feedback"
  before. The matrix wins, because the toggle's *identity* changes with the
  baseline and one neutral label would hide that: "Audio Walking Cues" reads as
  one feature you switch on, when it is two mutually exclusive ones [PRD §5].

### Where the spec's copy was changed

"Complete \(remaining) more valid Quick Tests" is ungrammatical at
`remaining == 1` — which is the session before last, when the line matters
most. It reads "Complete 1 more valid Quick Tests". Pluralisation agrees with
the number instead. On a screen built for readers in their seventies, the
sentence telling them how close they are is the last one to get sloppy.

### The gates are on the config, not the toggle

`audioConfig` is derived from the baseline state every time it is read, so a
toggle left on cannot smuggle a metronome into a pre-baseline session or
strand step feedback in a post-baseline one. `MetronomeCue` has no initializer
taking a bare BPM, so a cue can only ever carry this mode's own cadence
[PRD OQ-5].

### 100 comes from the domain

`Baseline.referenceIndex` is new. The card shows the reference index, and a
`100` typed into a view would be a number that could drift from the scoring
that produces it.

### What this deliberately does not do

`onStart(mode:audioConfig:)` hands the choice outward. This screen chooses a
session; it does not begin one — the countdown (8.2.6) does. Nothing routes to
the screen yet either, so it compiles and its logic is fully tested but it has
**not been seen running**.

### Verification

20 tests covering all six cells of the matrix, both toggle identities, the
off-by-default and on-by-default rules, both gates including the cross-boundary
case, and all four permission outcomes. The design-token guard and the 15pt
typography floor both scan `Features/` and passed with the new view in scope.
