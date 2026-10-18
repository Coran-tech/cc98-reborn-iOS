import XCTest

final class ShellSmokeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testOfflineToolbarConfirmationAndOriginalRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-offline"]
        app.launch()
        XCTAssertTrue(app.staticTexts["modeLabel"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["modeLabel"].label, "原站模式")
        XCTAssertTrue(app.otherElements["networkError"].exists || app.staticTexts["networkError"].exists)
        XCTAssertTrue(app.buttons["modeToggleButton"].exists)
        screenshot("01-original-offline-shell")

        app.buttons["modeToggleButton"].tap()
        XCTAssertTrue(app.alerts["先确认未提交内容"].waitForExistence(timeout: 3))
        screenshot("02-draft-risk-confirmation")
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["modeLabel"].label, "原站模式")

        app.buttons["modeToggleButton"].tap()
        app.alerts.buttons["继续"].tap()
        XCTAssertTrue(app.staticTexts["enhancedNotice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["modeLabel"].label, "Reborn 验证")
        screenshot("03-enhanced-mode-boundary")
        app.buttons["restoreOriginalButton"].tap()
        app.alerts.buttons["继续"].tap()
        XCTAssertEqual(app.staticTexts["modeLabel"].label, "原站模式")
        XCTAssertFalse(app.staticTexts["enhancedNotice"].exists)
        screenshot("04-restored-original")

        app.buttons["retryButton"].tap()
        XCTAssertTrue(app.alerts["先确认未提交内容"].exists)
        app.alerts.buttons["取消"].tap()
        app.buttons["diagnosticsButton"].tap()
        XCTAssertTrue(app.navigationBars["状态与诊断"].waitForExistence(timeout: 3))
        screenshot("05-sanitized-diagnostics")
    }
}
