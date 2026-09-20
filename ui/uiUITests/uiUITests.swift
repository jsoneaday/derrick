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

        let landing = app.staticTexts["What can Derrick help with?"]
        let initializing = app.staticTexts["Initializing Derrick"]
        XCTAssertTrue(
            initializing.waitForExistence(timeout: 10) || landing.waitForExistence(timeout: 10),
            "Launch should show initializing or the chat landing."
        )

        XCTAssertTrue(app.exists)
    }
}
