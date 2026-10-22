import Foundation
#if !NATIVE_SESSION_HARNESS
import XCTest
@testable import CC98RebornShell
#endif

// Runs the production coordinator with synthetic credentials only. No keychain,
// real HTTP, device clock changes, credentials in logs, or timing-based sleeps.
@MainActor
enum NativeSessionContractChecks {
    struct Failure: Error { let name: String }

    final class MemoryStore: NativeTokenStorage {
        var values: [Int: NativeTokenSet] = [:]
        var saves: [(Int, NativeTokenSet)] = []
        var clears: [Int] = []
        var failLoads = false
        var failedSavesRemaining = 0

        func load(accountID: Int) throws -> NativeTokenSet? {
            if failLoads { throw NativeAuthError.storage }
            return values[accountID]
        }

        func save(_ tokens: NativeTokenSet, accountID: Int) throws {
            if failedSavesRemaining > 0 {
                failedSavesRemaining -= 1
                throw NativeAuthError.storage
            }
            values[accountID] = tokens
            saves.append((accountID, tokens))
        }

        func clear(accountID: Int) {
            clears.append(accountID)
            values[accountID] = nil
        }
    }

    @MainActor
    final class Gate {
        private(set) var calls: [String] = []
        private var pending: [String: [CheckedContinuation<NativeTokenSet, Error>]] = [:]
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func refresh(_ token: String) async throws -> NativeTokenSet {
            calls.append(token)
            return try await withCheckedThrowingContinuation { continuation in
                pending[token, default: []].append(continuation)
                let ready = waiters.filter { calls.count >= $0.0 }
                waiters.removeAll { calls.count >= $0.0 }
                for waiter in ready { waiter.1.resume() }
            }
        }

        func waitForCalls(_ count: Int) async {
            if calls.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }

        func finish(_ token: String, _ result: Result<NativeTokenSet, Error>) throws {
            guard var queue = pending[token], !queue.isEmpty else {
                throw Failure(name: "test gate has a pending request")
            }
            let continuation = queue.removeFirst()
            pending[token] = queue
            continuation.resume(with: result)
        }
    }

    @MainActor
    final class PreparationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func prepare() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
                let ready = waiters
                waiters.removeAll()
                for waiter in ready { waiter.resume() }
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish() throws {
            guard let continuation else { throw Failure(name: "preparation gate is waiting") }
            self.continuation = nil
            continuation.resume()
        }
    }

    static func run() async throws -> Int {
        var count = 0
        func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
            guard try value() else { throw Failure(name: name) }
            count += 1
        }
        func rejects(_ name: String, _ expected: NativeAuthError, _ body: () throws -> Void) throws {
            do { try body() }
            catch {
                try check(name, (error as? NativeAuthError) == expected)
                return
            }
            throw Failure(name: name)
        }
        func rejectsAsync(_ name: String, _ expected: NativeAuthError,
                          _ body: () async throws -> Void) async throws {
            do { try await body() }
            catch {
                try check(name, (error as? NativeAuthError) == expected)
                return
            }
            throw Failure(name: name)
        }
        func json(_ fields: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: fields)
        }
        func parameters(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        func token(_ label: String, remaining: TimeInterval = 3_600, refresh: String? = nil,
                   scope: String? = "openid profile cc98-api read-user-info offline_access") -> NativeTokenSet {
            NativeTokenSet(accessToken: "synthetic-access-" + label,
                           refreshToken: refresh,
                           expiresAt: epoch.addingTimeInterval(remaining), scope: scope,
                           issuedAt: epoch)
        }

        // Migration does not require replacing existing Keychain items or expanding
        // the older web-binding flow's permissions.
        let oldData = try json([
            "accessToken": "synthetic-old-access", "refreshToken": "synthetic-old-refresh",
            "expiresAt": epoch.timeIntervalSinceReferenceDate,
            "scope": OAuthProtocol.scopes
        ])
        let decodedOld = try JSONDecoder().decode(NativeTokenSet.self, from: oldData)
        try check("old keychain payload decodes without new marker", decodedOld.requiresAuthorization == nil)
        try check("old keychain payload decodes without issuance time", decodedOld.issuedAt == nil)
        try check("old keychain expiry is preserved", decodedOld.expiresAt == epoch)
        let native = parameters(OAuthProtocol.nativeAuthorizationURL(state: "synthetic-state", verifier: "synthetic-verifier"))
        let legacy = parameters(OAuthProtocol.authorizationURL(state: "synthetic-state", verifier: "synthetic-verifier"))
        let nativeScopes = Set((native["scope"] ?? "").split(separator: " "))
        try check("native flow requests offline access", nativeScopes.contains("offline_access"))
        try check("native flow retains existing permissions", Set(OAuthProtocol.scopes.split(separator: " ")).isSubset(of: nativeScopes))
        try check("native flow asks for consent", (native["prompt"] ?? "").split(separator: " ").contains("consent"))
        try check("native flow keeps exact callback and PKCE", native["redirect_uri"] == OAuthProtocol.callback && native["response_type"] == "code" && native["code_challenge_method"] == "S256")
        try check("native flow has no client secret", native["client_secret"] == nil)
        try check("legacy flow keeps original scope and SSO", legacy["scope"] == OAuthProtocol.scopes && legacy["prompt"] == nil && !Set(OAuthProtocol.scopes.split(separator: " ")).contains("offline_access"))

        var payload: [String: Any] = ["access_token": "synthetic-access", "token_type": "Bearer", "expires_in": 12]
        let short = try NativeTokenResponse.decode(json(payload), status: 200, now: epoch)
        try check("short server lifetime is not extended to sixty seconds", short.expiresAt == epoch.addingTimeInterval(12))
        try check("token response records its actual issuance time", short.issuedAt == epoch)
        payload["expires_in"] = "7200"
        let long = try NativeTokenResponse.decode(json(payload), status: 200, now: epoch)
        try check("string server lifetime is honored", long.expiresAt == epoch.addingTimeInterval(7_200))
        for value in [0, -1, true, "NaN", "infinity", "bad"] as [Any] {
            payload["expires_in"] = value
            try rejects("invalid expiry rejected", .token) { _ = try NativeTokenResponse.decode(json(payload), status: 200, now: epoch) }
        }
        payload.removeValue(forKey: "expires_in")
        try rejects("missing expiry is not silently one hour", .token) { _ = try NativeTokenResponse.decode(json(payload), status: 200, now: epoch) }
        payload["expires_in"] = 3_600
        for value in ["", "synthetic\r\nHeader: injected", "with space"] {
            payload["access_token"] = value
            try rejects("unsafe access token rejected", .token) { _ = try NativeTokenResponse.decode(json(payload), status: 200, now: epoch) }
        }
        payload["access_token"] = "synthetic-access"
        payload["refresh_token"] = "unsafe\nrefresh"
        try rejects("unsafe refresh token rejected", .token) { _ = try NativeTokenResponse.decode(json(payload), status: 200, now: epoch) }
        payload.removeValue(forKey: "refresh_token")
        payload["token_type"] = "Basic"
        try rejects("unsupported token type rejected", .token) { _ = try NativeTokenResponse.decode(json(payload), status: 200, now: epoch) }
        for code in ["invalid_grant", "invalid_token"] {
            try rejects("explicit authorization rejection is typed", .loginRequired) {
                _ = try NativeTokenResponse.decode(json(["error": code, "error_description": "synthetic-secret-do-not-display"]), status: 400, now: epoch)
            }
        }
        for code in ["invalid_client", "unauthorized_client", "invalid_scope", "unsupported_grant_type"] {
            try rejects("configuration failure does not become expired login", .configuration) {
                _ = try NativeTokenResponse.decode(json(["error": code]), status: 400, now: epoch)
            }
        }
        for status in [429, 500, 503] {
            try rejects("temporary HTTP failure preserves authorization", .network) {
                _ = try NativeTokenResponse.decode(json(["error": "invalid_grant"]), status: status, now: epoch)
            }
        }
        try check("friendly errors never contain server descriptions", !NativeAuthError.loginRequired.localizedDescription.contains("synthetic-secret"))

        // Existing non-expiring credentials do not contact the token endpoint.
        do {
            let store = MemoryStore()
            let original = token("valid", refresh: "synthetic-refresh-valid")
            store.values[1] = original
            var refreshCalls = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in
                refreshCalls += 1
                throw NativeAuthError.network
            }
            let result = try await session.credential(accountID: 1)
            try check("unexpired access is reused", result == original && refreshCalls == 0)
            try check("reading valid credential does not rewrite storage", store.saves.isEmpty && store.clears.isEmpty)
        }

        do {
            let store = MemoryStore()
            let original = token("rejected-valid", refresh: "synthetic-refresh-rejected-valid")
            let fresh = token("after-explicit-rejection", refresh: "synthetic-refresh-after-rejection")
            store.values[1] = original
            var refreshCalls = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in refreshCalls += 1; return fresh }
            let result = try await session.credential(accountID: 1, rejectedToken: original.accessToken)
            try check("explicit current-token rejection refreshes before local expiry", result == fresh && refreshCalls == 1)
        }

        do {
            let store = MemoryStore()
            var nearExpiry = token("near-expiry", remaining: 30, refresh: "synthetic-refresh-near-expiry")
            nearExpiry.issuedAt = epoch.addingTimeInterval(-3_570)
            store.values[1] = nearExpiry
            let fresh = token("early-renewal", refresh: "synthetic-refresh-early-renewal")
            var refreshCalls = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in refreshCalls += 1; return fresh }
            let result = try await session.credential(accountID: 1)
            try check("available refresh renews within the early-refresh window", result == fresh && refreshCalls == 1)
        }

        do {
            let store = MemoryStore()
            let original = token("before-adopt", refresh: "synthetic-refresh-before-adopt")
            store.values[1] = original
            let session = NativeSession(storage: store, now: { epoch }) { _ in throw NativeAuthError.network }
            _ = try await session.credential(accountID: 1)
            store.failedSavesRemaining = 1
            try rejects("failed reauthorization save is storage error", .storage) {
                try session.adopt(token("failed-adopt", refresh: "synthetic-refresh-failed-adopt"), accountID: 1)
            }
            let result = try await session.credential(accountID: 1)
            try check("failed adopt retains previous usable grant", result == original && store.values[1] == original)
        }

        // An old access-only login stays useful until its actual expiry, even in
        // the normal sixty-second early-refresh window.
        do {
            let store = MemoryStore()
            var original = token("access-only", remaining: 30)
            original.issuedAt = nil
            store.values[1] = original
            var clock = epoch
            var refreshCalls = 0
            let session = NativeSession(storage: store, now: { clock }) { _ in
                refreshCalls += 1
                throw NativeAuthError.network
            }
            let beforeExpiry = try await session.credential(accountID: 1)
            try check("access-only migration preserves remaining validity", beforeExpiry == original)
            clock = epoch.addingTimeInterval(31)
            try await rejectsAsync("expired access-only asks for one authorization", .refreshUnavailable) { _ = try await session.credential(accountID: 1) }
            try check("access-only migration does not delete account or call refresh", store.values[1] == original && refreshCalls == 0 && store.clears.isEmpty)
        }

        // A short-lived token must remain usable between requests rather than
        // entering a refresh loop under a fixed sixty-second lead time.
        do {
            let store = MemoryStore()
            store.values[1] = token("short-expired", remaining: -1, refresh: "synthetic-refresh-short-old")
            var clock = epoch
            var refreshCalls = 0
            let session = NativeSession(storage: store, now: { clock }) { _ in
                refreshCalls += 1
                return try NativeTokenResponse.decode(json([
                    "access_token": "synthetic-short-access-\(refreshCalls)",
                    "refresh_token": "synthetic-short-refresh-\(refreshCalls)",
                    "token_type": "Bearer", "expires_in": 12
                ]), status: 200, now: clock)
            }
            let first = try await session.credential(accountID: 1)
            let second = try await session.credential(accountID: 1)
            try check("consecutive requests share a short-lived token", first == second && refreshCalls == 1)
            try check("short-lived refresh keeps the real expiry", first.expiresAt == epoch.addingTimeInterval(12) && first.issuedAt == epoch)
            clock = epoch.addingTimeInterval(10.7)
            let beforeWindow = try await session.credential(accountID: 1)
            try check("short token is reused outside its ten-percent window", beforeWindow == first && refreshCalls == 1)
            clock = epoch.addingTimeInterval(10.9)
            let renewed = try await session.credential(accountID: 1)
            try check("short token renews inside its ten-percent window", renewed.accessToken != first.accessToken && refreshCalls == 2)
            try check("short renewal does not extend the old expiry", first.expiresAt == epoch.addingTimeInterval(12) && renewed.expiresAt == clock.addingTimeInterval(12))
        }

        do {
            let store = MemoryStore()
            var original = token("legacy-near-expiry", remaining: 30, refresh: "synthetic-refresh-legacy-near-expiry")
            original.issuedAt = nil
            store.values[1] = original
            var response = token("refresh-without-issued-at", refresh: "synthetic-refresh-without-issued-at")
            response.issuedAt = nil
            var refreshCalls = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in refreshCalls += 1; return response }
            let result = try await session.credential(accountID: 1)
            try check("legacy token without issuance time keeps sixty-second lead", refreshCalls == 1)
            try check("refresh adds missing issuance time without extending expiry", result.issuedAt == epoch && result.expiresAt == response.expiresAt)
        }

        // The identity is captured before asynchronous photo/editor preparation,
        // not only when the HTTP request is finally ready to send.
        for switchBack in [false, true] {
            let identity = NativeAccountIdentity()
            identity.select(1)
            let scopeBeforePreparation = identity.current
            let preparation = PreparationGate()
            var submissionCount = 0
            let operation = Task { @MainActor in
                await preparation.prepare()
                try identity.validate(scopeBeforePreparation)
                submissionCount += 1
            }
            await preparation.waitUntilStarted()
            identity.select(2)
            if switchBack { identity.select(1) }
            try preparation.finish()
            try await rejectsAsync("account change during preparation cancels submission", .accountChanged) { try await operation.value }
            try check("stale prepared operation never submits", submissionCount == 0)
            try check("switch-away-and-back still changes identity epoch", identity.current.epoch != scopeBeforePreparation.epoch)
        }

        do {
            let identity = NativeAccountIdentity()
            identity.select(1)
            let original = identity.current
            identity.select(1)
            try identity.validate(original)
            try check("selecting the same UID preserves a valid context", identity.current == original)
        }

        do {
            let identity = NativeAccountIdentity()
            let guest = identity.current
            identity.select(1)
            try rejects("guest context is invalid after login", .accountChanged) { try identity.validate(guest) }
            try identity.validate(identity.current)
            try check("newly selected account context is usable", identity.current.accountID == 1)
        }

        // Concurrent consumers share exactly one rotation. The result is already
        // persisted before any consumer is allowed to continue.
        do {
            let store = MemoryStore()
            let old = token("old", remaining: -1, refresh: "synthetic-refresh-old")
            let fresh = token("fresh", refresh: "synthetic-refresh-new")
            store.values[1] = old
            let gate = Gate()
            let session = NativeSession(storage: store, now: { epoch }, refresh: gate.refresh)
            let tasks = (0..<8).map { _ in
                Task { @MainActor in try await session.credential(accountID: 1) }
            }
            await gate.waitForCalls(1)
            try check("pending rotation does not publish before response", try session.stored(accountID: 1) == old && store.saves.isEmpty)
            try gate.finish("synthetic-refresh-old", .success(fresh))
            for task in tasks {
                let result = try await task.value
                try check("all concurrent consumers receive persisted rotation", result == fresh && store.values[1] == fresh)
            }
            try check("one-time refresh was exchanged once", gate.calls.count == 1 && store.saves.count == 1)
            let recovered = try await session.credential(accountID: 1, rejectedToken: old.accessToken)
            try check("late old-token 401 reuses current rotation", recovered == fresh && gate.calls.count == 1)
            let restored = NativeSession(storage: store, now: { epoch }) { _ in throw NativeAuthError.network }
            let afterRestart = try await restored.credential(accountID: 1)
            try check("restart loads rotated credential", afterRestart == fresh)
        }

        // Missing refresh/scope fields in a successful rotation preserve the
        // previous grant, while a returned refresh value replaces it.
        do {
            let store = MemoryStore()
            let original = token("preserve", remaining: -1, refresh: "synthetic-refresh-preserve", scope: "openid offline_access")
            store.values[1] = original
            let session = NativeSession(storage: store, now: { epoch }) { _ in token("new-without-refresh", scope: nil) }
            let result = try await session.credential(accountID: 1)
            try check("omitted refresh value preserves previous credential", result.refreshToken == original.refreshToken)
            try check("omitted scope preserves granted scope", result.scope == original.scope)
        }

        // Temporary connectivity and configuration problems never erase or mark
        // an account revoked; a controlled later retry may recover normally.
        for expected in [NativeAuthError.network, .configuration, .token] {
            let store = MemoryStore()
            let old = token("retry", remaining: -1, refresh: "synthetic-refresh-retry")
            let fresh = token("retried", refresh: "synthetic-refresh-retried")
            store.values[1] = old
            var attempts = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in
                attempts += 1
                if attempts == 1 { throw expected }
                return fresh
            }
            try await rejectsAsync("temporary failure stays correctly classified", expected) { _ = try await session.credential(accountID: 1) }
            try check("temporary failure keeps exact saved credential", store.values[1] == old && store.clears.isEmpty && store.saves.isEmpty)
            let result = try await session.credential(accountID: 1)
            try check("later controlled retry can restore session", result == fresh && attempts == 2)
        }

        // An explicit refresh rejection is remembered per UID across restart.
        do {
            let store = MemoryStore()
            store.values[1] = token("revoked", remaining: -1, refresh: "synthetic-refresh-revoked")
            let other = token("other", refresh: "synthetic-refresh-other")
            store.values[2] = other
            var attempts = 0
            let refresh: (String) async throws -> NativeTokenSet = { _ in
                attempts += 1
                throw NativeAuthError.loginRequired
            }
            let session = NativeSession(storage: store, now: { epoch }, refresh: refresh)
            try await rejectsAsync("revoked refresh requests reauthorization", .loginRequired) { _ = try await session.credential(accountID: 1) }
            try check("revoked account is retained with marker", store.values[1]?.requiresAuthorization == true && store.clears.isEmpty)
            try await rejectsAsync("revoked refresh is not replayed in process", .loginRequired) { _ = try await session.credential(accountID: 1) }
            let restored = NativeSession(storage: store, now: { epoch }, refresh: refresh)
            try await rejectsAsync("revoked refresh is not replayed after restart", .loginRequired) { _ = try await restored.credential(accountID: 1) }
            try check("revocation causes only one token request", attempts == 1)
            let otherResult = try await session.credential(accountID: 2)
            try check("revocation leaves another UID unchanged", otherResult == other && store.values[2] == other)
            let renewed = token("authorized-again", refresh: "synthetic-refresh-authorized-again")
            try session.adopt(renewed, accountID: 1)
            let renewedResult = try await session.credential(accountID: 1)
            try check("explicit reauthorization replaces rejected grant", renewedResult == renewed && renewedResult.requiresAuthorization != true)
        }

        // Losing the first Keychain write after rotation must not cause a second
        // exchange of an already-consumed refresh token.
        do {
            let store = MemoryStore()
            let old = token("before-save-failure", remaining: -1, refresh: "synthetic-refresh-save-old")
            let fresh = token("after-save-failure", refresh: "synthetic-refresh-save-new")
            store.values[1] = old
            store.failedSavesRemaining = 2
            var attempts = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in attempts += 1; return fresh }
            try await rejectsAsync("rotation save failure is storage error", .storage) { _ = try await session.credential(accountID: 1) }
            try check("failed rotation save does not publish success", try session.stored(accountID: 1) == old && store.values[1] == old)
            try await rejectsAsync("persistent save failure only retries save", .storage) { _ = try await session.credential(accountID: 1) }
            let result = try await session.credential(accountID: 1)
            try check("recovered save publishes latest credential", result == fresh && store.values[1] == fresh)
            try check("save retries never replay consumed refresh", attempts == 1 && store.saves.count == 1)
        }

        do {
            let store = MemoryStore()
            store.values[1] = token("rejected-save", remaining: -1, refresh: "synthetic-refresh-rejected-save")
            store.failedSavesRemaining = 1
            var attempts = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in attempts += 1; throw NativeAuthError.loginRequired }
            try await rejectsAsync("rejection-marker save failure remains storage error", .storage) { _ = try await session.credential(accountID: 1) }
            try await rejectsAsync("rejection marker save retried without token request", .loginRequired) { _ = try await session.credential(accountID: 1) }
            try check("persisted rejection retry does not consume refresh again", attempts == 1 && store.values[1]?.requiresAuthorization == true)
        }

        do {
            let store = MemoryStore()
            store.failLoads = true
            var attempts = 0
            let session = NativeSession(storage: store, now: { epoch }) { _ in attempts += 1; throw NativeAuthError.network }
            try await rejectsAsync("locked storage is not reported as logout", .storage) { _ = try await session.credential(accountID: 1) }
            try check("storage read failure does not clear or refresh", attempts == 0 && store.clears.isEmpty)
        }

        // Each UID has its own flight and destination, even when completions arrive
        // in the opposite order from initiation.
        do {
            let store = MemoryStore()
            store.values[1] = token("uid-one-old", remaining: -1, refresh: "synthetic-refresh-one")
            store.values[2] = token("uid-two-old", remaining: -1, refresh: "synthetic-refresh-two")
            let one = token("uid-one-new", refresh: "synthetic-refresh-one-new")
            let two = token("uid-two-new", refresh: "synthetic-refresh-two-new")
            let gate = Gate()
            let session = NativeSession(storage: store, now: { epoch }, refresh: gate.refresh)
            let first = Task { @MainActor in try await session.credential(accountID: 1) }
            await gate.waitForCalls(1)
            let second = Task { @MainActor in try await session.credential(accountID: 2) }
            await gate.waitForCalls(2)
            try gate.finish("synthetic-refresh-two", .success(two))
            let secondResult = try await second.value
            try gate.finish("synthetic-refresh-one", .success(one))
            let firstResult = try await first.value
            try check("two UID flights can run independently", gate.calls.count == 2)
            try check("out-of-order completions retain UID ownership", firstResult == one && secondResult == two && store.values[1] == one && store.values[2] == two)
        }

        // Removing or replacing the grant invalidates the generation of an old
        // in-flight response, including one whose transport ignores cancellation.
        for replace in [false, true] {
            let store = MemoryStore()
            store.values[1] = token("stale", remaining: -1, refresh: "synthetic-refresh-stale")
            let gate = Gate()
            let session = NativeSession(storage: store, now: { epoch }, refresh: gate.refresh)
            let pending = Task { @MainActor in try await session.credential(accountID: 1) }
            await gate.waitForCalls(1)
            let replacement = token("replacement", refresh: "synthetic-refresh-replacement")
            if replace { try session.adopt(replacement, accountID: 1) }
            else { session.remove(accountID: 1) }
            let writesBeforeResponse = store.saves.count
            try gate.finish("synthetic-refresh-stale", .success(token("late", refresh: "synthetic-refresh-late")))
            try await rejectsAsync("old generation response is rejected", .accountChanged) { _ = try await pending.value }
            try check("late response cannot persist", store.saves.count == writesBeforeResponse)
            if replace {
                try check("late response cannot overwrite reauthorized grant", store.values[1] == replacement)
            } else {
                try check("late response cannot resurrect removed account", store.values[1] == nil)
            }
        }

        do {
            let store = MemoryStore()
            store.values[1] = token("late-rejection", remaining: -1, refresh: "synthetic-refresh-late-rejection")
            let gate = Gate()
            let session = NativeSession(storage: store, now: { epoch }, refresh: gate.refresh)
            let pending = Task { @MainActor in try await session.credential(accountID: 1) }
            await gate.waitForCalls(1)
            let replacement = token("successful-reauthorization", refresh: "synthetic-refresh-reauthorized")
            try session.adopt(replacement, accountID: 1)
            try gate.finish("synthetic-refresh-late-rejection", .failure(NativeAuthError.loginRequired))
            try await rejectsAsync("late rejection from old generation is ignored", .accountChanged) { _ = try await pending.value }
            try check("late rejection cannot invalidate new grant", store.values[1] == replacement && store.values[1]?.requiresAuthorization != true)
        }

        return count
    }

}

#if NATIVE_SESSION_HARNESS
@main
enum NativeSessionHarness {
    static func main() async {
        do {
            let count = try await NativeSessionContractChecks.run()
            print("Native production session checks passed: \(count)")
        } catch let failure as NativeSessionContractChecks.Failure {
            fputs("Native session contract failed: \(failure.name)\n", stderr)
            exit(1)
        } catch {
            fputs("Native session contract failed with a local test/setup error\n", stderr)
            exit(1)
        }
    }
}
#else
final class NativeSessionTests: XCTestCase {
    @MainActor
    func testProductionSessionContracts() async throws {
        let count = try await NativeSessionContractChecks.run()
        XCTAssertGreaterThan(count, 70)
    }
}
#endif
