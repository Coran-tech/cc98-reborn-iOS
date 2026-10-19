import XCTest
import AuthenticationServices
@testable import CC98RebornShell

final class NativeOAuthTests: XCTestCase {
    @MainActor
    func testNoWebContextFailsClosedAndCompletesOnce() {
        let oauth = NativeOAuth(model: nil)
        var replies = 0
        oauth.login(expectedAccount: ["userId": "42"]) { result in
            replies += 1
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["code"] as? String, OAuthFailure.noWebAccount.code)
            XCTAssertNil(result["binding"])
        }
        oauth.cancel(.cancelled)
        XCTAssertEqual(replies, 1)
        XCTAssertFalse(oauth.isBusy)
        XCTAssertTrue(oauth.state()["binding"] is NSNull)
        XCTAssertEqual(oauth.logout()["ok"] as? Bool, false, "Unavailable storage must not claim a successful local unbind")
    }

    func testSystemCallbackSchemeIsRegisteredWithoutReplacingExistingBundleIdentity() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "org.cc98.reborn.shell")
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        XCTAssertTrue(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains(OAuthProtocol.callbackScheme) == true })
        XCTAssertEqual(OAuthProtocol.callback, "org.cc98.reborn.shell:/oauth/callback")
    }
}
