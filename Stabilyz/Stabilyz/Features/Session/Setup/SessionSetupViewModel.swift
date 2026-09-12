import Foundation

/// Drives the session setup screen (docs/04 §4.5, Figma node 123:914).
///
/// Every string the screen shows is decided here rather than in the view, so
/// the whole copy matrix — two modes × three baseline states — is testable
/// without rendering anything (docs/11 §11.5). That matters more here than on
/// most screens: the copy is where the PRD's rules actually become visible, and
/// a wrong word is a wrong promise.
///
/// The two gates it enforces, both [PRD §5, §7]:
/// - **Step Feedback is pre-baseline only, and off by default.** Baseline
///   sessions capture walking as undisturbed as possible, so any audio is an
///   explicit opt-in.
/// - **The Metronome is post-baseline only**, and its tempo can only be this
///   mode's own baseline cadence — enforced by `MetronomeCue` having no
///   initializer that takes a bare BPM.
@MainActor
@Observable
final class SessionSetupViewModel {
    /// Whether the screen may start a session at all (docs/07 §7.6).
    enum PermissionState: Equatable {
        /// Not asked yet, or asked and granted. Either way, Start proceeds —
        /// `notDetermined` is not a refusal, since the system prompt appears on
        /// first access.
        case clear
        /// Denied or restricted. Start is blocked and the screen explains why
        /// rather than letting the user tap into a silent failure [PRD §6].
        case blocked(StabilyzError)
    }

    private(set) var mode: TestMode

    /// Both modes' states, held together so switching mode is instant and can
    /// never show one mode's progress under the other's name [PRD OQ-5].
    private(set) var baselineStates: [TestMode: BaselineState] = [:]

    /// Set when the store could not be read.
    ///
    /// Kept distinct from "no sessions yet" on purpose: defaulting a failed
    /// read to `.notStarted` would tell a user with an established baseline to
    /// start building one, which is the misreport `AppDependencies` refuses to
    /// make anywhere else.
    private(set) var baselineLoadFailed = false

    private(set) var permission: PermissionState = .clear

    /// This mode's state. `.notStarted` only when the store actually said so —
    /// `baselineLoadFailed` covers the case where it said nothing.
    var baselineState: BaselineState { baselineStates[mode] ?? .notStarted }

    /// The pre-baseline audio cue. **Off by default** [PRD §7 AC].
    var isAudioCueOn = false
    /// The countdown's taps and the stop pulse. On by default — unlike the
    /// audio cues these do not influence gait, they mark when the measurement
    /// starts and stops [PRD OQ-6].
    var isHapticsOn = true

    private let sessions: GaitSessionRepository
    private let baselines: BaselineRepository
    private let motionSensor: MotionSensorService
    private let logService: LogService
    /// Opens the system Settings page for this app. Handed in rather than
    /// reached for, so the view model stays free of UIKit (docs/12 §12.3).
    private let openSettings: @MainActor () -> Void
    /// What the countdown screen is handed when Start is tapped. Deliberately
    /// **not** the recorder: this screen chooses a session, it does not begin
    /// one (Task 8.2.6 owns that).
    private let onStart: @MainActor (TestMode, SessionAudioConfig) -> Void

    init(
        mode: TestMode = .quickTest,
        sessions: GaitSessionRepository,
        baselines: BaselineRepository,
        motionSensor: MotionSensorService,
        logService: LogService,
        openSettings: @escaping @MainActor () -> Void = {},
        onStart: @escaping @MainActor (TestMode, SessionAudioConfig) -> Void
    ) {
        self.mode = mode
        self.sessions = sessions
        self.baselines = baselines
        self.motionSensor = motionSensor
        self.logService = logService
        self.openSettings = openSettings
        self.onStart = onStart
    }

    // MARK: - Selection

    func select(_ mode: TestMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        // The cue toggle means a different thing in each mode, because each
        // mode has its own baseline [PRD OQ-5]. Carrying "on" across the switch
        // would silently opt the user into a different feature than the one
        // they turned on.
        isAudioCueOn = false
    }

    /// Reads both modes' baseline states from the store.
    ///
    /// Both, not just the selected one: the user can switch modes at any time,
    /// and a switch that had to wait on a query would show the wrong card for
    /// as long as the read took. Re-runnable — the screen calls it on appear,
    /// and again whenever a session commits.
    func refreshBaselineStates() async {
        var loaded: [TestMode: BaselineState] = [:]
        do {
            for mode in TestMode.allCases {
                loaded[mode] = try BaselineStateMachine.state(
                    for: mode,
                    validSessionCount: try await sessions.validSessionCount(mode: mode),
                    baseline: try await baselines.baseline(mode: mode)
                )
            }
        } catch {
            // Leave whatever was already known rather than replacing it with
            // zeros. The card says it could not load, instead of telling a user
            // with five sessions behind them to start building a baseline.
            baselineLoadFailed = true
            logService.log(.error, .app, "session setup: could not read baseline state")
            return
        }

        // Which cue the toggle currently means, before the new states land.
        let wasMetronome = baselineState.allowsMetronome

        baselineStates = loaded
        baselineLoadFailed = false

        // The toggle changes *identity* at the baseline boundary rather than
        // going away — Step Feedback before, the Metronome after. If the fifth
        // session commits while this screen is open, a toggle left on would
        // silently become a metronome the user never switched on, which is the
        // opposite of the opt-in the PRD requires [PRD §5]. Same reasoning as
        // `select(_:)`, for the same reason.
        if baselineState.allowsMetronome != wasMetronome {
            isAudioCueOn = false
        }
    }

    /// Applies a state directly — the post-restore invalidation broadcast
    /// (docs/11 §11.5), and tests.
    func apply(_ state: BaselineState, for mode: TestMode) {
        baselineStates[mode] = state
        baselineLoadFailed = false
    }

    // MARK: - Copy: the mode selector

    static let chooseTestHeader = "Choose a test"

    /// The segmented control's labels, which name the advertised length rather
    /// than the mode — it is the length the user is choosing between.
    func segmentLabel(for mode: TestMode) -> String {
        switch mode {
        case .quickTest: "Quick (2 min)"
        case .fullTest: "Full (6 min)"
        }
    }

    var modeSubtitle: String {
        switch mode {
        case .quickTest: "A quick check-in on your walking stability."
        case .fullTest: "A longer walk for a more detailed check-in on your stability."
        }
    }

    // MARK: - Copy: the baseline card

    var baselineCardHeader: String { "\(mode.displayName) Baseline" }

    /// The card's headline. The established state shows the reference index
    /// itself, which is what the Figma node draws at heading size.
    var baselineHeadline: String {
        if baselineLoadFailed { return Self.baselineUnavailableHeadline }
        switch baselineState {
        case .notStarted:
            return "Start building your baseline"
        case .building(let completed):
            return "\(completed) of \(Baseline.requiredValidSessionCount) sessions complete"
        case .established:
            return "\(Baseline.referenceIndex)"
        }
    }

    static let baselineUnavailableHeadline = "Baseline unavailable"

    /// True when the headline is the reference index rather than a sentence —
    /// the one case the view renders at heading size.
    var baselineHeadlineIsMetric: Bool { !baselineLoadFailed && baselineState.isEstablished }

    /// Shown instead of the state copy when the store could not be read.
    static let baselineUnavailableCopy =
        "We couldn't read your baseline just now. You can still record a session."

    var baselineSupportingCopy: String {
        if baselineLoadFailed { return Self.baselineUnavailableCopy }
        let required = Baseline.requiredValidSessionCount
        switch baselineState {
        case .notStarted:
            return "Complete \(required) valid \(pluralTests(required)) to create your personal reference point."
        case .building(let completed):
            let remaining = max(required - completed, 0)
            return "Complete \(remaining) more valid \(pluralTests(remaining)) to set your personal baseline."
        case .established:
            return "Your personal reference point, based on \(required) valid \(pluralTests(required))."
        }
    }

    /// "Quick Test" or "Quick Tests", agreeing with the number in front of it.
    ///
    /// The spec's copy reads "…\(remaining) more valid Quick Tests", which is
    /// wrong at the moment it matters most — the session before last, when
    /// `remaining` is 1. A screen that says "Complete 1 more valid Quick Tests"
    /// to a user in their seventies reads as carelessness, and this is the one
    /// sentence on the screen that tells them how close they are.
    private func pluralTests(_ count: Int) -> String {
        count == 1 ? mode.displayName : "\(mode.displayName)s"
    }

    // MARK: - Copy: session cues

    static let sessionCuesHeader = "Session Cues"

    /// The first toggle changes identity with the baseline, because the two
    /// features are mutually exclusive by design [PRD §5]: reactive Step
    /// Feedback while a baseline is being established, a paced Metronome only
    /// once there is a clean reference to pace against.
    var audioCueTitle: String {
        baselineState.allowsMetronome ? "Metronome Cue" : "Audio Step Feedback"
    }

    var audioCueSubtitle: String {
        baselineState.allowsMetronome
            ? "A steady beat at your own baseline pace."
            : "A short sound on each step. No target pace."
    }

    static let hapticsTitle = "Start & Stop Haptics"
    static let hapticsSubtitle = "A tap on each countdown second, and when the walk ends."

    // MARK: - Copy: the primary action

    var startButtonTitle: String { "Start \(mode.displayName)" }

    // MARK: - Copy: permission

    static let permissionTitle = "Motion access is off"

    /// The plain-language reason, from the shared presenter so this screen says
    /// what every other surface says about the same error (docs/15 §15.1).
    var permissionMessage: String? {
        guard case .blocked(let error) = permission else { return nil }
        return ErrorPresenter.presentation(for: error)?.message
    }

    var permissionOffersSettings: Bool {
        guard case .blocked(let error) = permission else { return false }
        return ErrorPresenter.presentation(for: error)?.offersSettingsLink ?? false
    }

    static let permissionSettingsLabel = "Open Settings"

    // MARK: - Gates

    var isStartEnabled: Bool {
        if case .blocked = permission { return false }
        return true
    }

    /// What the session will actually be recorded with.
    ///
    /// Built from the baseline state, not from the toggle alone: a toggle left
    /// on cannot smuggle a metronome into a pre-baseline session, and a cue can
    /// only ever carry this mode's own cadence.
    var audioConfig: SessionAudioConfig {
        guard isAudioCueOn else { return .none }

        if baselineState.allowsMetronome {
            guard let baseline = baselineState.baseline,
                  let cue = MetronomeCue(baseline: baseline, mode: mode)
            else { return .none }
            return .metronome(cue: cue)
        }

        return baselineState.allowsStepFeedback ? .stepFeedback : .none
    }

    // MARK: - Actions

    /// Pre-flights Motion & Fitness before the user can tap into a failure
    /// (docs/07 §7.6) [PRD §6 — the Start button explains why, never fails
    /// silently].
    func refreshPermission() async {
        switch await motionSensor.authorizationStatus {
        case .denied:
            permission = .blocked(.permission(.motionDenied))
            logService.log(.warning, .session, "session setup: motion permission denied")
        case .restricted:
            permission = .blocked(.permission(.motionRestricted))
            logService.log(.warning, .session, "session setup: motion permission restricted")
        case .authorized, .notDetermined:
            // `notDetermined` is not a refusal — the system prompt appears when
            // the recorder first touches the sensor.
            permission = .clear
        }
    }

    func openSystemSettings() {
        openSettings()
    }

    /// Hands the chosen session to the countdown. Starts nothing itself.
    func start() {
        guard isStartEnabled else { return }
        let config = audioConfig
        logService.log(.info, .session, "session setup: start \(mode.rawValue) audio=\(config)")
        onStart(mode, config)
    }
}
