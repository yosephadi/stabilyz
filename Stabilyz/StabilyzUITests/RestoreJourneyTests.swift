import XCTest

/// Restore from Welcome (Task 10.3.2) [PRD §5]: the restore screen opens on a
/// picked file, runs its preflight, and backs out to Welcome untouched.
final class RestoreJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRestoreFromWelcomeOpensRestoreYourDataAndBackReturnsToWelcome() {
        let app = launchStabilyz(.fresh)

        app.buttons["welcome.restore"].waitToAppear(timeout: 15).tap()

        let title = app.staticTexts["restore.title"].waitToAppear(timeout: 10, "Restore opens Restore your data")
        XCTAssertEqual(title.label, "Restore your data")
        app.element(labelContaining: "ui-test-backup").waitToAppear(timeout: 5, "the picked file is named")
        // The UI-testing file is not an export, so the preflight says so at once.
        app.element(labelContaining: "This isn't a Stabilyz backup").waitToAppear(timeout: 10, "the preflight ran")

        app.buttons["restore.back"].tap()

        app.buttons["welcome.getStarted"].waitToAppear(timeout: 10, "back returns to Welcome")
        XCTAssertFalse(app.staticTexts["restore.title"].exists)
    }
}
