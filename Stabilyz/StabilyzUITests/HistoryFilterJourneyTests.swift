import XCTest

/// History's mode filter (docs/19 §19.3, Task 9.1.1): each segment lists only
/// its own mode's valid walks [PRD OQ-5, §5, §7].
///
/// The store holds three valid Quick Tests, one valid Full Test, and one invalid
/// Quick Test that no segment may list. The modes are the app's two tests —
/// there is no "Daily Walk" mode to filter by.
final class HistoryFilterJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEachModeSegmentListsOnlyThatModesValidWalks() {
        let app = launchStabilyz(.history)

        app.tab("Result").waitToAppear(timeout: 15).tap()
        app.navigationBars["Result"].waitToAppear()

        let segments = app.segmentedControls.buttons
        let quick = segments.element(boundBy: 0).waitToAppear()
        let full = segments.element(boundBy: 1)
        XCTAssertEqual(quick.label, "Quick Test")
        XCTAssertEqual(full.label, "Full Test")

        let rows = app.buttons.matching(identifier: "history.row")

        // Opens on the newest walk's mode: Quick Test. The invalid walk is not
        // among its three.
        XCTAssertTrue(quick.isSelected, "History did not open on the newest walk's mode")
        rows.waitForCount(3, "Quick Test lists its three valid walks and no invalid one")

        full.tap()
        rows.waitForCount(1, "Full Test lists only its own walk")
        XCTAssertTrue(full.isSelected)

        quick.tap()
        rows.waitForCount(3, "switching back restores the Quick Test list")
    }
}
