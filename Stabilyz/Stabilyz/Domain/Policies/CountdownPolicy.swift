import Foundation

/// How long the start countdown runs, and how fast it ticks
/// ([PRD OQ-6], docs/07 §7.3).
///
/// A policy rather than a constant at the call site, for the same reason
/// `SessionPolicy` is: the value is **provisional and tunable** — the same
/// category as the ~90 sec / ~4 min valid-walking floors — and versioning it
/// means a change is a change to one declared thing rather than a number
/// someone edits in a view.
///
/// [PRD OQ-6] settles its shape as well as its size: a **single fixed
/// constant**, the same for Quick Test and Full Test and the same whether Step
/// Feedback, the Metronome cue or neither is enabled, and **not
/// user-adjustable**. The countdown is a setup affordance, not a measurement
/// parameter. If real sessions show five seconds is too tight for someone who
/// needs both hands to stow a phone, this constant moves — it does not become a
/// preference. That is why there is no `length(for: TestMode)` here and no
/// stored setting behind it.
struct CountdownPolicy: Sendable, Equatable {
    /// Bumped whenever the cadence changes, so a stored session could be read
    /// back against the countdown it was started under.
    let version: Int

    /// Numerals shown, one per tick: 5, 4, 3, 2, 1, then Go.
    ///
    /// The tap at Go is **not** one of these — it is a distinct, heavier tap
    /// fired after the last numeral's interval elapses, so a user feeling the
    /// countdown through a pocket can tell "1" from "go" [PRD OQ-6].
    let tickCount: Int

    /// The gap between numerals. One second, which is what makes the numerals
    /// countable and the taps legible as a cadence rather than a burst.
    let tickInterval: Duration

    init(version: Int, tickCount: Int, tickInterval: Duration) {
        self.version = version
        self.tickCount = tickCount
        self.tickInterval = tickInterval
    }

    /// How long the whole countdown takes, Go included.
    var totalDuration: Duration {
        tickInterval * tickCount
    }

    /// The numerals in the order they are shown, highest first.
    var countdownSequence: [Int] {
        Array(stride(from: tickCount, through: 1, by: -1))
    }

    /// The v1 countdown.
    ///
    /// **Five seconds is provisional** [PRD OQ-6] — a starting point to adjust
    /// against real TestFlight sessions, not a validated figure.
    static let v1 = CountdownPolicy(
        version: 1,
        tickCount: 5,
        tickInterval: .seconds(1)
    )
}
