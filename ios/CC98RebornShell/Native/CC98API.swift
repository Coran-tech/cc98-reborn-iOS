import Foundation

enum CC98APIError: LocalizedError {
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case server(Int, String?)
    case transport
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请求地址无效。"
        case .unauthorized: return "需要登录 CC98 才能继续。"
        case .forbidden: return "当前账号没有权限查看此内容。"
        case .notFound: return "内容不存在或已被删除。"
        case let .server(status, message):
            if let message, !message.isEmpty { return message }
            return "CC98 服务暂时不可用（HTTP \(status)）。"
        case .transport: return "无法连接 CC98，请确认校园网或系统 VPN 可用。"
        case .decoding: return "CC98 返回了无法识别的数据，请稍后重试。"
        }
    }
}

// Native API client. The base host is fixed, redirects are rejected so a
// bearer token can never be forwarded to another host, and tokens are only
// attached from the keychain-backed NativeAuth session.
final class CC98API {
    static let baseURLString = "https://api.cc98.org"

    private let auth: NativeAuth
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let redirectBlocker = RedirectBlocker()

    init(auth: NativeAuth) {
        self.auth = auth
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }

    func home() async throws -> NativeHome {
        try await get("/config/index")
    }

    func hotTopics() async throws -> [NativeHotTopic] {
        try await get("/topic/hot-weekly")
    }

    func boardGroups() async throws -> [NativeBoardGroup] {
        let data = try await data(path: "/board/all", authenticated: false)
        if let groups = try? decoder.decode([NativeBoardGroup].self, from: data), !groups.isEmpty {
            return groups
        }
        if let boards = try? decoder.decode([NativeBoard].self, from: data), !boards.isEmpty {
            return [NativeBoardGroup(id: 0, name: "全部版面", masters: nil, order: 0, boards: boards)]
        }
        throw CC98APIError.decoding
    }

    func topics(boardID: Int, from: Int, size: Int = 20) async throws -> [NativeTopicSummary] {
        try await get("/board/\(boardID)/topic", query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ])
    }

    func topic(id: Int) async throws -> NativeTopic {
        try await get("/topic/\(id)")
    }

    func posts(topicID: Int, from: Int, size: Int = 10) async throws -> [NativePost] {
        try await get("/topic/\(topicID)/post", query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ])
    }

    func me() async throws -> NativeUser {
        let data = try await data(path: "/me", authenticated: true)
        if let user = try? decoder.decode(NativeUser.self, from: data) { return user }
        if let envelope = try? decoder.decode(DataEnvelope<NativeUser>.self, from: data) { return envelope.data }
        throw CC98APIError.decoding
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = false) async throws -> T {
        let data = try await data(path: path, query: query, authenticated: authenticated)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CC98APIError.decoding
        }
    }

    private func data(path: String, query: [URLQueryItem] = [], authenticated: Bool, allowRetry: Bool = true) async throws -> Data {
        guard path.hasPrefix("/"), !path.contains("://"), !path.contains("..") else {
            throw CC98APIError.invalidURL
        }
        guard var components = URLComponents(string: CC98API.baseURLString + path) else {
            throw CC98APIError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CC98APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CC98Reborn/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let token: String?
        if authenticated {
            token = try await auth.validAccessToken()
        } else {
            token = await auth.optionalAccessToken()
        }
        if let token {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CC98APIError.transport }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401:
                if allowRetry, token != nil {
                    do {
                        try await auth.refreshIfPossible()
                        return try await self.data(path: path, query: query, authenticated: authenticated, allowRetry: false)
                    } catch {
                        throw CC98APIError.unauthorized
                    }
                }
                throw CC98APIError.unauthorized
            case 403:
                throw CC98APIError.forbidden
            case 404:
                throw CC98APIError.notFound
            default:
                let message = (try? decoder.decode(NativeAPIErrorBody.self, from: data))?.message
                throw CC98APIError.server(http.statusCode, message)
            }
        } catch let error as CC98APIError {
            throw error
        } catch {
            throw CC98APIError.transport
        }
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
