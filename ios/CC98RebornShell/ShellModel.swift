import SwiftUI
import WebKit
import UIKit

enum ShellMode: String { case original, enhanced
    var title: String { self == .original ? "原站模式" : "Reborn 验证" }
}

// The web page owns the forum session; the shell can only report what the
// isolated-world receiver answers. Failure to read is never treated as
// "signed out" (MOBILE_UI_SPEC.md 14.1).
enum WebAccountState: Equatable {
    case unknown, checking, unavailable, signedIn(String)
}

enum ShellTab: String, CaseIterable, Identifiable {
    case browse, boards, messages, me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: return "浏览"
        case .boards: return "版面"
        case .messages: return "消息"
        case .me: return "我的"
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "list.bullet.rectangle"
        case .boards: return "square.grid.2x2"
        case .messages: return "bubble.left.and.bubble.right"
        case .me: return "person.crop.circle"
        }
    }

    // Board directory and message categories use the original site routes.
    var defaultURL: URL? {
        switch self {
        case .browse: return ShellPolicy.home
        case .boards: return URL(string: "https://www.cc98.org/boardList")
        case .messages: return URL(string: "https://www.cc98.org/message/response")
        case .me: return nil
        }
    }

    var accessibilityIdentifier: String { "tab-" + rawValue }
}

struct TabPosition {
    var url: URL
    var scrollY: Double = 0
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
    enum Content { case diagnostics, safari(URL), share([Any]), popup(WKWebView) }
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
    @Published var selectedTab: ShellTab = .browse
    @Published var isReading = false
    @Published var isKeyboardVisible = false
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
    private var tabPositions: [ShellTab: TabPosition] = [:]
    private var pendingScroll: (tab: ShellTab, y: Double)?
    private var lastWebTab: ShellTab = .browse
    private var keyboardObservers: [NSObjectProtocol] = []
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
        keyboardObservers = [
            NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isKeyboardVisible = true }
            },
            NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isKeyboardVisible = false }
            }
        ]
        for tab in ShellTab.allCases {
            if let url = tab.defaultURL { tabPositions[tab] = TabPosition(url: url) }
        }
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
            isReading = false
            if isUITesting { loadInitial(webView); return }
            webView?.load(URLRequest(url: ShellPolicy.home))
        case .mode(let selected):
            let current = webView?.url
            mode = selected
            let targetTab = selectedTab == .me ? lastWebTab : selectedTab
            let url: URL
            if selectedTab != .me, let current, ShellPolicy.isTopic(current) {
                url = current
            } else {
                url = tabPositions[targetTab]?.url ?? ShellPolicy.home
            }
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
        isReading = selectedTab != .me && ShellPolicy.isTopic(url)
        pendingScroll = nil
        errorMessage = nil
        runtimeState = mode == .original ? "未启用增强" : "等待官方页面；尚未验证注入"
        observations = [
            browser.observe(\.url, options: [.new]) { [weak self] browser, _ in Task { @MainActor in guard browser === self?.webView else { return }; self?.oauth.cancel(); self?.navigationChanged(to: browser.url) } },
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
            browser.configuration.userContentController.addUserScript(WKUserScript(source: Self.routeObserverPageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            browser.configuration.userContentController.addUserScript(WKUserScript(source: Self.routeObserverWorldScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .world(name: ShellPolicy.worldName)))
            runtimeState = "注入脚本已安排；等待文档报告"
        } catch {
            browser.configuration.userContentController.removeAllUserScripts()
            errorMessage = "增强脚本加载失败。请切回原站模式；不会修改论坛数据。"
            runtimeState = "增强资源错误"
            record("assets.load.failed")
        }
    }

    func selectTab(_ tab: ShellTab) {
        guard tab != selectedTab, !isReading else { return }
        let previous = selectedTab
        guard previous != .me, let browser = webView else {
            activate(tab)
            return
        }
        let currentURL = browser.url
        browser.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let y = (result as? NSNumber)?.doubleValue ?? 0
                if var position = self.tabPositions[previous] {
                    if let currentURL { position.url = currentURL }
                    position.scrollY = y
                    self.tabPositions[previous] = position
                }
                self.activate(tab)
            }
        }
    }

    private func activate(_ tab: ShellTab) {
        selectedTab = tab
        guard tab != .me else { return }
        lastWebTab = tab
        isReading = false
        guard let browser = webView else { return }
        if isUITesting { loadInitial(browser); return }
        let position = tabPositions[tab] ?? TabPosition(url: tab.defaultURL ?? ShellPolicy.home)
        if browser.url != position.url {
            pendingScroll = (tab, position.scrollY)
            browser.load(URLRequest(url: position.url))
        } else if position.scrollY > 0 {
            restoreScroll(position.scrollY)
        }
    }

    func navigationChanged(to url: URL?) {
        guard selectedTab != .me, let url, ShellPolicy.isForum(url) else { return }
        if ShellPolicy.isTopic(url) {
            if !isReading { isReading = true }
            return
        }
        if isReading { isReading = false }
        guard var position = tabPositions[selectedTab] else { return }
        position.url = url
        tabPositions[selectedTab] = position
    }

    // The route observer reports pushState/replaceState/popstate changes that
    // WKWebView's URL KVO can miss. Only the path is accepted; queries and
    // page content never enter the native layer.
    func navigationChanged(path: String) {
        guard selectedTab != .me, path.hasPrefix("/"), path.count <= 200 else { return }
        if path.range(of: "^/topic/[0-9]+(?:/[0-9]+)?/?$", options: .regularExpression) != nil {
            if !isReading { isReading = true }
            return
        }
        if isReading { isReading = false }
        guard var position = tabPositions[selectedTab], let url = URL(string: "https://www.cc98.org" + path) else { return }
        position.url = url
        tabPositions[selectedTab] = position
    }

    func closeReading() {
        guard isReading else { return }
        if let browser = webView, browser.canGoBack {
            browser.goBack()
            return
        }
        isReading = false
        if let position = tabPositions[selectedTab], webView?.url != position.url {
            pendingScroll = (selectedTab, position.scrollY)
            webView?.load(URLRequest(url: position.url))
        }
    }

    func openReading(url: URL) {
        guard ShellPolicy.isTopic(url) else { return }
        isReading = true
        webView?.load(URLRequest(url: url))
    }

    func restorePendingScroll(_ browser: WKWebView) {
        guard browser === webView, let pending = pendingScroll, pending.tab == selectedTab else { return }
        pendingScroll = nil
        restoreScroll(pending.y)
    }

    private func restoreScroll(_ y: Double) {
        guard y > 0, let browser = webView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            browser.evaluateJavaScript("window.scrollTo(0, \(y));", completionHandler: nil)
        }
    }

    private static let routeObserverPageScript = """
    (() => {
      const notify = () => {
        try { window.dispatchEvent(new Event('cc98-ios-route')); } catch {}
      };
      try {
        for (const method of ['pushState', 'replaceState']) {
          const original = history[method];
          if (typeof original !== 'function') continue;
          history[method] = function (...args) {
            const value = original.apply(this, args);
            notify();
            return value;
          };
        }
      } catch {}
      window.addEventListener('popstate', notify);
      window.addEventListener('hashchange', notify);
    })();
    """

    private static let routeObserverWorldScript = """
    (() => {
      const handler = window.webkit?.messageHandlers?.reborn;
      if (!handler) return;
      const report = () => {
        try {
          const reply = handler.postMessage({ command: 'host.route', args: { path: location.pathname } });
          if (reply && typeof reply.catch === 'function') reply.catch(() => {});
        } catch {}
      };
      try {
        for (const method of ['pushState', 'replaceState']) {
          const original = history[method];
          if (typeof original !== 'function') continue;
          history[method] = function (...args) {
            const value = original.apply(this, args);
            report();
            return value;
          };
        }
      } catch {}
      window.addEventListener('cc98-ios-route', report);
      report();
    })();
    """

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
        if ShellPolicy.isTopic(url) { openReading(url: url); return }
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
