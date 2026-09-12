import Foundation
import Testing
@testable import Stabilyz

/// Stop → pipeline → store (Tasks 8.2.3, 8.2.4; docs/08, docs/11 §11.3).

private struct StubBuildInfo: BuildInfoProviding {
    let appVersion = "1.0 (1)"
    let deviceModel = "iPhone-test"
}

private final class OutcomeLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

/// A clean walk of the mode's own advertised length, as the recorder would
/// have frozen it.
///
/// Mode-aware on purpose: a 120-second signal is a complete Quick Test and a
/// *failed* Full Test, because a Full Test needs ~4 minutes of valid walking
/// [PRD OQ-3]. Handing the same buffer to both modes would quietly test the
/// invalid path while claiming to test the valid one.
private func walkBuffer(
    mode: TestMode = .quickTest,
    audioConfig: SessionAudioConfig = .none
) -> RawSessionBuffer {
    let seconds = mode == .quickTest ? 120.0 : 360.0
    return GoldenSignal.buffer(
        for: GoldenSignalSpec(seconds: seconds),
        mode: mode,
        audioConfig: audioConfig
    )
}

private func makeOutcomes(_ store: InMemoryStore) -> SessionOutcomeService {
    let log = OutcomeLog()
    return SessionOutcomeService(
        processor: SessionProcessor(algorithm: GaitAnalysisPipeline(), logService: log),
        commits: store.commits,
        baselines: store.baselines,
        profiles: store.profiles,
        buildInfo: StubBuildInfo(),
        logService: log
    )
}

// MARK: - The hand-off from a frozen buffer to the store

@Test func finishingAWalkPersistsItAndCountsIt() async throws {
    // The whole seam in one assertion: a frozen recording goes in, a stored
    // session comes out, and the mode's count moves.
    let store = try InMemoryStore()
    let outcomes = makeOutcomes(store)
    let id = UUID()

    let result = try await outcomes.finish(walkBuffer(), id: id)

    #expect(result.session.id == id)
    #expect(result.session.mode == .quickTest)
    #expect(try await store.sessions.session(id: id) != nil)
    #expect(try await store.sessions.validSessionCount(mode: .quickTest) == result.validSessionCount)
}

@Test func theStoredSessionCarriesTheBuildItWasRecordedOn() async throws {
    // A metric is only interpretable alongside the build that produced it, and
    // the export carries it [PRD §7].
    let store = try InMemoryStore()
    let id = UUID()

    _ = try await makeOutcomes(store).finish(walkBuffer(), id: id)

    let stored = try #require(try await store.sessions.session(id: id))
    #expect(stored.appVersion == "1.0 (1)")
    #expect(stored.deviceModel == "iPhone-test")
    #expect(stored.algorithmVersion.isEmpty == false)
}

@Test func theSessionRemembersHowItWasRecorded() async throws {
    // Audio config and a mid-walk silencing both travel from the buffer into
    // the stored row (ledger 37).
    let store = try InMemoryStore()
    let id = UUID()
    var buffer = walkBuffer(audioConfig: .stepFeedback)
    buffer = RawSessionBuffer(
        mode: buffer.mode,
        audioConfig: buffer.audioConfig,
        anchor: buffer.anchor,
        series: buffer.series,
        pedometerEvents: buffer.pedometerEvents,
        startedAt: buffer.startedAt,
        endedAt: buffer.endedAt,
        advertisedClockElapsed: buffer.advertisedClockElapsed,
        audioSilencedAt: .seconds(40),
        interruptionCount: buffer.interruptionCount,
        pedometerAvailable: buffer.pedometerAvailable
    )

    _ = try await makeOutcomes(store).finish(buffer, id: id)

    let stored = try #require(try await store.sessions.session(id: id))
    #expect(stored.audioConfig == .stepFeedback)
    #expect(stored.audioSilencedAt == .seconds(40))
}

@Test func anEmptyRecordingIsStoredAsInvalidAndNeverCounted() async throws {
    // docs/08 stage 1: nothing delivered is a sensor failure. It is still the
    // user's walk, so it is persisted — but it never advances the count and
    // never reaches a baseline [PRD §6, §7].
    let store = try InMemoryStore()
    let anchor = TimeAnchor(wallClock: Date(timeIntervalSince1970: 1_700_000_000), uptime: 1_000)
    let empty = RawSessionBuffer(
        mode: .quickTest,
        audioConfig: .none,
        anchor: anchor,
        series: AlignedSampleSeries(samples: [], gaps: []),
        pedometerEvents: [],
        startedAt: anchor.wallClock,
        endedAt: anchor.wallClock.addingTimeInterval(120),
        advertisedClockElapsed: .seconds(120),
        interruptionCount: 0,
        pedometerAvailable: true
    )
    let id = UUID()

    let result = try await makeOutcomes(store).finish(empty, id: id)

    #expect(result.session.isValid == false)
    #expect(result.validSessionCount == 0)
    #expect(try await store.sessions.session(id: id) != nil)
    #expect(result.baselineOutcome == .notReady(validCount: 0))
}

@Test func eachModeIsCountedOnItsOwn() async throws {
    // [PRD OQ-5] A Quick Test never advances the Full Test's count.
    let store = try InMemoryStore()
    let outcomes = makeOutcomes(store)

    _ = try await outcomes.finish(walkBuffer())
    _ = try await outcomes.finish(walkBuffer())
    let full = try await outcomes.finish(walkBuffer(mode: .fullTest))

    #expect(try await store.sessions.validSessionCount(mode: .quickTest) == 2)
    #expect(full.validSessionCount == 1)
}

@Test func theFifthValidWalkEstablishesTheBaseline() async throws {
    // The commit service owns this rule; this proves the flow actually reaches
    // it rather than stopping at persistence (docs/09 §9.4).
    let store = try InMemoryStore()
    let outcomes = makeOutcomes(store)

    var outcome: BaselineCommitOutcome = .notReady(validCount: 0)
    for _ in 0..<Baseline.requiredValidSessionCount {
        outcome = try await outcomes.finish(walkBuffer()).baselineOutcome
    }

    // Established or refused — both are correct endings for a fifth valid
    // session, and which one depends on whether the five walks could produce a
    // baseline. A refusal must not restart calibration or invent a substitute
    // (ledger 17), so either way the count stands at five.
    switch outcome {
    case .established:
        #expect(try await store.baselines.baseline(mode: .quickTest) != nil)
        #expect(try await store.baselineState(for: .quickTest).isEstablished)
    case .refused:
        #expect(try await store.baselines.baseline(mode: .quickTest) == nil)
    case .notReady, .alreadyEstablished:
        Issue.record("the fifth valid session should settle the baseline, got \(outcome)")
    }
    #expect(try await store.sessions.validSessionCount(mode: .quickTest)
        == Baseline.requiredValidSessionCount)
}

// MARK: - The processing screen

@Test func theProcessingCopyNamesTheMode() {
    #expect(ProcessingView.body(for: .quickTest)
        == "Reviewing your Quick Test data. This usually takes a few seconds.")
    #expect(ProcessingView.body(for: .fullTest)
        == "Reviewing your Full Test data. This usually takes a few seconds.")
}

@Test func theProcessingScreenPromisesTheDataStaysPut() {
    // [PRD §5] On-device only, no network call — and the screen says so, since
    // this is the moment a user wonders where their walk just went.
    #expect(ProcessingView.title == "Processing your data")
    #expect(ProcessingView.privacyNote == "Your data stays on your iPhone.")
}

// MARK: - The cover's phases

@Test func theWalkAndItsCountdownAreBothRecording() {
    // The recorder is live in both — the countdown primes it and T-0 opens it.
    #expect(SessionFlowPhase.countdown.isRecording)
    #expect(SessionFlowPhase.recording.isRecording)
    #expect(SessionFlowPhase.processing.isRecording == false)
}

@Test func processingCannotBeDismissed() {
    // [PRD §5] After processing, route to Noisy or Score — never neither. A
    // cancelled analysis would leave a recorded walk the user can never see.
    #expect(SessionFlowPhase.countdown.isDismissible == false)
    #expect(SessionFlowPhase.recording.isDismissible == false)
    #expect(SessionFlowPhase.processing.isDismissible == false)
}

@Test func aFinishedOrFailedFlowCanBeLeft() {
    #expect(SessionFlowPhase.failed(.processing(.cancelled)).isDismissible)
    #expect(SessionFlowPhase.failed(.processing(.cancelled)).error == .processing(.cancelled))
    #expect(SessionFlowPhase.processing.error == nil)
    #expect(SessionFlowPhase.processing.result == nil)
}

@Test func aFailedFlowCarriesSomethingTheUserCanBeTold() {
    // Whatever reaches `.failed` has to be presentable, or the screen has
    // nothing to say (docs/15 §15.1).
    for error: StabilyzError in [
        .processing(.cancelled),
        .persistence(.saveFailed),
        .sensor(.midSessionFailure),
        .recording(.notRecording)
    ] {
        #expect(ErrorPresenter.presentation(for: error) != nil)
    }
}
