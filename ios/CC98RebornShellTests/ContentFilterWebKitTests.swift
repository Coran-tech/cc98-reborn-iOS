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
        config.setURLSchemeHandler(RebornAssetHandler(assets: assets), forURLScheme: "reborn-asset")
        var outcome: [String: Any]?
        let probe = FilterFrameProbe(started: { started.fulfill() }) { result in outcome = result; finished.fulfill() }
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
        browser.loadHTMLString(html, baseURL: ShellPolicy.home)
        // WebContent cold launch is separate from the six-second transport deadline.
        // Async fulfillment leaves the main actor available for WebKit callbacks.
        await fulfillment(of: [started], timeout: 25)
        if probe.didStart { await fulfillment(of: [finished], timeout: 12) }
        let evidence: [String: Any] = ["events": probe.events, "result": outcome ?? ["stage": "native-timeout"]]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "filter-worker-transport-result"
        attachment.lifetime = .keepAlways
        add(attachment)
        let report = try XCTUnwrap(outcome, "No terminal report; inspect filter-worker-transport-result for main-document/JavaScript stages")
        XCTAssertEqual(report["parentOrigin"] as? String, "https://www.cc98.org", "Synthetic parent origin must satisfy the real frame guard")
        XCTAssertEqual(report["stage"] as? String, "result", "Frame/worker transport is not usable on this WebKit: \(report)")
        XCTAssertEqual(report["index"] as? Int, 0, "Real bundled RegExp worker must match the rule; no main-thread fallback")
        XCTAssertEqual(report["error"] as? Bool, false)
        withExtendedLifetime(probe) {}
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
    private func record(_ event: [String: Any]) {
        if events.count < 40 { events.append(event) }
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
        // loadHTMLString may ask for the synthetic main-document URL; it never performs a network load.
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
