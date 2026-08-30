import XCTest

final class uiUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchesWithDatabaseStartup() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GEMINI_API_KEY"] = "ui-test-placeholder"
        app.launch()

        XCTAssertTrue(app.staticTexts["What can Derrick help with?"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.exists)
    }
}
