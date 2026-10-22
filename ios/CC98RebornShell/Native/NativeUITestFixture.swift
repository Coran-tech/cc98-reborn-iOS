#if DEBUG
import Foundation

// Synthetic data is available only in Debug with an explicit launch argument.
// All API paths are intercepted while enabled: unknown paths fail locally.
enum NativeUITestFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--native-ui-fixture") }
    static let userID = 900001
    static let libraryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Reborn-UIFixture-" + UUID().uuidString, isDirectory: true)
    static let userObject: [String: Any] = [
        "id": userID, "name": "林间风", "introduction": "在求是园，记录日常与好奇。",
        "postCount": 128, "prestige": 42, "popularity": 56, "fanCount": 18, "followCount": 24,
        "signatureCode": "保持好奇，认真生活。", "watermarkId": "UITEST01", "gender": 1,
        "wealth": 12000, "emailAddress": "fixture@example.invalid", "customTitle": "求是园漫游者"
    ]
    static var user: NativeUser {
        // A malformed checked-in fixture is a test setup failure, never a network fallback.
        try! JSONDecoder().decode(NativeUser.self, from: json(userObject))
    }
    private static let titles = [
        "秋天的校园，有哪些值得慢慢走的小路？",
        "分享一份宿舍厨房的简单晚餐清单",
        "从零开始理解线性代数：我的学习笔记",
        "周末一起去看一场电影吧",
        "研究生的第一学期，如何安排时间？",
        "今天在图书馆读到的一段话",
        "征集：你最喜欢的校园声音",
        "一个开源小工具的开发记录",
        "运动打卡：让每天多走一点成为习惯",
        "长标题测试：关于校园生活与学习的一些想法，以及一份还在持续更新中的愿望清单"
    ]
    static let boardObject: [String: Any] = [
        "id": 182, "name": "缘分天空", "description": "分享校园生活，遇见同路的人。",
        "topicCount": 1280, "postCount": 6280, "todayCount": 36, "canEntry": true,
        "isLock": false, "canVote": true, "anonymousState": 0,
        "bigPaper": "[b]欢迎来到校园生活交流区[/b]\n友善交流，尊重每一位同学。", "boardMasters": ["测试版主"]
    ]
    private static func topics() -> [[String: Any]] {
        titles.enumerated().map { index, title in
            ["id": 91001 + index, "title": title, "boardId": 182, "boardName": "缘分天空",
             "userId": userID + 1, "userName": "晚风", "authorName": "晚风", "replyCount": 14 + index,
             "hitCount": 128 + index * 27, "time": "2026-10-22T16:20:00+08:00",
             "createTime": "2026-10-22T16:20:00+08:00", "lastPostTime": "2026-10-22T17:10:00+08:00",
             "lastPostUser": "林间风", "lastPostContent": "把日常的发现留在这里，也期待听见你的分享。",
             "isAnonymous": false, "isVote": false, "likeCount": 8, "dislikeCount": 1]
        }
    }

    static func response(path: String, query: [URLQueryItem], method: String) throws -> Data {
        func integer(_ key: String, _ fallback: Int = 0) -> Int {
            Int(query.first { $0.name == key }?.value ?? "") ?? fallback
        }
        let from = integer("from"), size = integer("size", 10)
        func page(_ values: [[String: Any]]) -> [[String: Any]] {
            Array(values.dropFirst(max(0, from)).prefix(max(0, size)))
        }
        if method != "GET" {
            if path == "/file" || path == "/file/portrait" { return try json(["https://example.invalid/fixture-image.jpg"]) }
            if path == "/board/182/topic" { return Data("91001".utf8) }
            return try json([:])
        }
        switch path {
        case "/config/index":
            return try json(["hotTopic": topics(), "todayCount": 368, "onlineUserCount": 1280,
                             "topicCount": 186420, "postCount": 968125, "userCount": 68120])
        case "/topic/hot-weekly": return try json(topics())
        case "/topic/new", "/topic/new-media", "/topic/search", "/topic/search/board/182", "/board/182/topic", "/topic/me/favorite":
            return try json(page(topics()))
        case "/board/all": return try json([["id": 1, "name": "校园生活", "boards": [boardObject,
            ["id": 414, "name": "学习交流", "description": "一起探索知识的边界", "todayCount": 12, "canEntry": true]]]])
        case "/board/182": return try json(boardObject)
        case "/board/414":
            var board = boardObject
            board["id"] = 414; board["name"] = "学习交流"
            return try json(board)
        case "/board/182/tag-v2": return try json(["layers": 1, "tags": [["id": 1, "name": "日常"], ["id": 2, "name": "分享"]]])
        case "/me": return try json(userObject)
        case "/user/search": return try json([userObject])
        case "/user/basic":
            return try json(query.filter { $0.name == "id" }.compactMap { item -> [String: Any]? in
                guard let id = Int(item.value ?? "") else { return nil }
                return ["id": id, "name": id == userID ? "林间风" : "晚风"]
            })
        case "/topic/basic": return try json(topics())
        case "/me/all-message-count": return try json(["replyCount": 2, "atCount": 1, "systemCount": 0, "messageCount": 1])
        case "/notification/reply", "/notification/at", "/notification/system":
            return try json(page([["id": 1, "topicId": 91001, "postId": 92002,
                "isRead": false, "time": "2026-10-22T17:10:00+08:00", "title": titles[0],
                "content": "晚风回复了你的帖子", "postBasicInfo": ["id": 92002, "floor": 2, "userId": userID + 1, "userName": "晚风"]]]))
        case "/message/recent-contact-users":
            return try json(page([["userId": userID + 1, "time": "2026-10-22T17:10:00+08:00", "isRead": false,
                                   "lastContent": "周末一起去校园走走吗？"]]))
        case "/me/favorite-topic-group": return try json(["data": [["id": 1, "name": "值得再读", "count": 10]]])
        case "/me/followee", "/me/follower": return try json([userID + 1])
        case "/me/recent-topic": return try json(page(topics()))
        case "/me/recent-post": return try json(["data": [["id": 92002, "topicId": 91001, "topicTitle": titles[0], "content": "很喜欢这个分享。", "floor": 2, "boardId": 182, "contentType": 0]]])
        default: break
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.first == "user" {
            var object = userObject
            object["id"] = Int(parts.last ?? "") ?? userID + 1
            object["name"] = "晚风"
            if parts.last == "recent-topic" { return try json(page(topics())) }
            return try json(object)
        }
        if path.hasPrefix("/message/user/") {
            return try json(page((0..<20).map { index in
                ["id": 93000 + index, "senderId": index % 2 == 0 ? userID + 1 : userID,
                 "receiverId": index % 2 == 0 ? userID : userID + 1,
                 "time": "2026-10-22T17:10:00+08:00",
                 "content": index % 2 == 0 ? "周末一起去校园走走吗？听说梧桐叶已经开始变黄了。" : "好呀，等阳光好的时候出发！"]
            }))
        }
        if parts.first == "topic", let id = parts.dropFirst().first.flatMap({ Int($0) }) {
            if parts.count == 2 {
                var object = topics().first { $0["id"] as? Int == id } ?? topics()[0]
                object["id"] = id; object["replyCount"] = 14
                return try json(object)
            }
            if parts.last == "post" {
                return try json(page((1...15).map { floor -> [String: Any] in
                    ["id": 92000 + floor, "topicId": id, "boardId": 182, "floor": floor,
                     "content": floor == 1
                        ? "最近的校园很适合散步。傍晚从图书馆出发，沿着湖边走一圈，风吹过树叶的声音很好听。\n\n[b]想收集一些大家喜欢的路线[/b]\n不必是热门地点，只要是让你觉得舒服的一小段路。也欢迎分享适合拍照的时间。\n\n[quote]生活里的小事，也值得被认真记录。[/quote]\n\n这是离线界面测试内容，不会发送到论坛。"
                        : "第 \(floor) 楼：我推荐沿着湖边慢慢走。长一点的回复也应该保留舒适的行距，让中文段落在小屏幕上依然容易阅读。",
                     "contentType": 0, "userId": floor == 2 ? userID : userID + 1,
                     "userName": floor == 2 ? "林间风" : "晚风", "isLZ": floor == 1, "isAnonymous": false,
                     "time": "2026-10-22T17:10:00+08:00", "likeCount": 12, "dislikeCount": 0, "likeState": 0]
                }))
            }
            if parts.last == "hot-post" { return try json([]) }
            if parts.last == "isfavorite" { return Data("false".utf8) }
        }
        if parts.first == "post", parts.last == "like" { return try json(["likeCount": 12, "dislikeCount": 0, "likeState": 0]) }
        if parts.first == "post", parts.last == "awards" { return try json([]) }
        if path == "/post/rating-reason" { return try json([["id": 1, "reason": "认真分享", "type": 0, "enabled": true]]) }
        throw CC98APIError.notFound
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
}
#endif
