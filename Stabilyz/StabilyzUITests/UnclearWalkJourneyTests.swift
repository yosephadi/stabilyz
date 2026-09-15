import XCTest

/// A walk that cannot be measured (docs/19 §19.3): the flow ends on the unclear
/// state, never a score, and the walk counts toward nothing [PRD §5, §6, §7].
final class UnclearWalkJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAnUnmeasurableWalkEndsUnclearWithNoScoreAndIsNotListed() {
        let app = launchStabilyz(.unclearWalk)

        let start = app.buttons["walk.start"].waitToAppear(timeout: 15)
        start.tap()
        let stop = app.buttons["session.stop"].waitToAppear(timeout: 20, "the countdown reaches the walk")
        app.buttons["countdown.cancel"].waitToDisappear(timeout: 10)
        stop.tap()

        // The unclear gate: one way out, and no result to view.
        let back = app.buttons["session.backToWalk"].waitToAppear(timeout: 60, "processing reached the completion gate")
        XCTAssertTrue(app.staticTexts["Walk Data Unclear"].exists, "the gate does not say the walk was unclear")
        app.element(labelContaining: "won't count toward your baseline").waitToAppear(timeout: 5, "the gate says the walk does not count")
        XCTAssertFalse(app.buttons["session.viewResult"].exists, "an unclear walk offers a result")
        XCTAssertFalse(app.scrollViews["score.screen"].exists, "an unclear walk shows a score screen")

        back.tap()
        start.waitToAppear(timeout: 15, "Back to Walk Menu returns to the Walk tab")

        // Never listed in History, in either mode.
        app.tab("Result").tap()
        app.navigationBars["Result"].waitToAppear()
        let rows = app.buttons.matching(identifier: "history.row")
        rows.waitForCount(0, timeout: 5, "an unclear walk appears in History")
        app.segmentedControls.buttons.element(boundBy: 1).tap()
        rows.waitForCount(0, timeout: 5, "an unclear walk appears in History")
    }
}
