import Foundation
import CoreFoundation

enum ShellPolicy {
    static let home = URL(string: "https://www.cc98.org/")!
    static let worldName = "cc98.reborn.v1"
    static let bridgeName = "reborn"
    static let bindingKey = "cc98RebornOpenIdBinding:v1"

    static func isForum(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["www.cc98.org", "cc98.org"].contains(url.host?.lowercased() ?? "")
    }

    static func isWebURL(_ url: URL?) -> Bool {
        guard let url, url.user == nil, url.password == nil else { return false }
        return ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    static func isAllowedOrigin(scheme: String, host: String, port: Int) -> Bool {
        scheme.lowercased() == "https" && ["cc98.org", "www.cc98.org"].contains(host.lowercased()) && [0, 443].contains(port)
    }

    static func validAssetPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count < 512, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("%"), !path.contains(":"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func assetPath(from url: URL) -> String? {
        guard url.scheme == "reborn-asset", url.host == "bundle", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("/") else { return nil }
        let path = String(decoded.dropFirst())
        return validAssetPath(path) ? path : nil
    }

    static func safeFilename(_ name: String) -> String {
        let leaf = (name as NSString).lastPathComponent
        let cleaned = leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? "download" : String(result.prefix(120))
    }
}

struct BridgeFailure: Error {
    let code: String
    let message: String
    var envelope: [String: Any] { ["ok": false, "error": ["code": code, "message": message]] }
    static let unsupported = BridgeFailure(code: "UNSUPPORTED", message: "此验证壳尚未接通这项扩展能力；请使用原站模式完成对应操作。")
}

enum StoragePolicy {
    static let writable: Set<String> = ["cc98ComfortSettings", "cc98RebornPinnedBoards:v1", "cc98RebornExtendedUbbTour:v1"]
    static let readOnly: Set<String> = [ShellPolicy.bindingKey, "cc98RebornSemanticConnection:v1", "cc98RebornSemanticState:v1"]
    static let patterns = [
        "^cc98Reborn(ReadLater:v1|SearchHistory:v1):uid:(guest|[1-9][0-9]*)$",
        "^cc98RebornUserNote:uid:[1-9][0-9]*:user:[1-9][0-9]*$",
        "^cc98RebornPrivateMessagePins:v1:uid:[1-9][0-9]*$"
    ]
    static func canWrite(_ key: String) -> Bool {
        writable.contains(key) || patterns.contains { key.range(of: $0, options: .regularExpression) != nil }
    }
    static func canRead(_ key: String) -> Bool { canWrite(key) || readOnly.contains(key) }
    static func containsSecret(_ value: Any, depth: Int = 0) -> Bool {
        if depth > 20 { return true }
        if let object = value as? [String: Any] {
            return object.contains { key, child in
                if ["__proto__", "prototype", "constructor"].contains(key) { return true }
                let sensitive = key.range(of: "secret|token|password|credential|api.?key", options: [.regularExpression, .caseInsensitive]) != nil
                let falseBoolean = (child as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } ?? false
                let empty = child is NSNull || (child as? String)?.isEmpty == true || falseBoolean
                return (sensitive && !empty) || containsSecret(child, depth: depth + 1)
            }
        }
        if let array = value as? [Any] { return array.contains { containsSecret($0, depth: depth + 1) } }
        return false
    }
}

enum SafeDiagnostics {
    // Values are never copied verbatim from page-provided strings, URLs, bodies or errors.
    static let numericKeys: Set<String> = ["count", "durationMs", "status", "line", "column", "loaded", "total"]
    static func event(_ value: Any?) -> String {
        let input = value as? String ?? "unknown"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(String.UnicodeScalarView(input.unicodeScalars.filter { allowed.contains($0) }.prefix(60)))
    }
    static func details(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { result, item in
            if numericKeys.contains(item.key), let number = item.value as? NSNumber { result[item.key] = number.stringValue }
        }
    }
    static func networkMessage(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorNotConnectedToInternet: return "网络未连接。请确认手机已接入能访问 CC98 的校园网络。"
        case NSURLErrorTimedOut: return "连接超时。请确认校网可达后重试；不会自动重新提交表单。"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed: return "无法连接网站。请检查校网与 DNS；此 App 不提供校外代理。"
        case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate: return "安全连接失败。未绕过证书校验，请检查设备时间与网络。"
        default: return "页面加载失败（错误码 \(code)）。可重试或切回原站模式；不会自动重发提交。"
        }
    }
}
