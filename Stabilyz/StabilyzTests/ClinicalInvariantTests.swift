import Foundation
import Testing
@testable import Stabilyz

/// The clinical rules the app must never bend, in one place (Task 11.1.2).
///
/// Each is enforced where it lives and tested there too; this suite states them
/// together, end to end, so a change that weakens one fails under the rule's
/// own name:
///
/// 1. a baseline is built from **exactly five valid walks of one mode** —
///    never fewer, never an invalid walk, never the other mode [PRD §6, OQ-5];
/// 2. invalid walks are **excluded from every read** that could show, count or
///    score them, unless the caller opts in by name [PRD §5, §6, §7];
/// 3. an export **never carries an invalid walk**, whatever it is handed
///    [PRD §5, §7];
/// 4. the store's own serialized form keeps every measured value **to the bit**.

// MARK: - Fixtures

private struct FixedBuild: BuildInfoProviding {
    let appVersion = "1.0 (7)"
    let deviceModel = "iPhone17,1"
}

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

/// `count` valid walks of `mode`, an hour apart, oldest first.
private func validWalks(_ count: Int, mode: TestMode = .quickTest, from start: TimeInterval = 0) -> [GaitSession] {
    (0..<count).map { GaitSession.fixtureValid(mode: mode, startedAt: at(start + Double($0) * 3_600)) }
}

private func calculate(_ sessions: [GaitSession], mode: TestMode = .quickTest) throws -> Baseline {
    try BaselineCalculationService.calculate(
        from: sessions,
        mode: mode,
        establishedAt: at(100 * 3_600),
        configuration: .v1
    )
}

// MARK: - 1. Five valid walks of one mode

@Suite struct BaselineRequiresExactlyFiveValidWalksOfOneMode {

    @Test func fiveValidWalksOfOneModeEstablishABaseline() throws {
        let walks = validWalks(5)
        let baseline = try calculate(walks)

        #expect(baseline.mode == .quickTest)
        #expect(baseline.sourceSessionIDs == walks.map(\.id))
        #expect(Baseline.requiredValidSessionCount == 5)
    }

    @Test(arguments: [0, 1, 4, 6, 10])
    func anyOtherNumberOfWalksIsRefused(_ count: Int) {
        #expect(throws: BaselineCalculationService.CalculationError.wrongSessionCount(expected: 5, actual: count)) {
            try calculate(validWalks(count))
        }
    }

    @Test(arguments: InvalidReason.allCases)
    func anInvalidWalkAmongFiveIsRefused(_ reason: InvalidReason) {
        var walks = validWalks(4)
        let invalid = GaitSession.fixtureInvalid(mode: .quickTest, reason: reason, startedAt: at(4 * 3_600))
        walks.append(invalid)

        #expect(throws: BaselineCalculationService.CalculationError.invalidSessionIncluded(id: invalid.id)) {
            try calculate(walks)
        }
    }

    @Test func aWalkFromTheOtherModeIsRefused() {
        var walks = validWalks(4)
        walks.append(GaitSession.fixtureValid(mode: .fullTest, startedAt: at(4 * 3_600)))

        #expect(throws: BaselineCalculationService.CalculationError.mixedModes(expected: .quickTest, found: .fullTest)) {
            try calculate(walks)
        }
    }

    @Test func theBaselineTypeItselfRefusesAnythingButFiveDistinctSources() {
        for count in [4, 6] {
            #expect(throws: Baseline.ValidationError.wrongSourceSessionCount(expected: 5, actual: count)) {
                try Baseline(
                    id: UUID(), mode: .quickTest, stats: [], cadenceBPM: 104, algorithmVersion: "1.0.0",
                    establishedAt: at(0), sourceSessionIDs: (0..<count).map { _ in UUID() }
                )
            }
        }
        let repeated = UUID()
        #expect(throws: Baseline.ValidationError.duplicateSourceSessions) {
            try Baseline(
                id: UUID(), mode: .quickTest, stats: [], cadenceBPM: 104, algorithmVersion: "1.0.0",
                establishedAt: at(0), sourceSessionIDs: [repeated, repeated] + (0..<3).map { _ in UUID() }
            )
        }
    }

    @Test func invalidWalksAndTheOtherModeNeverAdvanceCalibration() throws {
        // Four valid Quick Tests and a pile of walks that must not count.
        #expect(try BaselineStateMachine.state(for: .quickTest, validSessionCount: 4, baseline: nil) == .building(validCount: 4))
        #expect(try BaselineStateMachine.state(for: .quickTest, validSessionCount: 0, baseline: nil) == .notStarted)
        #expect(throws: BaselineStateMachine.StateError.baselineModeMismatch(expected: .quickTest, actual: .fullTest)) {
            try BaselineStateMachine.state(for: .quickTest, validSessionCount: 5, baseline: .fixture(mode: .fullTest))
        }
    }

    @Test func committingEstablishesFromTheFirstFiveValidWalksOfTheModeOnly() async throws {
        let store = try InMemoryStore()
        let quick = validWalks(5)

        // Four valid Quick Tests, every kind of invalid Quick Test, and five
        // valid Full Tests interleaved: none of the last two may count.
        for walk in quick.prefix(4) { try await store.commits.commit(walk) }
        for (offset, reason) in InvalidReason.allCases.enumerated() {
            try await store.commits.commit(.fixtureInvalid(mode: .quickTest, reason: reason, startedAt: at(10 + Double(offset))))
        }
        for walk in validWalks(4, mode: .fullTest, from: 50) { try await store.commits.commit(walk) }

        #expect(try await store.baselines.baseline(mode: .quickTest) == nil)
        #expect(try await store.baselineState(for: .quickTest) == .building(validCount: 4))

        try await store.commits.commit(quick[4])

        let baseline = try #require(try await store.baselines.baseline(mode: .quickTest))
        #expect(baseline.sourceSessionIDs == quick.map(\.id))
        #expect(try await store.baselines.baseline(mode: .fullTest) == nil, "four Full Tests are not a baseline")
    }
}

// MARK: - 2. Invalid walks are excluded from every read

@Suite struct InvalidWalksAreExcludedFromReads {

    /// Both modes, valid and invalid, every invalid reason.
    private func mixedStore() async throws -> (InMemoryStore, valid: Set<UUID>, invalid: Set<UUID>) {
        let store = try InMemoryStore()
        var valid = Set<UUID>()
        var invalid = Set<UUID>()
        for mode in TestMode.allCases {
            for walk in validWalks(2, mode: mode, from: mode == .quickTest ? 0 : 1_000) {
                try await store.sessions.save(walk)
                valid.insert(walk.id)
            }
            for (offset, reason) in InvalidReason.allCases.enumerated() {
                let walk = GaitSession.fixtureInvalid(mode: mode, reason: reason, startedAt: at(20_000 + Double(offset) * 60))
                try await store.sessions.save(walk)
                invalid.insert(walk.id)
            }
        }
        return (store, valid, invalid)
    }

    @Test func theDefaultReadReturnsNoInvalidWalkInEitherMode() async throws {
        let (store, valid, invalid) = try await mixedStore()

        var read = Set<UUID>()
        for mode in TestMode.allCases {
            let sessions = try await store.sessions.sessions(mode: mode, includeInvalid: false, limit: nil)
            #expect(sessions.allSatisfy { $0.isValid && $0.mode == mode })
            read.formUnion(sessions.map(\.id))
        }
        #expect(read == valid)
        #expect(read.isDisjoint(with: invalid))
    }

    @Test func validCountsAndCalibrationCandidatesIgnoreInvalidWalks() async throws {
        let (store, _, _) = try await mixedStore()

        for mode in TestMode.allCases {
            #expect(try await store.sessions.validSessionCount(mode: mode) == 2)
            let earliest = try await store.reader.earliestValidSessions(mode: mode, limit: 5)
            #expect(earliest.count == 2)
            #expect(earliest.allSatisfy { $0.isValid })
        }
    }

    @Test func optingInIsTheOnlyWayToSeeThem() async throws {
        let (store, _, invalid) = try await mixedStore()
        var seen = Set<UUID>()
        for mode in TestMode.allCases {
            seen.formUnion(try await store.sessions.sessions(mode: mode, includeInvalid: true, limit: nil).map(\.id))
        }
        #expect(invalid.isSubset(of: seen))
    }

    /// Reads that may include invalid walks, and why. Anything else that asks
    /// for them is a screen, a count or an export that must not.
    static let permittedInvalidReads: Set<String> = [
        // Restoring over data: invalid walks are deleted too, so they count as
        // data to lose (Task 10.3.3).
        "Services/Archive/LocalDataDetector.swift"
    ]

    @Test func noScreenCountOrExportAsksForInvalidWalks() {
        var readCount = 0
        for layer in ["App", "Features", "Services"] {
            for file in SourceTree.swiftFiles(in: layer) {
                guard let source = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                let code = StepFeedbackSchedulingGuardTests.codeLines(in: source).joined(separator: "\n")
                readCount += code.components(separatedBy: "includeInvalid:").count - 1
                guard code.contains("includeInvalid: true") else { continue }
                #expect(
                    Self.permittedInvalidReads.contains { file.path.hasSuffix($0) },
                    "\(file.path) reads invalid sessions — History, counts, scoring and export must pass includeInvalid: false"
                )
            }
        }
        #expect(readCount > 0, "the scan found no session reads — it is not reading the source")
    }
}

// MARK: - 3. An export never carries an invalid walk

@Suite struct ExportsNeverCarryInvalidWalks {

    @Test(arguments: InvalidReason.allCases)
    func aPayloadHandedOnlyInvalidWalksHoldsNone(_ reason: InvalidReason) {
        let payload = ArchivePayload(
            profile: .fixture(),
            baselines: [],
            sessions: TestMode.allCases.map { GaitSession.fixtureInvalid(mode: $0, reason: reason) },
            appVersion: "1.0 (7)",
            algorithmVersion: "1.0.0",
            exportedAt: at(0)
        )
        #expect(payload.sessions.isEmpty)
    }

    @Test func aMixedPayloadKeepsExactlyTheValidWalksOfBothModes() {
        let valid = validWalks(3) + validWalks(2, mode: .fullTest, from: 100)
        let invalid = TestMode.allCases.flatMap { mode in
            InvalidReason.allCases.map { GaitSession.fixtureInvalid(mode: mode, reason: $0) }
        }
        let payload = ArchivePayload(
            profile: .fixture(),
            baselines: [],
            sessions: (invalid + valid).shuffled(),
            appVersion: "1.0 (7)",
            algorithmVersion: "1.0.0",
            exportedAt: at(0)
        )

        #expect(Set(payload.sessions.map(\.id)) == Set(valid.map(\.id)))
    }

    @Test(arguments: InvalidReason.allCases)
    func anInvalidWalkHasNoArchiveRepresentationAtAll(_ reason: InvalidReason) {
        #expect(ArchivedSession(GaitSession.fixtureInvalid(reason: reason)) == nil)
        #expect(ArchivedSession(GaitSession.fixtureValid()) != nil)
    }

    @Test func theExportSnapshotOfAStoreFullOfInvalidWalksHoldsOnlyTheValidOnes() async throws {
        let store = try InMemoryStore()
        try await store.profiles.save(.fixture())
        let valid = validWalks(2) + validWalks(1, mode: .fullTest, from: 100)
        for walk in valid { try await store.sessions.save(walk) }
        for mode in TestMode.allCases {
            for (offset, reason) in InvalidReason.allCases.enumerated() {
                try await store.sessions.save(.fixtureInvalid(mode: mode, reason: reason, startedAt: at(500 + Double(offset))))
            }
        }

        let payload = try await ArchivePayload.snapshot(
            profiles: store.profiles,
            sessions: store.sessions,
            baselines: store.baselines,
            buildInfo: FixedBuild(),
            clock: FixedStoreClock()
        )

        #expect(Set(payload.sessions.map(\.id)) == Set(valid.map(\.id)))
        #expect(payload.sessions.allSatisfy { $0.isUserVisible })
    }
}

// MARK: - 4. Measured values survive serialization to the bit

@Suite struct MeasuredValuesSurviveSerializationExactly {

    /// Values a decimal round trip would get wrong if it were shortened: long
    /// fractions, binary-inexact sums, the extremes of the representable range.
    static let awkward: [Double] = [
        103.98765432109876,
        0.1 + 0.2,
        .pi,
        1.0 / 3.0,
        (104.0).nextUp,
        0.012345678901234567,
        2.2250738585072014e-308,
        5e-324,
        1.7976931348623157e308
    ]

    private func metrics(_ value: Double, _ index: Int) -> GaitMetrics {
        let shifted = Self.awkward[(index + 3) % Self.awkward.count]
        return GaitMetrics(
            stepRegularity: 0.82,
            strideRegularity: 0.78,
            cadenceMean: value,
            stepTimeCV: 0.041,
            trunkMotionML: shifted,
            trunkMotionVT: Self.awkward[(index + 5) % Self.awkward.count],
            stepTimeAsymmetry: Self.awkward[(index + 7) % Self.awkward.count],
            steps: 210,
            distance: shifted,
            validStrideCount: 96,
            windowCount: 12
        )
    }

    private func contents() throws -> (StoreContents, [GaitSession]) {
        let sessions = Self.awkward.enumerated().map { index, value in
            GaitSession.fixtureValid(mode: .quickTest, startedAt: at(Double(index) * 3_600), metrics: metrics(value, index))
        }
        let baseline = try Baseline(
            id: UUID(),
            mode: .quickTest,
            stats: MetricID.allCases.enumerated().map { index, metric in
                BaselineMetricStat(
                    metricID: metric,
                    mean: Self.awkward[index % Self.awkward.count],
                    sd: Self.awkward[(index + 1) % Self.awkward.count],
                    n: 5,
                    sdFloorApplied: index.isMultiple(of: 2)
                )
            },
            cadenceBPM: 103.98765432109876,
            algorithmVersion: "1.0.0",
            establishedAt: at(0),
            sourceSessionIDs: sessions.prefix(5).map(\.id)
        )
        return (StoreContents(profile: .fixture(), baselines: [baseline], sessions: sessions), sessions)
    }

    private func expectBitIdentical(_ restored: StoreContents, _ original: StoreContents) throws {
        #expect(restored == original)

        for (restoredSession, originalSession) in zip(restored.sessions, original.sessions) {
            let r = try #require(restoredSession.metrics)
            let o = try #require(originalSession.metrics)
            #expect(r.cadenceMean.bitPattern == o.cadenceMean.bitPattern, "cadence")
            #expect(r.trunkMotionML.bitPattern == o.trunkMotionML.bitPattern, "trunk sway ML")
            #expect(r.trunkMotionVT.bitPattern == o.trunkMotionVT.bitPattern, "trunk sway VT")
            #expect(r.stepTimeAsymmetry?.bitPattern == o.stepTimeAsymmetry?.bitPattern, "asymmetry")
        }
        for (restoredBaseline, originalBaseline) in zip(restored.baselines, original.baselines) {
            #expect(restoredBaseline.cadenceBPM.bitPattern == originalBaseline.cadenceBPM.bitPattern)
            for (r, o) in zip(restoredBaseline.stats, originalBaseline.stats) {
                #expect(r.mean.bitPattern == o.mean.bitPattern && r.sd.bitPattern == o.sd.bitPattern, "\(o.metricID)")
            }
        }
    }

    @Test func theRestoreSnapshotKeepsEveryValueToTheBit() throws {
        let (original, _) = try contents()
        let data = try StoreSnapshotCoding.encode(original, createdAt: at(0))
        try expectBitIdentical(try StoreSnapshotCoding.decode(data), original)
    }

    @Test func theStoreKeepsEveryValueToTheBit() async throws {
        let (original, _) = try contents()
        let store = try InMemoryStore()
        let replacer = SwiftDataStoreReplacer(reader: store.reader, writer: store.writer)

        try await replacer.replaceAll(with: original)
        try expectBitIdentical(try await replacer.contents(), original)
    }
}
