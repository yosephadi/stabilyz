import Foundation

/// The Live Activity that nudges the user to open the watch app (Task 12.5.1,
/// PRD §8). Local only: no push, no notification, no permission prompt.
///
/// Nothing waits on it — Start never does, and a nudge that fails to show
/// only costs the nudge.
protocol WatchNudgeService: Sendable {
    /// Shows the nudge, unless one is showing or the user turned Live
    /// Activities off.
    func show() async
    /// Ends every nudge, including any left from an earlier launch.
    func end() async
}

/// No nudge: the default slot value and the UI-testing stand-in.
struct SilentWatchNudgeService: WatchNudgeService {
    init() {}
    func show() async {}
    func end() async {}
}

/// Records what it was asked, in order, for tests.
final class MockWatchNudgeService: WatchNudgeService, Sendable {
    enum Call: Equatable, Sendable {
        case show
        case end
    }

    private let recorded = Locked<[Call]>([])

    init() {}

    var calls: [Call] { recorded.withLock { $0 } }

    func show() async { recorded.withLock { $0.append(.show) } }
    func end() async { recorded.withLock { $0.append(.end) } }
}
