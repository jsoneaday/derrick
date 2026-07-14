import XCTest

final class uiUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreatesPersistentDatabaseOnLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GEMINI_API_KEY"] = "ui-test-placeholder"
        app.launch()

        XCTAssertTrue(app.staticTexts["dave returns!"].waitForExistence(timeout: 10))

        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/derrick.ui/Data/Library/Application Support/ui/derrick.sqlite3")

        waitForFile(at: databaseURL, timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        XCTFail("Expected database file at \(url.path)")
    }
}
