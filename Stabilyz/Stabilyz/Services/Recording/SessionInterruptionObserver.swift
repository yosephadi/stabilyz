import Foundation

/// What interrupted a session (docs/07 §7.7).
///
/// Kept as domain values so the recorder never sees `UIApplication` or
/// `AVAudioSession` types (docs/03 boundary rule 4).
enum SessionInterruption: Sendable, Equatable {
    /// The app is about to lose focus — a call, Control Centre, an alert.
    case willResignActive
    /// The app went to the background. CMMotionManager delivers nothing while
    /// suspended, so this always produces a sensor gap.
    case didEnterBackground
    /// The app came back to the foreground.
    case didBecomeActive
    /// The audio session was interrupted (docs/10 §10.3).
    case audioInterrupted
    /// The audio route changed mid-session.
    case audioRouteChanged

    /// Whether this event begins a period where samples stop arriving.
    ///
    /// A route change or an audio interruption degrades feedback only — the
    /// accelerometer keeps delivering, so neither suspends recording
    /// (docs/10 §10.4).
    var suspendsRecording: Bool {
        switch self {
        case .didEnterBackground: true
        case .willResignActive, .didBecomeActive, .audioInterrupted, .audioRouteChanged: false
        }
    }
}

/// Observes app-lifecycle and audio-session events for the duration of a
/// recording (docs/07 §7.7).
///
/// Protocol-fronted so interruption handling is testable without backgrounding
/// a simulator — docs/19 §19.4 lists suspension behaviour as device-only
/// validation, which is exactly why the *policy* has to be testable here.
protocol SessionInterruptionObserver: Sendable {
    /// Begins observing. The stream finishes when `stopObserving()` is called.
    func startObserving() async -> AsyncStream<SessionInterruption>
    func stopObserving() async
}

/// Prevents the screen locking mid-session [REC — docs/07 §7.7].
///
/// Separated from the observer because it is a distinct capability with a
/// distinct failure mode: failing to keep the screen awake degrades a session,
/// while failing to notice a suspension corrupts one.
protocol ScreenSleepController: Sendable {
    func preventSleep() async
    func allowSleep() async
}
