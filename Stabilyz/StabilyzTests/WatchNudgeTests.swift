import Foundation
import Testing
@testable import Stabilyz

/// Waits, briefly, for `condition`. Fails the test if it never holds.
@MainActor
private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("condition never held", sourceLocation: sourceLocation)
}

/// When the nudge shows (Task 12.5.1, PRD §8).
@Suite struct WatchNudgeRuleTests {
    private func onSetup(_ reachability: WatchReachability) -> WatchNudgeRule {
        var rule = WatchNudgeRule()
        rule.isOnSetup = true
        rule.reachability = reachability
        return rule
    }

    @Test func itShowsOnlyWhileTheWatchAppIsInstalledButUnreachable() {
        var rule = onSetup(.installedNotReachable)
        #expect(rule.decide() == .show)
        #expect(rule.decide() == nil, "once")
        for reachability in [WatchReachability.reachable, .unavailable] {
            var other = onSetup(reachability)
            #expect(other.decide() == nil)
        }
    }

    @Test func itNeverStartsDuringAWalk() {
        var rule = onSetup(.installedNotReachable)
        rule.isSessionActive = true
        #expect(rule.decide() == nil)
    }

    @Test func aSpentNudgeWaitsForTheNextReturn() {
        var rule = onSetup(.installedNotReachable)
        rule.decide()
        rule.isSpent = true
        #expect(rule.decide() == .end)
        #expect(rule.decide() == nil)
    }
}

@MainActor @Suite struct WatchNudgeControllerTests {
    private func make(_ reachability: WatchReachability, isOnSetup: Bool = true)
        -> (WatchNudgeController, MockWatchNudgeService, MockWatchSessionService)
    {
        let watch = MockWatchSessionService(reachability: reachability)
        let nudge = MockWatchNudgeService()
        let controller = WatchNudgeController(nudge: nudge, watchSession: watch)
        controller.start(isOnSetup: isOnSetup)
        return (controller, nudge, watch)
    }

    @Test func onSetupWithTheWatchAppClosedTheNudgeShows() async {
        let (controller, nudge, _) = make(.installedNotReachable)
        await eventually { controller.rule.isShowing }
        await controller.settled()
        // Leftovers from an earlier launch are ended first.
        #expect(nudge.calls == [.end, .show])
    }

    @Test func noNudgeWhenTheWatchIsReachableOrHasNoApp() async {
        for reachability in [WatchReachability.reachable, .unavailable] {
            let (controller, nudge, _) = make(reachability)
            await eventually { controller.rule.reachability == reachability }
            await controller.settled()
            #expect(nudge.calls == [.end])
        }
    }

    @Test func itEndsWhenTheWatchBecomesReachable() async {
        let (controller, nudge, watch) = make(.installedNotReachable)
        await eventually { controller.rule.isShowing }
        watch.setReachability(.reachable)
        await eventually { !controller.rule.isShowing }
        await controller.settled()
        #expect(nudge.calls == [.end, .show, .end])
    }

    @Test func leavingSetupEndsItAndComingBackShowsItAgain() async {
        let (controller, nudge, _) = make(.installedNotReachable)
        await eventually { controller.rule.isShowing }
        controller.setupLeft()
        controller.setupEntered()
        await controller.settled()
        #expect(nudge.calls == [.end, .show, .end, .show])
    }

    @Test func itLastsThroughTheWalkAndEndsWithIt() async {
        let (controller, nudge, _) = make(.installedNotReachable)
        await eventually { controller.rule.isShowing }
        controller.sessionBegan()
        await controller.settled()
        #expect(nudge.calls == [.end, .show], "Start leaves it alone")

        controller.sessionEnded()
        controller.sessionEnded()
        await controller.settled()
        #expect(nudge.calls == [.end, .show, .end])

        // Back on setup after the walk: it waits for the next return.
        controller.setupLeft()
        controller.setupEntered()
        await controller.settled()
        #expect(nudge.calls == [.end, .show, .end, .show])
    }

    @Test func aCancelledCountdownEndsIt() async {
        let (controller, nudge, _) = make(.installedNotReachable)
        await eventually { controller.rule.isShowing }
        controller.sessionBegan()
        controller.sessionEnded()
        await controller.settled()
        #expect(nudge.calls == [.end, .show, .end])
    }

    @Test func itNeverStartsMidWalk() async {
        let (controller, nudge, watch) = make(.reachable)
        await eventually { controller.rule.reachability == .reachable }
        controller.sessionBegan()
        watch.setReachability(.installedNotReachable)
        await eventually { controller.rule.reachability == .installedNotReachable }
        await controller.settled()
        #expect(nudge.calls == [.end])
    }

    @Test func offTheWalkTabNothingShows() async {
        let (controller, nudge, _) = make(.installedNotReachable, isOnSetup: false)
        await eventually { controller.rule.reachability == .installedNotReachable }
        await controller.settled()
        #expect(nudge.calls == [.end])
    }

    @Test func theCopyIsTheApprovedWording() {
        #expect(WatchNudgeCopy.title == "Open Stabilyz on your watch")
        #expect(WatchNudgeCopy.detail == "See your timer and feel the countdown on your wrist.")
        #expect(WatchNudgeCopy.dynamicIsland == "Open on watch")
        #expect(WatchNudgeCopy.smartStack == "Open Stabilyz")
    }
}
