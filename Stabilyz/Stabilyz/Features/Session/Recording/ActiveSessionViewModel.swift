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

    /// Set once the user turns the audio cue off. **One way** — see
    /// `silenceAudioCue()`.
    private(set) var isAudioCueSilenced = false

    /// The countdown taps and the stop pulse. Free in both directions: these
    /// fire at T-0 and at Stop, so changing one mid-walk cannot affect the
    /// measurement [PRD OQ-6].
    var isHapticsOn: Bool

    private let onStop: @MainActor () -> Void
    private let onSilenceAudioCue: @MainActor () -> Void

    init(
        mode: TestMode,
        audioConfig: SessionAudioConfig,
        isHapticsOn: Bool = true,
        onStop: @escaping @MainActor () -> Void,
        onSilenceAudioCue: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.audioConfig = audioConfig
        self.isHapticsOn = isHapticsOn
        self.onStop = onStop
        self.onSilenceAudioCue = onSilenceAudioCue
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

    var audioCueTitle: String {
        if case .metronome = audioConfig { return "Metronome Cue" }
        return "Audio Step Feedback"
    }

    /// Whether this session started with any audio cue at all. A session
    /// started silent has nothing to silence.
    var hasAudioCue: Bool { audioConfig != .none }

    var isAudioCueOn: Bool { hasAudioCue && !isAudioCueSilenced }

    /// The toggle is live only while there is something to turn off.
    var canSilenceAudioCue: Bool { hasAudioCue && !isAudioCueSilenced && !isStopping }

    /// Shown beside the title once the cue is off, so the row explains why it
    /// will not go back on.
    var audioCueStatus: String? { isAudioCueSilenced ? "Silenced for this walk" : nil }

    static let audioCueSilenceHint = "Turning this off cannot be undone during this walk."
    static let hapticsHint = "Affects the tap when the walk ends."

    /// Turns the cue off for the rest of the walk.
    ///
    /// **One way, deliberately.** A walk that was unpaced and then paced would
    /// produce one set of metrics spanning two conditions, compared against a
    /// baseline established under one [PRD §5, OQ-5]. Silencing only removes
    /// influence — and the alternative for a user with failing earphones is
    /// abandoning the walk, which costs them the whole session.
    func silenceAudioCue() {
        guard canSilenceAudioCue else { return }
        isAudioCueSilenced = true
        onSilenceAudioCue()
    }

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
