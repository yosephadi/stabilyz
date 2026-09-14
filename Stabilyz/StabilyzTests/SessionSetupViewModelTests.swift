import Foundation
import Testing
@testable import Stabilyz

/// The session setup copy matrix (Task 8.2.1, Figma node 123:914).
///
/// Two modes × three baseline states, plus the two gates the PRD attaches to
/// the cue toggle. All of it lives in the view model precisely so it can be
/// checked here rather than by looking at a screen (docs/11 §11.5).

private final class SetupLog: LogService, @unchecked Sendable {
    let entries = Locked<[String]>([])

    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        entries.withLock { $0.append(message) }
    }
    func beginInterval(_ name: StaticString, category: LogCategory) -> SignpostInterval {
        SignpostInterval(name: name, category: category, id: 0)
    }
    func endInterval(_ interval: SignpostInterval) {}
}

private struct StubMotionService: MotionSensorService {
    var authorization: MotionAuthorizationStatus = .authorized
    var isAvailable: Bool { get async { true } }
    var authorizationStatus: MotionAuthorizationStatus { get async { authorization } }
    func requestAuthorization() async -> MotionAuthorizationStatus { authorization }
    func start(policy: MotionAcquisitionPolicy) async throws -> AsyncStream<SensorSample> {
        AsyncStream { $0.finish() }
    }
    func stop() async {}
}

private let establishedBaseline = BaselineState.established(.fixture(mode: .quickTest))

/// Answers whatever the test set up, or throws when `failing` — the store
/// being unreadable is its own case, not the same thing as having no sessions.
private actor StubSessionRepository: GaitSessionRepository {
    struct Unreadable: Error {}
    var counts: [TestMode: Int] = [:]
    var failing = false

    init(counts: [TestMode: Int] = [:], failing: Bool = false) {
        self.counts = counts
        self.failing = failing
    }

    func save(_ session: GaitSession) async throws {}
    func session(id: UUID) async throws -> GaitSession? { nil }
    func sessions(mode: TestMode, includeInvalid: Bool, limit: Int?) async throws -> [GaitSession] { [] }
    func validSessionCount(mode: TestMode) async throws -> Int {
        if failing { throw Unreadable() }
        return counts[mode] ?? 0
    }
}

private actor StubBaselineRepository: BaselineRepository {
    var stored: [TestMode: Baseline] = [:]

    init(stored: [TestMode: Baseline] = [:]) {
        self.stored = stored
    }

    func baseline(mode: TestMode) async throws -> Baseline? { stored[mode] }
    func save(_ baseline: Baseline) async throws { stored[baseline.mode] = baseline }
    func allBaselines() async throws -> [Baseline] { Array(stored.values) }
}

/// Turns a `BaselineState` back into the store rows that would produce it, so
/// a test can name the state it means and let the real state machine derive it.
private func stores(
    for state: BaselineState,
    mode: TestMode
) -> (StubSessionRepository, StubBaselineRepository) {
    switch state {
    case .notStarted:
        return (StubSessionRepository(), StubBaselineRepository())
    case .building(let count):
        return (StubSessionRepository(counts: [mode: count]), StubBaselineRepository())
    case .established(let baseline):
        return (
            StubSessionRepository(counts: [mode: Baseline.requiredValidSessionCount]),
            StubBaselineRepository(stored: [mode: baseline])
        )
    }
}

@MainActor
private func makeModel(
    mode: TestMode = .quickTest,
    baseline: BaselineState = .notStarted,
    authorization: MotionAuthorizationStatus = .authorized,
    onStart: @escaping @MainActor (TestMode, SessionAudioConfig, Bool) -> Void = { _, _, _ in },
    openSettings: @escaping @MainActor () -> Void = {}
) -> SessionSetupViewModel {
    let (sessions, baselines) = stores(for: baseline, mode: mode)
    let model = SessionSetupViewModel(
        mode: mode,
        sessions: sessions,
        baselines: baselines,
        motionSensor: StubMotionService(authorization: authorization),
        logService: SetupLog(),
        openSettings: openSettings,
        onStart: onStart
    )
    // The copy tests care about a state, not about how it was read, so seed it
    // directly; `refreshBaselineStates` has its own tests below.
    model.apply(baseline, for: mode)
    return model
}

// MARK: - A: the mode selector

@MainActor
@Test func eachModeHasItsOwnSegmentLabelAndSubtitle() {
    let model = makeModel()

    #expect(model.segmentLabel(for: .quickTest) == "Quick (2 min)")
    #expect(model.segmentLabel(for: .fullTest) == "Full (6 min)")

    #expect(model.modeSubtitle == "A quick check-in on your walking stability.")
    model.select(.fullTest)
    #expect(model.modeSubtitle == "A longer walk for a more detailed check-in on your stability.")
}

@MainActor
@Test func switchingModeClearsTheCueToggle() {
    // The toggle means a different feature in each mode, because each mode has
    // its own baseline [PRD OQ-5]. Carrying "on" across the switch would opt
    // the user into something they did not choose.
    let model = makeModel(baseline: .building(validCount: 2))
    model.isAudioCueOn = true

    model.select(.fullTest)

    #expect(model.isAudioCueOn == false)
}

// MARK: - B: the baseline card, across all six cells

@MainActor
@Test func theCardHeaderNamesTheMode() {
    let quick = makeModel(mode: .quickTest)
    let full = makeModel(mode: .fullTest)

    #expect(quick.baselineCardHeader == "Quick Test Baseline")
    #expect(full.baselineCardHeader == "Full Test Baseline")
}

@MainActor
@Test func theUncalibratedStateInvitesTheUserToStart() {
    let quick = makeModel(mode: .quickTest, baseline: .notStarted)
    #expect(quick.baselineHeadline == "Start building your baseline")
    #expect(quick.baselineHeadlineIsMetric == false)
    #expect(quick.baselineSupportingCopy
        == "Complete 5 valid Quick Tests to create your personal reference point.")

    let full = makeModel(mode: .fullTest, baseline: .notStarted)
    #expect(full.baselineSupportingCopy
        == "Complete 5 valid Full Tests to create your personal reference point.")
}

@MainActor
@Test func theCalibratingStateCountsTowardFive() {
    for completed in 1...4 {
        let model = makeModel(baseline: .building(validCount: completed))
        #expect(model.baselineHeadline == "\(completed) of 5 sessions complete")
        #expect(model.baselineHeadlineIsMetric == false)
    }
}

@MainActor
@Test func theCalibratingCopyCountsDownTheRemainder() {
    let two = makeModel(baseline: .building(validCount: 2))
    #expect(two.baselineSupportingCopy
        == "Complete 3 more valid Quick Tests to set your personal baseline.")

    let full = makeModel(mode: .fullTest, baseline: .building(validCount: 1))
    #expect(full.baselineSupportingCopy
        == "Complete 4 more valid Full Tests to set your personal baseline.")
}

@MainActor
@Test func theLastRemainingSessionIsSingular() {
    // The session before last is when this line matters most, and "Complete 1
    // more valid Quick Tests" is the moment a careful screen stops reading as
    // one. Deliberately not the spec's literal string.
    let quick = makeModel(baseline: .building(validCount: 4))
    #expect(quick.baselineSupportingCopy
        == "Complete 1 more valid Quick Test to set your personal baseline.")

    let full = makeModel(mode: .fullTest, baseline: .building(validCount: 4))
    #expect(full.baselineSupportingCopy
        == "Complete 1 more valid Full Test to set your personal baseline.")
}

@MainActor
@Test func theEstablishedStateShowsTheReferenceIndex() {
    // The state Figma node 123:914 draws.
    let model = makeModel(baseline: establishedBaseline)

    #expect(model.baselineHeadline == "100")
    #expect(model.baselineHeadlineIsMetric)
    #expect(model.baselineSupportingCopy
        == "Your personal reference point, based on 5 valid Quick Tests.")
}

@MainActor
@Test func theReferenceIndexComesFromTheDomainNotTheScreen() {
    // If scoring's reference point ever moved, the card would move with it
    // rather than keeping a stale number the view had typed in.
    let model = makeModel(baseline: establishedBaseline)
    #expect(model.baselineHeadline == "\(Baseline.referenceIndex)")
}

@MainActor
@Test func theEstablishedCopyNamesTheFullTestToo() {
    let model = makeModel(mode: .fullTest, baseline: .established(.fixture(mode: .fullTest)))
    #expect(model.baselineSupportingCopy
        == "Your personal reference point, based on 5 valid Full Tests.")
}

// MARK: - C: session cues

@MainActor
@Test func theCueToggleIsStepFeedbackBeforeABaselineExists() {
    #expect(makeModel(baseline: .notStarted).audioCueTitle == "Audio Step Feedback")
    for completed in 1...4 {
        #expect(makeModel(baseline: .building(validCount: completed)).audioCueTitle
            == "Audio Step Feedback")
    }
}

@MainActor
@Test func theCueToggleBecomesTheMetronomeOnceABaselineExists() {
    #expect(makeModel(baseline: establishedBaseline).audioCueTitle == "Metronome Cue")
}

@MainActor
@Test func theAudioCueIsOffByDefaultInEveryState() {
    // [PRD §7 AC] Off by default — the user must explicitly opt in to any audio
    // during baseline-establishing sessions. The Figma node draws this toggle
    // on; the PRD is the authority and it says off.
    #expect(makeModel(baseline: .notStarted).isAudioCueOn == false)
    #expect(makeModel(baseline: .building(validCount: 3)).isAudioCueOn == false)
    #expect(makeModel(baseline: establishedBaseline).isAudioCueOn == false)
}

@MainActor
@Test func hapticsAreOnByDefault() {
    // Unlike the audio cues, these do not influence gait — they mark when the
    // measurement starts and stops [PRD OQ-6].
    #expect(makeModel().isHapticsOn)
    #expect(SessionSetupViewModel.hapticsTitle == "Start & Stop Haptics")
}

@MainActor
@Test func theSectionHeadersMatchTheNode() {
    #expect(SessionSetupViewModel.chooseTestHeader == "Choose a test")
    #expect(SessionSetupViewModel.sessionCuesHeader == "Session Cues")
}

// MARK: - The two gates, enforced on the config rather than the toggle

@MainActor
@Test func aPreBaselineSessionCanOnlyEverAskForStepFeedback() {
    let model = makeModel(baseline: .building(validCount: 3))
    #expect(model.audioConfig == SessionAudioConfig.none)

    model.isAudioCueOn = true
    #expect(model.audioConfig == .stepFeedback)
}

@MainActor
@Test func aPostBaselineSessionCanOnlyEverAskForTheMetronome() {
    let model = makeModel(baseline: establishedBaseline)
    model.isAudioCueOn = true

    guard case .metronome(let cue) = model.audioConfig else {
        Issue.record("expected a metronome cue, got \(model.audioConfig)")
        return
    }
    // The tempo is necessarily this mode's own baseline cadence — there is no
    // initializer that takes a bare BPM [PRD OQ-5].
    #expect(cue.mode == .quickTest)
}

@MainActor
@Test func aToggleLeftOnCannotSmuggleACueAcrossTheBaselineBoundary() {
    // Turning it on pre-baseline and then arriving at an established baseline
    // must not silently become a metronome the user never chose, and vice
    // versa. The config is derived from the state, never from the toggle alone.
    let model = makeModel(baseline: .building(validCount: 4))
    model.isAudioCueOn = true
    #expect(model.audioConfig == .stepFeedback)

    model.apply(establishedBaseline, for: .quickTest)
    guard case .metronome = model.audioConfig else {
        Issue.record("expected the cue to follow the state")
        return
    }
}

// MARK: - D: the primary action

@MainActor
@Test func theStartButtonNamesTheMode() {
    #expect(makeModel(mode: .quickTest).startButtonTitle == "Start Quick Test")
    #expect(makeModel(mode: .fullTest).startButtonTitle == "Start Full Test")
}

@MainActor
@Test func startHandsTheModeAndConfigOutwardWithoutRecording() {
    // This screen chooses a session; it does not begin one. Task 8.2.6 owns
    // the countdown that does.
    let handed = Locked<[(TestMode, SessionAudioConfig, Bool)]>([])
    let model = makeModel(mode: .fullTest, baseline: .building(validCount: 2)) { mode, config, haptics in
        handed.withLock { $0.append((mode, config, haptics)) }
    }
    model.isAudioCueOn = true

    model.start()

    let calls = handed.withLock { $0 }
    #expect(calls.count == 1)
    #expect(calls.first?.0 == .fullTest)
    #expect(calls.first?.1 == .stepFeedback)
    // On by default [PRD OQ-6], and handed over as such.
    #expect(calls.first?.2 == true)
}

@MainActor
@Test func turningHapticsOffIsHandedToTheSession() {
    // The toggle used to be read by nothing: the countdown played every haptic
    // regardless. What the user chose here is what the session must receive.
    let handed = Locked<Bool?>(nil)
    let model = makeModel { _, _, haptics in handed.withLock { $0 = haptics } }
    model.isHapticsOn = false

    model.start()

    #expect(handed.withLock { $0 } == false)
}

// MARK: - Permission pre-flight

@MainActor
@Test func grantedPermissionLeavesStartEnabledAndSaysNothing() async {
    let model = makeModel(authorization: .authorized)
    await model.refreshPermission()

    #expect(model.permission == .clear)
    #expect(model.isStartEnabled)
    #expect(model.permissionMessage == nil)
}

@MainActor
@Test func undeterminedPermissionIsNotARefusal() async {
    // The system prompt appears when the recorder first touches the sensor, so
    // blocking here would refuse a user who has simply not been asked yet.
    let model = makeModel(authorization: .notDetermined)
    await model.refreshPermission()

    #expect(model.permission == .clear)
    #expect(model.isStartEnabled)
}

@MainActor
@Test func deniedPermissionBlocksStartAndExplainsWhy() async {
    // [PRD §6] The Start button must explain why recording cannot proceed
    // rather than failing silently.
    let model = makeModel(authorization: .denied)
    await model.refreshPermission()

    #expect(model.permission == .blocked(.permission(.motionDenied)))
    #expect(model.isStartEnabled == false)
    #expect(model.permissionMessage?.isEmpty == false)
    #expect(model.permissionOffersSettings)
}

@MainActor
@Test func restrictedPermissionBlocksStartWithoutOfferingSettings() async {
    // Restricted is not something the user can grant, so pointing them at
    // Settings would be a dead end.
    let model = makeModel(authorization: .restricted)
    await model.refreshPermission()

    #expect(model.permission == .blocked(.permission(.motionRestricted)))
    #expect(model.isStartEnabled == false)
    #expect(model.permissionOffersSettings == false)
}

@MainActor
@Test func aBlockedStartHandsNothingOutward() async {
    let handed = Locked(false)
    let model = makeModel(authorization: .denied) { _, _, _ in handed.withLock { $0 = true } }
    await model.refreshPermission()

    model.start()

    #expect(handed.withLock { $0 } == false)
}

@MainActor
@Test func theSettingsLinkIsHandedOutwardRatherThanReachedFor() async {
    let opened = Locked(false)
    let model = makeModel(authorization: .denied, openSettings: { opened.withLock { $0 = true } })
    await model.refreshPermission()

    model.openSystemSettings()

    #expect(opened.withLock { $0 })
}

// MARK: - Reading both modes from the store

@MainActor
@Test func refreshingReadsBothModesNotJustTheSelectedOne() async {
    // A mode switch must not have to wait on a query, or it would show the
    // wrong card for as long as the read took.
    let sessions = StubSessionRepository(counts: [.quickTest: 2, .fullTest: 4])
    let model = SessionSetupViewModel(
        sessions: sessions,
        baselines: StubBaselineRepository(),
        motionSensor: StubMotionService(),
        logService: SetupLog(),
        onStart: { _, _, _ in }
    )

    await model.refreshBaselineStates()

    #expect(model.baselineState == .building(validCount: 2))
    model.select(.fullTest)
    #expect(model.baselineState == .building(validCount: 4))
}

@MainActor
@Test func anEstablishedBaselineIsReadThroughTheRealStateMachine() async {
    let baseline = Baseline.fixture(mode: .fullTest)
    let model = SessionSetupViewModel(
        mode: .fullTest,
        sessions: StubSessionRepository(counts: [.fullTest: 5]),
        baselines: StubBaselineRepository(stored: [.fullTest: baseline]),
        motionSensor: StubMotionService(),
        logService: SetupLog(),
        onStart: { _, _, _ in }
    )

    await model.refreshBaselineStates()

    #expect(model.baselineState.isEstablished)
    #expect(model.audioCueTitle == "Metronome Cue")
    #expect(model.baselineHeadline == "100")
}

@MainActor
@Test func eachModeKeepsItsOwnProgress() async {
    // [PRD OQ-5] One mode's baseline must never appear under the other's name.
    let model = SessionSetupViewModel(
        sessions: StubSessionRepository(counts: [.quickTest: 5, .fullTest: 1]),
        baselines: StubBaselineRepository(stored: [.quickTest: .fixture(mode: .quickTest)]),
        motionSensor: StubMotionService(),
        logService: SetupLog(),
        onStart: { _, _, _ in }
    )

    await model.refreshBaselineStates()

    #expect(model.baselineState.isEstablished)
    #expect(model.audioCueTitle == "Metronome Cue")

    model.select(.fullTest)
    #expect(model.baselineState == .building(validCount: 1))
    // The other mode's established baseline must not offer this one a metronome.
    #expect(model.audioCueTitle == "Audio Step Feedback")
    #expect(model.baselineCardHeader == "Full Test Baseline")
}

@MainActor
@Test func anUnreadableStoreSaysSoRatherThanClaimingNoSessions() async {
    // `AppDependencies.storeUnavailable` refuses to report empty data for
    // exactly this reason: "no sessions yet" would misreport baseline progress
    // to someone who has five sessions behind them.
    let log = SetupLog()
    let model = SessionSetupViewModel(
        sessions: StubSessionRepository(failing: true),
        baselines: StubBaselineRepository(),
        motionSensor: StubMotionService(),
        logService: log,
        onStart: { _, _, _ in }
    )

    await model.refreshBaselineStates()

    #expect(model.baselineLoadFailed)
    #expect(model.baselineHeadline == "Baseline unavailable")
    #expect(model.baselineHeadline != "Start building your baseline")
    #expect(model.baselineHeadlineIsMetric == false)
    #expect(model.baselineSupportingCopy == SessionSetupViewModel.baselineUnavailableCopy)
    #expect(log.entries.withLock { $0.contains { $0.contains("could not read baseline state") } })
}

@MainActor
@Test func anUnreadableStoreStillLetsTheUserRecord() async {
    // Not knowing the baseline says nothing about whether the sensors work.
    let model = SessionSetupViewModel(
        sessions: StubSessionRepository(failing: true),
        baselines: StubBaselineRepository(),
        motionSensor: StubMotionService(),
        logService: SetupLog(),
        onStart: { _, _, _ in }
    )

    await model.refreshBaselineStates()
    await model.refreshPermission()

    #expect(model.isStartEnabled)
}

@MainActor
@Test func aBaselineLandingWhileTheScreenIsOpenDropsAStaleCue() async {
    // Step Feedback is pre-baseline only. If the fifth session commits while
    // this screen is open, a toggle left on would silently become a metronome
    // the user never chose.
    let sessions = StubSessionRepository(counts: [.quickTest: 4])
    let baselines = StubBaselineRepository()
    let model = SessionSetupViewModel(
        sessions: sessions,
        baselines: baselines,
        motionSensor: StubMotionService(),
        logService: SetupLog(),
        onStart: { _, _, _ in }
    )
    await model.refreshBaselineStates()
    model.isAudioCueOn = true
    #expect(model.audioConfig == .stepFeedback)

    try? await baselines.save(.fixture(mode: .quickTest))
    await model.refreshBaselineStates()

    #expect(model.isAudioCueOn == false)
    #expect(model.audioConfig == SessionAudioConfig.none)
}

@MainActor
@Test func aFailedReadDoesNotWipeWhatWasAlreadyKnown() async {
    let model = makeModel(baseline: establishedBaseline)
    #expect(model.baselineState.isEstablished)

    let failing = SessionSetupViewModel(
        sessions: StubSessionRepository(failing: true),
        baselines: StubBaselineRepository(),
        motionSensor: StubMotionService(),
        logService: SetupLog(),
        onStart: { _, _, _ in }
    )
    failing.apply(establishedBaseline, for: .quickTest)
    await failing.refreshBaselineStates()

    // The flag wins for display, but the known state is still underneath it
    // rather than having been replaced with zeros.
    #expect(failing.baselineLoadFailed)
    #expect(failing.baselineState.isEstablished)
}
