//
//  uiUITests.swift
//  uiUITests
//
//  Created by David Choi on 6/23/26.
//

import XCTest

final class uiUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testCreatesPersistentDatabaseOnLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GEMINI_API_KEY"] = "ui-test-placeholder"
        app.launch()

        XCTAssertTrue(app.staticTexts["Gemini Stream"].waitForExistence(timeout: 10))

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
