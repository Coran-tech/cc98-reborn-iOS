import SwiftUI
import WebKit

enum ShellMode: String { case original, enhanced
    var title: String { self == .original ? "原站模式" : "Reborn 验证" }
}

// The web page owns the forum session; the shell can only report what the
// isolated-world receiver answers. Failure to read is never treated as
// "signed out" (MOBILE_UI_SPEC.md 14.1).
enum WebAccountState: Equatable {
    case unknown, checking, unavailable, signedIn(String)
}

enum ShellAction: Identifiable {
    case reload, home, mode(ShellMode)
    var id: String { switch self { case .reload: return "reload"; case .home: return "home"; case .mode(let mode): return mode.rawValue } }
    var detail: String {
        switch self {
        case .reload: return "重新加载会丢失尚未保存的编辑内容。若刚刚提交但结果不明，请先确认结果，避免重复发帖。"
        case .home: return "返回首页可能丢失尚未保存的编辑内容。"
        case .mode(let mode): return "切换到\(mode.title)会新建网页并重新加载当前地址，未提交的内容可能丢失。论坛登录数据会保留。"
        }
    }
}

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let event: String
    let details: String
}

struct ShellSheet: Identifiable {
    let id = UUID()
    enum Content { case diagnostics, my, safari(URL), share([Any]), popup(WKWebView) }
    let content: Content
}

@MainActor
final class ShellModel: ObservableObject {
    @Published var webView: WKWebView?
    @Published var viewID = UUID()
    @Published var mode: ShellMode = .original
    @Published var host = "www.cc98.org"
    @Published var status = "准备连接"
    @Published var errorMessage: String?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var pendingAction: ShellAction?
    @Published var sheet: ShellSheet?
    @Published var diagnostics: [DiagnosticEntry] = []
    @Published var completedDownloads: [URL] = []
    @Published var runtimeState = "未启用增强"
    @Published var authStatus = "尚未绑定；请使用网页遮罩中的同账号绑定按钮"
    @Published var authBusy = false
    @Published var authBound = false
    @Published var pageTitle = ""
    @Published var webAccount: WebAccountState = .unknown
    let dataStore: WKWebsiteDataStore
    let assets: RebornAssets?
    let settings: LocalSettingsStore?
    let assetIssue: String?
    let settingsIssue: String?
    let isUITesting: Bool
    private var coordinator: BrowserCoordinator?
    private var popupCoordinator: BrowserCoordinator?
    private var popupWebView: WKWebView?
    private var lastRequestedURL = ShellPolicy.home
    private var observations: [NSKeyValueObservation] = []
    private var accountProbeID = UUID()
    lazy var downloads = NativeDownloads(model: self)
    lazy var oauth = NativeOAuth(model: self)

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let key = "cc98.shell.websiteDataStoreID"
        let identifier = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identifier.uuidString, forKey: key)
        dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        #if DEBUG
        isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing-offline")
        #else
        isUITesting = false
        #endif
        do {
            guard let resourceURL = bundle.resourceURL else { throw BridgeFailure.unsupported }
            assets = try RebornAssets(root: resourceURL.appendingPathComponent("Reborn", isDirectory: true))
            assetIssue = nil
        } catch { assets = nil; assetIssue = "增强资源未能完整读取，请重新运行资源打包与构建。原站模式仍可使用。" }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            settings = try LocalSettingsStore(file: support.appendingPathComponent("Reborn/settings.json"))
            settingsIssue = nil
        } catch { settings = nil; settingsIssue = "本地增强设置无法读取；保留原文件，原站模式仍可使用。" }
        authBound = settings?.binding != nil
        if authBound { authStatus = "已读取本机可信绑定摘要；网页仍会核对当前 UID" }
        replaceWebView(url: ShellPolicy.home)
    }

    var extensionVersion: String { assets?.index.extensionVersion ?? "未打包" }

    func request(_ action: ShellAction) { pendingAction = action }
    func perform(_ action: ShellAction) {
        oauth.cancel()
        switch action {
        case .reload:
            if isUITesting { loadInitial(webView); return }
            if webView?.url == nil { webView?.load(URLRequest(url: lastRequestedURL)) }
            else { webView?.reload() }
        case .home:
            if isUITesting { loadInitial(webView); return }
            webView?.load(URLRequest(url: ShellPolicy.home))
        case .mode(let selected):
            let current = webView?.url
            mode = selected
            let url = ShellPolicy.isWebURL(current) ? current! : ShellPolicy.home
            replaceWebView(url: url)
        }
    }

    private func replaceWebView(url: URL) {
        closePopup()
        observations.removeAll()
        if let old = webView {
            old.stopLoading()
            old.configuration.userContentController.removeAllUserScripts()
            old.configuration.userContentController.removeAllScriptMessageHandlers()
            old.navigationDelegate = nil
            old.uiDelegate = nil
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.allowsInlineMediaPlayback = true
        config.applicationNameForUserAgent = "CC98RebornShell/0.2"
        if let assets { config.setURLSchemeHandler(RebornAssetHandler(assets: assets), forURLScheme: "reborn-asset") }
        let delegate = BrowserCoordinator(model: self, isPopup: false)
        coordinator = delegate
        if mode == .enhanced {
            config.userContentController.addScriptMessageHandler(delegate, contentWorld: .world(name: ShellPolicy.worldName), name: ShellPolicy.bridgeName)
        }
        let browser = WKWebView(frame: .zero, configuration: config)
        browser.navigationDelegate = delegate
        browser.uiDelegate = delegate
        browser.allowsBackForwardNavigationGestures = true
        browser.scrollView.keyboardDismissMode = .interactive
        #if DEBUG
        browser.isInspectable = true
        #endif
        webView = browser
        viewID = UUID()
        canGoBack = false; canGoForward = false; isLoading = false; progress = 0
        pageTitle = ""
        webAccount = .unknown
        accountProbeID = UUID()
        errorMessage = nil
        runtimeState = mode == .original ? "未启用增强" : "等待官方页面；尚未验证注入"
        observations = [
            browser.observe(\.url, options: [.new]) { [weak self] browser, _ in Task { @MainActor in guard browser === self?.webView else { return }; self?.oauth.cancel() } },
            browser.observe(\.estimatedProgress, options: [.new]) { [weak self] browser, _ in Task { @MainActor in guard browser === self?.webView else { return }; self?.progress = browser.estimatedProgress } },
            browser.observe(\.canGoBack, options: [.new]) { [weak self] browser, _ in Task { @MainActor in guard browser === self?.webView else { return }; self?.canGoBack = browser.canGoBack } },
            browser.observe(\.canGoForward, options: [.new]) { [weak self] browser, _ in Task { @MainActor in guard browser === self?.webView else { return }; self?.canGoForward = browser.canGoForward } },
            browser.observe(\.isLoading, options: [.new]) { [weak self] browser, _ in Task { @MainActor in guard browser === self?.webView else { return }; self?.isLoading = browser.isLoading } },
            browser.observe(\.title, options: [.new]) { [weak self] browser, _ in Task { @MainActor in guard browser === self?.webView else { return }; self?.pageTitle = browser.title ?? "" } }
        ]
        configureScripts(for: url, browser: browser)
        record("session.created", details: ["mode": mode.rawValue])
        loadInitial(browser, url: url)
    }

    private func loadInitial(_ browser: WKWebView?, url: URL = ShellPolicy.home) {
        if isUITesting {
            errorMessage = "UI 测试离线场景：未连接 CC98，未验证论坛登录或增强功能。"
            let fixture = "fixtures/runtime-smoke.html"
            if assets?.allowed.contains(fixture) == true {
                browser?.load(URLRequest(url: URL(string: "reborn-asset://bundle/" + fixture)!))
            } else { browser?.loadHTMLString("<!doctype html><meta name='viewport' content='width=device-width'><h1>本地壳验证</h1><p>没有网络或账号数据。</p>", baseURL: nil) }
            return
        }
        browser?.load(URLRequest(url: url))
    }

    func configureScripts(for url: URL?, browser: WKWebView) {
        guard browser === webView else { return }
        oauth.cancel()
        if let url, ShellPolicy.isWebURL(url) { lastRequestedURL = url }
        browser.configuration.userContentController.removeAllUserScripts()
        guard mode == .enhanced, ShellPolicy.isForum(url) else { return }
        guard let assets, settings != nil else {
            errorMessage = assetIssue ?? settingsIssue
            runtimeState = "增强未加载"
            return
        }
        do {
            for script in try assets.scripts() { browser.configuration.userContentController.addUserScript(script) }
            runtimeState = "注入脚本已安排；等待文档报告"
        } catch {
            browser.configuration.userContentController.removeAllUserScripts()
            errorMessage = "增强脚本加载失败。请切回原站模式；不会修改论坛数据。"
            runtimeState = "增强资源错误"
            record("assets.load.failed")
        }
    }

    func update(_ browser: WKWebView) {
        guard browser === webView else { return }
        host = browser.url?.host ?? (isUITesting ? "本地测试" : "www.cc98.org")
        pageTitle = browser.title ?? pageTitle
        canGoBack = browser.canGoBack
        canGoForward = browser.canGoForward
        isLoading = browser.isLoading
        progress = browser.estimatedProgress
    }

    func stopLoading() {
        webView?.stopLoading()
        status = "已停止加载；可重新加载或返回首页"
        record("navigation.stopped")
    }

    func record(_ event: String, details: [String: String] = [:]) {
        diagnostics.append(DiagnosticEntry(event: SafeDiagnostics.event(event), details: details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · ")))
        if diagnostics.count > 100 { diagnostics.removeFirst(diagnostics.count - 100) }
    }

    func share(_ items: [Any]) throws {
        guard sheet == nil else { throw BridgeFailure(code: "UI_BUSY", message: "请先关闭当前窗口，再分享。") }
        sheet = ShellSheet(content: .share(items))
    }

    func open(_ url: URL, target: String) throws {
        guard ShellPolicy.isWebURL(url) else { throw BridgeFailure(code: "URL_DENIED", message: "只允许打开 HTTP/HTTPS 网页地址。") }
        if ShellPolicy.isForum(url), target != "_blank" && target != "new" { webView?.load(URLRequest(url: url)); return }
        guard sheet == nil else { throw BridgeFailure(code: "UI_BUSY", message: "请先关闭当前窗口。") }
        if ShellPolicy.isForum(url) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = dataStore
            _ = makePopup(configuration: config, request: URLRequest(url: url), loadRequest: true)
        } else { sheet = ShellSheet(content: .safari(url)) }
    }

    func makePopup(configuration: WKWebViewConfiguration, request: URLRequest?, loadRequest: Bool) -> WKWebView? {
        guard sheet == nil else { record("popup.blocked.busy"); return nil }
        // Popup/auth pages deliberately have no Reborn bridge or injection in this validation build.
        configuration.userContentController = WKUserContentController()
        configuration.websiteDataStore = dataStore
        let popup = WKWebView(frame: .zero, configuration: configuration)
        let delegate = BrowserCoordinator(model: self, isPopup: true)
        popupCoordinator = delegate
        popupWebView = popup
        popup.navigationDelegate = delegate
        popup.uiDelegate = delegate
        popup.allowsBackForwardNavigationGestures = true
        sheet = ShellSheet(content: .popup(popup))
        if loadRequest, let request { popup.load(request) }
        record("popup.opened.original")
        return popup
    }

    func closePopup() {
        if let popup = popupWebView {
            popup.stopLoading(); popup.uiDelegate = nil; popup.navigationDelegate = nil
            if case .popup? = sheet?.content { sheet = nil }
        }
        popupWebView = nil
        popupCoordinator = nil
    }

    func sheetDismissed() { closePopup() }

    func notifyBindingChanges(_ changes: [String: Any]) {
        authBound = settings?.binding != nil
        if mode == .enhanced { refreshWebAccount() }
        guard !changes.isEmpty, mode == .enhanced, let browser = webView, ShellPolicy.isForum(browser.url) else { return }
        browser.callAsyncJavaScript("globalThis.__CC98IOS__?.receiveStorageChanges(changes, 'local');", arguments: ["changes": changes], in: nil, in: .world(name: ShellPolicy.worldName), completionHandler: { [weak self] result in
            if case .failure = result { self?.record("auth.notification.failed") }
        })
    }

    func retryBinding() { oauth.login(expectedAccount: nil) { [weak self] result in
        if result["ok"] as? Bool != true { self?.authStatus = result["error"] as? String ?? OAuthFailure.unavailable.message }
    } }

    func refreshWebAccountIfNeeded() {
        if case .unknown = webAccount { refreshWebAccount() }
    }

    // Reads the account through the existing isolated-world receiver only; no
    // cookie or token enters Swift. A timeout or missing receiver is reported
    // as "unavailable", never as a signed-out state.
    func refreshWebAccount() {
        guard mode == .enhanced, !isUITesting, let browser = webView, ShellPolicy.isForum(browser.url) else {
            webAccount = .unknown
            return
        }
        let probe = UUID()
        accountProbeID = probe
        webAccount = .checking
        var answered = false
        let complete: (WebAccountState) -> Void = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                guard self.accountProbeID == probe else { return }
                self.webAccount = state
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !answered else { return }
            answered = true
            complete(.unavailable)
        }
        browser.callAsyncJavaScript(
            "return await globalThis.__CC98IOS__?.dispatchMessage({type:'CC98_REBORN_GET_CURRENT_WEB_ACCOUNT'});",
            arguments: [:], in: nil, in: .world(name: ShellPolicy.worldName)
        ) { result in
            guard !answered else { return }
            answered = true
            guard case .success(let raw) = result,
                  let response = raw as? [String: Any],
                  response["ok"] as? Bool == true,
                  let account = response["account"] as? [String: Any],
                  let id = OAuthProtocol.userID(account["userId"]) else {
                complete(.unavailable)
                return
            }
            complete(.signedIn(id))
        }
    }

    func switchMode(_ mode: ShellMode) {
        guard mode != self.mode else { return }
        sheet = nil
        perform(.mode(mode))
    }

    func confirmDownload(url: URL, browser: WKWebView, completion: @escaping (Bool) -> Void) {
        NativePrompt.confirm(on: browser, title: "下载文件", message: "将从 \(url.host ?? "网页") 下载到临时目录，完成后可分享或存储到“文件”。", completion: completion)
    }
}
