import Foundation
import Testing
@testable import StabilyzWatch_Watch_App

private func haptics(in effects: [WatchEffect]) -> [WatchHaptic] {
    effects.compactMap { if case .playHaptic(let haptic) = $0 { haptic } else { nil } }
}

/// The watch's half of haptic ownership (Task 12.3.1, PRD §8 decision 3).
@Suite struct WatchHapticOwnershipTests {
    /// Five clicks, Go, then Stop: the whole session felt on the wrist.
    @Test func anOwningWatchPlaysEveryCue() {
        var machine = WatchSessionMachine()
        var events: [WatchEvent] = [
            .reachability(true, at: at(-6)),
            .received(countdownStarted(owner: .watch), at: at(-5)),
        ]
        events += stride(from: -4.9, to: 0, by: 0.1).map { .tick(at($0)) }
        events += [
            .received(.started(sessionID: sessionA, t0: goAt), at: at(0.05)),
            .received(.stopped(sessionID: sessionA), at: at(60)),
        ]
        #expect(haptics(in: machine.run(events)) == [.click, .click, .click, .click, .click, .start, .stop])
    }

    @Test func aWatchThatDoesNotOwnPlaysNothing() {
        var machine = WatchSessionMachine()
        var events: [WatchEvent] = [
            .reachability(true, at: at(-6)),
            .received(countdownStarted(owner: .phone), at: at(-5)),
        ]
        events += stride(from: -4.9, to: 0, by: 0.1).map { .tick(at($0)) }
        events += [
            .received(.started(sessionID: sessionA, t0: goAt), at: at(0.05)),
            .received(.stopped(sessionID: sessionA), at: at(60)),
        ]
        #expect(haptics(in: machine.run(events)).isEmpty)
    }

    @Test func hapticsOffMeansNothingOnTheWatch() {
        var machine = WatchSessionMachine.counting(owner: .watch, hapticsEnabled: false)
        let effects = machine.run([
            .tick(at(-3.5)),
            .received(.started(sessionID: sessionA, t0: goAt), at: at(0.05)),
            .received(.stopped(sessionID: sessionA), at: at(60)),
        ])
        #expect(haptics(in: effects).isEmpty)
    }

    /// Start & Stop Haptics governs the watch, including a change mid-walk.
    @Test func aMidWalkHapticsChangeGovernsTheStopPulse() {
        var off = WatchSessionMachine.running(owner: .watch)
        let offEffects = off.run([
            .received(.hapticsChanged(enabled: false), at: at(20)),
            .received(.stopped(sessionID: sessionA), at: at(60)),
        ])
        #expect(haptics(in: offEffects).isEmpty)

        var on = WatchSessionMachine.running(owner: .watch, hapticsEnabled: false)
        let onEffects = on.run([
            .received(.hapticsChanged(enabled: true), at: at(20)),
            .received(.stopped(sessionID: sessionA), at: at(60)),
        ])
        #expect(haptics(in: onEffects) == [.stop])
    }

    @Test func aCancelledCountdownIsFeltAsStop() {
        var machine = WatchSessionMachine.counting(owner: .watch)
        let effects = machine.run([.received(.cancelled(sessionID: sessionA), at: at(-2))])
        #expect(haptics(in: effects) == [.stop])
        #expect(machine.phase == .waiting)
    }

    @Test func disconnectedHasNoHaptic() {
        var machine = WatchSessionMachine.running(owner: .watch)
        let effects = machine.run([
            .reachability(false, at: at(30)),
            .tick(at(31)),
            .tick(at(45)),
        ])
        #expect(haptics(in: effects).isEmpty)
    }
}

/// `started` never arriving (user addition to Task 12.3.1).
@Suite struct WatchMissedStartedTests {
    @Test func theCountdownHoldsUntilTwoSecondsAfterThePlannedGo() {
        var machine = WatchSessionMachine.counting()
        machine.run([.tick(at(1.9))])
        guard case .countingDown = machine.phase else {
            Issue.record("left the countdown early: \(machine.phase)")
            return
        }
    }

    @Test func withNoStartedTheWatchRunsFromThePlannedGoWithNoGoHaptic() {
        var machine = WatchSessionMachine.counting(owner: .watch)
        let effects = machine.run([.tick(at(2))])
        #expect(effects.isEmpty, "no Go haptic and no announcement: both would be late")
        guard case .running(let session) = machine.phase else {
            Issue.record("not running: \(machine.phase)")
            return
        }
        #expect(session.t0 == goAt)
        #expect(session.t0IsEstimated)
        #expect(WatchScreen(machine, at: at(2.1)).showsStop, "no 'Go' hold for a Go that was never felt")
    }

    @Test func aLateStartedReSyncsTheClockWithoutAGoHaptic() {
        var machine = WatchSessionMachine.counting(owner: .watch)
        machine.run([.tick(at(2))])
        let t0 = at(0.4)
        let effects = machine.run([.received(.started(sessionID: sessionA, t0: t0), at: at(3))])
        #expect(effects.isEmpty)
        #expect(machine.phase.session?.t0 == t0)
        #expect(machine.phase.session?.t0IsEstimated == false)
        guard case .running(let timer, _) = WatchScreen(machine, at: at(10.4)) else {
            Issue.record("not the running screen")
            return
        }
        #expect(timer.text == "00:10")
    }

    /// The watch dropped during the countdown: it moves on to Disconnected,
    /// keeping the timer from the planned Go.
    @Test func aWatchThatDroppedDuringTheCountdownMovesToDisconnected() {
        var machine = WatchSessionMachine.counting()
        machine.run([.reachability(false, at: at(-3)), .tick(at(2))])
        guard case .disconnected(let session) = machine.phase else {
            Issue.record("not disconnected: \(machine.phase)")
            return
        }
        #expect(session.t0 == goAt)

        machine.run([.reachability(true, at: at(20))])
        guard case .running = machine.phase else {
            Issue.record("not running after reconnect: \(machine.phase)")
            return
        }
    }

    @Test func stopStillWorksAfterTheFallback() {
        var machine = WatchSessionMachine.counting(owner: .watch)
        machine.run([.tick(at(2))])
        #expect(machine.run([.stopTapped(at: at(10))]) == [.sendStopRequest(sessionA)])
        #expect(haptics(in: machine.run([.received(.stopped(sessionID: sessionA), at: at(10.2))])) == [.stop])
    }
}
