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

**Date:** 2026-09-09 · **Task:** 6.1.2 · **Status:** Decided (behaviour) / **[OPEN]** (recovery policy)

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

### The flag is currently ephemeral — [OPEN]

The refusal is returned in `SessionCommitResult` and logged. It is **not
persisted**: nothing in the schema records "this mode has five valid sessions and
a baseline that could not be built".

That is deliberate for now, because the recovery policy is itself deferred.
docs/09 §9.6 leaves algorithm-version mismatch handling [OPEN] — re-baseline
prompt, coexistence, or migration — and until that is decided there is nothing
for a persisted flag to drive. v1 ships one algorithm version, so the case cannot
arise in practice; the refusal path exists so that it fails visibly rather than
silently if it ever does.

**Phase 12 / post-v1:** deciding §9.6's policy also decides whether this flag
needs persisting and what the user is told.

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
