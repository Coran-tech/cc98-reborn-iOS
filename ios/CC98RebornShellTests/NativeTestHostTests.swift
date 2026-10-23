import XCTest
@testable import CC98RebornShell

final class NativeTestHostTests: XCTestCase {
    func testAppHostedUnitTestsUseExplicitOfflineFixture() {
        XCTAssertTrue(
            NativeUITestFixture.isEnabled,
            "The Debug Test action must pass --native-ui-fixture to the app host; unit tests must not launch real forum requests."
        )
    }
}
