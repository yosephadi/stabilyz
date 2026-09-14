import Foundation

/// The countdown's second channel, and the stop pulse ([PRD OQ-6], docs/07 §7.1).
///
/// The countdown is deliberately **both visible and haptic, not one or the
/// other**: numerals for the user still looking at the phone, a tap per second
/// for the user who has already pocketed it. Haptics are the convenience half.
/// The on-screen numerals are the required fallback, so nothing here is ever
/// load-bearing — a device without a Taptic Engine, a user with System Haptics
/// switched off, or a user who turned Start & Stop Haptics off in the app loses
/// nothing they need. That last case never reaches an implementation of this
/// protocol at all: `CountdownCoordinator` plays through a silent double
/// instead, and the recording screen's toggle gates Stop.
///
/// **No method throws, and no method reports failure.** Haptic trouble is
/// surfaced only as silence, exactly like audio (docs/10 §10.4): no error, no
/// blocked Start, the visible countdown carries the flow alone [PRD §7 AC].
/// A caller cannot tell a played tap from a skipped one, and must not try.
///
/// Unlike audio, this never routes through an audio device, so the Bluetooth
/// route-change path does not apply to it (docs/07 §7.1). There is no `events`
/// stream here for the same reason: there is no route to change and no
/// interruption to report.
protocol HapticFeedbackService: Sendable {
    /// Pre-warms the haptic hardware so the first tap is not the slow one.
    ///
    /// Called when the countdown screen appears, not at Go. Safe to call
    /// repeatedly, and purely an optimisation — a play without a prepare still
    /// taps, just with the latency this exists to remove.
    func prepare() async

    /// One countdown tick, per numeral (5, 4, 3, 2, 1).
    ///
    /// A single light tap, because it repeats once a second and because it has
    /// to stay clearly *lighter* and *shorter* than the sustained vibration at Go — a user reading the countdown
    /// through their pocket has only that contrast to tell "1" from "go"
    /// [PRD OQ-6].
    func playCadenceTick() async

    /// T-0. A sustained, perceptibly distinct vibration at "Go", alongside the
    /// start tone [PRD OQ-6].
    ///
    /// **Returns before it has finished playing.** It is held for hundreds of
    /// milliseconds so it can be felt through a pocket
    /// (`HapticPattern.sessionStart`), and the caller must not wait for it to
    /// end: the countdown plays this immediately before opening the session
    /// against a `TimeAnchor` already stamped at T-0.
    func playSessionStart() async

    /// Stop [PRD OQ-6]. A single sustained vibration, a touch longer than Go,
    /// so the one cue a user may be waiting on with the phone out of sight is
    /// the hardest of the three to miss (`HapticPattern.sessionStop`).
    ///
    /// Returns before it has finished playing, like Go.
    func playSessionStop() async

    /// Releases the generators. Called when the session ends or the countdown
    /// is aborted.
    func teardown() async
}

extension HapticFeedbackService {
    /// Nothing to warm, and nothing to release.
    ///
    /// Only the live implementation holds hardware. The doubles have no state,
    /// so requiring them to write two empty methods each would be ceremony —
    /// but an implementation that *does* hold generators overrides both.
    func prepare() async {}
    func teardown() async {}
}
