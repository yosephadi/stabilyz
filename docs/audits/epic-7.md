# EPIC 7 Audit — Audio

**Performed by:** the Claude Code session that implemented Task 7.2.3, immediately after it.
**Date:** 2026-09-09.
**Method:** read-only inspection plus one full test run. The only code changes in this session are Task 7.2.3's own tests, the scoring-independence source scan, and one line added to `CLAUDE.md`.


**Postscript (2026-09-09, EPIC 7 close-out):** findings 1 and 3 are closed, and
finding 2 is scheduled.

- **Finding 1 — resolved.** `SessionRecorder` no longer awaits any audio call in
  either direction; the tones and the metronome are requested off the critical
  path. Recorded as decisions.md entry 25, which supersedes the Start/Stop
  ordering in docs/07 §7.3; §7.3 has been amended to match. `WedgedAudio` now
  stalls **every** audio call, and `theDataPathNeverAwaitsAudio` proves a session
  still records, freezes, hands off and scores byte-identically with all of them
  still in flight. Mutation-verified at its bound.
- **Finding 3 — resolved, at the type level rather than by a scan.**
  `SessionAudioConfig.metronome` now carries a `MetronomeCue`; no bare-BPM case
  remains, so a hand-written tempo is a compile error rather than something a
  guard has to notice. `MetronomeCue` gained a validating `init(from:)` —
  decoding is a read of history and re-checks only what stays checkable.
- **Finding 2 — scheduled, not closed.** Task 8.2.2 in
  docs/23-engineering-task-breakdown.md now carries the `AppDependencies` swap
  and the `prepare()`/`teardown()` lifecycle it depends on. The app is still
  silent until that lands.
- Findings 4 and the §6 judgment calls stand as written.

---

## 1. Full suite

`xcodebuild -project Stabilyz/Stabilyz.xcodeproj -scheme Stabilyz -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` — **TEST SUCCEEDED, 573 test cases executed, 0 failures** (567 unit, 6 UI). Run twice on the final tree.

**Methodology note, learned the hard way this session:** an `-only-testing` filter that matches nothing reports **TEST SUCCEEDED**. A mutation check run as `-only-testing:StabilyzTests/name` (no parentheses) executed zero tests and looked like a clean pass; the same check as `-only-testing:"StabilyzTests/name()"` failed as it should have. Any single-test run must be confirmed by executed-test count, not by the result line. Now recorded in `CLAUDE.md`.

## 2. PRD AC → test map

### §6 Session flow (audio-relevant)

| AC | Tests |
|---|---|
| Start plays a distinct start tone; Stop plays a distinct, different stop tone | `startAndStopTonesAreDistinct` (asserted on both frequency and duration), `everyToneIsSynthesisedNotLoadedFromAnAsset`, `aRenderedToneHasTheRequestedLengthAndStaysInRange`, `aToneFadesInAndOutRatherThanClicking`; ordering (ready → tone; stop tone → teardown) in `SessionRecorderTests` |
| Bluetooth device disconnects mid-session — fail silently to speaker or stop cleanly, never crash or freeze | `aRouteChangeIsSurvivedAndTheSessionContinues`, `anInterruptionSuspendsPlayback`, `theEndOfAnInterruptionResumesOrDegrades` (running-or-degraded, never a third state), `repeatedEventsAreIdempotent`, `aDegradedEventIsNotAmplifiedIntoFurtherDegradation`, `failureToStartDegradesSilently`, `aDegradedServiceStaysSilentButStaysUsable`, `everyToneCallIsSafeBeforePrepare`, `everyToneCallIsSafeAfterTeardown`, `teardownIsSafeWithoutPrepare` |
| Audio trouble never disturbs the recording | `audioEventsNeverIncrementInterruptionCount`, `onlyBackgroundingStillCounts`, `audioEventsLeaveTheRecordedSamplesUntouched`, `theSessionEventStreamCarriesNoAudioNoise`, `degradationIsLoggedRatherThanSurfaced`, `audioFailureIsNeverPresentedToTheUser` |

### §7 Step Feedback (sessions 1–5, pre-baseline)

| AC | Tests |
|---|---|
| **Off by default** — explicit opt-in required | `theWiringIsInertWithoutTheSessionsOptIn` (asserts `isConsuming == false`: the stream is not read, not read-and-ignored), `aSessionWithoutTheOptInNeverTicks`, `aMetronomeSessionDoesNotGetStepFeedback`, `theRecorderEmitsStepEventsOnlyWhenStepFeedbackIsOn` (the recorder builds no detector either — both halves) |
| Sound only on steps the detector is confident are genuine | `aStepBelowTheConfidenceThresholdIsSilent`, `onlyTheConfidentStepsOfAMixedRunTick`, `aStepExactlyAtTheThresholdTicks`, `lowConfidencePeaksDoNotFire`, `raisingTheThresholdFiresLessOften`, `confidenceIsBoundedToTheUnitRange` |
| Refractory period prevents one footfall producing more than one sound | `aSecondEventInsideTheRefractoryWindowIsSuppressed`, `theWindowIsMeasuredFromTheLastTickNotTheLastEvent`, `aShorterWindowLetsCloserStepsThrough`, `anOutOfOrderEventIsSuppressed`, `oneFootfallCannotProduceTwoTicks`, `theRefractoryWindowIsConfigurable` |
| **Never sets, targets or implies a tempo** — purely reactive | `irregularStepsProduceIrregularTicks` (tick intervals mirror step intervals exactly; spread > 0.5 s), `ticksFollowDetectedFootfallsThroughTheWholePath` (every tick within 30 ms of a scripted footfall, never evenly spaced), `standingStillIsSilent`, `aFlatSignalProducesNoSteps`, plus the source scan `theStepFeedbackPathSchedulesNothing` |
| Sound-to-footfall latency low enough not to feel disconnected | **By construction, not measured** — see §4 |

### §7 Metronome cue (session 6+, post-baseline)

| AC | Tests |
|---|---|
| Only available once that mode's baseline cadence exists — never during sessions 1–5 | `withoutABaselineTheMetronomeCannotBeSelected`, `aModeWithNoBaselineYetGetsNoMetronomeEvenWhenTheOtherModeHasOne`, `aBaselineFromTheOtherModeIsRefused`, `anImplausibleCadenceProducesNoCueRatherThanAnUnplayableTempo` — enforced by construction: `MetronomeCue` has no initializer taking a bare BPM |
| Toggle on/off before a session starts | Screen-level → Task 8.2.1; the data side is `noSessionOptInStartsNoScheduling`, `aMetronomeSessionStartsAndStopsAtTheSessionsTempo` |
| Steady interval derived from that mode's baseline cadence | `theIntervalIsSixtyOverTheBaselineCadence`, `anAwkwardCadenceStillYieldsItsExactInterval`, `eachModePacesFromItsOwnBaseline` (Quick 96 / Full 124, each using its own), `theGridIsAWholeNumberOfFramesPerBeat`, `beatsAreEvenlySpacedAndDoNotDrift` (one spacing over 200 beats, no accumulated drift), `anUnusableTempoOrFormatProducesNoSchedule`, `startingTheMetronomeQueuesBeatsAheadOnTheTimeline` |
| Interruption behaviour | `anInterruptionStopsTheBeatAndResumeCostsTheSameWhateverItsLength` (resume costs the same after 0.5 s and after 5 s at 240 bpm — the observable form of "missed beats are never replayed"), `reanchoringResumesFromNowAndReplaysNothing` (exact, pure), `aMetronomeRequestBeforePrepareOrAfterTeardownIsSilentNotFatal` |
| **Neither Step Feedback nor the Metronome alters or blocks the batch scoring computation at Stop** | `aScoredSessionIsByteIdenticalUnderEveryAudioConfig`, `aPreBaselineSessionIsByteIdenticalUnderEveryAudioConfig`, `anInvalidSessionIsJudgedIdenticallyUnderEveryAudioConfig`, `recordingTheSameWalkUnderEveryAudioConfigProducesTheSameData`, `aWedgedAudioLayerNeitherDelaysStopNorChangesTheResult`, `aSessionRecordedWithFailedAudioIsStillValidAndIdentical`, `audioTroubleDuringASessionChangesNeitherTheCountNorTheOutcome`, `aStalledAudioConsumerNeverDelaysRecording`, plus the scan `noAlgorithmReadsAnythingAboutAudio` — see §3 for what "byte-identical" means here and §5 finding 1 for what it does not cover |

### OQ-4 — the two engines must stay distinguishable

`theMetronomeSchedulesAndNeverMirrorsStepsWhileStepFeedbackDoesTheReverse` runs one irregular walk through both: step-feedback tick gaps spread > 0.2 s, metronome beat gaps are a one-element set at exactly 24 000 frames. Two source scans hold the property in the code rather than only in that case: `theStepFeedbackPathSchedulesNothing` and `theMetronomePathReadsNoStepTiming`.

## 3. Structural guarantees, and how strong each one is

Five source scans now enforce rules that are invisible at the point they would be broken. Each has a paired mutation test proving the scan can fail:

| Scan | Enforces | Mutation-verified |
|---|---|---|
| `domainImportsOnlyFoundation` / `algorithmsImportOnlyFoundationAndAccelerate` | docs/03 rule 1 | `theScanWouldCatchAForbiddenImport` |
| `userFacingCopyNeverUsesTheReservedTerm` | [PRD OQ-1] terminology | `theGuardCatchesCopyButNotIdentifiers` |
| `theStepFeedbackPathSchedulesNothing` | Step Feedback never schedules [PRD OQ-4] | `theScanWouldCatchAScheduler` |
| `theMetronomePathReadsNoStepTiming` | the metronome never follows the walk | `theScanWouldCatchStepTimingLeakingIn` |
| `noAlgorithmReadsAnythingAboutAudio` | scoring cannot see how the walk was paced | `theScanWouldCatchAnAlgorithmReadingTheAudioConfig`, **and** a real mutation this session |

The scoring-independence scan earns particular weight. `RawSessionBuffer` **carries** `audioConfig` — it is persisted for transparency — and the whole buffer is handed to the pipeline, so "the maths ignores it" is not automatic. Verified against a real mutation: adding `if case .metronome = buffer.audioConfig` to `GaitAnalysisPipeline` failed the scan, and a version of that mutation which changed the verdict also failed `aScoredSessionIsByteIdenticalUnderEveryAudioConfig` and `recordingTheSameWalkUnderEveryAudioConfigProducesTheSameData`. Both layers of the guarantee bite.

"Byte-identical" is literal: the outcome — validity, valid-walking duration, metrics, composite z, relative index, per-signal breakdown, algorithm version — is encoded with sorted keys and compared as `Data`, so a difference in the last bit of one `Double` fails. The comparison is also checked non-vacuous: the scored case asserts a score and a non-empty breakdown are actually present.

The disarm-not-cancel decision in `StepFeedbackBridge` is likewise mutation-verified: replacing the disarm with a `cancel()` fails `asecondOptInStillTicks`, because cancelling a task iterating an `AsyncStream` terminates that stream for good and every later session would be silent.

## 4. ACs with no test

**Deferred by design (scheduling, not neglect):**

- The Session Setup screen's whole surface — the "walk normally, no target pace" framing for a first-ever session, the toggle itself, and gating which toggle is offered on `BaselineState` → Task 8.2.1.
- Sound-to-footfall latency — a device measurement, → Task 11.2.2. It is right by construction (preloaded buffers, one player node per tone, `scheduleBuffer` on a running engine, no allocation and no main-actor hop on the tick path) and that construction is pinned by `schedulingReusesTheOnePreloadedBeatBuffer` and by 7.1.1's tests, but no test hears anything.
- Real Bluetooth route changes — a simulator cannot provoke one. The *response* to one is driven directly through `handle(_:)`; the hardware case is → Task 11.2.2.
- The confidence threshold, refractory window and `fullConfidenceSigma` are all `[OPEN]`/PROVISIONAL values → Task 11.2.1. The tests assert behaviour *relative to whatever the configuration says*, never the numbers themselves.
- The step-tick and metronome tone specs are PROVISIONAL. What [PRD AC] actually requires — start and stop being tellable apart, the tick being short and quieter than the session tones — is asserted.

## 5. Findings

**1. `stop()` awaits two audio calls, and nothing tests that a pathological implementation cannot delay it.**
`SessionRecorder.stop()` awaits `stopMetronome()` (metronome sessions only) and then `playStopTone()` before freezing the buffer. That ordering is deliberate — [PRD AC] requires the stop tone to sound, and 7.1.1 fixed "tone before teardown" — but it means Stop is not *structurally* independent of audio the way scoring is. The shipped `EngineAudioFeedbackService` cannot block there: both are actor methods that only stop or schedule a preloaded buffer, neither throws, and neither waits on anything. `WedgedAudio` in the independence tests therefore stalls only the feedback paths (`playStepTick`, `startMetronome`) and keeps the two stop-path calls prompt — a double that stalled them would hang the test, which is precisely the shape of the residual risk. **Flagged, not resolved.** Closing it would mean either bounding those two calls or moving the stop tone off the critical path, and both change a decided [PRD AC] ordering; that is a product call, not a cleanup.

**2. The audio epic is not reachable from the production app.**
`AppDependencies.live()` and `.storeUnavailable()` both still wire `SilentAudioFeedbackService`, under a comment reading "Task 7.1.1 replaces this with the AVAudioEngine implementation" — 7.1.1 shipped the implementation and did not swap it in. Every test that exercises `EngineAudioFeedbackService` constructs it directly, so the suite is green and the app is silent. This is not an oversight to fix blind: the engine needs `prepare()`/`teardown()` called around a session, and that lifecycle belongs to the recording flow (Task 8.2.2). **Recommendation:** swap the slot and take ownership of the lifecycle in 8.2.2, and delete the stale comment then — not before, or the app will activate an `AVAudioSession` with nothing to tear it down.

**3. The metronome's structural gate has one seam.**
`MetronomeCue` cannot be built without that mode's baseline, and it is the only thing that produces a `SessionAudioConfig.metronome`. But the enum case itself is still constructible — a future call site can write `.metronome(bpm: 120)` by hand and bypass the gate entirely. Nothing currently does (verified: the only construction in app code is `MetronomeCue.audioConfig`). **Closeable cheaply** with a fourth source scan in the shape of the existing ones: outside `MetronomeCue.swift`, no app file may construct `.metronome(bpm:`. Worth doing before Task 8.2.1 writes the Session Setup screen, which is exactly where a hand-written tempo would appear.

**4. `MetronomeSchedule` is verified as arithmetic, not as audio.**
Even spacing, no drift over 200 beats, and resume-from-now are proven exactly — on frame numbers. That the engine renders those frame numbers as evenly spaced clicks rests on `AVAudioTime` scheduling behaving as documented. Same bucket as latency: → Task 11.2.2.

## 6. Judgment calls flagged, not resolved

- **The metronome's per-batch `Task`.** The top-up callback hops into the actor via `Task { ... }`, which allocates. It runs once per batch of eight beats, not per beat, so "no per-tick allocation" holds as stated — but it is an allocation on a path adjacent to the audio thread. Left as is: the alternative is a lock-free scheduler this app has no need of.
- **Batch size and lead-in (8 beats, 0.1 s)** are unvalidated constants. At 240 bpm a batch is two seconds of audio; at 60 bpm it is eight. Nothing has established that either extreme is right on device → Task 11.2.2.

## Verdict

EPIC 7 is complete against its ACs, with the caveat that finding 2 means none of it is audible in the app until Task 8.2.2 wires it. The PRD-critical scoring-independence AC is held at two independent levels — byte-identity across every audio config on scored, pre-baseline, invalid, recorded, stalled, failed and interrupted paths, and a source scan making the read impossible in the first place — and both were confirmed to fail against a real mutation rather than assumed to work.
