import Foundation
import Testing
@testable import StabilyzWatch_Watch_App

private let session = WatchSession(
    id: sessionA,
    selection: WatchSelection(mode: .quick, durationSeconds: 120),
    plannedGoAt: goAt,
    t0: goAt,
    hapticOwner: .watch,
    hapticsEnabled: true
)

/// When the keep-alive starts and ends (Task 12.4.1).
@Suite struct WatchKeepAlivePolicyTests {
    @Test func itStartsWhenTheAppBecomesActiveOnWaiting() {
        var policy = WatchKeepAlivePolicy()
        #expect(policy.update(phase: .waiting, isActive: true, now: at(0)) == .start)
        #expect(policy.isRunning)
        #expect(policy.update(phase: .waiting, isActive: true, now: at(1)) == nil, "once")
    }

    @Test func itCannotStartWhileInactiveAndStartsOnceActive() {
        var policy = WatchKeepAlivePolicy()
        #expect(policy.update(phase: .waiting, isActive: false, now: at(0)) == nil)
        #expect(policy.update(phase: .countingDown(session), isActive: false, now: at(1)) == nil)
        #expect(policy.update(phase: .countingDown(session), isActive: true, now: at(2)) == .start)
    }

    @Test func itStartsWhenAppOpensMidCountdownOrMidWalk() {
        for phase in [WatchPhase.countingDown(session), .running(session), .disconnected(session)] {
            var policy = WatchKeepAlivePolicy()
            #expect(policy.update(phase: phase, isActive: true, now: at(0)) == .start)
        }
    }

    @Test func itNeverStartsOnStopped() {
        var policy = WatchKeepAlivePolicy()
        #expect(policy.update(phase: .stopped(sessionID: sessionA), isActive: true, now: at(0)) == nil)
    }

    @Test func itEndsAfterStoppedThenDone() {
        var policy = WatchKeepAlivePolicy()
        policy.update(phase: .running(session), isActive: true, now: at(0))
        #expect(policy.update(phase: .stopped(sessionID: sessionA), isActive: true, now: at(120)) == nil)
        #expect(policy.update(phase: .waiting, isActive: true, now: at(130)) == .end)
        #expect(!policy.isRunning)
        // Done does not restart it at once.
        #expect(policy.update(phase: .waiting, isActive: true, now: at(131)) == nil)
    }

    @Test func itEndsWhenStoppedSitsFiveMinutesWithoutDone() {
        var policy = WatchKeepAlivePolicy()
        policy.update(phase: .running(session), isActive: true, now: at(0))
        policy.update(phase: .stopped(sessionID: sessionA), isActive: false, now: at(120))
        #expect(policy.update(phase: .stopped(sessionID: sessionA), isActive: false, now: at(120 + 299)) == nil)
        #expect(policy.update(phase: .stopped(sessionID: sessionA), isActive: false, now: at(120 + 300)) == .end)
        // Done afterwards has nothing left to end.
        #expect(policy.update(phase: .waiting, isActive: false, now: at(500)) == nil)
        #expect(!policy.isRunning)
    }

    @Test func afterDoneTheNextCountdownStartsIt() {
        var policy = WatchKeepAlivePolicy()
        policy.update(phase: .running(session), isActive: true, now: at(0))
        policy.update(phase: .stopped(sessionID: sessionA), isActive: true, now: at(120))
        policy.update(phase: .waiting, isActive: true, now: at(130))
        #expect(policy.update(phase: .countingDown(session), isActive: true, now: at(140)) == .start)
    }

    @Test func afterDoneReopeningTheAppStartsIt() {
        var policy = WatchKeepAlivePolicy()
        policy.update(phase: .running(session), isActive: true, now: at(0))
        policy.update(phase: .stopped(sessionID: sessionA), isActive: true, now: at(120))
        policy.update(phase: .waiting, isActive: true, now: at(130))
        policy.update(phase: .waiting, isActive: false, now: at(140))
        #expect(policy.update(phase: .waiting, isActive: true, now: at(150)) == .start)
    }

    /// Invalidated mid-walk: gone, and back at the next chance — joining the
    /// walk, the phone coming back, or the app becoming active.
    @Test func afterInvalidationItRestartsAtTheNextChance() {
        var policy = WatchKeepAlivePolicy()
        policy.update(phase: .running(session), isActive: true, now: at(0))
        policy.keepAliveEnded()
        #expect(!policy.isRunning)
        #expect(policy.update(phase: .running(session), isActive: true, now: at(1)) == nil)
        policy.update(phase: .disconnected(session), isActive: false, now: at(2))
        // Reconnect while inactive: it cannot start yet.
        #expect(policy.update(phase: .running(session), isActive: false, now: at(3)) == nil)
        #expect(policy.update(phase: .running(session), isActive: true, now: at(4)) == .start)

        policy.keepAliveEnded()
        #expect(policy.update(phase: .disconnected(session), isActive: true, now: at(5)) == .start)
    }

    @Test func reconnectingMidWalkWhileActiveStartsIt() {
        var policy = WatchKeepAlivePolicy()
        policy.update(phase: .disconnected(session), isActive: true, now: at(0))
        policy.keepAliveEnded()
        #expect(policy.update(phase: .running(session), isActive: true, now: at(1)) == .start)
    }
}

/// A keep-alive that records what it was asked, and can be ended by "the
/// system".
private final class KeepAliveSpy: WatchKeepAliveControlling {
    var calls: [String] = []
    var onEnded: (() -> Void)?
    func start(onEnded: @escaping () -> Void) { calls.append("start"); self.onEnded = onEnded }
    func end() { calls.append("end"); onEnded = nil }
}

private final class SilentLink: WatchPhoneLinking, @unchecked Sendable {
    var onEvent: (@MainActor @Sendable (WatchLinkEvent) -> Void)?
    func activate(onEvent: @escaping @MainActor @Sendable (WatchLinkEvent) -> Void) { self.onEvent = onEvent }
    func send(_ message: WatchToPhoneMessage) {}
}

private struct NoHapticsSpy: WatchHapticPlaying {
    func play(_ haptic: WatchHaptic) {}
}

/// The model carries out the policy; the keep-alive never touches the walk.
@MainActor @Suite struct WatchKeepAliveModelTests {
    @Test func theModelStartsAndEndsTheKeepAlive() {
        let link = SilentLink()
        let keepAlive = KeepAliveSpy()
        var now = at(-6)
        let model = WatchSessionModel(link: link, haptics: NoHapticsSpy(), keepAlive: keepAlive, clock: { now }, announce: { _ in })
        model.start()
        model.setActive(true)
        #expect(keepAlive.calls == ["start"])

        link.onEvent?(.reachability(true))
        link.onEvent?(.message(countdownStarted(owner: .phone)))
        now = at(0.1)
        link.onEvent?(.message(.started(sessionID: sessionA, t0: goAt)))
        now = at(30)
        link.onEvent?(.message(.stopped(sessionID: sessionA)))
        #expect(keepAlive.calls == ["start"])
        model.tapDone()
        #expect(keepAlive.calls == ["start", "end"])
    }

    @Test func theSystemEndingItLeavesTheWalkAlone() {
        let link = SilentLink()
        let keepAlive = KeepAliveSpy()
        var now = at(-6)
        let model = WatchSessionModel(link: link, haptics: NoHapticsSpy(), keepAlive: keepAlive, clock: { now }, announce: { _ in })
        model.start()
        model.setActive(true)
        link.onEvent?(.reachability(true))
        link.onEvent?(.message(countdownStarted(owner: .phone)))
        now = at(0.1)
        link.onEvent?(.message(.started(sessionID: sessionA, t0: goAt)))
        now = at(30)
        let before = model.machine

        keepAlive.onEnded?()
        #expect(model.machine == before)
        #expect(keepAlive.calls == ["start"])

        // Back at the next chance: the app becoming active again.
        model.setActive(false)
        model.setActive(true)
        #expect(keepAlive.calls == ["start", "start"])
        #expect(model.machine == before)
    }
}
