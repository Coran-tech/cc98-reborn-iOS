import AuthenticationServices
import WebKit

@MainActor
final class NativeOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    weak var model: ShellModel?
    private var operationID: UUID?
    private var attempt: OAuthAttempt?
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var work: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var reply: (([String: Any]) -> Void)?
    private var retryPolicy = OAuthRetryPolicy()
    var isBusy: Bool { operationID != nil }
    init(model: ShellModel?) { self.model = model }

    func state() -> [String: Any] {
        ["ok": true, "configured": true, "busy": isBusy, "binding": model?.settings?.binding?.dictionary as Any? ?? NSNull()]
    }

    func login(expectedAccount: Any?, completion: @escaping ([String: Any]) -> Void) {
        guard !isBusy else { completion(OAuthFailure.busy.response); return }
        guard let model, model.mode == .enhanced, !model.isUITesting, model.settings != nil,
              let browser = model.webView, ShellPolicy.isForum(browser.url), let window = browser.window else {
            completion(OAuthFailure.noWebAccount.response); return
        }
        let expected: String?
        if let expectedAccount {
            guard let account = expectedAccount as? [String: Any], let id = OAuthProtocol.userID(account["userId"]) else {
                completion(OAuthFailure.noWebAccount.response); return
            }
            expected = id
        } else { expected = nil } // Native retry reads the same existing content receiver.
        let operation = UUID(), document = model.viewID, pageURL = browser.url
        operationID = operation; reply = completion; anchor = window
        model.authStatus = "正在核对当前网页账号"
        model.authBusy = true
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, self?.operationID == operation else { return }
            self?.cancel(.expired)
        }
        work = Task { [weak self, weak browser] in
            guard let self, let browser else { return }
            do {
                let id = try await self.readAccount(browser)
                try self.validate(operation, browser: browser, document: document, pageURL: pageURL)
                if let expected, expected != id { throw OAuthFailure.accountMismatch }
                self.attempt = OAuthAttempt(userID: id, documentID: document)
                self.beginSession(operation: operation, browser: browser, pageURL: pageURL)
                self.watchAccount(operation: operation, browser: browser, pageURL: pageURL)
            } catch { self.fail(error, operation: operation) }
        }
    }

    private func beginSession(operation: UUID, browser: WKWebView, pageURL: URL?) {
        guard let attempt, operationID == operation else { return }
        let authentication = ASWebAuthenticationSession(url: OAuthProtocol.authorizationURL(state: attempt.state, verifier: attempt.verifier, forceLogin: retryPolicy.forceLogin), callbackURLScheme: OAuthProtocol.callbackScheme) { [weak self, weak browser] callback, error in
            Task { @MainActor in
                guard let self, let browser, self.operationID == operation else { return }
                guard let callback else {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    self.cancel(cancelled ? .cancelled : .unavailable)
                    return
                }
                self.received(callback, operation: operation, browser: browser, pageURL: pageURL)
            }
        }
        authentication.presentationContextProvider = self
        authentication.prefersEphemeralWebBrowserSession = false
        session = authentication // Strong retention until callback/cancellation.
        model?.authStatus = retryPolicy.forceLogin ? "请在系统授权窗口重新登录，选择与网页相同的 CC98 账号" : "请在系统授权窗口使用与网页相同的 CC98 账号"
        if !authentication.start() { cancel(.unavailable) }
    }

    private func received(_ callback: URL, operation: UUID, browser: WKWebView, pageURL: URL?) {
        do {
            guard var current = attempt else { throw OAuthFailure.stale }
            try validate(operation, browser: browser, document: current.documentID, pageURL: pageURL)
            let code = try current.accept(callback)
            attempt = current
            session = nil
            model?.authStatus = "正在验证授权账号与水印"
            work = Task { [weak self, weak browser] in
                guard let self, let browser else { return }
                do {
                    let binding = try await OAuthHTTPClient().binding(code: code, verifier: current.verifier, userID: current.userID)
                    let account = try await self.readAccount(browser)
                    try self.validate(operation, browser: browser, document: current.documentID, pageURL: pageURL)
                    guard var live = self.attempt else { throw OAuthFailure.stale }
                    try live.complete(userID: account, documentID: current.documentID)
                    guard let store = self.model?.settings else { throw OAuthFailure.storage }
                    let changes: [String: Any]
                    do { changes = try store.setNativeBinding(binding) } catch { throw OAuthFailure.storage }
                    self.retryPolicy.didBind()
                    self.attempt = live
                    self.model?.notifyBindingChanges(changes)
                    self.model?.authStatus = "已核对同一 UID，可信水印摘要已保存在本机"
                    self.finish(["ok": true, "binding": binding.dictionary])
                } catch { self.fail(error, operation: operation) }
            }
        } catch { fail(error, operation: operation) }
    }

    private func validate(_ operation: UUID, browser: WKWebView, document: UUID, pageURL: URL?) throws {
        guard operationID == operation, let model, model.mode == .enhanced, model.webView === browser,
              model.viewID == document, browser.url == pageURL, ShellPolicy.isForum(browser.url) else { throw OAuthFailure.stale }
    }

    private func watchAccount(operation: UUID, browser: WKWebView, pageURL: URL?) {
        monitor = Task { [weak self, weak browser] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let browser, self.operationID == operation, let attempt = self.attempt else { return }
                do {
                    let id = try await self.readAccount(browser)
                    try self.validate(operation, browser: browser, document: attempt.documentID, pageURL: pageURL)
                    try attempt.check(userID: id, documentID: attempt.documentID)
                } catch { self.fail(error, operation: operation); return }
            }
        }
    }

    // Calls only the existing isolated-world account receiver. No forum token leaves WK.
    private func readAccount(_ browser: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var answered = false
            let timeout = DispatchWorkItem {
                guard !answered else { return }; answered = true
                continuation.resume(throwing: OAuthFailure.noWebAccount)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            browser.callAsyncJavaScript("return await globalThis.__CC98IOS__.dispatchMessage({type:'CC98_REBORN_GET_CURRENT_WEB_ACCOUNT'});", arguments: [:], in: nil, in: .world(name: ShellPolicy.worldName), completionHandler: { result in
                guard !answered else { return }; answered = true; timeout.cancel()
                guard case .success(let raw) = result, let response = raw as? [String: Any], response["ok"] as? Bool == true,
                      let account = response["account"] as? [String: Any], let id = OAuthProtocol.userID(account["userId"]) else {
                    continuation.resume(throwing: OAuthFailure.noWebAccount); return
                }
                continuation.resume(returning: id)
            })
        }
    }

    func logout() -> [String: Any] {
        cancel(.cancelled)
        guard let store = model?.settings else { return OAuthFailure.storage.response }
        do {
            let changes = try store.setNativeBinding(nil)
            model?.notifyBindingChanges(changes)
            model?.authStatus = "本机绑定已解除；论坛登录未退出"
            return ["ok": true, "binding": NSNull(), "localOnly": true]
        } catch { return OAuthFailure.storage.response }
    }

    func cancel(_ error: OAuthFailure = .stale) {
        guard isBusy else { return }
        retryPolicy.failed(error)
        attempt?.cancel()
        model?.authStatus = error.message
        finish(error.response)
    }
    private func fail(_ error: Error, operation: UUID) {
        guard operationID == operation else { return }
        cancel(error as? OAuthFailure ?? .unavailable)
    }
    private func finish(_ result: [String: Any]) {
        let completion = reply
        reply = nil; operationID = nil; attempt = nil
        work?.cancel(); work = nil; monitor?.cancel(); monitor = nil; deadline?.cancel(); deadline = nil
        let old = session; session = nil; old?.cancel(); anchor = nil
        model?.authBusy = false
        // The result contains only a fixed error or trusted summary, never an OAuth credential.
        completion?(result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor ?? ASPresentationAnchor() }
}
