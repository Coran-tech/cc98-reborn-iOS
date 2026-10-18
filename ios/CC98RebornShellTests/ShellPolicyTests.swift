import XCTest
@testable import CC98RebornShell

final class ShellPolicyTests: XCTestCase {
    func testOnlyExactHTTPSForumHostsReceiveEnhancement() {
        for value in ["https://cc98.org/", "https://www.cc98.org/topic/1", "https://www.cc98.org:443/"] { XCTAssertTrue(ShellPolicy.isForum(URL(string: value)), value) }
        for value in ["http://www.cc98.org/", "https://openid.cc98.org/", "https://api.cc98.org/", "https://www.cc98.org.evil.test/", "https://evilcc98.org/", "https://user:pass@cc98.org/", "https://www.cc98.org:444/", "file:///cc98.org"] { XCTAssertFalse(ShellPolicy.isForum(URL(string: value)), value) }
    }
    func testActualSecurityOriginPolicy() {
        XCTAssertTrue(ShellPolicy.isAllowedOrigin(scheme: "https", host: "www.cc98.org", port: 443))
        XCTAssertFalse(ShellPolicy.isAllowedOrigin(scheme: "https", host: "openid.cc98.org", port: 443))
        XCTAssertFalse(ShellPolicy.isAllowedOrigin(scheme: "http", host: "www.cc98.org", port: 80))
    }
    func testAssetsDoNotAllowTraversalOrEncodedAliases() {
        XCTAssertEqual(ShellPolicy.assetPath(from: URL(string: "reborn-asset://bundle/images/CC98/CC9801.gif")!), "images/CC98/CC9801.gif")
        for path in ["../secret", "src/../secret", "/absolute", "src//file", "src\\file", "src/%2e%2e/file", "C:/secret", ""] { XCTAssertFalse(ShellPolicy.validAssetPath(path), path) }
        for raw in ["reborn-asset://other/src/a.js", "reborn-asset://bundle/%252e%252e/secret", "reborn-asset://bundle/a.js?token=x", "reborn-asset://user@bundle/a.js"] { XCTAssertNil(ShellPolicy.assetPath(from: URL(string: raw)!), raw) }
    }
    func testProtectedKeysAndAccountNamespaces() {
        XCTAssertTrue(StoragePolicy.canRead(ShellPolicy.bindingKey))
        XCTAssertFalse(StoragePolicy.canWrite(ShellPolicy.bindingKey))
        XCTAssertTrue(StoragePolicy.canWrite("cc98RebornReadLater:v1:uid:42"))
        XCTAssertTrue(StoragePolicy.canWrite("cc98RebornReadLater:v1:uid:guest"))
        XCTAssertFalse(StoragePolicy.canWrite("cc98RebornReadLater:v1:uid:42:other"))
        XCTAssertFalse(StoragePolicy.canWrite("access_token"))
    }
    func testSettingsRejectCredentialsAndPrototypeKeys() {
        XCTAssertTrue(StoragePolicy.containsSecret(["nested": ["apiKey": "private"]]))
        XCTAssertTrue(StoragePolicy.containsSecret(["accessToken": "private"]))
        XCTAssertTrue(StoragePolicy.containsSecret(["__proto__": [:]]))
        XCTAssertFalse(StoragePolicy.containsSecret(["aiSearchSuggestApiKey": "", "enabled": true]))
    }
    func testDiagnosticDetailsNeverCopyRawPageStrings() {
        let details = SafeDiagnostics.details(["url": "https://cc98.org/?token=private", "body": "private text", "token": "private", "status": 403])
        XCTAssertEqual(details, ["status": "403"])
        let message = SafeDiagnostics.networkMessage(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "private query"]))
        XCTAssertFalse(message.contains("private"))
    }
    func testDownloadFilenameIsOnlyALeaf() {
        XCTAssertEqual(ShellPolicy.safeFilename("../../photo.jpg"), "photo.jpg")
        XCTAssertEqual(ShellPolicy.safeFilename(".."), "download")
        XCTAssertFalse(ShellPolicy.safeFilename("a\\b:c.txt").contains("\\"))
    }
}
