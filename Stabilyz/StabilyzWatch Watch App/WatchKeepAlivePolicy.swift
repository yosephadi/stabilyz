import Foundation

/// What the keep-alive must do now.
nonisolated enum WatchKeepAliveAction: Equatable, Sendable {
    case start
    case end
}

/// When the watch app keeps itself running (Task 12.4.1, docs/04 §4.18).
///
/// An extended runtime session keeps the app alive through wrist-down and
/// leaving the app [PRD §8]. It can only start while the app is active, so it
/// starts on the first chance:
/// - the app becomes active on anything but Stopped (Waiting, or a countdown
///   or walk already under way), or
/// - while active, a countdown begins, a walk is joined, or the phone comes
///   back mid-walk.
///
/// It ends after Stopped → Done, or once Stopped has sat for `staleStopped`
/// without Done. The system ending it (expiry, invalidation) only marks it
/// gone: the walk never depends on it, and it starts again at the next
/// chance.
///
/// Pure: the model feeds it the phase, whether the app is active, and the
/// time.
nonisolated struct WatchKeepAlivePolicy: Equatable, Sendable {
    /// How long Stopped may sit without Done before the keep-alive ends.
    static let staleStopped: TimeInterval = 5 * 60

    private(set) var isRunning = false
    private var isActive = false
    private var lastStep: Step = .waiting
    private var stoppedSince: Date?

    private enum Step: Equatable, Sendable {
        case waiting, countingDown, running, disconnected, stopped

        init(_ phase: WatchPhase) {
            switch phase {
            case .waiting: self = .waiting
            case .countingDown: self = .countingDown
            case .running: self = .running
            case .disconnected: self = .disconnected
            case .stopped: self = .stopped
            }
        }

        var isSessionUnderWay: Bool {
            self == .countingDown || self == .running || self == .disconnected
        }
    }

    init() {}

    /// Called after every event, with where the watch is now.
    mutating func update(phase: WatchPhase, isActive: Bool, now: Date) -> WatchKeepAliveAction? {
        let step = Step(phase)
        let previous = lastStep
        let becameActive = isActive && !self.isActive
        self.isActive = isActive
        lastStep = step
        stoppedSince = step == .stopped ? (stoppedSince ?? now) : nil

        if isRunning {
            let done = previous == .stopped && step == .waiting
            let stale = stoppedSince.map { now.timeIntervalSince($0) >= Self.staleStopped } ?? false
            guard done || stale else { return nil }
            isRunning = false
            return .end
        }

        guard isActive, step != .stopped else { return nil }
        let sessionMoved = step != previous && step.isSessionUnderWay
        guard becameActive || sessionMoved else { return nil }
        isRunning = true
        return .start
    }

    /// The system ended the keep-alive: it expired or was invalidated.
    mutating func keepAliveEnded() {
        isRunning = false
    }
}
