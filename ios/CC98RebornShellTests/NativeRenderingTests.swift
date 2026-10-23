import XCTest
@testable import CC98RebornShell

final class NativeRenderingTests: XCTestCase {
    func testNotificationTargetsMatchMessageCategories() {
        XCTAssertEqual(NativeMessageSection.fromNotification(category: "reply"), .reply)
        XCTAssertEqual(NativeMessageSection.fromNotification(category: "at"), .at)
        XCTAssertEqual(NativeMessageSection.fromNotification(category: "system"), .system)
        XCTAssertEqual(NativeMessageSection.fromNotification(category: "message"), .privateMessages)
        XCTAssertNil(NativeMessageSection.fromNotification(category: "unknown"))
    }
    func testHiddenImagesDoNotEnterThumbnailsOrPublicGallery() {
        let source = "[img=1]https://example.invalid/private.jpg[/img]\n[img]https://example.invalid/visible.jpg[/img]"
        XCTAssertEqual(UBBFirstImage.first(in: source)?.lastPathComponent, "visible.jpg")
        XCTAssertEqual(UBBBlockParser.parse(source, markdown: false).flatMap(\.images).map(\.lastPathComponent), ["visible.jpg"])
        XCTAssertNil(UBBFirstImage.first(in: "[img=1]https://example.invalid/private.jpg[/img]"))
    }

    func testLegacyThumbnailSyntaxRemainsAvailable() {
        for source in [
            "[img]https://example.invalid/image.jpg[/img]",
            "before ![alt](https://example.invalid/image.jpg) after",
            "<img src=\"https://example.invalid/image.jpg\">"
        ] {
            XCTAssertEqual(UBBFirstImage.first(in: source)?.lastPathComponent, "image.jpg", source)
        }
    }
}
