import AuthenticationServices
import SwiftUI
import UIKit

enum NativeAuthState: Equatable {
    case unknown
    case signedOut
    case signingIn
    case signedIn
    case unavailable(String)
}

enum NativeAuthError: LocalizedError {
    case cancelled
    case unavailable
    case loginRequired
    case profile
    case network
    case token
    case storage

    var errorDescription: String? {
        switch self {
        case .cancelled: return "登录已取消。"
        case .unavailable: return "无法打开 CC98 登录窗口，请稍后重试。"
        case .loginRequired: return "登录已过期，请重新登录。"
        case .profile: return "无法读取 CC98 账号信息，请稍后重试。"
        case .network: return "无法连接 CC98，请确认校园网或系统 VPN 可用。"
        case .token: return "登录凭证无效，请重新登录。"
        case .storage: return "登录状态无法安全保存，请重试。"
        }
    }
}

// Native OpenID session. Only the keychain stores tokens; no token is written
// to logs, diagnostics or UserDefaults. The API token is issued by the same
// CC98 OpenID client that the Reborn extension uses.
@MainActor
final class NativeAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var state: NativeAuthState = .unknown
    @Published private(set) var profile: NativeUser?

    private var tokens: NativeTokenSet?
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var busy = false
    private let store = NativeTokenStore.shared
    private let decoder = JSONDecoder()

    var isSignedIn: Bool { profile != nil }

    override init() {
        super.init()
        tokens = store.load()
    }

    func restore() async {
        guard state == .unknown || state == .signedOut else { return }
        guard let stored = tokens ?? store.load() else {
            state = .signedOut
            return
        }
        tokens = stored
        do {
            let access = try await validAccessToken()
            let user = try await fetchMe(token: access)
            profile = user
            state = .signedIn
        } catch NativeAuthError.loginRequired {
            clearLocal()
            state = .signedOut
        } catch {
            state = .unavailable(NativeAuthError.network.localizedDescription)
        }
    }

    func signIn() async throws {
        guard !busy else { throw NativeAuthError.unavailable }
        busy = true
        state = .signingIn
        defer { busy = false }
        do {
            let stateValue = OAuthProtocol.randomValue()
            let verifier = OAuthProtocol.randomValue()
            let url = OAuthProtocol.authorizationURL(state: stateValue, verifier: verifier)
            let callback = try await authorize(url: url)
            let code = try OAuthProtocol.callbackCode(callback, expectedState: stateValue)
            let fresh = try await exchange(code: code, verifier: verifier)
            try store.save(fresh)
            tokens = fresh
            let user = try await fetchMe(token: fresh.accessToken)
            profile = user
            self.state = .signedIn
        } catch {
            self.state = .signedOut
            throw map(error)
        }
    }

    func signOut() {
        tokens = nil
        profile = nil
        store.clear()
        state = .signedOut
    }

    func validAccessToken() async throws -> String {
        guard let current = tokens ?? store.load() else { throw NativeAuthError.loginRequired }
        tokens = current
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        guard let refresh = current.refreshToken, !refresh.isEmpty else { throw NativeAuthError.loginRequired }
        let fresh = try await refreshTokens(refresh)
        try store.save(fresh)
        tokens = fresh
        return fresh.accessToken
    }

    func optionalAccessToken() async -> String? {
        try? await validAccessToken()
    }

    func refreshIfPossible() async throws {
        guard let current = tokens ?? store.load() else { throw NativeAuthError.loginRequired }
        guard let refresh = current.refreshToken, !refresh.isEmpty else { throw NativeAuthError.loginRequired }
        let fresh = try await refreshTokens(refresh)
        try store.save(fresh)
        tokens = fresh
    }

    private func clearLocal() {
        tokens = nil
        profile = nil
        store.clear()
    }

    // MARK: OAuth

    private func authorize(url: URL) async throws -> URL {
        guard let window = keyWindow() else { throw NativeAuthError.unavailable }
        anchor = window
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: OAuthProtocol.callbackScheme) { callback, error in
                Task { @MainActor in
                    guard !resumed else { return }
                    resumed = true
                    self.session = nil
                    if let error {
                        let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                        continuation.resume(throwing: cancelled ? NativeAuthError.cancelled : NativeAuthError.unavailable)
                        return
                    }
                    guard let callback else {
                        continuation.resume(throwing: NativeAuthError.unavailable)
                        return
                    }
                    continuation.resume(returning: callback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                resumed = true
                self.session = nil
                continuation.resume(throwing: NativeAuthError.unavailable)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? keyWindow() ?? ASPresentationAnchor()
    }

    private func exchange(code: String, verifier: String) async throws -> NativeTokenSet {
        var request = URLRequest(url: OAuthProtocol.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthProtocol.tokenBody(code: code, verifier: verifier)
        let data = try await tokenRequest(request)
        return try decodeTokens(data)
    }

    private func refreshTokens(_ refresh: String) async throws -> NativeTokenSet {
        var request = URLRequest(url: OAuthProtocol.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let fields = [("grant_type", "refresh_token"), ("client_id", OAuthProtocol.clientID), ("refresh_token", refresh)]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
        let data = try await tokenRequest(request)
        var fresh = try decodeTokens(data)
        if fresh.refreshToken == nil { fresh.refreshToken = refresh }
        return fresh
    }

    private func tokenRequest(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw NativeAuthError.token
            }
            return data
        } catch let error as NativeAuthError {
            throw error
        } catch {
            throw NativeAuthError.network
        }
    }

    private func decodeTokens(_ data: Data) throws -> NativeTokenSet {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              !access.isEmpty,
              access.count <= 16_384,
              ((json["token_type"] as? String) ?? "Bearer").lowercased() == "bearer" else {
            throw NativeAuthError.token
        }
        let lifetime: Int
        if let number = json["expires_in"] as? NSNumber {
            lifetime = number.intValue
        } else if let text = json["expires_in"] as? String, let value = Int(text) {
            lifetime = value
        } else {
            lifetime = 3600
        }
        return NativeTokenSet(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(60, lifetime))),
            scope: json["scope"] as? String
        )
    }

    private func fetchMe(token: String? = nil) async throws -> NativeUser {
        let access: String
        if let token {
            access = token
        } else {
            access = try await validAccessToken()
        }
        var request = URLRequest(url: OAuthProtocol.me)
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NativeAuthError.network }
            if http.statusCode == 401 { throw NativeAuthError.loginRequired }
            guard http.statusCode == 200 else { throw NativeAuthError.profile }
            if let user = try? decoder.decode(NativeUser.self, from: data) { return user }
            if let envelope = try? decoder.decode(DataEnvelope<NativeUser>.self, from: data) { return envelope.data }
            throw NativeAuthError.profile
        } catch let error as NativeAuthError {
            throw error
        } catch {
            throw NativeAuthError.network
        }
    }

    private func map(_ error: Error) -> NativeAuthError {
        if let error = error as? NativeAuthError { return error }
        if let error = error as? OAuthFailure {
            switch error {
            case .cancelled: return .cancelled
            case .network: return .network
            case .storage: return .storage
            default: return .unavailable
            }
        }
        return .unavailable
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
