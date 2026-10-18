import Foundation
import CryptoKit
import CoreFoundation

enum OAuthFailure: String, Error {
    case busy, cancelled, stale, expired, invalidCallback, invalidState, denied, invalidToken, invalidProfile, missingWatermark, accountMismatch, noWebAccount, unavailable, network, storage
    var code: String { "OAUTH_" + rawValue.uppercased() }
    var message: String {
        switch self {
        case .busy: return "已有授权正在进行，请完成或取消当前窗口。"
        case .cancelled: return "授权已取消，未写入绑定；可重新点击绑定。"
        case .stale: return "网页或账号已变化，本次授权已作废；请在当前页面重新绑定。"
        case .expired: return "授权等待超时，请重新点击绑定。"
        case .invalidCallback, .invalidState: return "授权回调校验失败，未写入绑定；请重新授权。"
        case .denied: return "未获得授权，请确认在 CC98 授权页允许所需权限后重试。"
        case .invalidToken: return "授权码兑换失败，请确认客户端回调与 PKCE 配置后重新授权。"
        case .invalidProfile: return "未取得有效的 CC98 /me 身份，请确认读取用户信息权限后重试。"
        case .missingWatermark: return "CC98 /me 未返回有效水印，本次没有绑定；请检查用户信息权限后重试。"
        case .accountMismatch: return "授权账号与当前网页 UID 不一致，本次没有绑定；请使用同一账号重新授权。"
        case .noWebAccount: return "未能读取当前网页 UID；请先在原站登录，再切回增强模式绑定。"
        case .unavailable: return "授权窗口无法打开；请关闭其他窗口后重试。"
        case .network: return "授权网络请求失败，请确认手机可访问 CC98 校网服务后重试。"
        case .storage: return "本机绑定保存失败；原绑定未更改，请稍后重试。"
        }
    }
    var response: [String: Any] { ["ok": false, "code": code, "error": message] }
}

struct OAuthBinding: Equatable {
    let userID: String
    let watermarkPrefix: String
    let boundAt: Double
    var dictionary: [String: Any] {
        ["ok": true, "bound": true, "provider": "cc98", "userId": userID,
         "watermarkIdPrefix": watermarkPrefix, "profileSource": "api-me", "profileWarning": "",
         "scope": OAuthProtocol.scopes, "boundAt": boundAt]
    }
    init(userID: String, watermarkPrefix: String, boundAt: Double = Date().timeIntervalSince1970 * 1000) throws {
        guard OAuthProtocol.userID(userID) == userID, watermarkPrefix.range(of: "^[A-Za-z0-9]{8}$", options: .regularExpression) != nil,
              boundAt.isFinite, boundAt > 0, boundAt <= Date().timeIntervalSince1970 * 1000 + 60_000 else { throw OAuthFailure.invalidProfile }
        self.userID = userID; self.watermarkPrefix = watermarkPrefix; self.boundAt = boundAt
    }
    init(stored: Any) throws {
        guard let value = stored as? [String: Any], value["bound"] as? Bool == true,
              value["provider"] as? String == "cc98", value["profileSource"] as? String == "api-me",
              let id = value["userId"] as? String, let prefix = value["watermarkIdPrefix"] as? String,
              let time = value["boundAt"] as? Double else { throw OAuthFailure.invalidProfile }
        try self.init(userID: id, watermarkPrefix: prefix, boundAt: time)
    }
}

enum OAuthProtocol {
    static let clientID = "9ca359c2-4112-44de-6177-08debd80dfb1"
    static let callback = "org.cc98.reborn.shell:/oauth/callback"
    static let callbackScheme = "org.cc98.reborn.shell"
    static let authorize = URL(string: "https://openid.cc98.org/connect/authorize")!
    static let token = URL(string: "https://openid.cc98.org/connect/token")!
    static let me = URL(string: "https://api.cc98.org/me")!
    static let scopes = "openid profile cc98-api read-user-info"

    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func randomValue() -> String {
        var random = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }))
    }
    static func userID(_ value: Any?) -> String? {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
        else { return nil }
        return text.range(of: "^[1-9][0-9]{0,18}$", options: .regularExpression) == nil ? nil : text
    }
    static func authorizationURL(state: String, verifier: String) -> URL {
        var url = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "redirect_uri", value: callback),
                         URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "scope", value: scopes),
                         URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge(verifier)),
                         URLQueryItem(name: "code_challenge_method", value: "S256")]
        return url.url!
    }
    static func callbackCode(_ url: URL, expectedState: String) throws -> String {
        guard url.absoluteString.split(separator: "?", maxSplits: 1).first.map(String.init) == callback,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == callbackScheme,
              parts.host == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.percentEncodedPath == "/oauth/callback", parts.fragment == nil else { throw OAuthFailure.invalidCallback }
        let pairs = parts.queryItems ?? []
        guard Set(pairs.map(\.name)).count == pairs.count else { throw OAuthFailure.invalidCallback }
        let fields = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
        guard fields["state"] == expectedState, !expectedState.isEmpty else { throw OAuthFailure.invalidState }
        if fields["error"] != nil { throw OAuthFailure.denied }
        guard let code = fields["code"], !code.isEmpty, code.count <= 4096,
              code.rangeOfCharacter(from: .controlCharacters) == nil else { throw OAuthFailure.invalidCallback }
        return code
    }
    static func tokenBody(code: String, verifier: String) -> Data {
        let fields = [("grant_type", "authorization_code"), ("client_id", clientID), ("redirect_uri", callback), ("code", code), ("code_verifier", verifier)]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }
    static func accessToken(data: Data, status: Int) throws -> String {
        guard status == 200, data.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil,
              let token = json["access_token"] as? String, !token.isEmpty, token.count <= 16_384,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              (json["token_type"] as? String)?.lowercased() == "bearer" else { throw OAuthFailure.invalidToken }
        if let scope = json["scope"] as? String {
            guard Set(scopes.split(separator: " ")).isSubset(of: Set(scope.split(separator: " "))) else { throw OAuthFailure.denied }
        }
        // id_token and refresh_token are deliberately never consumed or persisted.
        return token
    }
    static func binding(data: Data, status: Int, expectedUserID: String) throws -> OAuthBinding {
        guard status == 200, data.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OAuthFailure.invalidProfile }
        let profile = json["data"] as? [String: Any] ?? json
        guard let id = userID(profile["id"] ?? profile["userId"] ?? profile["uid"]) else { throw OAuthFailure.invalidProfile }
        guard id == expectedUserID else { throw OAuthFailure.accountMismatch }
        guard let watermark = profile["watermarkId"] as? String else { throw OAuthFailure.missingWatermark }
        let prefix = String(watermark.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
        guard prefix.range(of: "^[A-Za-z0-9]{8}$", options: .regularExpression) != nil else { throw OAuthFailure.missingWatermark }
        return try OAuthBinding(userID: id, watermarkPrefix: prefix)
    }
}

// One attempt consumes at most one callback. Cancellation/navigation invalidates it
// even if an already-running HTTP request later returns successfully.
struct OAuthAttempt {
    enum Phase { case authorizing, exchanging, complete, cancelled }
    let id = UUID()
    let userID: String
    let documentID: UUID
    let state: String
    let verifier: String
    let startedAt: Date
    private(set) var phase = Phase.authorizing
    init(userID: String, documentID: UUID, state: String = OAuthProtocol.randomValue(), verifier: String = OAuthProtocol.randomValue(), now: Date = Date()) {
        self.userID = userID; self.documentID = documentID; self.state = state; self.verifier = verifier; startedAt = now
    }
    func check(userID: String, documentID: UUID, now: Date = Date()) throws {
        guard phase == .authorizing || phase == .exchanging else { throw OAuthFailure.stale }
        guard now.timeIntervalSince(startedAt) >= 0, now.timeIntervalSince(startedAt) <= 180 else { throw OAuthFailure.expired }
        guard self.documentID == documentID, self.userID == userID else { throw OAuthFailure.stale }
    }
    mutating func accept(_ url: URL, now: Date = Date()) throws -> String {
        guard phase == .authorizing else { throw OAuthFailure.stale }
        do {
            try check(userID: userID, documentID: documentID, now: now)
            let code = try OAuthProtocol.callbackCode(url, expectedState: state)
            phase = .exchanging
            return code
        } catch { phase = .cancelled; throw error }
    }
    mutating func complete(userID: String, documentID: UUID, now: Date = Date()) throws {
        guard phase == .exchanging else { throw OAuthFailure.stale }
        do {
            try check(userID: userID, documentID: documentID, now: now)
            phase = .complete
        } catch { phase = .cancelled; throw error }
    }
    mutating func cancel() { phase = .cancelled }
}
