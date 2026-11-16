import Foundation
import Testing
@testable import StabilyzWatch_Watch_App

/// What each watch screen shows [PRD §8 Watch screens] (Task 12.2.1).
@Suite struct WatchScreenContentTests {
    @Test func theCopyIsExactlyThePRDs() {
        #expect(WatchCopy.waitingTitle == "Start on your iPhone")
        #expect(WatchCopy.countdownHeading == "Get ready")
        #expect(WatchCopy.go == "Go")
        #expect(WatchCopy.countdownFooter == "Phone in pocket")
        #expect(WatchCopy.stop == "Stop")
        #expect(WatchCopy.stoppedTitle == "Walk finished")
        #expect(WatchCopy.stoppedDetail == "See your result on iPhone")
        #expect(WatchCopy.done == "Done")
        #expect(WatchCopy.disconnectedTitle == "Phone not reachable")
        #expect(WatchCopy.disconnectedDetail == "Keep walking. Your walk is still recording.")
    }

    @Test func waitingShowsTheSelectedModeAndLength() {
        var machine = WatchSessionMachine()
        #expect(WatchScreen(machine, at: at(0)) == .waiting(selection: nil, selectionLabel: nil))

        machine.run([.received(.setupSelection(mode: .quick, durationSeconds: 90), at: at(0))])
        #expect(WatchScreen(machine, at: at(0)) == .waiting(selection: "Quick Test · 1:30", selectionLabel: "Quick Test, 1 minute 30 seconds"))

        machine.run([.received(.setupSelection(mode: .full, durationSeconds: 180), at: at(0))])
        #expect(WatchScreen(machine, at: at(0)) == .waiting(selection: "Full Test · 3:00", selectionLabel: "Full Test, 3 minutes"))
    }

    @Test func theCountdownShowsTheNumeralThenGo() {
        var machine = WatchSessionMachine.counting()
        #expect(WatchScreen(machine, at: at(-5)) == .countdown(numeral: "5"))
        #expect(WatchScreen(machine, at: at(-1)) == .countdown(numeral: "1"))

        machine.run([.received(.started(sessionID: sessionA, t0: goAt), at: at(0.1))])
        #expect(WatchScreen(machine, at: at(0.5)) == .countdown(numeral: "Go"))
        #expect(WatchScreen(machine, at: at(1)).showsStop)
    }

    @Test func runningShowsElapsedTimeProgressAndStop() {
        let machine = WatchSessionMachine.running()
        guard case .running(let timer, let stopEnabled) = WatchScreen(machine, at: at(65.4)) else {
            Issue.record("not the running screen")
            return
        }
        #expect(timer.text == "01:05")
        #expect(timer.accessibilityLabel == "1 minute 5 seconds elapsed")
        #expect(abs(timer.progress - 65.0 / 90.0) < 0.000_1)
        #expect(stopEnabled)
    }

    @Test func progressStopsAtTheAdvertisedLength() {
        let timer = WatchTimer(t0: goAt, durationSeconds: 90, now: at(500))
        #expect(timer.progress == 1)
        #expect(WatchTimer(t0: goAt, durationSeconds: 90, now: at(-3)).text == "00:00")
    }

    @Test func stopIsDisabledWhileARequestIsPending() {
        var machine = WatchSessionMachine.running()
        machine.run([.stopTapped(at: at(10))])
        #expect(WatchScreen(machine, at: at(10.5)) == .running(
            WatchTimer(t0: goAt, durationSeconds: 90, now: at(10.5)),
            stopEnabled: false
        ))
    }

    @Test func disconnectedKeepsTheTimerAndHidesStop() {
        var machine = WatchSessionMachine.running()
        machine.run([.reachability(false, at: at(30))])
        let screen = WatchScreen(machine, at: at(90))
        #expect(screen == .disconnected(WatchTimer(t0: goAt, durationSeconds: 90, now: at(90))))
        #expect(screen.showsStop == false)
    }

    @Test func stopIsShownOnlyOnRunning() {
        #expect(WatchScreen.waiting(selection: nil, selectionLabel: nil).showsStop == false)
        #expect(WatchScreen.countdown(numeral: "3").showsStop == false)
        #expect(WatchScreen.stopped.showsStop == false)
    }

    @Test func stoppedIsItsOwnScreen() {
        var machine = WatchSessionMachine.running()
        machine.run([.received(.stopped(sessionID: sessionA), at: at(60))])
        #expect(WatchScreen(machine, at: at(61)) == .stopped)
    }
}

/// Non-text contrast (WCAG 1.4.11: 3:1) and the label's text contrast (4.5:1),
/// computed from the `WatchTheme` values themselves.
@Suite struct WatchContrastTests {
    @Test func theProgressFillClearsThreeToOneOnItsTrack() {
        #expect(WatchTheme.progressFillRGB.contrast(with: WatchTheme.progressTrackRGB) >= 3)
    }

    @Test func theProgressFillClearsThreeToOneOnBlack() {
        #expect(WatchTheme.progressFillRGB.contrast(with: WatchTheme.backgroundRGB) >= 3)
    }

    @Test func theNavyCapsuleHasABoundaryThatClearsThreeToOneOnBlack() {
        // The navy alone is under 3:1 on black, which is why the outline exists.
        #expect(WatchTheme.primaryRGB.contrast(with: WatchTheme.backgroundRGB) < 3)
        #expect(WatchTheme.capsuleOutlineRGB.contrast(with: WatchTheme.backgroundRGB) >= 3)
        #expect(WatchTheme.capsuleOutlineWidth >= 1)
    }

    @Test func theWhiteLabelOnNavyKeepsFourPointFiveToOne() {
        #expect(WatchTheme.onPrimaryRGB.contrast(with: WatchTheme.primaryRGB) >= 4.5)
    }

    @Test func theContrastMathMatchesTheKnownExtremes() {
        let white = WatchRGB(hex: 0xFFFFFF), black = WatchRGB(hex: 0x000000)
        #expect(abs(white.contrast(with: black) - 21) < 0.001)
        #expect(abs(white.contrast(with: white) - 1) < 0.001)
    }
}
