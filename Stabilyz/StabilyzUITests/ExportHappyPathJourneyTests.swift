import XCTest

/// Export My Data, end to end (docs/19 §19.3, Tasks 10.2.1–10.2.2): passphrase
/// and confirmation, the unrecoverable-passphrase warning, generation, and the
/// system share sheet [PRD §5, §7 AC].
final class ExportHappyPathJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExportingSetsAPassphraseAcknowledgesTheWarningAndOpensTheShareSheet() {
        let app = launchStabilyz(.onboarded)

        app.tabBars.buttons["You"].waitToAppear(timeout: 15).tap()
        app.buttons["settings.export"].waitToAppear().tap()

        // Step 1: the passphrase, twice. Return on the first moves to the
        // second; Return on the second continues, as the button would.
        let passphrase = app.secureTextFields["export.passphrase"].waitToAppear(timeout: 10, "Export My Data opens its wizard")
        passphrase.tap()
        passphrase.typeText(uiTestingBackupPassphrase + "\n")
        app.secureTextFields["export.confirmation"].typeText(uiTestingBackupPassphrase + "\n")

        // Step 2: the warning comes before anything is generated [PRD §7 AC].
        app.staticTexts["Before You Continue"].waitToAppear(timeout: 10, "the matching passphrase leads to the warning")
        let create = app.buttons["export.create"]
        XCTAssertFalse(create.isEnabled, "a backup can be created without acknowledging the warning")
        app.descendants(matching: .any)["export.acknowledge"].tap()
        XCTAssertTrue(create.isEnabled, "acknowledging the warning did not enable Create Backup")
        create.tap()

        // Generated, and handed to the system share sheet.
        app.staticTexts["Choose Where to Save It"].waitToAppear(timeout: 30, "the backup was generated")
        let shareSheet = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'ActivityListView' OR identifier == 'UIActivityContentView' OR label == 'Save to Files' OR label == 'Copy'"
        )).firstMatch
        shareSheet.waitToAppear(timeout: 15, "the system share sheet opened on the backup")
    }
}
