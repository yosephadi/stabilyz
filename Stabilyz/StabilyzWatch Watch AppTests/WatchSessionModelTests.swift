import Foundation
import Testing
import WatchKit
@testable import StabilyzWatch_Watch_App

/// A link that records sends and lets a test deliver events.
private final class FakeLink: WatchPhoneLinking, @unchecked Sendable {
    var sent: [WatchToPhoneMessage] = []
    var onEvent: (@MainActor @Sendable (WatchLinkEvent) -> Void)?

    func activate(onEvent: @escaping @MainActor @Sendable (WatchLinkEvent) -> Void) {
        self.onEvent = onEvent
    }

    func send(_ message: WatchToPhoneMessage) { sent.append(message) }
}

private final class HapticSpy: WatchHapticPlaying {
    var played: [WatchHaptic] = []
    func play(_ haptic: WatchHaptic) { played.append(haptic) }
}

/// The model only carries out what the machine decides (Task 12.2.1).
@MainActor @Suite struct WatchSessionModelTests {
    @Test func linkEventsDriveTheScreensAndEffectsAreCarriedOut() async {
        let link = FakeLink()
        var now = at(-5)
        var announced: [String] = []
        let haptics = HapticSpy()
        let model = WatchSessionModel(link: link, haptics: haptics, clock: { now }, announce: { announced.append($0) })
        model.start()

        link.onEvent?(.reachability(true))
        link.onEvent?(.message(countdownStarted(owner: .phone)))
        #expect(model.screen == .countdown(numeral: "5"))
        #expect(announced == ["5"])

        now = at(0.1)
        link.onEvent?(.message(.started(sessionID: sessionA, t0: goAt)))
        now = at(10)
        model.tapStop()
        #expect(link.sent == [.stopRequest(sessionID: sessionA)])

        link.onEvent?(.message(.stopped(sessionID: sessionA)))
        #expect(model.screen == .stopped)
        model.tapDone()
        #expect(model.screen == .waiting(selection: "Quick Test · 1:30", selectionLabel: "Quick Test, 1 minute 30 seconds"))
        #expect(haptics.played.isEmpty, "the phone owned the haptics")
    }

    @Test func hapticEffectsReachTheTapticEngine() {
        let link = FakeLink()
        let haptics = HapticSpy()
        var now = at(-5)
        let model = WatchSessionModel(link: link, haptics: haptics, clock: { now }, announce: { _ in })
        model.start()

        link.onEvent?(.reachability(true))
        link.onEvent?(.message(countdownStarted(owner: .watch)))
        now = at(-4)
        model.tick()
        now = at(0.05)
        link.onEvent?(.message(.started(sessionID: sessionA, t0: goAt)))
        link.onEvent?(.message(.stopped(sessionID: sessionA)))

        #expect(haptics.played == [.click, .click, .start, .stop])
    }

    @Test func theDeviceHapticsAreThePRDCandidates() {
        #expect(DeviceWatchHaptics.type(for: .click) == .click)
        #expect(DeviceWatchHaptics.type(for: .start) == .start)
        #expect(DeviceWatchHaptics.type(for: .stop) == .stop)
    }
}
