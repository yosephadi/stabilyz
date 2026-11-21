#if DEBUG
import Foundation

/// DEBUG only: opens the watch app frozen in one of its five states, for
/// screenshots and design review. Not compiled into a release build.
///
///     xcrun simctl launch <watch> com.adi.Stabilyz.watchkitapp -watch-preview running
///
/// The states are reached the honest way: the real `WatchSessionMachine` is
/// fed the contract messages the phone would send, through a stand-in link, on
/// a frozen clock. What it shows is what the machine produces, not a mock-up.
enum WatchDebugPreview: String, CaseIterable {
    case waiting
    /// The numeral "3".
    case countdown
    /// 01:24 into a Quick Test.
    case running
    case stopped
    case disconnected

    static let argument = "-watch-preview"

    /// The state named after `-watch-preview` in the launch arguments, if any.
    static func requested(in arguments: [String] = ProcessInfo.processInfo.arguments) -> WatchDebugPreview? {
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return WatchDebugPreview(rawValue: arguments[index + 1])
    }

    /// A model frozen in this state, with no haptics.
    @MainActor
    func makeModel(at now: Date = Date()) -> WatchSessionModel {
        WatchSessionModel(
            link: ScriptedLink(events: events(at: now)),
            haptics: NoHaptics(),
            clock: { now },
            announce: { _ in }
        )
    }

    func events(at now: Date) -> [WatchLinkEvent] {
        let id = UUID()
        let quick = PhoneToWatchMessage.setupSelection(mode: .quick, durationSeconds: 90)
        // T-0 1 minute 4 seconds ago (of a 1:30 Quick Test).
        let t0 = now.addingTimeInterval(-64)
        let walking: [WatchLinkEvent] = [
            .reachability(true),
            .message(quick),
            .message(.countdownStarted(
                sessionID: id, mode: .quick, durationSeconds: 90,
                plannedGoAt: t0, hapticOwner: .phone, hapticsEnabled: true
            )),
            .message(.started(sessionID: id, t0: t0)),
        ]

        switch self {
        case .waiting:
            return [.reachability(true), .message(quick)]
        case .countdown:
            // Go in 2.5 s: the numeral showing is 3.
            return [
                .reachability(true),
                .message(quick),
                .message(.countdownStarted(
                    sessionID: id, mode: .quick, durationSeconds: 90,
                    plannedGoAt: now.addingTimeInterval(2.5), hapticOwner: .phone, hapticsEnabled: true
                )),
            ]
        case .running:
            return walking
        case .stopped:
            return walking + [.message(.stopped(sessionID: id))]
        case .disconnected:
            return walking + [.reachability(false)]
        }
    }
}

/// Delivers a fixed script of events on activation, and sends nothing.
private struct ScriptedLink: WatchPhoneLinking {
    let events: [WatchLinkEvent]

    func activate(onEvent: @escaping @MainActor @Sendable (WatchLinkEvent) -> Void) {
        let events = events
        Task { @MainActor in
            for event in events { onEvent(event) }
        }
    }

    func send(_ message: WatchToPhoneMessage) {}
}

private struct NoHaptics: WatchHapticPlaying {
    func play(_ haptic: WatchHaptic) {}
}
#endif
