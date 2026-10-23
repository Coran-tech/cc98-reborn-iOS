import XCTest

// The shipping SwiftUI hierarchy, synthetic offline data, no OAuth or forum writes.
final class ShellSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // Cold simulator launch and complete draft round trips can exceed one minute.
        executionTimeAllowance = 120
    }
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--native-ui-fixture"] + arguments
        app.launch()
        XCTAssertTrue(element("home.hot.91001", in: app).waitForExistence(timeout: 15))
        return app
    }
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func tap(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(id, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 8), "Missing \(id)", file: file, line: line)
        XCTAssertTrue(target.isHittable, "Not hittable: \(id)", file: file, line: line)
        target.tap()
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testHomeAndReadingNavigation() throws {
        let app = launch()
        screenshot("01-home-light")
        tap("home.hot.91001", in: app)
        XCTAssertTrue(element("topic.title", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("topic.floor.1", in: app).waitForExistence(timeout: 8))
        screenshot("02-topic-light")
        XCTAssertGreaterThanOrEqual(element("topic.reply", in: app).frame.height, 44)
        tap("topic.nextPage", in: app)
        XCTAssertTrue(element("topic.floor.11", in: app).waitForExistence(timeout: 8))
        screenshot("03-topic-second-page")
        tap("topic.reply", in: app)
        XCTAssertTrue(element("reply.send", in: app).waitForExistence(timeout: 5))
        screenshot("04-reply-editor")
        tap("reply.close", in: app)
        XCTAssertTrue(element("topic.reply", in: app).waitForExistence(timeout: 5))
    }
    func testBoardsPinningAndComposer() throws {
        let app = launch()
        app.tabBars.buttons["版面"].tap()
        XCTAssertTrue(element("board.182", in: app).waitForExistence(timeout: 8))
        screenshot("05-boards")
        tap("board.more.182", in: app)
        app.buttons["置顶版面"].tap()
        XCTAssertTrue(element("board.pinned.182", in: app).waitForExistence(timeout: 5))
        tap("board.pinned.182", in: app)
        XCTAssertTrue(element("board.topic.91001", in: app).waitForExistence(timeout: 8))
        screenshot("06-board-topics")
        tap("board.compose", in: app)
        XCTAssertTrue(element("compose.title", in: app).waitForExistence(timeout: 5))
        screenshot("07-new-topic-editor")
        let title = element("compose.title", in: app)
        title.tap()
        title.typeText("Offline draft")
        screenshot("07b-new-topic-keyboard")
        // Move the lower draft controls above the keyboard before opening the menu.
        app.scrollViews["compose.scroll"].swipeUp()
        for _ in 0..<4 where !element("compose.draft", in: app).isHittable { app.swipeUp() }
        tap("compose.draft", in: app)
        let save = app.buttons["保存当前草稿"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.staticTexts["草稿已保存到本机"].waitForExistence(timeout: 5))
        screenshot("08-draft-saved")
        XCTAssertFalse(app.alerts["无法保存"].exists)
    }
    func testNewTopicsMessagesAndProfile() throws {
        let app = launch()
        app.tabBars.buttons["新帖"].tap()
        XCTAssertTrue(element("newTopics.topic.91001", in: app).waitForExistence(timeout: 8))
        screenshot("09-new-topics")
        tap("newTopics.layout", in: app)
        screenshot("10-new-topics-alternate-layout")
        app.tabBars.buttons["消息"].tap()
        XCTAssertTrue(app.navigationBars["消息"].waitForExistence(timeout: 5))
        screenshot("11-messages")
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))
        screenshot("12-profile")
    }
    func testDarkAccessibilityReading() throws {
        let app = launch(["--fixture-dark", "--fixture-large-type"])
        screenshot("13-home-dark-large-type")
        tap("home.hot.91001", in: app)
        XCTAssertTrue(element("topic.title", in: app).waitForExistence(timeout: 8))
        let reply = element("topic.reply", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertTrue(reply.isHittable)
        screenshot("14-topic-dark-large-type")
        tap("topic.reply", in: app)
        XCTAssertTrue(element("reply.send", in: app).waitForExistence(timeout: 5))
        screenshot("15-editor-dark-large-type")
        let body = element("reply.body", in: app)
        body.tap()
        body.typeText("Large text draft")
        screenshot("15b-editor-dark-large-type-input")
    }
    func testCompactWidth() throws {
        let app = launch(["--fixture-compact"])
        screenshot("16-home-320pt")
        app.tabBars.buttons["新帖"].tap()
        XCTAssertTrue(element("newTopics.topic.91001", in: app).waitForExistence(timeout: 8))
        screenshot("17-new-topics-320pt")
        tap("newTopics.layout", in: app)
        screenshot("18-new-topics-cards-320pt")
    }

    func testPrivateDraftRecoveryAndBackupEntry() throws {
        let app = launch()
        app.tabBars.buttons["消息"].tap()
        tap("messages.privateMessages", in: app)
        tap("message.contact.900002", in: app)
        let input = element("message.input", in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        screenshot("19-private-conversation")
        input.tap()
        input.typeText("Private offline draft")
        screenshot("19b-private-keyboard")
        tap("message.back", in: app)
        app.tabBars.buttons["我的"].tap()
        let drafts = element("profile.drafts", in: app)
        for _ in 0..<4 where !drafts.isHittable { app.swipeUp() }
        tap("profile.drafts", in: app)
        tap("draft-center.item.pm:900002", in: app)
        XCTAssertTrue(element("message.input", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("message.input", in: app).value as? String, "Private offline draft")
        screenshot("20-private-draft-restored")
        XCTAssertFalse(app.buttons["关闭"].exists)
        tap("message.back", in: app)
        XCTAssertTrue(element("draft-center.list", in: app).waitForExistence(timeout: 5))
        tap("draft-center.item.pm:900002", in: app)
        XCTAssertTrue(element("message.input", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("message.input", in: app).value as? String, "Private offline draft")
        tap("message.back", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let backup = element("profile.library", in: app)
        for _ in 0..<4 where !backup.isHittable { app.swipeUp() }
        tap("profile.library", in: app)
        XCTAssertTrue(element("library-transfer.import", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("library-transfer.export", in: app).exists)
        screenshot("21-local-backup")
    }
}
