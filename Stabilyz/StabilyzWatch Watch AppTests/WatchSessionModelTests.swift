import Foundation
import Testing
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

/// The model only carries out what the machine decides (Task 12.2.1).
@MainActor @Suite struct WatchSessionModelTests {
    @Test func linkEventsDriveTheScreensAndEffectsAreCarriedOut() async {
        let link = FakeLink()
        var now = at(-5)
        var announced: [String] = []
        let model = WatchSessionModel(link: link, clock: { now }, announce: { announced.append($0) })
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
        #expect(model.screen == .waiting(selection: "Quick Test · 2 min", selectionLabel: "Quick Test, 2 minutes"))
    }
}
