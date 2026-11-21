import Foundation
@testable import StabilyzWatch_Watch_App

let sessionA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
let sessionB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
let goAt = Date(timeIntervalSince1970: 1_000)

/// `goAt` offset by `seconds`.
func at(_ seconds: TimeInterval) -> Date { goAt.addingTimeInterval(seconds) }

func countdownStarted(
    _ id: UUID = sessionA,
    mode: WireTestMode = .quick,
    owner: WireHapticOwner = .watch,
    hapticsEnabled: Bool = true
) -> PhoneToWatchMessage {
    .countdownStarted(
        sessionID: id,
        mode: mode,
        durationSeconds: mode == .quick ? 90 : 180,
        plannedGoAt: goAt,
        hapticOwner: owner,
        hapticsEnabled: hapticsEnabled
    )
}

extension WatchSessionMachine {
    /// Feeds events in order and returns every effect, in order.
    @discardableResult
    mutating func run(_ events: [WatchEvent]) -> [WatchEffect] {
        events.flatMap { handle($0) }
    }

    /// Reachable, counting down for session A from five seconds before Go.
    static func counting(owner: WireHapticOwner = .watch, hapticsEnabled: Bool = true) -> WatchSessionMachine {
        var machine = WatchSessionMachine()
        machine.run([
            .reachability(true, at: at(-6)),
            .received(countdownStarted(owner: owner, hapticsEnabled: hapticsEnabled), at: at(-5)),
        ])
        return machine
    }

    /// Reachable and running session A from T-0 = `goAt`.
    static func running(owner: WireHapticOwner = .watch, hapticsEnabled: Bool = true) -> WatchSessionMachine {
        var machine = counting(owner: owner, hapticsEnabled: hapticsEnabled)
        machine.run([.received(.started(sessionID: sessionA, t0: goAt), at: at(0.1))])
        return machine
    }
}
