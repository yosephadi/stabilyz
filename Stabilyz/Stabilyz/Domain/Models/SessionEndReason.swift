/// How a recording ended: the timer reaching the advertised length, or the
/// user's own Stop (phone or watch).
///
/// Decides whether the tail of the recording is trimmed before analysis
/// (`SessionLeadIn`). A timer end cuts the recording mid-walk, so the tail is
/// ordinary gait. A manual Stop includes the user slowing and stopping, which
/// Tura et al. (2012) report degrades the regularity estimates.
///
/// Derived from what was recorded rather than stored: the clock the recorder
/// measured (`RawSessionBuffer.advertisedClockElapsed`, monotonic) either
/// reached the mode's advertised length or it did not. The timer stops the walk
/// at the first elapsed tick at or past that length, so a timer end always has
/// `elapsed >= advertisedDuration`; a Stop tapped earlier always has less. This
/// also covers a Stop tapped on the watch, since the phone is the recorder.
enum SessionEndReason: Sendable, Equatable {
    /// The advertised length elapsed and the walk was ended by the clock.
    case timer
    /// The user ended the walk before the advertised length.
    case manualStop

    init(advertisedClockElapsed: Duration, mode: TestMode) {
        self = advertisedClockElapsed >= mode.advertisedDuration ? .timer : .manualStop
    }
}
