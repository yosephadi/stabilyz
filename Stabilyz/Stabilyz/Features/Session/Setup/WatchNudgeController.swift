import Foundation

/// What the nudge must do now.
enum WatchNudgeAction: Equatable, Sendable {
    case show
    case end
}

/// When the Live Activity nudge shows (Task 12.5.1, PRD §8). Pure.
///
/// It shows while the setup screen is the one in front and the watch app is
/// installed but not reachable. It ends when the watch becomes reachable,
/// when the user leaves the setup screen, or when the walk ends or the
/// countdown is cancelled — and after that it waits for the user to come
/// back to the setup screen.
///
/// It never starts during a walk: the phone is pocketed by then, and a Live
/// Activity can only be started from the foreground. One showing at Start
/// stays until one of the above ends it.
struct WatchNudgeRule: Equatable, Sendable {
    private(set) var isShowing = false
    var reachability: WatchReachability = .unavailable
    var isOnSetup = false
    var isSessionActive = false
    /// Set when a walk ends or a countdown is cancelled; cleared on the next
    /// return to the setup screen.
    var isSpent = false

    mutating func decide() -> WatchNudgeAction? {
        let wanted = reachability == .installedNotReachable && isOnSetup && !isSpent
        if wanted, !isShowing, !isSessionActive {
            isShowing = true
            return .show
        }
        if !wanted, isShowing {
            isShowing = false
            return .end
        }
        return nil
    }
}

/// Runs the nudge for the Walk tab (Task 12.5.1): feeds `WatchNudgeRule` the
/// watch's reachability and where the user is, and carries out what it
/// decides.
///
/// Every call to the nudge service is queued behind the last, in order, and
/// none is awaited by its caller — Start never waits on the nudge.
@MainActor
final class WatchNudgeController {
    private(set) var rule = WatchNudgeRule()

    private let nudge: WatchNudgeService
    private let watchSession: WatchSessionService
    private var calls: [Task<Void, Never>] = []
    private var listener: Task<Void, Never>?

    init(nudge: WatchNudgeService, watchSession: WatchSessionService) {
        self.nudge = nudge
        self.watchSession = watchSession
    }

    /// Ends any nudge left from an earlier launch, then follows the watch.
    /// Call once.
    func start(isOnSetup: Bool) {
        guard listener == nil else { return }
        enqueue(.end)
        rule.isOnSetup = isOnSetup
        let updates = watchSession.reachability()
        listener = Task { [weak self] in
            for await reachability in updates {
                guard let self else { return }
                self.rule.reachability = reachability
                self.apply()
            }
        }
    }

    /// The Walk tab became the one in front.
    func setupEntered() {
        rule.isOnSetup = true
        rule.isSpent = false
        apply()
    }

    /// The user went to another tab.
    func setupLeft() {
        rule.isOnSetup = false
        apply()
    }

    /// Start was tapped.
    func sessionBegan() {
        rule.isSessionActive = true
        apply()
    }

    /// The walk ended, or the countdown was cancelled or failed. Safe to call
    /// more than once.
    func sessionEnded() {
        rule.isSessionActive = false
        rule.isSpent = true
        apply()
    }

    /// Waits for every queued call to the nudge service. For tests.
    func settled() async {
        for call in calls { await call.value }
    }

    private func apply() {
        if let action = rule.decide() { enqueue(action) }
    }

    private func enqueue(_ action: WatchNudgeAction) {
        let nudge = nudge
        let previous = calls.last
        calls.append(Task {
            await previous?.value
            switch action {
            case .show: await nudge.show()
            case .end: await nudge.end()
            }
        })
    }
}
