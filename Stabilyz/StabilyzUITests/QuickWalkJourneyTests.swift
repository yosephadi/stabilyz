import XCTest

/// A Quick Test end to end, on replayed sensors [PRD §5, OQ-6]: setup, the
/// countdown, the walk, Stop, the result, and back to Walk.
final class QuickWalkJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAQuickTestCountsInWalksStopsAndReturnsFromItsResult() {
        let app = launchStabilyz(.onboarded)

        let start = app.buttons["walk.start"].waitToAppear(timeout: 15)
        XCTAssertEqual(start.label, "Start Quick Test")
        start.tap()

        // The countdown, then the walk: Stop is hidden from accessibility while
        // the countdown covers it, so its arrival means Go has passed.
        app.buttons["countdown.cancel"].waitToAppear(timeout: 10, "Start opens the countdown")
        let stop = app.buttons["session.stop"].waitToAppear(timeout: 20, "the countdown reaches the walk")
        app.buttons["countdown.cancel"].waitToDisappear(timeout: 10)

        stop.tap()

        // Processing routes to the gate; a scoreable walk offers its result.
        let viewResult = app.buttons["session.viewResult"]
        viewResult.waitToAppear(
            timeout: 60,
            "Stop did not reach a scoreable result (a \"Walk Data Unclear\" gate would offer only Back to Walk Menu)"
        )
        viewResult.tap()

        // The result: measured content under the Done bar.
        let score = app.scrollViews["score.screen"].waitToAppear()
        XCTAssertGreaterThan(score.staticTexts.count, 3, "the result shows no measured content")
        app.element(labelContaining: "of 5").waitToAppear(timeout: 5, "the first walk shows calibration progress")

        app.buttons["score.done"].tap()
        start.waitToAppear(timeout: 15, "Done returns to the Walk tab")

        // The Result tab carries no Clinician Summary entry point: You does.
        app.tab("Result").tap()
        app.navigationBars["Result"].waitToAppear()
        XCTAssertFalse(app.buttons["Clinician Summary"].exists, "Result still offers the Clinician Summary")
    }
}
