import CoreHaptics
import Foundation
import UIKit

/// The three weights, chosen for contrast rather than taste.
///
/// `light` → `heavy` is the widest separation the feedback generators offer,
/// which is what a user feeling the countdown through a pocket needs in order
/// to tell the last count from the start of recording [PRD OQ-6]. `medium`
/// sits between them, so Stop is mistakable for neither.
private enum HapticTap {
    case cadenceTick
    case sessionStart
    case sessionStop

    var style: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .cadenceTick: .light
        case .sessionStart: .heavy
        case .sessionStop: .medium
        }
    }

    static let all: [HapticTap] = [.cadenceTick, .sessionStart, .sessionStop]
}

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
        for tap in HapticTap.all { generator(for: tap.style).prepare() }
    }

    func play(_ tap: HapticTap) {
        let generator = generator(for: tap.style)
        generator.impactOccurred()
        // A generator goes cold after firing, and the countdown's next tick is
        // a second away — long enough for the hardware to idle back down.
        // Re-warming now is what keeps every tick feeling like the first.
        generator.prepare()
    }

    func release() {
        byStyle.removeAll()
    }

    /// Lazily, so a play that arrives without a `prepare` still taps.
    ///
    /// `prepare` is an optimisation, not an initialisation: a countdown that
    /// somehow reached Go without one should feel slightly late, never silent.
    private func generator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let existing = byStyle[style] { return existing }
        let created = UIImpactFeedbackGenerator(style: style)
        byStyle[style] = created
        return created
    }
}

/// Production `HapticFeedbackService` over `UIImpactFeedbackGenerator`
/// (docs/07 §7.1, [PRD OQ-6]).
///
/// **`UIFeedbackGenerator`, not a CoreHaptics pattern engine.** What the PRD
/// asks for is three taps of three weights — a light tick per numeral, a heavy
/// one at Go, a medium one at Stop. The feedback generators deliver exactly
/// that, respect the user's System Haptics setting for free, and have
/// `prepare()` as their documented latency pre-warm. A `CHHapticEngine` would
/// buy custom envelopes nobody asked for, at the cost of an engine lifecycle, a
/// reset handler and a stopped-handler to get wrong. CoreHaptics is imported
/// for one thing: the hardware capability probe, which is the right way to ask
/// even when the taps themselves come from UIKit.
///
/// **Degradation is silent and total.** On a device with no Taptic Engine, or
/// in the simulator, `supportsHaptics` is false and every method becomes a
/// no-op after one log line. Nothing throws and nothing is reported upward —
/// the visible countdown is the channel that must work, and it is not this
/// type's business [PRD §7 AC].
final class LiveHapticFeedbackService: HapticFeedbackService {
    private let logService: LogService
    private let generators = HapticGenerators()

    /// Whether this device has a Taptic Engine at all.
    ///
    /// Note what this does **not** cover: there is no public API for the user's
    /// System Haptics toggle. When it is off, the generators simply do nothing
    /// — the correct outcome, and indistinguishable from here. The setting
    /// needs no detection; what it needs is that nothing downstream depends on
    /// a tap having happened, which the protocol already guarantees.
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

    // MARK: - Taps

    func playCadenceTick() async { await play(.cadenceTick) }
    func playSessionStart() async { await play(.sessionStart) }
    func playSessionStop() async { await play(.sessionStop) }

    private func play(_ tap: HapticTap) async {
        guard supportsHaptics else { return }
        await generators.play(tap)
    }
}
