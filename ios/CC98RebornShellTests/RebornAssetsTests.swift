import XCTest
import WebKit
@testable import CC98RebornShell

final class RebornAssetsTests: XCTestCase {
    @MainActor
    func testNamedWorldSharesTopLevelBindingsInRegistrationOrder() {
        let finished = expectation(description: "local WebKit contract")
        let world = WKContentWorld.world(name: "cc98.test.lexical")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: "let lexicalProbe = 41; function probe() { return lexicalProbe + 1; }", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        config.userContentController.addUserScript(WKUserScript(source: "globalThis.probeResult = probe();", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        let browser = WKWebView(frame: .zero, configuration: config)
        let delegate = LocalNavigationProbe {
            browser.evaluateJavaScript("globalThis.probeResult", in: nil, in: world) { result in
                switch result {
                case .success(let value): XCTAssertEqual(value as? Int, 42)
                case .failure(let error): XCTFail("Named-world script contract failed: \(error)")
                }
                finished.fulfill()
            }
        }
        browser.navigationDelegate = delegate
        browser.loadHTMLString("<!doctype html><p>Anonymous local test</p>", baseURL: nil)
        wait(for: [finished], timeout: 15)
        browser.navigationDelegate = nil
        withExtendedLifetime(delegate) {}
    }

    @MainActor
    func testPackagedAssetsAndScriptOrder() throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Resources/Reborn", isDirectory: true)
        let assets = try RebornAssets(root: root)
        XCTAssertEqual(assets.index.pageScripts, ["src/page-submit-monitor.js"])
        XCTAssertEqual(assets.index.contentScripts.first, "runtime/ios-adapter.js")
        XCTAssertEqual(assets.index.styles.last, "runtime/ios-mobile.css")
        for path in assets.index.assets { XCTAssertFalse(try assets.data(path).isEmpty, path) }
        let scripts = try assets.scripts()
        XCTAssertEqual(scripts.count, assets.index.pageScripts.count + assets.index.styles.count + assets.index.contentScripts.count + 1)
        let content = try XCTUnwrap(scripts.first { $0.source.contains("const STORAGE_KEY = \"cc98ComfortSettings\"") })
        XCTAssertTrue(content.source.hasPrefix("if (window !== window.top"))
        XCTAssertTrue(content.source.contains("throw new Error('REBORN_HOST_GUARD'); }\nconst STORAGE_KEY"), "Host guard must not wrap source in a new scope")
        XCTAssertThrowsError(try assets.data("../Info.plist"))
        XCTAssertThrowsError(try assets.data("manifest.json"))
    }
}

@MainActor
private final class LocalNavigationProbe: NSObject, WKNavigationDelegate {
    let finish: () -> Void
    init(finish: @escaping () -> Void) { self.finish = finish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
}
