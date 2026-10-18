import UIKit
import WebKit

@MainActor
final class BrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    weak var model: ShellModel?
    let isPopup: Bool
    init(model: ShellModel, isPopup: Bool) { self.model = model; self.isPopup = isPopup }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true, !isPopup { model?.configureScripts(for: url, browser: webView) }
        if url.scheme == "reborn-asset" {
            let fixture = model?.isUITesting == true && ShellPolicy.assetPath(from: url) == "fixtures/runtime-smoke.html"
            let filter = ShellPolicy.allowsFilterFrame(url: url, isMainFrame: navigationAction.targetFrame?.isMainFrame, topURL: webView.url, enhanced: model?.mode == .enhanced, isPopup: isPopup)
                && model?.assets?.allowed.contains("src/content-filter-frame.html") == true
            if filter { model?.record("filter.frame.allowed") }
            decisionHandler(fixture || filter ? .allow : .cancel); return
        }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if url.scheme == "blob", ShellPolicy.isAllowedOrigin(scheme: navigationAction.sourceFrame.securityOrigin.protocol, host: navigationAction.sourceFrame.securityOrigin.host, port: navigationAction.sourceFrame.securityOrigin.port) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow); return
        }
        guard ShellPolicy.isWebURL(url) else {
            decisionHandler(.cancel)
            if ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                NativePrompt.confirm(on: webView, title: "打开系统应用", message: "此链接将离开网页并打开系统应用。") { accepted in
                    if accepted { UIApplication.shared.open(url) }
                }
            } else { model?.record("navigation.scheme.denied") }
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if !isPopup, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType == .linkActivated, !ShellPolicy.isForum(url), url.host != "openid.cc98.org" {
            decisionHandler(.cancel)
            do { try model?.open(url, target: "_blank") } catch { model?.errorMessage = "请关闭当前窗口后再打开外部链接。" }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
        if !navigationResponse.canShowMIMEType || attachment { decisionHandler(.download); return }
        if let status = http?.statusCode, status >= 400 {
            model?.record("navigation.http.error", details: ["status": String(status)])
            if !isPopup { model?.errorMessage = "网站返回 HTTP \(status)。原页面内容保留；请确认登录、访问权限及网络。" }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if !isPopup {
            if model?.isUITesting != true { model?.errorMessage = nil }
            model?.status = "正在连接"
            model?.update(webView)
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { model?.update(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isPopup else { return }
        model?.status = model?.isUITesting == true ? "本地测试夹具 · 未连接论坛" : "页面已加载 · 功能需手动验证"
        model?.update(webView)
        model?.record("navigation.finished")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    private func failed(_ webView: WKWebView, error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        let safe = SafeDiagnostics.networkMessage(error)
        if isPopup { NativePrompt.alert(on: webView, title: "新窗口加载失败", message: safe, completion: {}) }
        else { model?.errorMessage = safe; model?.status = "连接失败"; model?.update(webView) }
        model?.record("navigation.failed", details: ["code": String((error as NSError).code)])
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if !isPopup { model?.oauth.cancel() }
        model?.record("webprocess.terminated")
        if isPopup { model?.closePopup() }
        model?.errorMessage = "网页进程已终止。未自动重发任何请求；请确认草稿和提交结果后重载或切回原站。"
        model?.runtimeState = "网页进程已停止"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url,
              ShellPolicy.isWebURL(url) || url.absoluteString == "about:blank" else { return nil }
        return model?.makePopup(configuration: configuration, request: navigationAction.request, loadRequest: false)
    }
    func webViewDidClose(_ webView: WKWebView) { if isPopup { model?.closePopup() } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        NativePrompt.alert(on: webView, title: "网页提示 · \(frame.securityOrigin.host)", message: String(message.prefix(2000)), completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        NativePrompt.confirm(on: webView, title: "网页确认 · \(frame.securityOrigin.host)", message: String(message.prefix(2000)), completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        NativePrompt.text(on: webView, title: "网页输入 · \(frame.securityOrigin.host)", message: String(prompt.prefix(2000)), defaultText: defaultText, completion: completionHandler)
    }
    // Intentionally do not implement runOpenPanel. On iOS the system provides Safari-style file/photo/camera selection.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { model?.downloads.register(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { model?.downloads.register(download) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let model, !isPopup, model.mode == .enhanced, message.webView === model.webView,
              message.frameInfo.isMainFrame, message.world.name == ShellPolicy.worldName,
              ShellPolicy.isAllowedOrigin(scheme: message.frameInfo.securityOrigin.protocol, host: message.frameInfo.securityOrigin.host, port: message.frameInfo.securityOrigin.port) else {
            replyHandler(BridgeFailure(code: "ORIGIN_DENIED", message: "此页面或框架没有原生桥权限。").envelope, nil); return
        }
        guard let body = message.body as? [String: Any], let command = body["command"] as? String,
              let args = body["args"] as? [String: Any], JSONSerialization.isValidJSONObject(body),
              let size = try? JSONSerialization.data(withJSONObject: body).count, size <= LocalSettingsStore.byteLimit + 16 * 1024 else {
            replyHandler(BridgeFailure(code: "INVALID_MESSAGE", message: "桥消息格式无效或超过大小限制。").envelope, nil); return
        }
        do {
            let value: Any
            switch command {
            case "storage.get": value = try requireStore(model).get(args["keys"])
            case "storage.set":
                guard let values = args["values"] as? [String: Any] else { throw BridgeFailure(code: "INVALID_ARGUMENT", message: "缺少存储值。") }
                value = ["changes": try requireStore(model).set(values)]
            case "storage.remove": value = ["changes": try requireStore(model).remove(args["keys"])]
            case "host.open":
                guard let raw = args["url"] as? String, raw.count < 8192, let url = URL(string: raw) else { throw BridgeFailure(code: "INVALID_URL", message: "网页地址无效。") }
                try model.open(url, target: args["target"] as? String ?? "_self")
                value = ["opened": true]
            case "host.share":
                var items: [Any] = []
                if let text = args["text"] as? String, !text.isEmpty, text.count <= 16000 { items.append(text) }
                if let raw = args["url"] as? String, let url = URL(string: raw), ShellPolicy.isWebURL(url) { items.append(url) }
                guard !items.isEmpty else { throw BridgeFailure(code: "INVALID_ARGUMENT", message: "没有可分享的内容。") }
                try model.share(items)
                value = ["presented": true]
            case "diagnostics.report":
                let known: Set<String> = ["document.end", "runtime.ready", "runtime.error", "resource.error", "csp.violation", "bridge.unsupported", "storage.error", "iframe.unsupported"]
                let event = args["event"] as? String ?? "unknown"
                var safe = SafeDiagnostics.details(args["details"])
                if let details = args["details"] as? [String: Any] {
                    let codes: Set<String> = ["READY", "UNSUPPORTED", "UNSUPPORTED_SUBFRAME", "RESOURCE_LOAD_FAILED", "CSP_BLOCKED", "LISTENER_ERROR", "NOT_CONFIGURED", "STORAGE_KEY_DENIED"]
                    if let code = details["code"] as? String, codes.contains(code) { safe["code"] = code }
                    if let resource = details["resource"] as? String, model.assets?.allowed.contains(resource) == true { safe["resource"] = resource }
                    let directives: Set<String> = ["style-src", "style-src-elem", "script-src", "script-src-elem", "font-src", "img-src", "worker-src", "frame-src", "connect-src", "default-src"]
                    if let directive = details["directive"] as? String, directives.contains(directive) { safe["directive"] = directive }
                }
                model.record(known.contains(event) ? event : "runtime.report", details: safe)
                if event == "document.end" { model.runtimeState = "已收到文档报告；绑定、编辑仍待验证" }
                if event == "runtime.ready" { model.runtimeState = "本地适配器已报告；完整增强仍待验证" }
                value = ["recorded": true]
            case "runtime.message":
                guard let payload = args["message"] as? [String: Any], let type = payload["type"] as? String else { throw BridgeFailure.unsupported }
                switch type {
                case "CC98_REBORN_OPENID_GET_STATE": value = model.oauth.state()
                case "CC98_REBORN_OPENID_LOGIN":
                    guard payload["expectedAccount"] != nil else { value = OAuthFailure.noWebAccount.response; break }
                    model.oauth.login(expectedAccount: payload["expectedAccount"]) { result in replyHandler(["ok": true, "value": result], nil) }
                    return
                case "CC98_REBORN_OPENID_LOGOUT":
                    value = model.oauth.logout()
                case "CC98_REBORN_DOWNLOAD_FILE":
                    guard let raw = payload["url"] as? String, let url = URL(string: raw), url.scheme == "https", ShellPolicy.isWebURL(url), let browser = model.webView else { throw BridgeFailure(code: "URL_DENIED", message: "下载只允许有效 HTTPS 地址。") }
                    model.confirmDownload(url: url, browser: browser) { [weak model, weak browser] accepted in
                        guard accepted else { replyHandler(["ok": true, "value": ["ok": true, "cancelled": true, "started": false]], nil); return }
                        guard let model, let browser else { replyHandler(BridgeFailure(code: "STALE_DOCUMENT", message: "原页面已关闭。").envelope, nil); return }
                        browser.startDownload(using: URLRequest(url: url)) { download in model.downloads.register(download, confirmed: true) }
                        replyHandler(["ok": true, "value": ["ok": true, "started": true]], nil)
                    }
                    return
                default:
                    model.record("runtime.unsupported")
                    throw BridgeFailure.unsupported
                }
            default: throw BridgeFailure.unsupported
            }
            replyHandler(["ok": true, "value": value], nil)
        } catch let failure as BridgeFailure { replyHandler(failure.envelope, nil) }
        catch { replyHandler(BridgeFailure(code: "LOCAL_FAILURE", message: "本地操作未完成；请重试或使用原站模式。").envelope, nil) }
    }

    private func requireStore(_ model: ShellModel) throws -> LocalSettingsStore {
        guard let store = model.settings else { throw BridgeFailure(code: "STORAGE_UNAVAILABLE", message: "本地增强设置不可用。") }
        return store
    }
}

@MainActor
enum NativePrompt {
    private static func presenter(_ view: UIView) -> UIViewController? {
        guard view.window != nil else { return nil }
        var controller = view.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller is UIAlertController || controller?.isBeingDismissed == true ? nil : controller
    }
    static func alert(on view: UIView, title: String, message: String, completion: @escaping () -> Void) {
        guard let controller = presenter(view) else { completion(); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completion() })
        controller.present(alert, animated: true)
    }
    static func confirm(on view: UIView, title: String, message: String, completion: @escaping (Bool) -> Void) {
        guard let controller = presenter(view) else { completion(false); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "继续", style: .default) { _ in completion(true) })
        controller.present(alert, animated: true)
    }
    static func text(on view: UIView, title: String, message: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        guard let controller = presenter(view) else { completion(nil); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in completion(alert?.textFields?.first?.text) })
        controller.present(alert, animated: true)
    }
}

@MainActor
final class NativeDownloads: NSObject, WKDownloadDelegate {
    weak var model: ShellModel?
    private var active: [ObjectIdentifier: WKDownload] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var confirmed: Set<ObjectIdentifier> = []
    init(model: ShellModel) { self.model = model }
    func register(_ download: WKDownload, confirmed: Bool = false) {
        let id = ObjectIdentifier(download)
        active[id] = download
        if confirmed { self.confirmed.insert(id) }
        download.delegate = self
        model?.record("download.started")
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let id = ObjectIdentifier(download)
        let create: (Bool) -> Void = { [weak self] accepted in
            guard accepted, let self else { completionHandler(nil); return }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RebornDownloads/" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(ShellPolicy.safeFilename(suggestedFilename))
                self.destinations[id] = destination
                completionHandler(destination)
            } catch { completionHandler(nil); self.model?.errorMessage = "无法创建临时下载文件。" }
        }
        if confirmed.contains(id) { create(true) }
        else if let model, let browser = model.webView, let url = response.url { model.confirmDownload(url: url, browser: browser, completion: create) }
        else { create(false) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        defer { active.removeValue(forKey: id); destinations.removeValue(forKey: id); confirmed.remove(id) }
        guard let file = destinations[id] else { return }
        model?.record("download.finished")
        model?.completedDownloads.append(file)
        do { try model?.share([file]) } catch { model?.errorMessage = "文件已下载。可在“状态、下载与诊断”的下载记录中分享或保存。" }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        active.removeValue(forKey: id); destinations.removeValue(forKey: id); confirmed.remove(id)
        model?.record("download.failed", details: ["code": String((error as NSError).code)])
        model?.errorMessage = "下载未完成。未自动重试；请重新点击附件确认下载。"
    }
}
