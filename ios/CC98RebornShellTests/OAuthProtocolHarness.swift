import Foundation
#if !OAUTH_PROTOCOL_HARNESS
import XCTest
@testable import CC98RebornShell
#endif

enum OAuthContractChecks {
    struct Failure: Error { let name: String }
    static func run() throws -> Int {
        var count = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw Failure(name: name) }; count += 1
        }
        func rejects(_ name: String, _ expected: OAuthFailure? = nil, _ body: () throws -> Void) throws {
            do { try body() } catch {
                if let expected { try check(name, (error as? OAuthFailure) == expected) } else { count += 1 }
                return
            }
            throw Failure(name: name)
        }
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        try check("RFC 7636 S256 vector", OAuthProtocol.challenge(verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let random = OAuthProtocol.randomValue()
        try check("PKCE entropy length/alphabet", random.count == 43 && random.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        try check("independent state/verifier", random != OAuthProtocol.randomValue())
        let authorization = URLComponents(url: OAuthProtocol.authorizationURL(state: "test-state", verifier: verifier), resolvingAgainstBaseURL: false)!
        let parameters = Dictionary(uniqueKeysWithValues: authorization.queryItems!.map { ($0.name, $0.value!) })
        try check("fixed authorize endpoint", authorization.scheme == "https" && authorization.host == "openid.cc98.org" && authorization.path == "/connect/authorize")
        try check("fixed callback and client", parameters["redirect_uri"] == "org.cc98.reborn.shell:/oauth/callback" && parameters["client_id"] == OAuthProtocol.clientID)
        try check("code S256 exact scopes", parameters["response_type"] == "code" && parameters["code_challenge_method"] == "S256" && parameters["scope"] == OAuthProtocol.scopes)
        try check("no secret or ID-token request", parameters["client_secret"] == nil && parameters["nonce"] == nil)
        let valid = URL(string: OAuthProtocol.callback + "?state=test-state&code=synthetic-code")!
        try check("valid exact callback", try OAuthProtocol.callbackCode(valid, expectedState: "test-state") == "synthetic-code")
        for address in [
            "org.cc98.reborn.shell://oauth/callback?state=test-state&code=x",
            "org.cc98.reborn.shell:/oauth/callback/?state=test-state&code=x",
            "org.cc98.reborn.shell:/oauth/%63allback?state=test-state&code=x",
            "org.cc98.reborn.shell:/oauth/callback?state=test-state&code=x#extra",
            "org.cc98.reborn.shell:/oauth/callback?state=test-state&state=test-state&code=x",
            "org.cc98.reborn.shell:/oauth/callback?state=test-state&code=x&code=y",
            "org.cc98.reborn.shell://user@host:123/oauth/callback?state=test-state&code=x",
            "other:/oauth/callback?state=test-state&code=x"
        ] { try rejects("invalid callback structure", .invalidCallback) { _ = try OAuthProtocol.callbackCode(URL(string: address)!, expectedState: "test-state") } }
        try rejects("state mismatch", .invalidState) { _ = try OAuthProtocol.callbackCode(valid, expectedState: "different") }
        try rejects("authorization denial", .denied) { _ = try OAuthProtocol.callbackCode(URL(string: OAuthProtocol.callback + "?state=test-state&error=access_denied&error_description=DO_NOT_LOG")!, expectedState: "test-state") }
        try rejects("missing code", .invalidCallback) { _ = try OAuthProtocol.callbackCode(URL(string: OAuthProtocol.callback + "?state=test-state")!, expectedState: "test-state") }
        let form = String(decoding: OAuthProtocol.tokenBody(code: "a+b&c", verifier: verifier), as: UTF8.self)
        try check("form code escaped", form.contains("code=a%2Bb%26c") && form.contains("code_verifier=" + verifier) && !form.contains("client_secret"))
        let token = try json(["access_token": "synthetic-token", "token_type": "Bearer", "scope": OAuthProtocol.scopes, "id_token": "ignored", "refresh_token": "ignored"])
        try check("valid access token only", try OAuthProtocol.accessToken(data: token, status: 200) == "synthetic-token")
        try rejects("token HTTP error", .invalidToken) { _ = try OAuthProtocol.accessToken(data: token, status: 400) }
        try rejects("token server error", .invalidToken) { _ = try OAuthProtocol.accessToken(data: json(["error": "invalid_grant", "error_description": "DO_NOT_LOG"]), status: 200) }
        try rejects("token header injection", .invalidToken) { _ = try OAuthProtocol.accessToken(data: json(["access_token": "a\r\nb", "token_type": "Bearer"]), status: 200) }
        try rejects("unsupported token type", .invalidToken) { _ = try OAuthProtocol.accessToken(data: json(["access_token": "a", "token_type": "Basic"]), status: 200) }
        try rejects("required scope denied", .denied) { _ = try OAuthProtocol.accessToken(data: json(["access_token": "a", "token_type": "Bearer", "scope": "openid"]), status: 200) }
        let profile = try json(["id": 42, "watermarkId": "abcdefgh0123456789", "name": "Anonymous fixture"])
        let binding = try OAuthProtocol.binding(data: profile, status: 200, expectedUserID: "42")
        try check("UID and watermark prefix", binding.userID == "42" && binding.watermarkPrefix == "abcdefgh")
        try check("minimal trusted summary", binding.dictionary["access_token"] == nil && binding.dictionary["userName"] == nil && binding.dictionary["profileSource"] as? String == "api-me")
        try rejects("UID mismatch", .accountMismatch) { _ = try OAuthProtocol.binding(data: profile, status: 200, expectedUserID: "43") }
        try rejects("missing watermark", .missingWatermark) { _ = try OAuthProtocol.binding(data: json(["id": 42]), status: 200, expectedUserID: "42") }
        try rejects("invalid watermark", .missingWatermark) { _ = try OAuthProtocol.binding(data: json(["id": 42, "watermarkId": "bad"]), status: 200, expectedUserID: "42") }
        try rejects("boolean UID", .invalidProfile) { _ = try OAuthProtocol.binding(data: json(["id": true, "watermarkId": "abcdefgh"]), status: 200, expectedUserID: "1") }
        try rejects("profile HTTP error", .invalidProfile) { _ = try OAuthProtocol.binding(data: profile, status: 403, expectedUserID: "42") }
        let document = UUID()
        var flow = OAuthAttempt(userID: "42", documentID: document, state: "test-state", verifier: verifier)
        _ = try flow.accept(valid)
        try rejects("duplicate callback", .stale) { _ = try flow.accept(valid) }
        try flow.complete(userID: "42", documentID: document)
        try rejects("completed flow cannot write twice", .stale) { try flow.complete(userID: "42", documentID: document) }
        var mismatch = OAuthAttempt(userID: "42", documentID: document, state: "test-state")
        _ = try mismatch.accept(valid)
        try rejects("changed account before write", .stale) { try mismatch.complete(userID: "43", documentID: document) }
        try rejects("changed account invalidates write permanently", .stale) { try mismatch.complete(userID: "42", documentID: document) }
        var navigated = OAuthAttempt(userID: "42", documentID: document, state: "test-state")
        _ = try navigated.accept(valid)
        try rejects("changed document before write", .stale) { try navigated.complete(userID: "42", documentID: UUID()) }
        var cancelled = OAuthAttempt(userID: "42", documentID: document)
        cancelled.cancel()
        try rejects("cancelled flow rejects callback", .stale) { _ = try cancelled.accept(valid) }
        var exchanged = OAuthAttempt(userID: "42", documentID: document, state: "test-state")
        _ = try exchanged.accept(valid)
        exchanged.cancel()
        try rejects("cancelled exchange cannot bind after HTTP returns", .stale) { try exchanged.complete(userID: "42", documentID: document) }
        var stale = OAuthAttempt(userID: "42", documentID: document, state: "test-state", now: Date(timeIntervalSinceNow: -181))
        try rejects("expired flow rejects callback", .expired) { _ = try stale.accept(valid) }
        var invalid = OAuthAttempt(userID: "42", documentID: document, state: "test-state")
        try rejects("invalid state cancels attempt", .invalidState) { _ = try invalid.accept(URL(string: OAuthProtocol.callback + "?state=wrong&code=x")!) }
        try rejects("invalid attempt cannot recover with replay", .stale) { _ = try invalid.accept(valid) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = try LocalSettingsStore(file: file)
        try rejects("JS cannot write binding") { _ = try store.set([ShellPolicy.bindingKey: binding.dictionary]) }
        try rejects("JS cannot fake binding defaults") { _ = try store.get([ShellPolicy.bindingKey: binding.dictionary]) }
        let changes = try store.setNativeBinding(binding)
        try check("native notification shape", (changes[ShellPolicy.bindingKey] as? [String: Any])?["newValue"] != nil)
        try rejects("JS cannot remove binding") { _ = try store.remove(ShellPolicy.bindingKey) }
        let reloaded = try LocalSettingsStore(file: file)
        let readable = try reloaded.get(ShellPolicy.bindingKey)
        try check("trusted summary persisted and readable", reloaded.binding == binding && readable[ShellPolicy.bindingKey] != nil)
        try check("only summary on disk", !String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("synthetic-token"))
        let cleared = try reloaded.setNativeBinding(nil)
        try check("local unbind notification", (cleared[ShellPolicy.bindingKey] as? [String: Any])?["oldValue"] != nil)
        try check("local unbind persisted", try LocalSettingsStore(file: file).binding == nil)
        try json([ShellPolicy.bindingKey: ["bound": true, "provider": "cc98", "profileSource": "api-me", "userId": "42", "boundAt": Date().timeIntervalSince1970 * 1000]]).write(to: file)
        try check("startup drops incomplete binding without watermark", try LocalSettingsStore(file: file).binding == nil)
        let redirectClient = OAuthHTTPClient()
        let urlSession = URLSession(configuration: .ephemeral)
        defer { urlSession.invalidateAndCancel() }
        let task = urlSession.dataTask(with: OAuthProtocol.token) // Never resumed; no network.
        var redirectRejected = false
        redirectClient.urlSession(urlSession, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: OAuthProtocol.token, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.invalid/"])!, newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) { redirectRejected = $0 == nil }
        try check("production HTTP delegate rejects redirect", redirectRejected)
        return count
    }
}

#if OAUTH_PROTOCOL_HARNESS
@main
enum OAuthProtocolHarness {
    static func main() {
        do { print("OAuth production protocol/storage/redirect checks passed: \(try OAuthContractChecks.run())") }
        catch let failure as OAuthContractChecks.Failure { fputs("OAuth contract failed: \(failure.name)\n", stderr); exit(1) }
        catch { fputs("OAuth contract failed with a local test/setup error\n", stderr); exit(1) }
    }
}
#else
final class OAuthProtocolTests: XCTestCase {
    func testProductionOAuthContracts() throws { XCTAssertGreaterThan(try OAuthContractChecks.run(), 40) }
}
#endif
