import AuthenticationServices
import SwiftUI
import UIKit

enum NativeAuthState: Equatable {
    case unknown, signedOut, signingIn, signedIn
    case requiresAuthorization(String)
    case unavailable(String)
}

struct NativeRequestAuthorization {
    let accountID: Int?
    let selectionID: UUID
    let accessToken: String?
}

// System authorization UI and published account identity. NativeSession owns
// refresh serialization and credential persistence independently of selection.
@MainActor
final class NativeAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var state: NativeAuthState = .unknown
    @Published private(set) var profile: NativeUser?
    @Published private(set) var accounts: [NativeAccount] = []
    @Published private(set) var activeAccountID: Int?
    @Published private(set) var isBusy = false
    @Published private(set) var hasRefreshAuthorization = false

    private let store = NativeTokenStore.shared
    private let sessions: NativeSession
    private let identity = NativeAccountIdentity()
    private var selectionID = UUID()
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private let accountsKey = "native.accounts"
    private let activeAccountKey = "native.activeAccountID"

    var isSignedIn: Bool { profile != nil }

    override init() {
        sessions = NativeSession(storage: NativeTokenStore.shared, refresh: Self.refreshTokens)
        super.init()
        #if DEBUG
        if NativeUITestFixture.isEnabled {
            UserDefaults.standard.set(false, forKey: "native.newTopicsCardMode")
            UserDefaults.standard.set("system", forKey: "native.appearance")
            UserDefaults.standard.set(false, forKey: "native.notificationsEnabled")
            profile = NativeUITestFixture.user
            activeAccountID = NativeUITestFixture.userID
            accounts = [NativeAccount(id: NativeUITestFixture.userID, name: "林间风", avatarURL: nil)]
            identity.select(activeAccountID)
            state = .signedIn
            hasRefreshAuthorization = true
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let stored = try? JSONDecoder().decode([NativeAccount].self, from: data) { accounts = stored }
        if UserDefaults.standard.object(forKey: activeAccountKey) != nil {
            let id = UserDefaults.standard.integer(forKey: activeAccountKey)
            activeAccountID = id > 0 ? id : nil
        }
        identity.select(activeAccountID)
    }

    func restore() async {
        #if DEBUG
        if NativeUITestFixture.isEnabled { return }
        #endif
        guard !isBusy else { return }
        // UID 0 is only the pre-multi-account legacy keychain item.
        let accountID = activeAccountID ?? 0
        isBusy = true
        defer { isBusy = false }
        do {
            guard try sessions.stored(accountID: accountID) != nil else {
                if activeAccountID == nil { state = .signedOut }
                else { present(NativeAuthError.loginRequired, accountID: activeAccountID) }
                return
            }
            let tokens = try await sessions.credential(accountID: accountID)
            let user = try await verifiedUser(accountID: accountID, tokens: tokens)
            let current = try sessions.stored(accountID: accountID) ?? tokens
            if accountID == 0 {
                try sessions.adopt(current, accountID: user.id)
                sessions.remove(accountID: 0)
            }
            activate(user: user, tokens: current)
        } catch {
            present(error, accountID: activeAccountID)
        }
    }

    func resume() async {
        #if DEBUG
        if NativeUITestFixture.isEnabled { return }
        #endif
        guard !isBusy else { return }
        if profile == nil { await restore(); return }
        _ = try? await requestAuthorization(required: true)
    }

    func signIn() async throws {
        try await signIn(addingAccount: false, expectedAccountID: activeAccountID)
    }

    func addAccount() async throws {
        try await signIn(addingAccount: true, expectedAccountID: nil)
    }

    func reauthorize(accountID: Int) async throws {
        try await signIn(addingAccount: true, expectedAccountID: accountID)
    }

    private func signIn(addingAccount: Bool, expectedAccountID: Int?) async throws {
        guard !isBusy else { throw NativeAuthError.unavailable }
        isBusy = true
        let previousState = state
        state = .signingIn
        selectionID = UUID() // Previously dispatched operations cannot commit into this transition.
        defer { isBusy = false }
        do {
            let stateValue = OAuthProtocol.randomValue()
            let verifier = OAuthProtocol.randomValue()
            let url = OAuthProtocol.nativeAuthorizationURL(state: stateValue, verifier: verifier)
            let callback = try await authorize(url: url, ephemeral: addingAccount || expectedAccountID != nil)
            let code = try OAuthProtocol.callbackCode(callback, expectedState: stateValue)
            let fresh = try await Self.exchange(code: code, verifier: verifier)
            let user = try await Self.fetchMe(token: fresh.accessToken)
            if let expectedAccountID, user.id != expectedAccountID { throw NativeAuthError.accountMismatch }
            try sessions.adopt(fresh, accountID: user.id)
            activate(user: user, tokens: fresh)
        } catch {
            state = previousState
            throw map(error)
        }
    }

    func switchAccount(to accountID: Int) async throws {
        guard !isBusy else { throw NativeAuthError.unavailable }
        if accountID == activeAccountID {
            await restore()
            return
        }
        isBusy = true
        let previousState = state
        state = .signingIn
        selectionID = UUID()
        defer { isBusy = false }
        do {
            let tokens = try await sessions.credential(accountID: accountID)
            let user = try await verifiedUser(accountID: accountID, tokens: tokens)
            activate(user: user, tokens: try sessions.stored(accountID: accountID) ?? tokens)
        } catch {
            // Target UID never becomes active until credentials AND /me are verified.
            state = previousState
            throw map(error)
        }
    }

    func removeAccount(_ accountID: Int) async {
        guard !isBusy else { return }
        sessions.remove(accountID: accountID)
        accounts.removeAll { $0.id == accountID }
        if activeAccountID == accountID {
            selectionID = UUID()
            activeAccountID = nil
            identity.select(nil)
            profile = nil
            hasRefreshAuthorization = false
            state = .signedOut
        }
        persistAccounts()
    }

    func signOutCurrent() async {
        guard !isBusy, let activeAccountID else { return }
        await removeAccount(activeAccountID)
        // This is an explicit user action; the confirmation describes switching
        // to the next saved account. Credential expiry never takes this path.
        if let next = accounts.first { try? await switchAccount(to: next.id) }
    }

    func signOut() {
        guard !isBusy else { return }
        for account in accounts { sessions.remove(accountID: account.id) }
        sessions.remove(accountID: 0)
        store.clearAll()
        selectionID = UUID()
        accounts = []; activeAccountID = nil; profile = nil
        identity.select(nil)
        hasRefreshAuthorization = false
        persistAccounts()
        state = .signedOut
    }

    func validAccessToken() async throws -> String {
        guard let token = try await requestAuthorization(required: true).accessToken else {
            throw NativeAuthError.loginRequired
        }
        return token
    }

    func optionalAccessToken() async -> String? {
        try? await requestAuthorization(required: false).accessToken
    }

    func captureAccountContext() -> NativeAccountContext { identity.current }

    func requestAuthorization(required: Bool, accountContext: NativeAccountContext? = nil) async throws -> NativeRequestAuthorization {
        if let accountContext { try identity.validate(accountContext) }
        guard !isBusy else { throw NativeAuthError.unavailable }
        let context = NativeRequestAuthorization(accountID: activeAccountID, selectionID: selectionID, accessToken: nil)
        guard let id = context.accountID else {
            if required { throw NativeAuthError.loginRequired }
            return context
        }
        do {
            let tokens = try await sessions.credential(accountID: id)
            if let accountContext { try identity.validate(accountContext) }
            try validate(context)
            hasRefreshAuthorization = tokens.refreshToken != nil
            if profile != nil { state = .signedIn }
            return NativeRequestAuthorization(accountID: id, selectionID: context.selectionID, accessToken: tokens.accessToken)
        } catch {
            try validate(context)
            present(error, accountID: id)
            if !required, error as? NativeAuthError == .loginRequired || error as? NativeAuthError == .refreshUnavailable {
                return context
            }
            throw map(error)
        }
    }

    func recoverAuthorization(_ context: NativeRequestAuthorization) async throws -> NativeRequestAuthorization {
        try validate(context)
        guard let id = context.accountID, let rejected = context.accessToken else { throw NativeAuthError.loginRequired }
        do {
            let tokens = try await sessions.credential(accountID: id, rejectedToken: rejected)
            try validate(context)
            hasRefreshAuthorization = tokens.refreshToken != nil
            return NativeRequestAuthorization(accountID: id, selectionID: context.selectionID, accessToken: tokens.accessToken)
        } catch {
            try validate(context)
            present(error, accountID: id)
            throw map(error)
        }
    }

    func validate(_ context: NativeRequestAuthorization) throws {
        guard context.accountID == activeAccountID, context.selectionID == selectionID else {
            throw NativeAuthError.accountChanged
        }
        try Task.checkCancellation()
    }

    func refreshProfile() async {
        do {
            let context = try await requestAuthorization(required: true)
            guard let id = context.accountID, let token = context.accessToken else { return }
            let user = try await Self.fetchMe(token: token)
            try validate(context)
            guard user.id == id else { throw NativeAuthError.accountMismatch }
            profile = user
        } catch { /* A profile refresh must not delete a usable session. */ }
    }

    private func verifiedUser(accountID: Int, tokens: NativeTokenSet) async throws -> NativeUser {
        let user: NativeUser
        do { user = try await Self.fetchMe(token: tokens.accessToken) }
        catch NativeAuthError.loginRequired {
            let fresh = try await sessions.credential(accountID: accountID, rejectedToken: tokens.accessToken)
            user = try await Self.fetchMe(token: fresh.accessToken)
        }
        guard user.id > 0, accountID == 0 || user.id == accountID else { throw NativeAuthError.accountMismatch }
        return user
    }

    private func activate(user: NativeUser, tokens: NativeTokenSet) {
        if activeAccountID != user.id { selectionID = UUID() }
        activeAccountID = user.id
        identity.select(user.id)
        profile = user
        hasRefreshAuthorization = tokens.refreshToken != nil
        let account = NativeAccount(id: user.id, name: user.name ?? "CC98 用户", avatarURL: user.avatarURL?.absoluteString)
        if let index = accounts.firstIndex(where: { $0.id == user.id }) { accounts[index] = account }
        else { accounts.append(account) }
        persistAccounts()
        state = .signedIn
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: accountsKey) }
        if let activeAccountID { UserDefaults.standard.set(activeAccountID, forKey: activeAccountKey) }
        else { UserDefaults.standard.removeObject(forKey: activeAccountKey) }
    }

    private func present(_ error: Error, accountID: Int?) {
        guard accountID == activeAccountID else { return }
        let error = map(error)
        switch error {
        case .loginRequired, .refreshUnavailable:
            profile = nil
            hasRefreshAuthorization = false
            state = .requiresAuthorization(error.localizedDescription)
        case .cancelled, .accountChanged: break
        default: state = .unavailable(error.localizedDescription)
        }
    }

    // MARK: System authorization

    private func authorize(url: URL, ephemeral: Bool) async throws -> URL {
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
            session.prefersEphemeralWebBrowserSession = ephemeral
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

    private static func exchange(code: String, verifier: String) async throws -> NativeTokenSet {
        try await tokenRequest(body: OAuthProtocol.tokenBody(code: code, verifier: verifier))
    }

    private static func refreshTokens(_ refresh: String) async throws -> NativeTokenSet {
        let fields = [("grant_type", "refresh_token"), ("client_id", OAuthProtocol.clientID), ("refresh_token", refresh)]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = Data(fields.map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
        return try await tokenRequest(body: body)
    }

    private static func tokenRequest(body: Data) async throws -> NativeTokenSet {
        var request = URLRequest(url: OAuthProtocol.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await requestData(request)
        return try NativeTokenResponse.decode(data, status: response.statusCode)
    }

    private static func fetchMe(token: String) async throws -> NativeUser {
        var request = URLRequest(url: OAuthProtocol.me)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await requestData(request)
        if response.statusCode == 401 { throw NativeAuthError.loginRequired }
        guard response.statusCode == 200 else { throw NativeAuthError.profile }
        let decoder = JSONDecoder()
        if let user = try? decoder.decode(NativeUser.self, from: data), user.id > 0 { return user }
        if let envelope = try? decoder.decode(DataEnvelope<NativeUser>.self, from: data), envelope.data.id > 0 { return envelope.data }
        throw NativeAuthError.profile
    }

    private static func requestData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        // Reuse the established redirect-denying delegate for both auth endpoints.
        let delegate = OAuthHTTPClient()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard response.url == request.url, let http = response as? HTTPURLResponse else { throw NativeAuthError.network }
            return (data, http)
        } catch let error as NativeAuthError { throw error }
        catch is CancellationError { throw NativeAuthError.cancelled }
        catch { throw NativeAuthError.network }
    }

    private func map(_ error: Error) -> NativeAuthError {
        if let error = error as? NativeAuthError { return error }
        if error is NativeTokenStoreError { return .storage }
        if error is CancellationError { return .cancelled }
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
