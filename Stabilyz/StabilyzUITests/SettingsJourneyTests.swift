import XCTest

/// The You tab (Task 8.3.1): its sections, the Clinician Summary, and the
/// disclaimer that stays readable after onboarding [PRD §5, §7 AC].
final class SettingsJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func openYou() -> XCUIApplication {
        let app = launchStabilyz(.onboarded)
        app.tabBars.buttons["You"].waitToAppear(timeout: 15).tap()
        return app
    }

    @MainActor
    func testYouShowsBackupAndAboutSections() {
        let app = openYou()

        app.text(equalToIgnoringCase: "Backup & Data").waitToAppear()
        XCTAssertTrue(app.text(equalToIgnoringCase: "About & Legal").exists)
        XCTAssertTrue(app.buttons["settings.export"].exists)
        XCTAssertTrue(app.buttons["settings.restore"].exists)
    }

    @MainActor
    func testTheClinicianSummaryOpensFromYouAndClosesCleanly() {
        let app = openYou()

        app.buttons["settings.clinicianSummary"].waitToAppear().tap()
        let close = app.buttons["clinicianSummary.close"].waitToAppear(timeout: 10, "the summary sheet opens")

        close.tap()
        close.waitToDisappear()
        app.buttons["settings.clinicianSummary"].waitToAppear(timeout: 5, "closing returns to You")
    }

    @MainActor
    func testTheDisclaimerOpensAndGoesBack() {
        let app = openYou()

        app.buttons["settings.disclaimer"].waitToAppear().tap()
        let bar = app.navigationBars["Disclaimer"].waitToAppear()
        app.element(labelContaining: "not a medical device").waitToAppear(timeout: 5, "the disclaimer text is shown")

        bar.buttons.firstMatch.tap()
        bar.waitToDisappear()
        app.buttons["settings.disclaimer"].waitToAppear(timeout: 5, "back returns to You")
    }
}
