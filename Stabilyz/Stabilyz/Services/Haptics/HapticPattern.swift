import Foundation

/// What one haptic cue actually feels like ([PRD OQ-6], docs/07 §7.1).
///
/// A value rather than a line inside the live service, because the thing worth
/// holding to is the *shape* — transient or sustained, how long, how hard, how
/// sharp — and that is the one part of a haptic no test can observe by playing
/// it. The simulator has no Taptic Engine, so the patterns are asserted here and
/// the hardware is only asked not to blow up.
///
/// **Sized for a phone in a pocket.** The countdown's contract is that a user
/// who has already pocketed the device can still read the flow [PRD OQ-6]. A
/// transient impact — even a heavy one, even repeated — is a click of a few
/// milliseconds, and through a trouser pocket it is easy to miss entirely. Go
/// and Stop are therefore *sustained* vibrations: energy delivered over
/// hundreds of milliseconds rather than a spike, at low sharpness so the motor
/// produces a rumble that carries through fabric rather than a crisp tap that
/// the fabric absorbs.
///
/// The per-second tick stays a light transient. It repeats five times on its
/// own, and a sustained tick would blur into the one after it and destroy the
/// contrast that exists to tell "1" from "walk now".
struct HapticPattern: Sendable, Equatable {

    /// The two transient weights this app uses, named without UIKit so the
    /// shape stays assertable in a plain test.
    enum Weight: Sendable, Equatable {
        case light
        case heavy
    }

    enum Kind: Sendable, Equatable {
        /// A single impact: effectively instantaneous.
        case transient(Weight)
        /// A continuous vibration held for `duration`.
        ///
        /// - Parameters:
        ///   - intensity: 0...1, how strongly the motor drives.
        ///   - sharpness: 0...1. Low is a dull rumble, high a crisp buzz. Low is
        ///     what survives clothing: fabric damps the high-frequency content
        ///     that makes a haptic feel sharp, and lets the low-frequency body
        ///     through.
        case continuous(duration: Duration, intensity: Double, sharpness: Double)
    }

    let kind: Kind

    /// How long the cue lasts. Zero for a transient.
    var duration: Duration {
        switch kind {
        case .transient: .zero
        case .continuous(let duration, _, _): duration
        }
    }

    var isSustained: Bool { duration > .zero }

    /// One countdown numeral. Light and instantaneous, deliberately.
    static let cadenceTick = HapticPattern(kind: .transient(.light))

    /// T-0.
    ///
    /// The shorter of the two sustained cues. Go marks an instant, so it holds
    /// only as long as it takes to be felt through a pocket, and is over well
    /// before the first stride lands.
    static let sessionStart = HapticPattern(
        kind: .continuous(duration: .milliseconds(400), intensity: 1.0, sharpness: 0.3)
    )

    /// Stop, and a countdown cancelled before it.
    ///
    /// **One sustained vibration** — [PRD §5] calls this "a single haptic
    /// pulse", and a held rumble is that more faithfully than a burst of taps.
    /// A touch longer than Go: Stop is the cue a user is most likely to be
    /// waiting on with the phone out of sight, so it is the last to be cut
    /// short. The two never occur back to back — one opens a walk and the other
    /// closes it minutes later, each beside its own tone — so the length is
    /// reinforcement, not the only thing telling them apart.
    static let sessionStop = HapticPattern(
        kind: .continuous(duration: .milliseconds(500), intensity: 1.0, sharpness: 0.3)
    )
}
