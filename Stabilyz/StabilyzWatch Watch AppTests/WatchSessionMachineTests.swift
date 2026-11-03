import Foundation
import Testing
@testable import StabilyzWatch_Watch_App

/// The watch state machine (Task 12.2.1, docs/04 §4.18).
@Suite struct WatchSessionMachineTests {
    // MARK: Waiting

    @Test func itStartsWaitingWithNoSelection() {
        let machine = WatchSessionMachine()
        #expect(machine.phase == .waiting)
        #expect(machine.selection == nil)
    }

    @Test func theSetupSelectionIsRememberedForWaiting() {
        var machine = WatchSessionMachine()
        machine.run([.received(.setupSelection(mode: .full, durationSeconds: 360), at: at(-60))])
        #expect(machine.selection == WatchSelection(mode: .full, durationSeconds: 360))
        #expect(machine.phase == .waiting)
    }

    // MARK: Countdown

    @Test func countdownStartedBeginsCountingAndAnnouncesFive() {
        var machine = WatchSessionMachine()
        let effects = machine.run([.received(countdownStarted(), at: at(-5))])
        guard case .countingDown(let session) = machine.phase else {
            Issue.record("not counting: \(machine.phase)")
            return
        }
        #expect(session.id == sessionA)
        #expect(session.plannedGoAt == goAt)
        #expect(session.t0 == nil)
        #expect(effects == [.announce("5")])
        #expect(machine.selection == WatchSelection(mode: .quick, durationSeconds: 120))
    }

    @Test func numeralsCountDownToThePlannedGo() {
        #expect(WatchSessionMachine.numeral(plannedGoAt: goAt, at: at(-5)) == 5)
        #expect(WatchSessionMachine.numeral(plannedGoAt: goAt, at: at(-4.01)) == 5)
        #expect(WatchSessionMachine.numeral(plannedGoAt: goAt, at: at(-4)) == 4)
        #expect(WatchSessionMachine.numeral(plannedGoAt: goAt, at: at(-0.5)) == 1)
        // Held at 1 until `started` arrives; never 0 or negative.
        #expect(WatchSessionMachine.numeral(plannedGoAt: goAt, at: at(1)) == 1)
        // A late countdownStarted never shows more than 5.
        #expect(WatchSessionMachine.numeral(plannedGoAt: goAt, at: at(-9)) == 5)
    }

    /// One announcement per numeral, however often the clock ticks
    /// [PRD §8: "a VoiceOver announcement per numeral"].
    @Test func eachNumeralIsAnnouncedOnce() {
        var machine = WatchSessionMachine()
        var events: [WatchEvent] = [.received(countdownStarted(), at: at(-5))]
        events += stride(from: -4.9, to: 0, by: 0.1).map { .tick(at($0)) }
        let announcements = machine.run(events).compactMap { effect -> String? in
            if case .announce(let text) = effect { return text }
            return nil
        }
        #expect(announcements == ["5", "4", "3", "2", "1"])
    }

    @Test func startedMovesToRunningAndAnnouncesGo() {
        var machine = WatchSessionMachine.counting()
        let effects = machine.run([.received(.started(sessionID: sessionA, t0: at(0.02)), at: at(0.1))])
        #expect(machine.phase.session?.t0 == at(0.02))
        guard case .running = machine.phase else {
            Issue.record("not running: \(machine.phase)")
            return
        }
        #expect(effects.contains(.announce("Go")))
    }

    @Test func cancelReturnsToWaiting() {
        var machine = WatchSessionMachine.counting()
        machine.run([.received(.cancelled(sessionID: sessionA), at: at(-2))])
        #expect(machine.phase == .waiting)
        #expect(machine.selection == WatchSelection(mode: .quick, durationSeconds: 120))
    }

    @Test func theCountdownIsNotLeftWhenThePhoneDrops() {
        // Disconnected is entered from running only.
        var machine = WatchSessionMachine.counting()
        machine.run([.reachability(false, at: at(-3))])
        guard case .countingDown = machine.phase else {
            Issue.record("left the countdown: \(machine.phase)")
            return
        }
    }

    @Test func stopIsNotAcceptedDuringTheCountdown() {
        var machine = WatchSessionMachine.counting()
        #expect(machine.run([.stopTapped(at: at(-2))]).isEmpty)
        #expect(machine.isStopPending == false)
    }

    // MARK: Running and Disconnected

    @Test func losingThePhoneWhileRunningIsDisconnectedAndBackIsRunning() {
        var machine = WatchSessionMachine.running()
        machine.run([.reachability(false, at: at(30))])
        #expect(machine.phase == .disconnected(machine.phase.session!))
        #expect(machine.phase.session?.t0 == goAt, "the local timer keeps T-0")

        machine.run([.reachability(true, at: at(40))])
        guard case .running = machine.phase else {
            Issue.record("not running after reconnect: \(machine.phase)")
            return
        }
    }

    @Test func stopIsNotAcceptedWhileDisconnected() {
        var machine = WatchSessionMachine.running()
        machine.run([.reachability(false, at: at(30))])
        #expect(machine.run([.stopTapped(at: at(31))]).isEmpty)
    }

    @Test func stoppedEndsTheWalkAndDoneReturnsToWaiting() {
        var machine = WatchSessionMachine.running()
        machine.run([.received(.stopped(sessionID: sessionA), at: at(60))])
        #expect(machine.phase == .stopped(sessionID: sessionA))

        machine.run([.doneTapped])
        #expect(machine.phase == .waiting)
        #expect(machine.selection != nil, "Waiting still shows the mode")
    }

    @Test func stoppedAlsoEndsADisconnectedWalk() {
        var machine = WatchSessionMachine.running()
        machine.run([
            .reachability(false, at: at(30)),
            .received(.stopped(sessionID: sessionA), at: at(60)),
        ])
        #expect(machine.phase == .stopped(sessionID: sessionA))
    }

    @Test func doneOutsideStoppedDoesNothing() {
        var machine = WatchSessionMachine.running()
        let before = machine
        machine.run([.doneTapped])
        #expect(machine == before)
    }

    // MARK: Stop

    @Test func stopSendsOneRequestForTheRunningSession() {
        var machine = WatchSessionMachine.running()
        let effects = machine.run([
            .stopTapped(at: at(30)),
            .stopTapped(at: at(30.5)),
            .stopTapped(at: at(31)),
        ])
        #expect(effects == [.sendStopRequest(sessionA)])
        #expect(machine.isStopPending)
        guard case .running = machine.phase else {
            Issue.record("the watch ended the walk on its own: \(machine.phase)")
            return
        }
    }

    /// Until the phone answers (Task 12.3.2), an unanswered Stop must not leave
    /// the button disabled for good.
    @Test func anUnansweredStopIsReEnabledAfterThreeSeconds() {
        var machine = WatchSessionMachine.running()
        machine.run([.stopTapped(at: at(30))])

        machine.run([.tick(at(32.9))])
        #expect(machine.isStopPending)

        machine.run([.tick(at(33))])
        #expect(machine.isStopPending == false)
        #expect(machine.run([.stopTapped(at: at(33.1))]) == [.sendStopRequest(sessionA)])
    }

    @Test func aStopIsReEnabledWhenThePhoneComesBack() {
        var machine = WatchSessionMachine.running()
        machine.run([
            .stopTapped(at: at(30)),
            .reachability(false, at: at(30.2)),
            .reachability(true, at: at(31)),
        ])
        #expect(machine.isStopPending == false)
    }

    @Test func theStoppedAnswerClearsThePendingStop() {
        var machine = WatchSessionMachine.running()
        machine.run([.stopTapped(at: at(30)), .received(.stopped(sessionID: sessionA), at: at(30.3))])
        #expect(machine.isStopPending == false)
    }

    // MARK: Other sessions

    @Test func messagesForAnotherSessionAreIgnored() {
        var machine = WatchSessionMachine.running()
        let before = machine
        machine.run([
            .received(.started(sessionID: sessionB, t0: at(5)), at: at(5)),
            .received(.stopped(sessionID: sessionB), at: at(6)),
            .received(.cancelled(sessionID: sessionB), at: at(7)),
        ])
        #expect(machine == before)
    }

    @Test func aNewCountdownAlwaysWins() {
        var machine = WatchSessionMachine.running()
        machine.run([.received(countdownStarted(sessionB), at: at(100))])
        #expect(machine.phase.session?.id == sessionB)
    }

    @Test func aLateStoppedForTheEndedSessionIsIgnored() {
        var machine = WatchSessionMachine.running()
        machine.run([.received(.stopped(sessionID: sessionA), at: at(60)), .doneTapped])
        machine.run([.received(.stopped(sessionID: sessionA), at: at(61))])
        #expect(machine.phase == .waiting)
    }

    @Test func hapticsChangedUpdatesTheSession() {
        var machine = WatchSessionMachine.running()
        machine.run([.received(.hapticsChanged(enabled: false), at: at(20))])
        #expect(machine.phase.session?.hapticsEnabled == false)
    }
}
