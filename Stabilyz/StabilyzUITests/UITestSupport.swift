import XCTest

/// Launches and waits shared by the journey suites (Task 11.1.1).
///
/// Every launch passes `-ui-testing`, which gives the app an empty in-memory
/// store, replayed sensors and silent audio, so each journey starts from the
/// same state on any simulator (docs/19 §19.3).
enum UITestLaunch {
    /// Welcome: no profile, no draft.
    case fresh
    /// A profile past the disclaimer, so the app opens on the Walk tab.
    case onboarded

    var arguments: [String] {
        switch self {
        case .fresh: ["-ui-testing"]
        case .onboarded: ["-ui-testing", "-ui-testing-onboarded"]
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
