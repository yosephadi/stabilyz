import Foundation

/// Every string the watch shows [PRD §8 Watch screens].
nonisolated enum WatchCopy {
    static let waitingTitle = "Start on your iPhone"
    static let countdownHeading = "Get ready"
    static let go = "Go"
    static let countdownFooter = "Phone in pocket"
    static let stop = "Stop"
    static let stoppedTitle = "Walk finished"
    static let stoppedDetail = "See your result on iPhone"
    static let done = "Done"
    static let disconnectedTitle = "Phone not reachable"
    static let disconnectedDetail = "Keep walking. Your walk is still recording."

    static func modeName(_ mode: WireTestMode) -> String {
        switch mode {
        case .quick: "Quick Test"
        case .full: "Full Test"
        }
    }

    /// "Quick Test · 2 min".
    static func selectionLine(_ selection: WatchSelection) -> String {
        "\(modeName(selection.mode)) · \(selection.durationSeconds / 60) min"
    }

    /// VoiceOver for the selection: "Quick Test, 2 minutes".
    static func selectionLabel(_ selection: WatchSelection) -> String {
        let minutes = selection.durationSeconds / 60
        return "\(modeName(selection.mode)), \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
}

/// The walk timer as a screen shows it.
nonisolated struct WatchTimer: Equatable, Sendable {
    /// Elapsed since T-0, "mm:ss".
    let text: String
    /// "1 minute 5 seconds elapsed".
    let accessibilityLabel: String
    /// 0 at T-0, 1 at the advertised length.
    let progress: Double

    init(t0: Date, durationSeconds: Int, now: Date) {
        let elapsed = max(0, Int(now.timeIntervalSince(t0).rounded(.down)))
        text = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let minutes = elapsed / 60, seconds = elapsed % 60
        accessibilityLabel = "\(minutes) \(minutes == 1 ? "minute" : "minutes") \(seconds) \(seconds == 1 ? "second" : "seconds") elapsed"
        progress = durationSeconds > 0 ? min(Double(elapsed) / Double(durationSeconds), 1) : 0
    }
}

/// What the watch is showing, derived from the machine and the clock
/// (Task 12.2.1). Pure, so the copy and the rules about what is visible are
/// tested without rendering.
nonisolated enum WatchScreen: Equatable, Sendable {
    case waiting(selection: String?, selectionLabel: String?)
    /// `numeral` is "5"…"1", then "Go" for `goHold` after T-0.
    case countdown(numeral: String)
    case running(WatchTimer, stopEnabled: Bool)
    case stopped
    case disconnected(WatchTimer)

    /// How long "Go" stays up once the walk has started.
    static let goHold: TimeInterval = 1

    /// Whether this screen offers Stop at all. Never during the countdown and
    /// never while the phone is unreachable [PRD §8].
    var showsStop: Bool {
        if case .running = self { return true }
        return false
    }

    init(_ machine: WatchSessionMachine, at now: Date) {
        switch machine.phase {
        case .waiting:
            self = .waiting(
                selection: machine.selection.map(WatchCopy.selectionLine),
                selectionLabel: machine.selection.map(WatchCopy.selectionLabel)
            )
        case .countingDown(let session):
            self = .countdown(numeral: "\(WatchSessionMachine.numeral(plannedGoAt: session.plannedGoAt, at: now))")
        case .running(let session):
            let t0 = session.t0 ?? session.plannedGoAt
            if !session.t0IsEstimated, now.timeIntervalSince(t0) < Self.goHold {
                self = .countdown(numeral: WatchCopy.go)
            } else {
                self = .running(
                    WatchTimer(t0: t0, durationSeconds: session.selection.durationSeconds, now: now),
                    stopEnabled: !machine.isStopPending
                )
            }
        case .disconnected(let session):
            let t0 = session.t0 ?? session.plannedGoAt
            self = .disconnected(WatchTimer(t0: t0, durationSeconds: session.selection.durationSeconds, now: now))
        case .stopped:
            self = .stopped
        }
    }
}
