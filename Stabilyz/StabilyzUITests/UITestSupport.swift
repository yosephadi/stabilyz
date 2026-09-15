import XCTest

/// Launches and waits shared by the journey suites (Task 11.1.1).
///
/// Every launch passes `-ui-testing`, which gives the app an empty in-memory
/// store, replayed sensors and silent audio, so each journey starts from the
/// same state on any simulator (docs/19 §19.3).
/// The passphrase `-ui-testing-real-backup` seals its export with.
let uiTestingBackupPassphrase = "correct horse battery"

enum UITestLaunch {
    /// Welcome: no profile, no draft.
    case fresh
    /// A profile past the disclaimer, so the app opens on the Walk tab.
    case onboarded
    /// Onboarded, with Motion & Fitness denied.
    case motionDenied
    /// Onboarded, with a replayed walk too short to measure.
    case unclearWalk
    /// Onboarded, with three valid Quick Tests, one valid Full Test and one
    /// invalid Quick Test in the store.
    case history
    /// No profile, and a wizard left on its third question (above the knee,
    /// right side answered).
    case onboardingDraft
    /// `history`, with a real encrypted export as the restore file.
    case restoreConflict

    var arguments: [String] {
        switch self {
        case .fresh: ["-ui-testing"]
        case .onboarded: ["-ui-testing", "-ui-testing-onboarded"]
        case .motionDenied: ["-ui-testing", "-ui-testing-onboarded", "-ui-testing-motion-denied"]
        case .unclearWalk: ["-ui-testing", "-ui-testing-onboarded", "-ui-testing-unclear-walk"]
        case .history: ["-ui-testing", "-ui-testing-history"]
        case .onboardingDraft: ["-ui-testing", "-ui-testing-onboarding-draft"]
        case .restoreConflict: ["-ui-testing", "-ui-testing-history", "-ui-testing-real-backup"]
        }
    }
}

@MainActor
func launchStabilyz(_ state: UITestLaunch) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = state.arguments
    app.launch()
    return app
}

@MainActor
extension XCUIElement {
    /// Waits for the element and fails the test, naming it, if it never comes.
    @discardableResult
    func waitToAppear(
        timeout: TimeInterval = 10,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            waitForExistence(timeout: timeout),
            "\(self) did not appear within \(timeout)s. \(message)",
            file: file,
            line: line
        )
        return self
    }

    /// Waits for the element to be gone.
    func waitToDisappear(
        timeout: TimeInterval = 10,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        XCTAssertEqual(
            XCTWaiter.wait(for: [gone], timeout: timeout),
            .completed,
            "\(self) was still there after \(timeout)s. \(message)",
            file: file,
            line: line
        )
    }
}

@MainActor
extension XCUIElementQuery {
    /// Waits until the query matches exactly `count` elements.
    func waitForCount(
        _ count: Int,
        timeout: TimeInterval = 10,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: self)
        XCTAssertEqual(
            XCTWaiter.wait(for: [matched], timeout: timeout),
            .completed,
            "expected \(count) matches, found \(self.count). \(message)",
            file: file,
            line: line
        )
    }
}

@MainActor
extension XCUIApplication {
    /// Any element whose label contains `text`, case-insensitively. For copy
    /// inside combined or long text elements.
    func element(labelContaining text: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// A static text matching `text` whatever case it is rendered in —
    /// grouped-list section headers are drawn uppercase.
    func text(equalToIgnoringCase text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label ==[c] %@", text)).firstMatch
    }
}
