# EPIC 6 Audit — Scoring & Baseline

**Performed by:** the Claude Code session that closed EPIC 6, immediately before Task 7.2.1.
**Date:** 2026-09-09.
**Method:** read-only inspection plus one full test run. Nothing was changed.

> **Snapshot at 481 tests; suite has since grown.**

**Postscript (2026-09-09, following session):** the two genuine gaps below —
§4 item #4 (the terminology guard for PRD AC 5) and §4 item #5 (the
`Domain/`/`Algorithms/` import-hygiene rule) — were closed by source-scan
guards in `StabilyzTests/SourceGuardTests.swift`, each mutation-verified with a
test proving the scan would catch a violation. The Foundation judgment call
raised in §2 was resolved by amending `docs/03-application-layer-architecture.md`
(ledger entry 22).

The audit text below is reproduced unaltered; only the AC → test map has been
set as a table.

---

Audit complete. Nothing was changed — read-only inspection plus one test run.

## 1. Full suite

`xcodebuild -scheme Stabilyz -destination 'platform=iOS Simulator,name=iPhone 17' test` — TEST SUCCEEDED, 481 passed, 0 failed. (First invocation errored: CLAUDE.md says "from repo root" but the `.xcodeproj` lives in `Stabilyz/`. Worth a doc fix.)

## 2. Framework isolation in `Domain/` and `Algorithms/`

26 files; the only import in any of them is Foundation. Zero CoreMotion, AVFoundation, SwiftData, CryptoKit, CommonCrypto, SwiftUI, Charts. Accelerate permitted in `Algorithms/` but unused.

Judgment call flagged, not resolved silently: docs/03 rule 1 says "zero Apple-framework imports except Accelerate" while the Domain row says "Stdlib only" — Foundation is strictly an Apple framework, so all 26 files technically deviate. Usage is `Date`, `UUID`, `TimeInterval` only — cross-platform surface, nothing that breaks independent testability, which is the rule's own reason.

Nothing enforces this rule automatically — no import-hygiene test; it holds by discipline alone.

## 3. PRD §7 scoring/baseline AC → test map

| AC | Tests |
|---|---|
| **#1** Ad1/Ad2 identical for all users; alongside CV + trunk proxy; stored, mode-tagged | `featuresAreIdenticalRegardlessOfUserProfile`, `theSameSignalDiffersOnlyByProfileForAsymmetry` (golden: uni == bi for both Ad's), `theProfileChangesOnlyAsymmetryAndItsLabel`, `trunkProxyIsPerAxisRMSOnMediolateralAndVertical`, `aLargerSwayRaisesOnlyTheMediolateralProxy`, `validSessionRoundTripsThroughTheEntity`, `metricsRoundTripThroughCodingForBlobStorage` |
| **#2** Unilateral asymmetry computed + stored, distinct, not merged | `unequalStepDurationsProduceNonzeroAsymmetry`, `theIndexIsNonNegativeAndCarriesNoLimbAttribution`, `asymmetryIsNotDerivableFromTheRegularityMetrics`, `timingAsymmetryWithoutAlternatingPolarityIsAbsentWithAReason`, `aWalkWithoutProminentPeaksIsAbsentWithAReason`, `aSessionWithNoProfileGetsAbsenceWithAReason`, `asymmetryIsStandardizedButNeverEntersTheComposite`, `asymmetryIsNotACompositeTerm` |
| **#3** Bilateral: never fabricated; score from the 3 signals only | `bilateralUsersGetAbsentAsymmetryNeverZero`, `asymmetryIsAbsentRatherThanZeroWhenSideIsNotIdentifiable`, `aBilateralUsersSessionsProduceNoAsymmetryStatAtAll`, `goldenTimingAsymmetryBilateral`, `aWildlyDifferentAsymmetryDoesNotMoveTheIndex` (asymmetry nil scores byte-identically — the bilateral-still-scores case) |
| **#4** Gait consistency never the sole basis | `gaitConsistencyIsNeverTheSoleBasisOfTheScore`, `compositeWeightsSumToOne`, `theCompositeAlwaysHasExactlyFourTerms`, `aMissingCompositeTermMeansNoScoreAtAll`, `halfATrunkProxyIsNotATrunkProxy`, `compositeInputsIncludeSignalsBeyondGaitConsistency` |
| **#5** Copy says "gait consistency", never symmetry/asymmetry | `theConsistencySignalIsNeverCalledSymmetry` (exhaustive over `SignalID.allCases`), `theConsistencySignalIsNeverCalledSymmetryInCopy` — see gaps |
| **#6** Minimum SD floor before relative scoring | `everyStandardisableMetricHasAPositiveAbsoluteFloor`, `theFloorRaisesAnImplausiblySmallSD`, `aHealthySDIsLeftAlone`, `theAbsoluteFloorCatchesABaselineMeanNearZero`, `theFloorIsNeverBelowTheObservedSD`, `identicalSessionsGiveZeroObservedSpreadAndTheFlooredSD`, `aFlooredBaselineBoundsAnOrdinarySessionDeviation`, `theFloorIsNotReAppliedDuringNormalization`, `statRecordsWhetherTheSDFloorWasApplied` |
| **#7** Before 5 valid in a mode → building state, no relative score | `stateProgressesFromNotStartedThroughBuildingToEstablished`, `stateReportsProgressTowardTheFiveSessionRequirement`, `aPreBaselineSessionStoresMetricsOnly`, `aPreBaselineSessionCarriesMetricsButNoScore` — data layer only |
| **#8** After the 5th valid, baseline computed + stored per metric, per mode | `everyRegistryMetricGetsAStat`, `fewerOrMoreThanFiveSessionsAreRefused`, `aSessionFromAnotherModeIsRefused`, `theFifthValidCommitEstablishesTheBaselineAndFlipsTheState`, `theFourthValidCommitIsStillBuildingWithNoBaseline`, `theFifthValidSessionEstablishesTheBaselineAndCarriesNoScore` |
| **#9** 6th onward: relative index vs that mode's baseline, never a percentage | `theSixthValidSessionPersistsACompleteScore`, `goldenScoredSixthSession`, `baselinePerformanceMapsToOneHundred`, `fiveIdenticalCalibrationSessionsEachScoreExactlyOneHundred`, `aSessionTwelveHundredthsOfAnSDBetterScoresOneHundredAndTwelve`, `theIndexIsClampedSoOneWildSessionCannotBreakTheTrend`; no-percentage: `theSummaryNeverContainsAPercentageSign` + `everyBranchIsExercisedByThePercentageGuard` (proves the guard reaches all 6 claim branches) |
| **#10** Baseline trustworthy only after 5; earlier framed provisional | data side same as #7; framing copy — see gaps |
| **#11** Noisy/flagged session doesn't count toward the 5 | `invalidSessionsNeverAdvanceTheCounter`, `invalidSessionsNeverAdvanceTheCount`, `invalidSessionsDoNotAdvanceEitherModesCount`, `anInvalidSessionIsRefused`, `validSessionCountIgnoresInvalidSessionsAndOtherModes`, `anInvalidCommitStoresNoScoreAndDoesNotAdvanceTheCount`, `anInvalidSessionCannotBeScoredEvenDirectly`, `anInvalidRowCarryingAScoreIsRejected`, `everyInvalidGoldenCarriesNoMetrics` |
| **#12** Quick/Full baselines, counts, trend fully independent | all 6 `ModeSegregationIntegrationTests`, `threeQuickAndTwoFullProduceNoBaselineInEitherMode`, `anEstablishedModeDoesNotAdvanceTheOtherMode`, `aBaselineFromTheWrongModeIsRejected`, `aBaselineFromAnotherModeIsRefused`, `aBaselineFromAnotherModeNeverReachesTheAlgorithm`, `modesHoldIndependentBaselines`, `scoringOneModeLeavesTheOtherModesSessionsUnscored`, `aFullSessionWithOnlyAQuickBaselineIsStoredWithNoScore`, `sessionsAreFilteredByModeAtTheStore` — trend excepted |

Defence-in-depth is real: mode segregation independently enforced at five layers (state machine, calculation service, normalization, processor, repository).

## 4. ACs with no test

Deferred by design (scheduling, not neglect): screen-level ACs 7/9/10 → Task 8.2.4; trend independence → Task 9.1.2; the "never exported" limb of the invalid-session rule → Task 10.2.2's tests.

Genuine gaps in shipped code: **#4** — AC 5 has no repo-wide guard (current copy clean by manual scan); **#5** — the `Domain`/`Algorithms` import rule has no test. Both closeable with source scans before Epic 8 adds most of the app's copy.

Ready for Epic 7 — nothing blocking. Task 7.2.3 (scoring-independence) is where the audio epic's PRD-critical AC lands.
