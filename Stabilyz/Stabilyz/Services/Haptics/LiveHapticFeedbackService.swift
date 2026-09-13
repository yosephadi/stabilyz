import CoreHaptics
import Foundation
import UIKit

/// Main-actor home for the generators, which `UIFeedbackGenerator` requires.
///
/// Split out rather than folded into the service because the service has to be
/// `nonisolated` to witness a `nonisolated` protocol: the isolation lives with
/// the UIKit objects that actually need it, and the service hops here.
@MainActor
private final class HapticGenerators {
    /// One per weight, so a tap never waits on another's re-warm. Created on
    /// demand and dropped at `release`.
    private var byStyle: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    nonisolated init() {}

    func warmAll() {
        for pattern in HapticPattern.all { generator(for: pattern.weight).prepare() }
    }

    /// Fires a pattern's first pulse now and schedules the rest.
    ///
    /// **Returns after the first pulse, never after the last.** A three-pulse
    /// Stop spans 240ms, and the callers cannot afford to wait for it: the
    /// countdown plays Start immediately before `recorder.begin(at:)` against a
    /// `TimeAnchor` already stamped, so a blocking burst would open the session
    /// late against its own origin. Haptics are requested, never awaited —
    /// nothing downstream may depend on one having finished.
    ///
    /// The trailing pulses hold the generator directly rather than looking it
    /// up again, so a `release()` landing mid-burst — which is exactly what
    /// Stop-then-teardown does — cannot leave the tail of a pattern playing on
    /// a cold generator.
    func play(_ pattern: HapticPattern) {
        let generator = generator(for: pattern.weight)
        fire(generator)

        let remaining = pattern.pulseCount - 1
        guard remaining > 0 else { return }

        Task { @MainActor in
            for _ in 0..<remaining {
                try? await Task.sleep(for: pattern.gap)
                fire(generator)
            }
        }
    }

    func release() {
        byStyle.removeAll()
    }

    private func fire(_ generator: UIImpactFeedbackGenerator) {
        generator.impactOccurred()
        // A generator goes cold after firing, and the next pulse — the next
        // countdown tick a second away, or the next beat of a burst 100ms away
        // — would otherwise be the slow one. Re-warming now is what keeps every
        // pulse in a burst feeling like the first.
        generator.prepare()
    }

    /// Lazily, so a play that arrives without a `prepare` still taps.
    ///
    /// `prepare` is an optimisation, not an initialisation: a countdown that
    /// somehow reached Go without one should feel slightly late, never silent.
    private func generator(for weight: HapticPattern.Weight) -> UIImpactFeedbackGenerator {
        let style = weight.style
        if let existing = byStyle[style] { return existing }
        let created = UIImpactFeedbackGenerator(style: style)
        byStyle[style] = created
        return created
    }
}

private extension HapticPattern.Weight {
    /// The UIKit weight. `light` → `heavy` is the widest separation the
    /// feedback generators offer, which is what a user feeling the countdown
    /// through a pocket needs to tell the last count from the start of
    /// recording [PRD OQ-6].
    var style: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: .light
        case .heavy: .heavy
        }
    }
}

private extension HapticPattern {
    static let all: [HapticPattern] = [.cadenceTick, .sessionStart, .sessionStop]
}

/// Production `HapticFeedbackService` over `UIImpactFeedbackGenerator`
/// (docs/07 §7.1, [PRD OQ-6]).
///
/// **`UIFeedbackGenerator`, not a CoreHaptics pattern engine.** What the flow
/// needs is transients: a light tick per numeral, and two bursts that can be
/// felt through a pocket. Repeating an impact generator delivers that, respects
/// the user's System Haptics setting for free, and has `prepare()` as its
/// documented latency pre-warm. A `CHHapticEngine` would buy custom envelopes
/// at the cost of an engine lifecycle, a reset handler and a stopped-handler to
/// get wrong — and would still fall back to exactly this on a device that
/// cannot run it. CoreHaptics is imported for one thing: the hardware
/// capability probe, which is the right way to ask even when the pulses
/// themselves come from UIKit.
///
/// **Degradation is silent and total.** On a device with no Taptic Engine, or
/// in the simulator, `supportsHaptics` is false and every method becomes a
/// no-op after one log line — no burst is scheduled, so nothing is left running
/// against hardware that is not there. Nothing throws and nothing is reported
/// upward: the visible countdown is the channel that must work, and it is not
/// this type's business [PRD §7 AC].
final class LiveHapticFeedbackService: HapticFeedbackService {
    private let logService: LogService
    private let generators = HapticGenerators()

    /// Whether this device has a Taptic Engine at all.
    ///
    /// Note what this does **not** cover: there is no public API for the user's
    /// System Haptics toggle. When it is off, the generators simply do nothing
    /// — the correct outcome, and indistinguishable from here. The setting
    /// needs no detection; what it needs is that nothing downstream depends on
    /// a pulse having happened, which the protocol already guarantees.
    private let supportsHaptics: Bool

    /// One explanation per service, not one per countdown. `prepare()` runs
    /// every time the countdown screen appears, and a device that will never
    /// have haptics would otherwise fill the log with a line about a
    /// non-fault.
    private let hasExplained = Locked(false)

    /// Whether this device can play anything. Read by diagnostics and by the
    /// tests, which have to behave differently on a simulator and on a phone.
    var isSupported: Bool { supportsHaptics }

    init(logService: LogService) {
        self.logService = logService
        self.supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - Lifecycle

    func prepare() async {
        guard supportsHaptics else {
            // Info, not a warning: a device without a Taptic Engine is a
            // supported configuration, not a fault, and the countdown is
            // unaffected either way.
            let shouldExplain = hasExplained.withLock { explained -> Bool in
                defer { explained = true }
                return !explained
            }
            if shouldExplain {
                logService.log(.info, .audio, "haptics unavailable on this device; countdown stays visual")
            }
            return
        }
        await generators.warmAll()
    }

    func teardown() async {
        guard supportsHaptics else { return }
        await generators.release()
    }

    // MARK: - Patterns

    func playCadenceTick() async { await play(.cadenceTick) }
    func playSessionStart() async { await play(.sessionStart) }
    func playSessionStop() async { await play(.sessionStop) }

    private func play(_ pattern: HapticPattern) async {
        guard supportsHaptics else { return }
        await generators.play(pattern)
    }
}
