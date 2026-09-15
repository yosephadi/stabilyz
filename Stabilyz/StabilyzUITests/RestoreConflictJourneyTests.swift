import XCTest

/// Restoring over existing data from Settings (docs/19 §19.3, Task 10.3.3):
/// never a silent overwrite, three choices, and Keep Current Data changes
/// nothing [PRD §5, §7 AC].
///
/// The store holds three valid Quick Tests; the restore file is a real export
/// of a different profile with no walks, so a replace would be visible in
/// History.
final class RestoreConflictJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRestoringOverExistingDataOffersThreeChoicesAndKeepingChangesNothing() {
        let app = launchStabilyz(.restoreConflict)
        let rows = app.buttons.matching(identifier: "history.row")

        // What is there before.
        app.tabBars.buttons["Result"].waitToAppear(timeout: 15).tap()
        rows.waitForCount(3, "the seeded Quick Test walks are listed")

        // You → Restore from Backup, on the real export.
        app.tabBars.buttons["You"].tap()
        app.buttons["settings.restore"].waitToAppear().tap()
        app.staticTexts["restore.title"].waitToAppear(timeout: 10, "Restore from Backup opens Restore your data")

        let passphrase = app.secureTextFields["restore.passphrase"].waitToAppear()
        passphrase.tap()
        // Return restores, as the button would.
        passphrase.typeText(uiTestingBackupPassphrase + "\n")

        // The backup opened, the store holds data: the choice, all three ways.
        let replace = app.buttons["Replace Data"].waitToAppear(timeout: 30, "the overwrite choice appears")
        XCTAssertTrue(app.buttons["Export Current Data First"].exists, "the choice offers no export first")
        let keep = app.buttons["Keep Current Data"]
        XCTAssertTrue(keep.exists, "the choice offers no way to keep the current data")

        keep.tap()
        replace.waitToDisappear()

        // Still on the restore screen, with the passphrase gone.
        XCTAssertTrue(app.staticTexts["restore.title"].exists, "keeping current data left the restore screen")
        XCTAssertFalse(app.buttons["restore.restoreBackup"].isEnabled, "the passphrase outlived Keep Current Data")

        // And nothing changed.
        app.buttons["restore.back"].tap()
        app.buttons["settings.restore"].waitToAppear()
        app.tabBars.buttons["Result"].tap()
        rows.waitForCount(3, "keeping current data changed History")
    }
}
