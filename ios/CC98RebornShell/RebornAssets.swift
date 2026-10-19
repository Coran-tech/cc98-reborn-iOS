import Foundation
import WebKit
import UniformTypeIdentifiers

struct RebornAssetIndex: Decodable {
    let schemaVersion: Int
    let extensionVersion: String
    let pageScripts: [String]
    let contentScripts: [String]
    let styles: [String]
    let assets: [String]
}

final class RebornAssets {
    let root: URL
    let index: RebornAssetIndex
    let allowed: Set<String>

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        index = try JSONDecoder().decode(RebornAssetIndex.self, from: Data(contentsOf: root.appendingPathComponent("manifest-index.json")))
        allowed = Set(index.assets)
        guard index.schemaVersion == 1,
              index.pageScripts == ["src/page-submit-monitor.js"],
              index.contentScripts.first == "runtime/ios-adapter.js",
              index.styles.last == "runtime/ios-mobile.css",
              allowed.count == index.assets.count,
              index.assets.allSatisfy(ShellPolicy.validAssetPath),
              (index.pageScripts + index.contentScripts + index.styles).allSatisfy({ allowed.contains($0) }) else {
            throw BridgeFailure(code: "ASSET_INDEX_INVALID", message: "本地资源索引无效；请重新打包，或使用原站模式。")
        }
    }

    func data(_ path: String) throws -> Data {
        guard ShellPolicy.validAssetPath(path), allowed.contains(path) else {
            throw BridgeFailure(code: "ASSET_DENIED", message: "资源未列入包内白名单。")
        }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw BridgeFailure(code: "ASSET_DENIED", message: "资源路径越界。")
        }
        return try Data(contentsOf: file)
    }

    func text(_ path: String) throws -> String {
        let bytes = try data(path)
        guard bytes.count <= 4 * 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else {
            throw BridgeFailure(code: "ASSET_ENCODING", message: "脚本或样式不是有效 UTF-8 文本。")
        }
        return text
    }

    func scripts() throws -> [WKUserScript] {
        let world = WKContentWorld.world(name: ShellPolicy.worldName)
        // A top-level guard preserves cross-file lexical bindings. Per-file closures would break them.
        let guardSource = "if (window !== window.top || location.protocol !== 'https:' || !['www.cc98.org','cc98.org'].includes(location.hostname) || (location.port && location.port !== '443')) { throw new Error('REBORN_HOST_GUARD'); }\n"
        var scripts: [WKUserScript] = []
        for path in index.pageScripts {
            scripts.append(WKUserScript(source: guardSource + (try text(path)), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        // Styles and platform prelude exist before the runtime's document-start bootstrap.
        for (number, path) in index.styles.enumerated() {
            let encoded = try Self.jsLiteral(text(path))
            let source = guardSource + "(() => { const s=document.createElement('style'); s.id='cc98-ios-style-\(number)'; s.textContent=\(encoded); const mount=()=>{if(!document.documentElement)return false;document.documentElement.appendChild(s);return true;};if(!mount()){const observer=new MutationObserver(()=>{if(mount())observer.disconnect();});observer.observe(document,{childList:true});} })();"
            scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        for path in index.contentScripts {
            scripts.append(WKUserScript(source: guardSource + (try text(path)) + "\n//# sourceURL=reborn-asset://bundle/" + path, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        let ready = guardSource + "window.webkit.messageHandlers.reborn.postMessage({command:'diagnostics.report',args:{event:'document.end',details:{loaded:document.querySelectorAll('[id^=cc98-ios-style-]').length}}}).catch(()=>{});"
        scripts.append(WKUserScript(source: ready, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        return scripts
    }

    static func jsLiteral(_ value: String) throws -> String {
        let bytes = try JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        let array = String(decoding: bytes, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

final class RebornAssetHandler: NSObject, WKURLSchemeHandler {
    private let assets: RebornAssets
    init(assets: RebornAssets) { self.assets = assets }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let path = ShellPolicy.assetPath(from: url), urlSchemeTask.request.httpMethod == "GET" || urlSchemeTask.request.httpMethod == nil else {
            urlSchemeTask.didFailWithError(NSError(domain: "RebornAsset", code: 403)); return
        }
        do {
            let bytes = try assets.data(path)
            let ext = (path as NSString).pathExtension
            let overrides = ["js": "text/javascript", "css": "text/css", "html": "text/html", "woff2": "font/woff2", "woff": "font/woff", "svg": "image/svg+xml"]
            let mime = overrides[ext] ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            // These are public, immutable bundle assets only. Font/image CORS does not expose filesystem or credentials.
            let headers = ["Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""), "Content-Length": String(bytes.count), "Access-Control-Allow-Origin": "*"]
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw BridgeFailure(code: "ASSET_RESPONSE", message: "本地资源响应失败。")
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(bytes)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(NSError(domain: "RebornAsset", code: 404)) }
    }
    // Reads are synchronous local-file operations; no work or callback remains after start returns.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
