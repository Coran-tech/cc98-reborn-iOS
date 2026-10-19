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

enum NativeNotificationKind: String, CaseIterable, Identifiable {
    case reply, at, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: return "回复"
        case .at: return "@我"
        case .system: return "系统"
        }
    }

    var path: String {
        switch self {
        case .reply: return "/notification/reply"
        case .at: return "/notification/at"
        case .system: return "/notification/system"
        }
    }

    var readAllPath: String {
        switch self {
        case .reply: return "/notification/read-all-reply"
        case .at: return "/notification/read-all-at"
        case .system: return "/notification/read-all-system"
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

    // MARK: Reading

    func home() async throws -> NativeHome {
        try await get("/config/index")
    }

    func hotTopics() async throws -> [NativeHotTopic] {
        try await get("/topic/hot-weekly")
    }

    func newTopics(from: Int, size: Int = 20, mediaOnly: Bool = false) async throws -> [NativeTopicSummary] {
        try await get(mediaOnly ? "/topic/new-media" : "/topic/new", query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ], authenticated: false)
    }

    func firstTopicImage(topicID: Int) async throws -> URL? {
        let posts = try await posts(topicID: topicID, from: 0, size: 1)
        guard let content = posts.first?.content else { return nil }
        return UBBFirstImage.first(in: content)
    }

    func userTopics(userID: Int, from: Int, size: Int = 10) async throws -> [NativeMyTopic] {
        let data = try await self.data(
            path: "/user/\(userID)/recent-topic",
            query: [
                URLQueryItem(name: "userid", value: String(userID)),
                URLQueryItem(name: "from", value: String(from)),
                URLQueryItem(name: "size", value: String(size))
            ],
            authenticated: false
        )
        if let topics = try? decoder.decode([NativeMyTopic].self, from: data) {
            return topics
        }
        if let envelope = try? decoder.decode(DataEnvelope<[NativeMyTopic]>.self, from: data) {
            return envelope.data
        }
        throw CC98APIError.decoding
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

    func board(id: Int) async throws -> NativeBoard {
        try await get("/board/\(id)", authenticated: false)
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

    func hotPosts(topicID: Int) async throws -> [NativePost] {
        try await get("/topic/\(topicID)/hot-post", authenticated: false)
    }

    func me() async throws -> NativeUser {
        let data = try await data(path: "/me", authenticated: true)
        if let user = try? decoder.decode(NativeUser.self, from: data) { return user }
        if let envelope = try? decoder.decode(DataEnvelope<NativeUser>.self, from: data) { return envelope.data }
        throw CC98APIError.decoding
    }

    func user(id: Int) async throws -> NativeUser {
        try await get("/user/\(id)", authenticated: false)
    }

    func user(name: String) async throws -> NativeUser {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw CC98APIError.invalidURL
        }
        return try await get("/user/name/\(encoded)", authenticated: false)
    }

    func searchTopics(keyword: String, from: Int, size: Int = 20) async throws -> [NativeTopicSummary] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await get("/topic/search", query: [
            URLQueryItem(name: "keyword", value: trimmed),
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ], authenticated: false)
    }

    func searchBoardTopics(keyword: String, boardID: Int, from: Int, size: Int = 20) async throws -> [NativeTopicSummary] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await get("/topic/search/board/\(boardID)", query: [
            URLQueryItem(name: "keyword", value: trimmed),
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ], authenticated: false)
    }

    func searchUsers(keyword: String, from: Int, size: Int = 20) async throws -> [NativeUser] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let data = try await self.data(
                path: "/user/search",
                query: [
                    URLQueryItem(name: "keyword", value: trimmed),
                    URLQueryItem(name: "from", value: String(from)),
                    URLQueryItem(name: "size", value: String(size))
                ],
                authenticated: false
            )
            if let users = try? decoder.decode([NativeUser].self, from: data) {
                return users
            }
            if let envelope = try? decoder.decode(DataEnvelope<[NativeUser]>.self, from: data) {
                return envelope.data
            }
        } catch {
            // Fall through to the exact-name/id lookup.
        }

        if from > 0 { return [] }
        if let id = Int(trimmed), let user = try? await user(id: id) {
            return [user]
        }
        if let user = try? await user(name: trimmed) {
            return [user]
        }
        return []
    }

    func favoriteTopics(from: Int, size: Int = 20, groupID: Int? = nil) async throws -> [NativeTopicSummary] {
        var query = [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "order", value: "1")
        ]
        if let groupID {
            query.append(URLQueryItem(name: "groupid", value: String(groupID)))
        }
        return try await get("/topic/me/favorite", query: query, authenticated: true)
    }

    func favoriteGroups() async throws -> [NativeFavoriteGroup] {
        let data = try await self.data(path: "/me/favorite-topic-group", authenticated: true)
        if let envelope = try? decoder.decode(NativeFavoriteGroupEnvelope.self, from: data) {
            return envelope.data ?? []
        }
        if let groups = try? decoder.decode([NativeFavoriteGroup].self, from: data) {
            return groups
        }
        throw CC98APIError.decoding
    }

    func createFavoriteGroup(name: String) async throws {
        try await send(
            "/me/favorite-topic-group",
            method: "POST",
            body: try json(["name": name]),
            contentType: "application/json",
            authenticated: true
        )
    }

    func followings(from: Int, size: Int = 10) async throws -> [Int] {
        try await userIDList(path: "/me/followee", from: from, size: size)
    }

    func fans(from: Int, size: Int = 10) async throws -> [Int] {
        try await userIDList(path: "/me/follower", from: from, size: size)
    }

    private func userIDList(path: String, from: Int, size: Int) async throws -> [Int] {
        let data = try await self.data(path: path, query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ], authenticated: true)
        if let ids = try? decoder.decode([Int].self, from: data) {
            return ids
        }
        if let users = try? decoder.decode([NativeBasicUser].self, from: data) {
            return users.map(\.id)
        }
        throw CC98APIError.decoding
    }

    func follow(userID: Int) async throws {
        try await send("/me/followee/\(userID)", method: "PUT", authenticated: true)
    }

    func unfollow(userID: Int) async throws {
        try await send("/me/followee/\(userID)", method: "DELETE", authenticated: true)
    }

    func myTopics(from: Int, size: Int = 10) async throws -> [NativeMyTopic] {
        try await get("/me/recent-topic", query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ], authenticated: true)
    }

    func myPosts(from: Int, size: Int = 10) async throws -> [NativeMyPost] {
        let data = try await data(
            path: "/me/recent-post",
            query: [
                URLQueryItem(name: "from", value: String(from)),
                URLQueryItem(name: "size", value: String(size))
            ],
            authenticated: true
        )
        if let page = try? decoder.decode(NativeMyPostPage.self, from: data) {
            return page.data
        }
        if let posts = try? decoder.decode([NativeMyPost].self, from: data) {
            return posts
        }
        throw CC98APIError.decoding
    }

    func updateProfile(
        email: String,
        gender: Int,
        introduction: String,
        qq: String,
        signature: String,
        birthday: String,
        displayTitleID: Int,
        userTitleIDs: [Int]
    ) async throws {
        let payload: [String: Any] = [
            "EmailAddress": email,
            "Gender": gender,
            "Introduction": introduction,
            "QQ": qq,
            "SignatureCode": signature,
            "Birthday": birthday,
            "DisplayTitleId": displayTitleID,
            "userTitleIds": userTitleIDs
        ]
        try await send(
            "/me",
            method: "PUT",
            body: try json(payload),
            contentType: "application/json",
            authenticated: true
        )
    }

    func ratingReasons(type: Int) async throws -> [NativeJudgeReason] {
        try await get("/post/rating-reason", query: [
            URLQueryItem(name: "type", value: String(type))
        ], authenticated: true)
    }

    func ratePost(postID: Int, reasonID: Int, type: Int) async throws {
        let payload: [String: Any] = ["reasonId": reasonID, "type": type]
        try await send(
            "/post/\(postID)/rating-v2",
            method: "PUT",
            body: try json(payload),
            contentType: "application/json",
            authenticated: true
        )
    }

    func postAwards(postID: Int) async throws -> [NativeAward] {
        let data = try await self.data(path: "/post/\(postID)/awards", authenticated: false)
        if let awards = try? decoder.decode([NativeAward].self, from: data) {
            return awards
        }
        if let envelope = try? decoder.decode(DataEnvelope<[NativeAward]>.self, from: data) {
            return envelope.data
        }
        throw CC98APIError.decoding
    }

    func voteInfo(topicID: Int) async throws -> NativeVoteInfo {
        try await get("/topic/\(topicID)/vote", authenticated: false)
    }

    func castVote(topicID: Int, items: [Int]) async throws {
        try await send(
            "/topic/\(topicID)/vote",
            method: "POST",
            body: try json(["items": items]),
            contentType: "application/json",
            authenticated: true
        )
    }

    // MARK: Messages

    func messageCounts() async throws -> NativeMessageCounts {
        try await get("/me/all-message-count", authenticated: true)
    }

    func notifications(kind: NativeNotificationKind, from: Int, size: Int = 10) async throws -> [NativeNotification] {
        try await get(kind.path, query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ], authenticated: true)
    }

    func markAllRead(kind: NativeNotificationKind) async throws {
        try await send(kind.readAllPath, method: "PUT", body: Data(), authenticated: true)
    }

    func recentContacts(from: Int, size: Int = 10) async throws -> [NativeRecentContact] {
        try await get("/message/recent-contact-users", query: [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "size", value: String(size))
        ], authenticated: true)
    }

    func privateMessages(userID: Int, from: Int, size: Int = 10) async throws -> [NativePrivateMessage] {
        do {
            return try await get("/message/user/\(userID)", query: [
                URLQueryItem(name: "from", value: String(from)),
                URLQueryItem(name: "size", value: String(size))
            ], authenticated: true)
        } catch CC98APIError.server(let status, _) where status == 400 {
            // Some deployments reject size > 10 or the combined query. Retry
            // without size before giving up.
            return try await get("/message/user/\(userID)", query: [
                URLQueryItem(name: "from", value: String(from))
            ], authenticated: true)
        }
    }

    func sendPrivateMessage(receiverID: Int, content: String) async throws {
        let body = try json(["receiverId": receiverID, "content": content])
        try await send("/message", method: "POST", body: body, contentType: "application/json", authenticated: true)
    }

    func userBasics(ids: [Int]) async throws -> [NativeBasicUser] {
        guard !ids.isEmpty else { return [] }
        return try await get("/user/basic", query: ids.map { URLQueryItem(name: "id", value: String($0)) }, authenticated: false)
    }

    func topicBasics(ids: [Int]) async throws -> [NativeTopicBasic] {
        guard !ids.isEmpty else { return [] }
        return try await get("/topic/basic", query: ids.map { URLQueryItem(name: "id", value: String($0)) }, authenticated: false)
    }

    // MARK: Interactions

    func likeState(postID: Int) async throws -> NativeLikeState {
        try await get("/post/\(postID)/like", authenticated: true)
    }

    func setLike(postID: Int, state: Int) async throws {
        let clamped = min(max(state, 0), 2)
        try await send(
            "/post/\(postID)/like",
            method: "PUT",
            body: Data(String(clamped).utf8),
            contentType: "application/json",
            authenticated: true
        )
    }

    func clearLike(postID: Int) async throws {
        do {
            try await send("/post/\(postID)/like", method: "DELETE", authenticated: true)
        } catch {
            // Some deployments expose cancellation only through the state
            // endpoint; try 0 as a fallback before surfacing the error.
            try await send(
                "/post/\(postID)/like",
                method: "PUT",
                body: Data("0".utf8),
                contentType: "application/json",
                authenticated: true
            )
        }
    }

    func isFavorite(topicID: Int) async throws -> Bool {
        do {
            let data = try await self.data(path: "/topic/\(topicID)/isfavorite", authenticated: true)
            let object = try? JSONSerialization.jsonObject(with: data)
            if let number = object as? NSNumber { return number.boolValue }
            if let object = object as? [String: Any] {
                if let value = object["isFavorite"] as? Bool { return value }
                if let value = object["isFavorite"] as? NSNumber { return value.boolValue }
                if let value = object["data"] as? Bool { return value }
            }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return text == "true"
        } catch CC98APIError.notFound {
            return false
        }
    }

    func addFavorite(topicID: Int, groupID: Int = 0) async throws {
        try await send(
            "/me/favorite/\(topicID)",
            query: [URLQueryItem(name: "groupid", value: String(groupID))],
            method: "PUT",
            authenticated: true
        )
    }

    func removeFavorite(topicID: Int) async throws {
        try await send("/me/favorite/\(topicID)", method: "DELETE", authenticated: true)
    }

    func reply(topicID: Int, content: String, parentID: Int? = nil) async throws {
        var payload: [String: Any] = ["content": content, "contentType": 0, "title": ""]
        if let parentID { payload["parentId"] = parentID }
        let body = try json(payload)
        try await send("/topic/\(topicID)/post", method: "POST", body: body, contentType: "application/json", authenticated: true)
    }

    func newTopic(
        boardID: Int,
        title: String,
        content: String,
        isAnonymous: Bool,
        contentType: Int = 0,
        notifyPoster: Bool = false,
        type: Int = 0
    ) async throws {
        let payload: [String: Any] = [
            "content": content,
            "contentType": contentType,
            "title": title,
            "type": type,
            "notifyPoster": notifyPoster,
            "isAnonymous": isAnonymous,
            "clientType": 1
        ]
        try await send(
            "/board/\(boardID)/topic",
            method: "POST",
            body: try json(payload),
            contentType: "application/json",
            authenticated: true
        )
    }

    func editPost(postID: Int, title: String, content: String, contentType: Int) async throws {
        let payload: [String: Any] = [
            "content": content,
            "contentType": contentType,
            "title": title,
            "type": 0,
            "notifyPoster": false
        ]
        try await send(
            "/post/\(postID)",
            method: "PUT",
            body: try json(payload),
            contentType: "application/json",
            authenticated: true
        )
    }

    func uploadImage(_ data: Data, fileName: String = "image.jpg", mimeType: String = "image/jpeg") async throws -> String {
        try await uploadFile(data, fileName: fileName, mimeType: mimeType, path: "/file")
    }

    func uploadAttachment(_ data: Data, fileName: String, mimeType: String) async throws -> String {
        try await uploadFile(data, fileName: fileName, mimeType: mimeType, path: "/file")
    }

    func uploadPortrait(_ data: Data, fileName: String = "portrait.jpg") async throws -> String {
        let url = try await uploadFile(data, fileName: fileName, mimeType: "image/jpeg", path: "/file/portrait")
        let body = try JSONEncoder().encode(url)
        try await send(
            "/me/portrait",
            method: "PUT",
            body: body,
            contentType: "application/json",
            authenticated: true
        )
        return url
    }

    private func uploadFile(_ data: Data, fileName: String, mimeType: String, path: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) {
            body.append(Data(value.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"files\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"contentType\"\r\n\r\n")
        append("multipart/form-data\r\n")
        append("--\(boundary)--\r\n")
        let result = try await self.data(
            path: path,
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authenticated: true
        )
        let urls = try decoder.decode([String].self, from: result)
        guard let first = urls.first, !first.isEmpty else { throw CC98APIError.decoding }
        return first
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = false) async throws -> T {
        let data = try await data(path: path, query: query, authenticated: authenticated)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CC98APIError.decoding
        }
    }

    private func send(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        authenticated: Bool
    ) async throws {
        _ = try await data(
            path: path,
            query: query,
            method: method,
            body: body,
            contentType: contentType,
            authenticated: authenticated
        )
    }

    private func data(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        authenticated: Bool,
        allowRetry: Bool = true
    ) async throws -> Data {
        guard path.hasPrefix("/"), !path.contains("://"), !path.contains("..") else {
            throw CC98APIError.invalidURL
        }
        guard var components = URLComponents(string: CC98API.baseURLString + path) else {
            throw CC98APIError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CC98APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CC98Reborn/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let token: String?
        do {
            token = authenticated ? try await auth.validAccessToken() : await auth.optionalAccessToken()
        } catch {
            throw CC98APIError.unauthorized
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
                        return try await self.data(
                            path: path,
                            query: query,
                            method: method,
                            body: body,
                            contentType: contentType,
                            authenticated: authenticated,
                            allowRetry: false
                        )
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

    private func json(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw CC98APIError.invalidURL }
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw CC98APIError.decoding
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
