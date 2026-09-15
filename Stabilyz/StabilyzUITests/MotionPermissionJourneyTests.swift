import XCTest

/// Motion & Fitness denied (docs/19 §19.3): the Walk tab says why a walk
/// cannot start, rather than letting Start fail silently [PRD §6, docs/07 §7.6].
final class MotionPermissionJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testADeniedPermissionShowsItsCardAndDisablesStart() {
        let app = launchStabilyz(.motionDenied)

        app.staticTexts["Motion access is off"].waitToAppear(timeout: 15, "the permission card appears on the Walk tab")
        app.element(labelContaining: "Motion & Fitness").waitToAppear(timeout: 5, "the card says what to turn on")
        XCTAssertTrue(app.buttons["Open Settings"].exists, "the card offers the way to fix it")

        let start = app.buttons["walk.start"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "Start can be tapped into a certain failure")
    }
}
