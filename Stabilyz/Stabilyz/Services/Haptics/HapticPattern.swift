import Foundation

/// What one haptic cue actually feels like ([PRD OQ-6], docs/07 §7.1).
///
/// A value rather than a line inside the live service, because the thing worth
/// holding to is the *shape* — how many pulses, how heavy, how long — and that
/// is the one part of a haptic no test can observe by playing it. The simulator
/// has no Taptic Engine, so the patterns are asserted here and the hardware is
/// only asked not to blow up.
///
/// **Sized for a phone in a pocket.** The countdown's contract is that a user
/// who has already pocketed the device can still read the flow [PRD OQ-6], and
/// a single transient impact through a trouser pocket is easy to miss entirely.
/// Start and Stop are therefore multi-pulse bursts: the repetition is what
/// survives the clothing, and the *count and length* are what tell them apart
/// once they do. The per-second tick stays a single light tap — it repeats five
/// times on its own, and making it heavier would destroy the contrast the tick
/// exists to create against Go.
struct HapticPattern: Sendable, Equatable {

    /// The impact weights this app uses, named without UIKit so the shape stays
    /// assertable in a plain test.
    enum Weight: Sendable, Equatable {
        case light
        case heavy
    }

    let weight: Weight
    /// How many impacts the burst is. One is a plain tap.
    let pulseCount: Int
    /// The spacing between consecutive pulses. Zero for a single tap.
    let gap: Duration

    /// First pulse to last. The perceptual difference between Start and Stop is
    /// mostly this: one is a bump, the other is a shudder.
    var duration: Duration {
        gap * (pulseCount - 1)
    }

    /// One countdown numeral.
    ///
    /// Light and single, deliberately. It fires once a second for five seconds,
    /// so the rhythm carries it; what it must never do is approach the weight
    /// of Go, which is the only thing distinguishing "1" from "walk now".
    static let cadenceTick = HapticPattern(weight: .light, pulseCount: 1, gap: .zero)

    /// T-0.
    ///
    /// A double bump at the heaviest weight UIKit offers. Two pulses rather
    /// than one because a lone impact is the cue most often missed through
    /// clothing, and only two because Go has to stay short — it marks an
    /// instant, and a burst that rolled on would blur the moment it is naming.
    static let sessionStart = HapticPattern(
        weight: .heavy,
        pulseCount: 2,
        gap: .milliseconds(100)
    )

    /// Stop, and a countdown cancelled before it.
    ///
    /// Three heavy pulses spread wider than Start's two: 240ms end to end
    /// against 100ms. That length is the point — Stop is the one cue a user may
    /// be waiting on with the phone out of sight, and a longer shudder is far
    /// harder to miss or to mistake for the start of something. The extra pulse
    /// and the extra spacing both push the same way, so the two are told apart
    /// by duration rather than by counting taps.
    static let sessionStop = HapticPattern(
        weight: .heavy,
        pulseCount: 3,
        gap: .milliseconds(120)
    )
}
