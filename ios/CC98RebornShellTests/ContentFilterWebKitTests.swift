import XCTest
import WebKit
import UIKit
@testable import CC98RebornShell

final class ContentFilterWebKitTests: XCTestCase {
    @MainActor
    func testBundledFilterFrameHandshakeAndRealWorker() async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Reborn", isDirectory: true)
        let assets = try RebornAssets(root: root)
        let started = expectation(description: "synthetic main document executes inline harness")
        let finished = expectation(description: "bundled frame + MessageChannel + Worker")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        var outcome: [String: Any]?
        let probe = FilterFrameProbe(started: { started.fulfill() }) { result in outcome = result; finished.fulfill() }
        config.setURLSchemeHandler(FilterAssetProbe(assets: assets, record: probe.record), forURLScheme: "reborn-asset")
        config.userContentController.add(probe, name: "filterTestResult")
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        browser.navigationDelegate = probe
        // A detached zero-size view can have its web process/timers suspended. Exercise
        // the same visible-view lifecycle as the app, without using its persistent store.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: { $0.isKeyWindow })
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = browser
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            browser.stopLoading()
            browser.navigationDelegate = nil
            config.userContentController.removeScriptMessageHandler(forName: "filterTestResult")
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        // Synthetic HTTPS origin is needed by the real frame's parent-origin guard.
        // No document is fetched, no credentials are present, and all network navigation is denied.
        let html = """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; frame-src reborn-asset:; connect-src 'none'">
        <title>Anonymous Worker transport test</title><body><script>
        (() => {
          let done=false, ready=false;
          const trace=stage=>window.webkit.messageHandlers.filterTestResult.postMessage({kind:'trace',stage,parentOrigin:location.origin});
          window.__filterHarnessStarted=true;
          trace('inline-start');
          const finish=value=>{if(done)return;done=true;clearTimeout(timer);window.webkit.messageHandlers.filterTestResult.postMessage({...value,parentOrigin:location.origin});};
          const timer=setTimeout(()=>finish({stage:ready?'worker-timeout':'handshake-timeout'}),6000);
          addEventListener('error',event=>finish({stage:'javascript-error',line:event.lineno||0,column:event.colno||0}),{once:true});
          addEventListener('securitypolicyviolation',event=>finish({stage:'csp-blocked',directive:event.effectiveDirective}),{once:true});
          const frame=document.createElement('iframe');
          frame.src='reborn-asset://bundle/src/content-filter-frame.html';
          frame.addEventListener('load',()=>{
            trace('frame-load');
            const channel=new MessageChannel();
            channel.port1.onmessage=event=>{
              if(event.data?.ready){ready=true;trace('frame-ready');channel.port1.postMessage({id:1,rules:['/needle/i'],text:'NEEDLE',metrics:{}});}
              else if(event.data?.id===1){finish({stage:'result',index:event.data.index,error:!!event.data.error});}
            };
            frame.contentWindow.postMessage({type:'CC98_CONTENT_FILTER_CONNECT'},'*',[channel.port2]);
          },{once:true});
          document.body.append(frame);
        })();
        </script></body>
        """
        // Model an HTTPS response directly rather than assigning a base URL to a
        // substitute-data document. The request is simulated; no network load occurs.
        browser.loadSimulatedRequest(URLRequest(url: ShellPolicy.home), responseHTML: html)
        // WebContent cold launch is separate from the six-second transport deadline.
        // Async fulfillment leaves the main actor available for WebKit callbacks.
        await fulfillment(of: [started], timeout: 25)
        if probe.didStart { await fulfillment(of: [finished], timeout: 12) }
        let knownUnsupported = FilterTransportCapability.isKnownMixedContentBlock(outcome, events: probe.events)
        let supported = outcome?["parentOrigin"] as? String == "https://www.cc98.org"
            && outcome?["stage"] as? String == "result" && outcome?["index"] as? Int == 0 && outcome?["error"] as? Bool == false
        let capability = knownUnsupported ? "known-unsupported-mixed-content" : supported ? "supported" : "failed"
        let evidence: [String: Any] = ["capability": capability, "runtime": "iOS \(UIDevice.current.systemVersion)",
                                       "events": probe.events, "result": outcome ?? ["stage": "native-timeout"]]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "filter-worker-transport-result"
        attachment.lifetime = .keepAlways
        add(attachment)
        let report = try XCTUnwrap(outcome, "No terminal report; inspect filter-worker-transport-result for main-document/JavaScript stages")
        XCTAssertEqual(report["parentOrigin"] as? String, "https://www.cc98.org", "Synthetic parent origin must satisfy the real frame guard")
        let assertRealWorker = {
            XCTAssertEqual(report["stage"] as? String, "result", "Frame/worker transport is not usable on this WebKit: \(report)")
            XCTAssertEqual(report["index"] as? Int, 0, "Real bundled RegExp worker must match the rule; no main-thread fallback")
            XCTAssertEqual(report["error"] as? Bool, false)
        }
        if knownUnsupported {
            // WebKit DocumentLoader checks iframe loads with IsUpgradable::No;
            // MixedContentChecker's custom-scheme exception is only for upgradable loads.
            // https://github.com/WebKit/WebKit/blob/main/Source/WebCore/loader/DocumentLoader.cpp
            // https://github.com/WebKit/WebKit/blob/main/Source/WebCore/loader/MixedContentChecker.cpp
            let reason = "KNOWN UNSUPPORTED: legacy web-shell HTTPS to reborn-asset iframe is blocked before the scheme handler. NativeRoot does not use this transport; legacy filter compatibility remains incomplete."
            print(reason)
            XCTExpectFailure(reason, failingBlock: assertRealWorker)
        } else {
            assertRealWorker()
        }
        withExtendedLifetime(probe) {}
    }

    func testKnownLimitationRequiresExactPreHandlerHTTPSFrameEvidence() {
        let report: [String: Any] = ["parentOrigin": "https://www.cc98.org", "stage": "handshake-timeout"]
        let events: [[String: Any]] = [
            ["stage": "main-committed"], ["stage": "main-finished"],
            ["stage": "frame-navigation-allowed", "scheme": "reborn-asset", "isMainFrame": false, "topIsForum": true]
        ]
        XCTAssertTrue(FilterTransportCapability.isKnownMixedContentBlock(report, events: events))
        for stage in ["asset-start", "frame-load", "frame-ready", "navigation-denied", "web-process-terminated", "main-provisional-failed"] {
            XCTAssertFalse(FilterTransportCapability.isKnownMixedContentBlock(report, events: events + [["stage": stage]]), stage)
        }
        XCTAssertFalse(FilterTransportCapability.isKnownMixedContentBlock(report, events: []))
        XCTAssertFalse(FilterTransportCapability.isKnownMixedContentBlock(["parentOrigin": "http://www.cc98.org", "stage": "handshake-timeout"], events: events))
        XCTAssertFalse(FilterTransportCapability.isKnownMixedContentBlock(["parentOrigin": "https://www.cc98.org", "stage": "worker-timeout"], events: events))
        XCTAssertFalse(FilterTransportCapability.isKnownMixedContentBlock(["parentOrigin": "https://www.cc98.org", "stage": "result", "index": 0, "error": false], events: events))
        XCTAssertFalse(FilterTransportCapability.isKnownMixedContentBlock(nil, events: events))
    }
}

private enum FilterTransportCapability {
    static func isKnownMixedContentBlock(_ report: [String: Any]?, events: [[String: Any]]) -> Bool {
        guard report?["parentOrigin"] as? String == "https://www.cc98.org",
              report?["stage"] as? String == "handshake-timeout" else { return false }
        let stages = Set(events.compactMap { $0["stage"] as? String })
        let unrelatedFailures: Set<String> = ["navigation-no-url", "navigation-denied", "main-provisional-failed", "main-navigation-failed", "web-process-terminated", "document-evaluation-failed"]
        return stages.contains("main-committed") && stages.contains("main-finished")
            && stages.isDisjoint(with: unrelatedFailures)
            && !stages.contains("asset-start") && !stages.contains("frame-load") && !stages.contains("frame-ready")
            && events.contains { $0["stage"] as? String == "frame-navigation-allowed"
                && $0["scheme"] as? String == "reborn-asset" && $0["isMainFrame"] as? Bool == false && $0["topIsForum"] as? Bool == true }
    }
}

@MainActor
private final class FilterFrameProbe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let started: () -> Void
    private let completion: ([String: Any]) -> Void
    private var completed = false
    private(set) var didStart = false
    private(set) var events: [[String: Any]] = []
    init(started: @escaping () -> Void, completion: @escaping ([String: Any]) -> Void) {
        self.started = started; self.completion = completion
    }
    fileprivate func record(_ event: [String: Any]) {
        if events.count < 80 { events.append(event) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !completed, message.frameInfo.isMainFrame, let result = message.body as? [String: Any] else { return }
        record(result)
        if result["stage"] as? String == "inline-start", !didStart { didStart = true; started() }
        if result["kind"] as? String == "trace" { return }
        completed = true; completion(result)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { record(["stage": "navigation-no-url"]); decisionHandler(.cancel); return }
        // loadSimulatedRequest asks for the synthetic main-document URL, without fetching it.
        if action.targetFrame?.isMainFrame == true && (url == ShellPolicy.home || url.absoluteString == "about:blank") {
            record(["stage": "main-navigation-allowed", "scheme": url.scheme ?? "none"])
            decisionHandler(.allow); return
        }
        let allowed = ShellPolicy.allowsFilterFrame(url: url, isMainFrame: action.targetFrame?.isMainFrame, topURL: webView.url, enhanced: true, isPopup: false)
        record(["stage": allowed ? "frame-navigation-allowed" : "navigation-denied", "scheme": url.scheme ?? "none", "isMainFrame": action.targetFrame?.isMainFrame as Any? ?? "unknown", "topIsForum": ShellPolicy.isForum(webView.url)])
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { record(["stage": "main-committed"]) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        record(["stage": "main-finished"])
        webView.evaluateJavaScript("({stage:'document-state',parentOrigin:location.origin,readyState:document.readyState,inlineStarted:!!window.__filterHarnessStarted})") { [weak self] value, error in
            if let state = value as? [String: Any] { self?.record(state) }
            else { self?.record(["stage": "document-evaluation-failed", "code": (error as NSError?)?.code ?? 0]) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        record(["stage": "main-provisional-failed", "code": (error as NSError).code])
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record(["stage": "main-navigation-failed", "code": (error as NSError).code])
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { record(["stage": "web-process-terminated"]) }
}

/// Observe the real bundle handler without replacing its bytes, responses or errors.
/// All recorded paths are local allowlisted asset names; no credentials or network URLs.
@MainActor
private final class FilterAssetProbe: NSObject, WKURLSchemeHandler {
    private let handler: RebornAssetHandler
    private let record: ([String: Any]) -> Void
    init(assets: RebornAssets, record: @escaping ([String: Any]) -> Void) {
        handler = RebornAssetHandler(assets: assets)
        self.record = record
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let path = urlSchemeTask.request.url.flatMap(ShellPolicy.assetPath) ?? "invalid"
        record(["stage": "asset-start", "path": path])
        handler.webView(webView, start: FilterAssetTask(task: urlSchemeTask, path: path, record: record))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let path = urlSchemeTask.request.url.flatMap(ShellPolicy.assetPath) ?? "invalid"
        record(["stage": "asset-stop", "path": path])
        handler.webView(webView, stop: urlSchemeTask)
    }
}

@MainActor
private final class FilterAssetTask: NSObject, WKURLSchemeTask {
    private let task: WKURLSchemeTask
    private let path: String
    private let record: ([String: Any]) -> Void
    var request: URLRequest { task.request }
    init(task: WKURLSchemeTask, path: String, record: @escaping ([String: Any]) -> Void) {
        self.task = task; self.path = path; self.record = record
    }
    func didReceive(_ response: URLResponse) {
        record(["stage": "asset-response", "path": path, "mime": response.mimeType ?? "none",
                "status": (response as? HTTPURLResponse)?.statusCode ?? 0])
        task.didReceive(response)
    }
    func didReceive(_ data: Data) { task.didReceive(data) }
    func didFinish() {
        record(["stage": "asset-finished", "path": path])
        task.didFinish()
    }
    func didFailWithError(_ error: Error) {
        record(["stage": "asset-failed", "path": path, "code": (error as NSError).code])
        task.didFailWithError(error)
    }
}
