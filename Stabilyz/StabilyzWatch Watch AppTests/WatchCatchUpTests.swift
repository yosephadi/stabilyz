import Foundation
import Testing
@testable import StabilyzWatch_Watch_App

private func haptics(in effects: [WatchEffect]) -> [WatchHaptic] {
    effects.compactMap { if case .playHaptic(let haptic) = $0 { haptic } else { nil } }
}

private func announcements(in effects: [WatchEffect]) -> [String] {
    effects.compactMap { if case .announce(let text) = $0 { text } else { nil } }
}

/// Stored state for session A: its countdown, plus `state` as the latest.
private func stored(
    _ state: PhoneToWatchMessage? = nil,
    owner: WireHapticOwner = .watch,
    haptics: Bool? = nil
) -> WatchCatchUp {
    let countdown = countdownStarted(owner: owner)
    return WatchCatchUp(
        setup: .setupSelection(mode: .quick, durationSeconds: 120),
        countdown: countdown,
        sessionState: state ?? countdown,
        haptics: haptics.map { .hapticsChanged(enabled: $0) }
    )
}

/// Reading what the phone stored (Task 12.3.3).
@Suite struct WatchCatchUpDecodingTests {
    @Test func everyKeyIsReadWhenPresent() throws {
        let countdown = countdownStarted()
        let context: [String: Any] = [
            WatchSyncKeys.setup: try WatchSyncCoder.encode(PhoneToWatchMessage.setupSelection(mode: .full, durationSeconds: 360)),
            WatchSyncKeys.countdown: try WatchSyncCoder.encode(countdown),
            WatchSyncKeys.sessionState: try WatchSyncCoder.encode(PhoneToWatchMessage.started(sessionID: sessionA, t0: goAt)),
            WatchSyncKeys.haptics: try WatchSyncCoder.encode(PhoneToWatchMessage.hapticsChanged(enabled: false)),
        ]
        #expect(WatchCatchUp(applicationContext: context) == WatchCatchUp(
            setup: .setupSelection(mode: .full, durationSeconds: 360),
            countdown: countdown,
            sessionState: .started(sessionID: sessionA, t0: goAt),
            haptics: .hapticsChanged(enabled: false)
        ))
    }

    @Test func missingKeysAreAbsent() {
        #expect(WatchCatchUp(applicationContext: [:]) == WatchCatchUp())
    }

    @Test func junkWrongKindsAndOtherVersionsAreAbsent() throws {
        let context: [String: Any] = [
            WatchSyncKeys.setup: "not data",
            // A started message is not a countdown.
            WatchSyncKeys.countdown: try WatchSyncCoder.encode(PhoneToWatchMessage.started(sessionID: sessionA, t0: goAt)),
            WatchSyncKeys.sessionState: try WatchSyncCoder.encode(PhoneToWatchMessage.stopped(sessionID: sessionA), version: 2),
            WatchSyncKeys.haptics: Data("junk".utf8),
        ]
        #expect(WatchCatchUp(applicationContext: context) == WatchCatchUp())
    }
}

/// Catching up after launch or a reconnect (Task 12.3.3).
@Suite struct WatchCatchUpMachineTests {
    @Test func aStoredCountdownIsJoinedAtTheNumeralShowingNow() {
        var machine = WatchSessionMachine()
        let effects = machine.run([.catchUp(stored(), at: at(-2.5))])
        guard case .countingDown = machine.phase else {
            Issue.record("not counting: \(machine.phase)")
            return
        }
        #expect(announcements(in: effects) == ["3"])
        #expect(machine.selection == WatchSelection(mode: .quick, durationSeconds: 120))
    }

    /// The case from the brief: the watch owns haptics, drops at "4" and
    /// reopens at "2". No replayed 4 or 3; 2, 1 and Go play as usual.
    @Test func aWatchReopenedAtTwoPlaysTwoOneAndGoButNotFourOrThree() {
        var machine = WatchSessionMachine()
        var effects = machine.run([
            .catchUp(stored(owner: .watch), at: at(-1.5)),
            .reachability(true, at: at(-1.5)),
        ])
        effects += machine.run(stride(from: -1.4, to: 0, by: 0.1).map { .tick(at($0)) })
        effects += machine.run([.received(.started(sessionID: sessionA, t0: at(0.01)), at: at(0.05))])

        #expect(announcements(in: effects) == ["2", "1", "Go"])
        #expect(haptics(in: effects) == [.click, .click, .start])
    }

    @Test func aStoredRunningSessionIsRunningReSyncedToT0WithNoGo() {
        var machine = WatchSessionMachine()
        let t0 = at(0.03)
        let effects = machine.run([
            .catchUp(stored(.started(sessionID: sessionA, t0: t0)), at: at(40)),
            .reachability(true, at: at(40)),
        ])
        #expect(effects.isEmpty, "Go already happened")
        guard case .running(let session) = machine.phase else {
            Issue.record("not running: \(machine.phase)")
            return
        }
        #expect(session.t0 == t0)
        #expect(session.t0IsEstimated == false)
    }

    @Test func aStoredRunningSessionWithThePhoneAwayIsDisconnected() {
        var machine = WatchSessionMachine()
        machine.run([
            .catchUp(stored(.started(sessionID: sessionA, t0: goAt)), at: at(40)),
            .reachability(false, at: at(40)),
        ])
        guard case .disconnected = machine.phase else {
            Issue.record("not disconnected: \(machine.phase)")
            return
        }
    }

    @Test func aReconnectReSyncsTheRunningClock() {
        // Running on the fallback's estimated T-0, then the phone comes back.
        var machine = WatchSessionMachine.counting()
        machine.run([.reachability(false, at: at(-1)), .tick(at(2))])
        let realT0 = at(0.4)
        let effects = machine.run([
            .catchUp(stored(.started(sessionID: sessionA, t0: realT0)), at: at(30)),
            .reachability(true, at: at(30)),
        ])
        #expect(effects.isEmpty)
        #expect(machine.phase.session?.t0 == realT0)
        guard case .running = machine.phase else {
            Issue.record("not running: \(machine.phase)")
            return
        }
    }

    @Test func aStoredStopShowsStoppedWithoutABuzz() {
        var machine = WatchSessionMachine.running(owner: .watch)
        machine.run([.reachability(false, at: at(30))])
        let effects = machine.run([.catchUp(stored(.stopped(sessionID: sessionA)), at: at(60))])
        #expect(machine.phase == .stopped(sessionID: sessionA))
        #expect(effects.isEmpty)
    }

    @Test func aStoredCancelReturnsToWaitingWithoutABuzz() {
        var machine = WatchSessionMachine.counting(owner: .watch)
        let effects = machine.run([.catchUp(stored(.cancelled(sessionID: sessionA)), at: at(-1))])
        #expect(machine.phase == .waiting)
        #expect(effects.isEmpty)
    }

    @Test func catchUpAppliesAStoredHapticsChange() {
        var machine = WatchSessionMachine()
        machine.run([.catchUp(stored(.started(sessionID: sessionA, t0: goAt), haptics: false), at: at(30))])
        #expect(machine.phase.session?.hapticsEnabled == false)
    }

    /// A walk this watch saw end — here at 00:00 on its own — is never brought
    /// back by an older stored state.
    @Test func catchUpNeverMovesASessionBackwards() {
        var machine = WatchSessionMachine.running(owner: .watch)
        machine.run([.reachability(false, at: at(30)), .tick(at(120))])
        #expect(machine.phase == .stopped(sessionID: sessionA))

        machine.run([.catchUp(stored(.started(sessionID: sessionA, t0: goAt)), at: at(125))])
        #expect(machine.phase == .stopped(sessionID: sessionA))

        machine.run([.doneTapped, .catchUp(stored(.stopped(sessionID: sessionA)), at: at(130))])
        #expect(machine.phase == .waiting, "Done is not undone by the stored Stop")
    }

    @Test func aStoredCountdownDoesNotRestartOneAlreadyRunning() {
        var machine = WatchSessionMachine.running()
        let before = machine.phase
        machine.run([.catchUp(stored(), at: at(10))])
        #expect(machine.phase == before)
    }

    /// Stored state counts as current until 5 minutes after the planned end.
    @Test func aStaleSessionLeavesTheWatchWaiting() {
        // Quick Test: planned end at goAt + 120 s; current until + 300 s.
        var current = WatchSessionMachine()
        current.run([.catchUp(stored(.stopped(sessionID: sessionA)), at: at(420))])
        #expect(current.phase == .stopped(sessionID: sessionA))

        var stale = WatchSessionMachine()
        stale.run([.catchUp(stored(.stopped(sessionID: sessionA)), at: at(420.1))])
        #expect(stale.phase == .waiting)
        #expect(stale.selection == WatchSelection(mode: .quick, durationSeconds: 120), "the setup still applies")
    }

    @Test func aStoredRunningWalkPastItsLengthIsShownEndedWithoutABuzz() {
        var machine = WatchSessionMachine()
        let effects = machine.run([.catchUp(stored(.started(sessionID: sessionA, t0: goAt)), at: at(200))])
        #expect(machine.phase == .stopped(sessionID: sessionA))
        #expect(effects.isEmpty)
    }

    /// The stored copy of `started` can beat the live one. Go is still now.
    @Test func aStoredStartedThatBeatTheLiveOneStillPlaysGo() {
        var machine = WatchSessionMachine.counting(owner: .watch)
        let effects = machine.run([.catchUp(stored(.started(sessionID: sessionA, t0: at(0.01))), at: at(0.2))])
        #expect(haptics(in: effects) == [.start])
        #expect(announcements(in: effects) == ["Go"])
        // The live one, landing after, adds nothing.
        #expect(machine.run([.received(.started(sessionID: sessionA, t0: at(0.01)), at: at(0.3))]).isEmpty)
    }
}

/// 00:00 while the phone is out of reach (Task 12.3.3).
@Suite struct WatchLocalTimeUpTests {
    @Test func atTheEndWhileDisconnectedTheWatchStopsAndBuzzesIfItOwns() {
        var machine = WatchSessionMachine.running(owner: .watch)
        machine.run([.reachability(false, at: at(30))])
        #expect(machine.run([.tick(at(119.9))]).isEmpty)

        let effects = machine.run([.tick(at(120))])
        #expect(machine.phase == .stopped(sessionID: sessionA))
        #expect(haptics(in: effects) == [.stop])
    }

    @Test func noBuzzWhenThePhoneOwnsOrHapticsAreOff() {
        for (owner, enabled) in [(WireHapticOwner.phone, true), (.watch, false)] {
            var machine = WatchSessionMachine.running(owner: owner, hapticsEnabled: enabled)
            machine.run([.reachability(false, at: at(30))])
            let effects = machine.run([.tick(at(120))])
            #expect(machine.phase == .stopped(sessionID: sessionA))
            #expect(haptics(in: effects).isEmpty)
        }
    }

    @Test func thePhonesLateStoppedAddsNoSecondBuzz() {
        var machine = WatchSessionMachine.running(owner: .watch)
        machine.run([.reachability(false, at: at(30)), .tick(at(120))])
        let effects = machine.run([
            .reachability(true, at: at(125)),
            .received(.stopped(sessionID: sessionA), at: at(125.1)),
        ])
        #expect(haptics(in: effects).isEmpty)
        #expect(machine.phase == .stopped(sessionID: sessionA))
    }

    /// With the phone reachable, the watch waits for it: the phone is
    /// authoritative.
    @Test func whileReachableTheWatchWaitsForThePhone() {
        var machine = WatchSessionMachine.running(owner: .watch)
        #expect(machine.run([.tick(at(121))]).isEmpty)
        guard case .running = machine.phase else {
            Issue.record("the watch ended the walk on its own: \(machine.phase)")
            return
        }
    }
}
