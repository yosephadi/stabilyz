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

    /// What the last check found. Starts at `.authorized` so no "why" line is
    /// shown before the first check has run.
    private(set) var authorization: MotionAuthorizationStatus = .authorized

    /// True while the system Motion & Fitness prompt is up after Start.
    private(set) var isRequestingAuthorization = false

    /// Whether the user has yet to answer the Motion & Fitness prompt. Drives
    /// the one-line "why" near Start, shown only in this state.
    var isAuthorizationUndetermined: Bool { authorization == .notDetermined }

    static let authorizationWhyLine =
        "Stabilyz needs Motion & Fitness access to measure your walking. We'll ask when you tap Start."

    /// This mode's state. `.notStarted` only when the store actually said so —
    /// `baselineLoadFailed` covers the case where it said nothing.
    var baselineState: BaselineState { baselineStates[mode] ?? .notStarted }

    /// The pre-baseline audio cue. **Off by default** [PRD §7 AC].
    var isAudioCueOn = false
    /// The countdown's ticks, Go, and the stop pulse. On by default — unlike
    /// the audio cues these do not influence gait, they mark when the
    /// measurement starts and stops [PRD OQ-6].
    ///
    /// Handed to the session through `onStart`. Until it was, this toggle was
    /// read by nothing: the countdown played every haptic regardless and the
    /// recording screen's own toggle started on whatever the user had chosen.
    var isHapticsOn = true

    private let sessions: GaitSessionRepository
    private let baselines: BaselineRepository
    private let motionSensor: MotionSensorService
    private let logService: LogService
    /// Tells the watch which mode is selected, for its Waiting screen
    /// [PRD §8]. Silent when there is no watch.
    private let watchSession: WatchSessionService
    /// Opens the system Settings page for this app. Handed in rather than
    /// reached for, so the view model stays free of UIKit (docs/12 §12.3).
    private let openSettings: @MainActor () -> Void
    /// What the countdown screen is handed when Start is tapped. Deliberately
    /// **not** the recorder: this screen chooses a session, it does not begin
    /// one (Task 8.2.6 owns that).
    ///
    /// A `var` for the same reason `ActiveSessionViewModel.onStop` is one: the
    /// shell holds this model in `@State` and so builds it in its own
    /// initializer, where the closure would have to reach state that does not
    /// exist yet. It is assigned once, before the screen is interactive.
    var onStart: @MainActor (TestMode, SessionAudioConfig, Bool) -> Void

    init(
        mode: TestMode = .quickTest,
        sessions: GaitSessionRepository,
        baselines: BaselineRepository,
        motionSensor: MotionSensorService,
        logService: LogService,
        watchSession: WatchSessionService = SilentWatchSessionService(),
        openSettings: @escaping @MainActor () -> Void = {},
        onStart: @escaping @MainActor (TestMode, SessionAudioConfig, Bool) -> Void
    ) {
        self.mode = mode
        self.sessions = sessions
        self.baselines = baselines
        self.motionSensor = motionSensor
        self.logService = logService
        self.watchSession = watchSession
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
        Task { await shareSelectionWithWatch() }
    }

    /// Sends the selected mode and its length to the watch's Waiting screen.
    /// Called when the screen appears and on every mode change; the watch link
    /// keeps the latest for a watch that opens later.
    /// The setup screen's watch line [PRD §8]: shown only while the watch app
    /// is reachable. Nothing takes its place otherwise — phone-only is the v1
    /// experience, not an error.
    static let watchLine = "Timer will show on your watch"

    /// Whether the watch app is reachable now, for `watchLine`.
    private(set) var isWatchReachable = false

    /// Follows the watch's reachability for as long as the screen is up.
    func observeWatch() async {
        for await reachability in watchSession.reachability() {
            isWatchReachable = reachability == .reachable
        }
    }

    func shareSelectionWithWatch() async {
        await watchSession.send(.setupSelection(
            mode: WireTestMode(mode),
            durationSeconds: WatchSyncMapping.durationSeconds(for: mode)
        ))
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
        case .quickTest: "Quick (1:30)"
        case .fullTest: "Full (3:00)"
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
            return BaselineProgressCopy.progress(walk: completed)
        case .baselineRefused:
            // Never "7 of 5" (Task 9.2.1).
            return Self.baselineRefusedHeadline
        case .established:
            return "\(Baseline.referenceIndex)"
        }
    }

    static let baselineRefusedHeadline = "Baseline not set"

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
            return BaselineProgressCopy.remainingSentence(remaining)
        case .baselineRefused:
            // Cause-neutral, and no promise that another walk fixes it: a retry
            // refuses the same first five (docs/decisions.md entry 17).
            return "Your baseline couldn't be set from your first \(required) valid \(pluralTests(required)). Your walks are still saved."
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

    // MARK: - Copy: how to walk [PRD §5, §6 edge cases]

    static let noTargetPaceLine = "Walk normally — there's no target pace"
    static let straightLineLine = "Walk in as straight a line as you can"

    /// The framing shown before Start. "No target pace" is the PRD's
    /// pre-baseline framing (sessions 1-5 in a mode, where Step Feedback is
    /// the only cue and no tempo may be implied), so it goes once the mode's
    /// baseline exists and the Metronome Cue — a pace — becomes available. The
    /// straight-line instruction applies to every walk (turns are not scored).
    var framingLines: [String] {
        baselineState.allowsStepFeedback
            ? [Self.noTargetPaceLine, Self.straightLineLine]
            : [Self.straightLineLine]
    }

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
        if isRequestingAuthorization { return false }
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
        let status = await motionSensor.authorizationStatus
        authorization = status
        switch status {
        case .denied:
            permission = .blocked(.permission(.motionDenied))
            logService.log(.warning, .session, "session setup: motion permission denied")
        case .restricted:
            permission = .blocked(.permission(.motionRestricted))
            logService.log(.warning, .session, "session setup: motion permission restricted")
        case .authorized, .notDetermined:
            // `notDetermined` is not a refusal — `start()` asks for it before
            // the countdown begins.
            permission = .clear
        }
    }

    func openSystemSettings() {
        openSettings()
    }

    /// Hands the chosen session to the countdown. Starts nothing itself.
    ///
    /// When Motion & Fitness has not been answered yet, the system prompt is
    /// raised here, first, and the countdown only begins once it is answered —
    /// otherwise the alert lands while the user is stowing the phone.
    func start() {
        guard isStartEnabled else { return }
        guard isAuthorizationUndetermined else {
            begin()
            return
        }
        Task { await startAfterAuthorization() }
    }

    /// The undetermined path of `start()`: ask, wait, then begin or explain.
    func startAfterAuthorization() async {
        guard isStartEnabled else { return }
        isRequestingAuthorization = true
        let status = await motionSensor.requestAuthorization()
        isRequestingAuthorization = false
        authorization = status
        switch status {
        case .denied:
            permission = .blocked(.permission(.motionDenied))
            logService.log(.warning, .session, "session setup: motion permission denied at start")
        case .restricted:
            permission = .blocked(.permission(.motionRestricted))
            logService.log(.warning, .session, "session setup: motion permission restricted at start")
        case .authorized, .notDetermined:
            // Still undetermined means the system could not ask (no activity
            // hardware); the recorder reports that case itself.
            permission = .clear
            begin()
        }
    }

    private func begin() {
        let config = audioConfig
        logService.log(
            .info, .session,
            "session setup: start \(mode.rawValue) audio=\(config) haptics=\(isHapticsOn)"
        )
        onStart(mode, config, isHapticsOn)
    }
}
