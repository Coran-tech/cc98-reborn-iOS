import Foundation
import CoreFoundation

struct NativeTokenSet: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var scope: String?
    // Optional for compatibility with credentials saved by earlier builds.
    var requiresAuthorization: Bool? = nil
    var issuedAt: Date? = nil
}

enum NativeAuthError: LocalizedError, Equatable {
    case cancelled, unavailable, loginRequired, refreshUnavailable, profile, network, token, storage
    case configuration, accountChanged, accountMismatch

    var errorDescription: String? {
        switch self {
        case .cancelled: return "登录已取消。"
        case .unavailable: return "已有账号操作正在进行，或无法打开登录窗口，请稍后重试。"
        case .loginRequired: return "此账号需要重新登录。本机草稿和账号资料已保留。"
        case .refreshUnavailable: return "此账号尚未取得长期登录授权，请重新授权一次。"
        case .profile: return "无法读取 CC98 账号信息，请稍后重试。"
        case .network: return "暂时无法连接 CC98，请确认校园网或系统 VPN 可用。登录凭据已保留。"
        case .token: return "授权中心返回了无法识别的凭证，请稍后重试。"
        case .storage: return "登录状态未能安全保存，请重试或检查设备钥匙串。"
        case .configuration: return "授权配置暂不可用，请检查客户端的授权范围与站方限制。"
        case .accountChanged: return "账号已变化，未应用旧请求结果；提交操作请先确认是否成功。"
        case .accountMismatch: return "授权返回的账号与所选账号不同，原账号未改变。请重新选择正确账号。"
        }
    }
}

protocol NativeTokenStorage: AnyObject {
    func load(accountID: Int) throws -> NativeTokenSet?
    func save(_ tokens: NativeTokenSet, accountID: Int) throws
    func clear(accountID: Int)
}

struct NativeAccountContext: Equatable {
    let accountID: Int?
    let epoch: UUID
}

// View-scoped API clients capture this context before asynchronous preparation
// (photo downloads, editor work, chained HTTP calls), not just before transport.
@MainActor
final class NativeAccountIdentity {
    private(set) var current = NativeAccountContext(accountID: nil, epoch: UUID())

    func select(_ accountID: Int?) {
        guard current.accountID != accountID else { return }
        current = NativeAccountContext(accountID: accountID, epoch: UUID())
    }

    func validate(_ context: NativeAccountContext) throws {
        guard context == current else { throw NativeAuthError.accountChanged }
        try Task.checkCancellation()
    }
}

// Foundation-only production coordinator; storage, transport and time are injectable.
// All reads, rotations and writes for one UID go through this owner.
@MainActor
final class NativeSession {
    private struct Flight {
        let id: UUID
        let task: Task<NativeTokenSet, Error>
    }
    private let storage: NativeTokenStorage
    private let refresh: (String) async throws -> NativeTokenSet
    private let now: () -> Date
    private var cache: [Int: NativeTokenSet] = [:]
    private var generations: [Int: UUID] = [:]
    private var flights: [Int: Flight] = [:]
    // A rotated credential must not be exchanged again if its first save failed.
    private var pendingWrites: [Int: NativeTokenSet] = [:]

    init(storage: NativeTokenStorage, now: @escaping () -> Date = Date.init,
         refresh: @escaping (String) async throws -> NativeTokenSet) {
        self.storage = storage; self.now = now; self.refresh = refresh
    }

    func stored(accountID: Int) throws -> NativeTokenSet? {
        if let cached = cache[accountID] { return cached }
        do {
            let value = try storage.load(accountID: accountID)
            cache[accountID] = value
            return value
        } catch { throw NativeAuthError.storage }
    }

    func adopt(_ tokens: NativeTokenSet, accountID: Int) throws {
        do { try storage.save(tokens, accountID: accountID) }
        catch { throw NativeAuthError.storage }
        invalidateFlight(accountID: accountID)
        pendingWrites[accountID] = nil
        cache[accountID] = tokens
    }

    func remove(accountID: Int) {
        invalidateFlight(accountID: accountID)
        pendingWrites[accountID] = nil
        cache[accountID] = nil
        storage.clear(accountID: accountID)
    }

    private func invalidateFlight(accountID: Int) {
        generations[accountID] = UUID()
        flights[accountID]?.task.cancel()
        flights[accountID] = nil
    }

    func credential(accountID: Int, rejectedToken: String? = nil) async throws -> NativeTokenSet {
        try Task.checkCancellation()
        if let pending = pendingWrites[accountID] {
            try persist(pending, accountID: accountID)
        }
        guard let current = try stored(accountID: accountID) else { throw NativeAuthError.loginRequired }
        guard current.requiresAuthorization != true else { throw NativeAuthError.loginRequired }
        if let flight = flights[accountID] { return try await flight.task.value }
        let remaining = current.expiresAt.timeIntervalSince(now())
        let rejectedCurrent = rejectedToken == current.accessToken
        let earlyRefresh = current.issuedAt.map {
            min(60, max(0, current.expiresAt.timeIntervalSince($0)) * 0.1)
        } ?? 60
        if !rejectedCurrent, remaining > earlyRefresh { return current }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            // Do not prematurely expire an old access-only session during migration.
            if !rejectedCurrent, remaining > 0 { return current }
            throw NativeAuthError.refreshUnavailable
        }

        let generation = generations[accountID] ?? UUID()
        generations[accountID] = generation
        let flightID = UUID()
        let task = Task { @MainActor [self] () async throws -> NativeTokenSet in
            defer {
                if flights[accountID]?.id == flightID { flights[accountID] = nil }
            }
            do {
                var fresh = try await refresh(refreshToken)
                guard generations[accountID] == generation else { throw NativeAuthError.accountChanged }
                try Task.checkCancellation()
                if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
                if fresh.scope == nil { fresh.scope = current.scope }
                fresh.requiresAuthorization = nil
                if fresh.issuedAt == nil { fresh.issuedAt = now() }
                pendingWrites[accountID] = fresh
                try persist(fresh, accountID: accountID)
                return fresh
            } catch NativeAuthError.loginRequired {
                guard generations[accountID] == generation else { throw NativeAuthError.accountChanged }
                var invalid = current
                invalid.requiresAuthorization = true
                // Persist rejection so restarts do not keep replaying a revoked refresh token.
                pendingWrites[accountID] = invalid
                try persist(invalid, accountID: accountID)
                throw NativeAuthError.loginRequired
            }
        }
        flights[accountID] = Flight(id: flightID, task: task)
        return try await task.value
    }

    private func persist(_ tokens: NativeTokenSet, accountID: Int) throws {
        do { try storage.save(tokens, accountID: accountID) }
        catch { throw NativeAuthError.storage }
        cache[accountID] = tokens
        pendingWrites[accountID] = nil
    }
}

enum NativeTokenResponse {
    static func decode(_ data: Data, status: Int, now: Date = Date()) throws -> NativeTokenSet {
        guard data.count <= 1_048_576 else { throw NativeAuthError.token }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status != 200 {
            // Do not expose server error_description (it may contain sensitive material).
            if status == 400 || status == 401 {
                switch json?["error"] as? String {
                case "invalid_grant", "invalid_token": throw NativeAuthError.loginRequired
                case "invalid_client", "unauthorized_client", "invalid_scope", "unsupported_grant_type":
                    throw NativeAuthError.configuration
                default: break
                }
            }
            if status == 429 || status >= 500 { throw NativeAuthError.network }
            throw NativeAuthError.token
        }
        guard let json, json["error"] == nil,
              let access = json["access_token"] as? String, validToken(access),
              (json["token_type"] as? String)?.lowercased() == "bearer" else { throw NativeAuthError.token }
        let lifetime: Double?
        if let number = json["expires_in"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            lifetime = number.doubleValue
        } else if let text = json["expires_in"] as? String { lifetime = Double(text) }
        else { lifetime = nil }
        guard let lifetime, lifetime.isFinite, lifetime > 0 else { throw NativeAuthError.token }
        let refresh = json["refresh_token"] as? String
        if let refresh, !validToken(refresh) { throw NativeAuthError.token }
        return NativeTokenSet(accessToken: access, refreshToken: refresh,
                              expiresAt: now.addingTimeInterval(lifetime), scope: json["scope"] as? String,
                              issuedAt: now)
    }

    private static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 16_384
            && token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }
}
