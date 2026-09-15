import XCTest

/// First launch to Home [PRD §5, §7 AC]: Welcome, the profile questions, the
/// disclaimer gate, and the Walk tab.
final class OnboardingJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAFreshLaunchLandsOnWelcome() {
        let app = launchStabilyz(.fresh)

        app.buttons["welcome.getStarted"].waitToAppear(timeout: 15, "a fresh install opens on Welcome")
        XCTAssertTrue(app.buttons["welcome.restore"].exists, "Welcome offers Restore from Export [PRD §5]")
        XCTAssertFalse(app.tab("Walk").exists, "nothing reaches Home before onboarding")
    }

    @MainActor
    func testGetStartedWalksThroughTheProfileAndTheDisclaimerToTheWalkTab() {
        let app = launchStabilyz(.fresh)
        app.buttons["welcome.getStarted"].waitToAppear(timeout: 15).tap()

        let next = app.buttons["onboarding.next"]

        // Required: amputation level, side, time since amputation.
        app.staticTexts["What is your amputation level?"].waitToAppear()
        app.buttons["Below the knee"].tap()
        next.tap()

        app.staticTexts["Which side?"].waitToAppear()
        app.buttons["Left"].tap()
        next.tap()

        app.staticTexts["How long has it been since your amputation?"].waitToAppear()
        app.buttons["Less than 6 months"].tap()
        next.tap()

        // Optional: skipped, and skipping never blocks [PRD §7 AC].
        app.staticTexts["What type of prosthesis do you use?"].waitToAppear()
        app.buttons["onboarding.skip"].tap()

        app.staticTexts["Do you know your K-level?"].waitToAppear()
        app.buttons["onboarding.skip"].tap()

        // The disclaimer is a hard gate [PRD §7 AC].
        app.staticTexts["Before You Begin"].waitToAppear()
        XCTAssertFalse(next.isEnabled, "the disclaimer can be passed without ticking the box")
        app.descendants(matching: .any)["onboarding.disclaimer.accept"].tap()
        XCTAssertTrue(next.isEnabled, "ticking the box did not open the gate")
        next.tap()

        app.buttons["walk.start"].waitToAppear(timeout: 15, "finishing onboarding lands on the Walk tab")
        XCTAssertTrue(app.tab("Walk").isSelected)
    }
}
