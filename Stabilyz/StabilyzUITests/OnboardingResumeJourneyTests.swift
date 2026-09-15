import XCTest

/// A relaunch mid-onboarding resumes where the user left off (docs/19 §19.3)
/// [PRD §6 edge case, §7 AC: onboarding progress persists across a relaunch].
///
/// The launch carries a draft left on the third question with the first two
/// answered: above the knee, right side.
final class OnboardingResumeJourneyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testARelaunchResumesAtTheSavedQuestionWithEarlierAnswersIntact() {
        let app = launchStabilyz(.onboardingDraft)

        // Straight to the question the user was on — not Welcome, not the start.
        app.staticTexts["How long has it been since your amputation?"]
            .waitToAppear(timeout: 15, "the wizard resumed at the saved question")
        XCTAssertFalse(app.buttons["welcome.getStarted"].exists, "a draft relaunch passed through Welcome")
        XCTAssertFalse(app.buttons["onboarding.next"].isEnabled, "the unanswered question is not blank")

        // Earlier answers survived the relaunch.
        app.buttons["onboarding.back"].tap()
        app.staticTexts["Which side?"].waitToAppear()
        XCTAssertTrue(app.buttons["Right"].isSelected, "the saved side was lost")
        XCTAssertFalse(app.buttons["Left"].isSelected)

        app.buttons["onboarding.back"].tap()
        app.staticTexts["What is your amputation level?"].waitToAppear()
        XCTAssertTrue(app.buttons["Above the knee"].isSelected, "the saved amputation level was lost")

        // And the wizard carries on from them.
        app.buttons["onboarding.next"].tap()
        app.staticTexts["Which side?"].waitToAppear()
        XCTAssertTrue(app.buttons["onboarding.next"].isEnabled, "a resumed answer does not count as answered")
    }
}
