import CoreHaptics
import Foundation
import UIKit

/// Main-actor home for the haptic hardware.
///
/// Split out rather than folded into the service because the service has to be
/// `nonisolated` to witness a `nonisolated` protocol: the isolation lives with
/// the objects that actually need it, and the service hops here.
///
/// Two instruments, one per kind of cue:
///
/// - **`UIImpactFeedbackGenerator`** for the countdown tick — a transient is
///   exactly what the generator is for, and it has `prepare()` as its
///   documented latency pre-warm.
/// - **`CHHapticEngine`** for Go and Stop. A sustained, low-sharpness vibration
///   is something the feedback generators cannot produce at all: they only
///   play transients, and a transient is the cue a pocket swallows. That is the
///   whole reason CoreHaptics is here now when it was deliberately not before.
@MainActor
private final class HapticHardware {
    private let logService: LogService

    private var tickGenerator: UIImpactFeedbackGenerator?
    /// Used only when the engine cannot run. A heavy transient is a poorer cue
    /// through clothing, but it is still a cue — degradation should cost
    /// strength, never the signal outright.
    private var fallbackGenerator: UIImpactFeedbackGenerator?

    private var engine: CHHapticEngine?
    /// Whether `engine` is believed to be running. Cleared by the engine's own
    /// stopped and reset handlers, so the next sustained cue restarts it
    /// instead of playing into an engine the system has already shut down.
    private var engineRunning = false
    /// One explanation per failure mode, not one per cue.
    private var hasLoggedEngineFailure = false

    nonisolated init(logService: LogService) {
        self.logService = logService
    }

    func warm() {
        tick().prepare()
        startEngineIfNeeded()
    }

    func play(_ pattern: HapticPattern) {
        switch pattern.kind {
        case .transient:
            let generator = tick()
            generator.impactOccurred()
            // A generator goes cold after firing, and the next tick is a second
            // away — long enough for the hardware to idle back down.
            generator.prepare()

        case .continuous:
            if playSustained(pattern) { return }
            let fallback = fallbackGenerator ?? UIImpactFeedbackGenerator(style: .heavy)
            fallbackGenerator = fallback
            fallback.impactOccurred()
        }
    }

    /// Releases the hardware **without cutting a cue already playing**.
    ///
    /// Stop is played and torn down back to back, and a 500ms vibration that an
    /// immediate `engine.stop()` ended after a few milliseconds would undo this
    /// whole change. So the engine is told to stop once its players finish, and
    /// the handler holds the engine alive until then. With nothing playing, the
    /// handler runs at once.
    func release() {
        tickGenerator = nil
        fallbackGenerator = nil

        guard let finishing = engine else { return }
        engine = nil
        engineRunning = false

        nonisolated(unsafe) let retained = finishing
        finishing.notifyWhenPlayersFinished { _ in
            withExtendedLifetime(retained) {}
            return .stopEngine
        }
    }

    // MARK: - Sustained cues

    /// - Returns: false when the engine could not play, so the caller falls
    ///   back to a transient.
    ///
    /// Never waits for the vibration: `start(atTime:)` schedules it and returns.
    /// The countdown plays Go immediately before opening the session against a
    /// `TimeAnchor` already stamped at T-0, so a call that held for the cue's
    /// length would open the recording behind its own origin.
    private func playSustained(_ pattern: HapticPattern) -> Bool {
        let events = LiveHapticFeedbackService.events(for: pattern)
        guard !events.isEmpty, startEngineIfNeeded(), let engine else { return false }

        do {
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            do {
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {
                // The flag can be stale — the stopped handler hops here
                // asynchronously. One restart and one retry, then give up.
                engineRunning = false
                guard startEngineIfNeeded() else { return false }
                try player.start(atTime: CHHapticTimeImmediate)
            }
            return true
        } catch {
            explainEngineFailure("haptic engine could not play a sustained cue; using a transient")
            return false
        }
    }

    /// Creates and starts the engine on first use, and restarts it after the
    /// system stops or resets it.
    ///
    /// Synchronous. `prepare()` runs this when the countdown screen appears, so
    /// Go normally finds the engine already running; only a cue arriving after
    /// the system has idled the engine — Stop, minutes into a walk — pays for a
    /// restart, and that cue is not racing an anchor.
    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        if engineRunning, engine != nil { return true }

        do {
            let engine = try self.engine ?? makeEngine()
            try engine.start()
            self.engine = engine
            engineRunning = true
            return true
        } catch {
            explainEngineFailure("haptic engine unavailable; Go and Stop fall back to transients")
            return false
        }
    }

    private func makeEngine() throws -> CHHapticEngine {
        let engine = try CHHapticEngine()
        // Haptics only. This app runs its own audio session for the session
        // tones, and an engine that also claimed audio could interrupt or be
        // interrupted by it — two owners of one piece of system state
        // (docs/10 §10.2).
        engine.playsHapticsOnly = true

        engine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.engineRunning = false }
        }
        engine.resetHandler = { [weak self] in
            // The haptic server restarted and every player is gone. Mark it,
            // and let the next cue start it again rather than restarting here
            // on a queue this type does not own.
            Task { @MainActor in self?.engineRunning = false }
        }
        return engine
    }

    private func explainEngineFailure(_ message: String) {
        guard !hasLoggedEngineFailure else { return }
        hasLoggedEngineFailure = true
        logService.log(.warning, .audio, message)
    }

    private func tick() -> UIImpactFeedbackGenerator {
        if let tickGenerator { return tickGenerator }
        let created = UIImpactFeedbackGenerator(style: .light)
        tickGenerator = created
        return created
    }
}

/// Production `HapticFeedbackService` (docs/07 §7.1, [PRD OQ-6]).
///
/// A light transient per countdown numeral from `UIImpactFeedbackGenerator`,
/// and a sustained, low-sharpness vibration for Go and Stop from
/// `CHHapticEngine` — see `HapticPattern` for why those two need the engine.
///
/// **Degradation is silent and total.** On a device with no Taptic Engine, or
/// in the simulator, `supportsHaptics` is false and every method becomes a
/// no-op after one log line — no engine is created at all. On hardware whose
/// engine will not start, Go and Stop fall back to a heavy transient. Nothing
/// throws and nothing is reported upward: the visible countdown is the channel
/// that must work, and it is not this type's business [PRD §7 AC].
///
/// **One behavioural difference to know about.** `UIFeedbackGenerator` defers
/// to the user's System Haptics setting; `CHHapticEngine` does not. The tick
/// still honours that switch, but Go and Stop now play regardless of it. For a
/// cue whose purpose is reaching a user who cannot see the screen, that is the
/// trade this change makes; the app's own haptics toggle still governs Stop.
final class LiveHapticFeedbackService: HapticFeedbackService {
    private let logService: LogService
    private let hardware: HapticHardware

    /// Whether this device has a Taptic Engine at all.
    private let supportsHaptics: Bool

    /// One explanation per service, not one per countdown.
    private let hasExplained = Locked(false)

    /// Whether this device can play anything. Read by diagnostics and by the
    /// tests, which have to behave differently on a simulator and on a phone.
    var isSupported: Bool { supportsHaptics }

    init(logService: LogService) {
        self.logService = logService
        self.hardware = HapticHardware(logService: logService)
        self.supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - Lifecycle

    func prepare() async {
        guard supportsHaptics else {
            // Info, not a warning: a device without a Taptic Engine is a
            // supported configuration, not a fault.
            let shouldExplain = hasExplained.withLock { explained -> Bool in
                defer { explained = true }
                return !explained
            }
            if shouldExplain {
                logService.log(.info, .audio, "haptics unavailable on this device; countdown stays visual")
            }
            return
        }
        await hardware.warm()
    }

    func teardown() async {
        guard supportsHaptics else { return }
        await hardware.release()
    }

    // MARK: - Cues

    func playCadenceTick() async { await play(.cadenceTick) }
    func playSessionStart() async { await play(.sessionStart) }
    func playSessionStop() async { await play(.sessionStop) }

    private func play(_ pattern: HapticPattern) async {
        guard supportsHaptics else { return }
        await hardware.play(pattern)
    }

    // MARK: - Pattern → CoreHaptics

    /// The engine events for a sustained cue; empty for a transient.
    ///
    /// Its own function so the translation is asserted without hardware:
    /// building a `CHHapticEvent` needs no Taptic Engine, only playing one does.
    static func events(for pattern: HapticPattern) -> [CHHapticEvent] {
        guard case .continuous(let duration, let intensity, let sharpness) = pattern.kind else {
            return []
        }
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18

        return [
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness))
                ],
                relativeTime: 0,
                duration: seconds
            )
        ]
    }
}
