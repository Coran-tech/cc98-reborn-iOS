import XCTest
import WebKit
@testable import CC98RebornShell

final class ContentFilterWebKitTests: XCTestCase {
    @MainActor
    func testBundledFilterFrameHandshakeAndRealWorker() throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Resources/Reborn", isDirectory: true)
        let assets = try RebornAssets(root: root)
        let finished = expectation(description: "bundled frame + MessageChannel + Worker")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(RebornAssetHandler(assets: assets), forURLScheme: "reborn-asset")
        var outcome: [String: Any]?
        let probe = FilterFrameProbe { result in outcome = result; finished.fulfill() }
        config.userContentController.add(probe, name: "filterTestResult")
        let browser = WKWebView(frame: .zero, configuration: config)
        browser.navigationDelegate = probe
        // Synthetic HTTPS origin is needed by the real frame's parent-origin guard.
        // No document is fetched, no credentials are present, and all network navigation is denied.
        let html = """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; frame-src reborn-asset:; connect-src 'none'">
        <title>Anonymous Worker transport test</title><body><script>
        (() => {
          let done=false, ready=false;
          const finish=value=>{if(done)return;done=true;clearTimeout(timer);window.webkit.messageHandlers.filterTestResult.postMessage({...value,parentOrigin:location.origin});};
          const timer=setTimeout(()=>finish({stage:ready?'worker-timeout':'handshake-timeout'}),6000);
          const frame=document.createElement('iframe');
          frame.src='reborn-asset://bundle/src/content-filter-frame.html';
          frame.addEventListener('load',()=>{
            const channel=new MessageChannel();
            channel.port1.onmessage=event=>{
              if(event.data?.ready){ready=true;channel.port1.postMessage({id:1,rules:['/needle/i'],text:'NEEDLE',metrics:{}});}
              else if(event.data?.id===1){finish({stage:'result',index:event.data.index,error:!!event.data.error});}
            };
            frame.contentWindow.postMessage({type:'CC98_CONTENT_FILTER_CONNECT'},'*',[channel.port2]);
          },{once:true});
          document.body.append(frame);
        })();
        </script></body>
        """
        browser.loadHTMLString(html, baseURL: ShellPolicy.home)
        wait(for: [finished], timeout: 12)
        browser.stopLoading()
        browser.navigationDelegate = nil
        config.userContentController.removeScriptMessageHandler(forName: "filterTestResult")
        let report = try XCTUnwrap(outcome)
        let attachment = XCTAttachment(string: String(describing: report))
        attachment.name = "filter-worker-transport-result"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(report["parentOrigin"] as? String, "https://www.cc98.org", "Synthetic parent origin must satisfy the real frame guard")
        XCTAssertEqual(report["stage"] as? String, "result", "Frame/worker transport is not usable on this WebKit: \(report)")
        XCTAssertEqual(report["index"] as? Int, 0, "Real bundled RegExp worker must match the rule; no main-thread fallback")
        XCTAssertEqual(report["error"] as? Bool, false)
        withExtendedLifetime(probe) {}
    }
}

@MainActor
private final class FilterFrameProbe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let completion: ([String: Any]) -> Void
    private var completed = false
    init(completion: @escaping ([String: Any]) -> Void) { self.completion = completion }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !completed, message.frameInfo.isMainFrame, let result = message.body as? [String: Any] else { return }
        completed = true; completion(result)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // loadHTMLString may ask for the synthetic main-document URL; it never performs a network load.
        if action.targetFrame?.isMainFrame == true && (url == ShellPolicy.home || url.absoluteString == "about:blank") { decisionHandler(.allow); return }
        let allowed = ShellPolicy.allowsFilterFrame(url: url, isMainFrame: action.targetFrame?.isMainFrame, topURL: webView.url, enhanced: true, isPopup: false)
        decisionHandler(allowed ? .allow : .cancel)
    }
}
