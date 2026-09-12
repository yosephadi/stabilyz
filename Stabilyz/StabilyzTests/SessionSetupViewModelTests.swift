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

@MainActor
private func makeModel(
    mode: TestMode = .quickTest,
    baseline: BaselineState = .notStarted,
    authorization: MotionAuthorizationStatus = .authorized,
    onStart: @escaping @MainActor (TestMode, SessionAudioConfig) -> Void = { _, _ in },
    openSettings: @escaping @MainActor () -> Void = {}
) -> SessionSetupViewModel {
    SessionSetupViewModel(
        mode: mode,
        baselineState: baseline,
        motionSensor: StubMotionService(authorization: authorization),
        logService: SetupLog(),
        openSettings: openSettings,
        onStart: onStart
    )
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

    model.updateBaselineState(establishedBaseline)
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
    let handed = Locked<[(TestMode, SessionAudioConfig)]>([])
    let model = makeModel(mode: .fullTest, baseline: .building(validCount: 2)) { mode, config in
        handed.withLock { $0.append((mode, config)) }
    }
    model.isAudioCueOn = true

    model.start()

    let calls = handed.withLock { $0 }
    #expect(calls.count == 1)
    #expect(calls.first?.0 == .fullTest)
    #expect(calls.first?.1 == .stepFeedback)
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
    let model = makeModel(authorization: .denied) { _, _ in handed.withLock { $0 = true } }
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
