import Foundation

/// The walk in progress (Figma node 128:2591, docs/04 §4.6).
///
/// **The clock is the recorder's, not the screen's.** Elapsed time arrives as
/// `SessionRecordingEvent.elapsed`, which the recorder derives from sample
/// timestamps on the monotonic timebase (docs/07 §7.4) — so the ring and the
/// numerals track the recording rather than a `Timer` running beside it. A UI
/// timer would drift from the data it claims to describe, and would keep
/// counting through a suspension that stopped delivery.
@MainActor
@Observable
final class ActiveSessionViewModel {
    let mode: TestMode
    let audioConfig: SessionAudioConfig

    /// What the recorder has measured so far. Advances once per whole second.
    private(set) var elapsed: Duration = .zero
    /// Set when the walk has been stopped, so the button cannot fire twice.
    private(set) var isStopping = false

    private let onStop: @MainActor () -> Void

    init(
        mode: TestMode,
        audioConfig: SessionAudioConfig,
        onStop: @escaping @MainActor () -> Void
    ) {
        self.mode = mode
        self.audioConfig = audioConfig
        self.onStop = onStop
    }

    // MARK: - The clock

    /// The advertised length — 2 minutes or 6 minutes [PRD §5].
    ///
    /// Deliberately not the valid-walking minimum: the ring shows the walk the
    /// user was asked for, while whether the session is scoreable is decided
    /// afterwards from how much of it was actually walking [PRD OQ-3].
    var total: Duration { mode.advertisedDuration }

    /// Never negative. A user who keeps walking past the advertised length is
    /// not shown a countdown running backwards.
    var remaining: Duration {
        let left = total - elapsed
        return left > .zero ? left : .zero
    }

    /// 1 at the start, 0 at the end. What the ring trims to.
    var progress: Double {
        let totalSeconds = total.seconds
        guard totalSeconds > 0 else { return 0 }
        return min(max(remaining.seconds / totalSeconds, 0), 1)
    }

    /// `mm:ss`, zero-padded — "02:00", "06:00", "00:09".
    var timerText: String { Self.clockText(remaining) }

    static let timerCaption = "Time remaining"

    /// Spoken rather than read: "2 minutes 0 seconds remaining" beats
    /// VoiceOver spelling out a colon-separated string.
    var timerAccessibilityLabel: String {
        let seconds = Int(remaining.seconds.rounded())
        let minutes = seconds / 60
        let trailing = seconds % 60
        let minutePart = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        let secondPart = trailing == 1 ? "1 second" : "\(trailing) seconds"
        return "\(minutePart) \(secondPart) remaining"
    }

    static func clockText(_ duration: Duration) -> String {
        let seconds = Int(duration.seconds.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Copy

    static let stopTitle = "Stop"

    /// Shown on the cues list while the walk runs. The toggles are a record of
    /// what this session was started with, not a control — changing a cue
    /// mid-walk would change the conditions being measured [PRD §5].
    var audioCueTitle: String {
        if case .metronome = audioConfig { return "Metronome Cue" }
        return "Audio Step Feedback"
    }

    var isAudioCueOn: Bool { audioConfig != .none }

    // MARK: - Events

    /// Drains the recorder's event stream until it finishes.
    ///
    /// Only `elapsed` is consumed here. Gaps, interruptions and sensor errors
    /// are the session flow's business, not the timer's — they change whether
    /// the session is scoreable, which is decided after Stop, never on screen
    /// mid-walk [PRD §6].
    func observe(_ events: AsyncStream<SessionRecordingEvent>) async {
        for await event in events {
            if case .elapsed(let duration) = event {
                elapsed = duration
            }
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        onStop()
    }
}

extension Duration {
    /// Seconds as a `Double`, for the arithmetic the ring and the clock need.
    var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
