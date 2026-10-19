import Foundation

// Native models follow the public CC98 API contracts used by the official
// frontend. Every field that is not needed for the first native screens is
// optional so a server-side addition never breaks decoding.

struct NativeHome: Decodable {
    let hotTopic: [NativeHotTopic]?
    let announcement: String?
    let todayCount: Int?
    let topicCount: Int?
    let postCount: Int?
    let userCount: Int?
    let onlineUserCount: Int?
    let lastUpdateTime: String?
}

struct NativeHotTopic: Identifiable, Decodable {
    let id: Int
    let title: String?
    let boardId: Int?
    let boardName: String?
    let authorName: String?
    let replyCount: Int?
    let hitCount: Int?
    let participantCount: Int?
    let createTime: String?
    let type: Int?
}

struct NativeBoardGroup: Identifiable, Decodable {
    let id: Int
    let name: String
    let masters: [String]?
    let order: Int?
    let boards: [NativeBoard]?
}

struct NativeBoard: Identifiable, Decodable {
    let id: Int
    let name: String
    let description: String?
    let topicCount: Int?
    let postCount: Int?
    let todayCount: Int?
    let parentId: Int?
    let canEntry: Bool?
    let isLock: Bool?
    let internalState: Int?
    let canVote: Bool?
    let bigPaper: String?
    let boardMasters: [String]?
}

struct NativeTopicSummary: Identifiable, Decodable {
    let id: Int
    let boardId: Int?
    let boardName: String?
    let title: String?
    let userId: Int?
    let userName: String?
    let time: String?
    let lastPostTime: String?
    let replyCount: Int?
    let hitCount: Int?
    let lastPostUser: String?
    let lastPostContent: String?
    let isAnonymous: Bool?
    let state: Int?
    let type: Int?
    let topState: Int?
    let bestState: Int?
    let isVote: Bool?
    let likeCount: Int?
    let dislikeCount: Int?
}

struct NativeTopic: Decodable {
    let id: Int
    let boardId: Int?
    let title: String?
    let userId: Int?
    let userName: String?
    let time: String?
    let lastPostTime: String?
    let replyCount: Int?
    let hitCount: Int?
    let isAnonymous: Bool?
    let isPosterOnly: Bool?
    let allowedViewerState: Int?
    let state: Int?
    let type: Int?
    let topState: Int?
    let bestState: Int?
    let isVote: Bool?
    let likeCount: Int?
    let dislikeCount: Int?
}

struct NativePost: Identifiable, Decodable {
    let id: Int
    let topicId: Int?
    let boardId: Int?
    let floor: Int?
    let content: String?
    let contentType: Int?
    let userId: Int?
    let userName: String?
    let time: String?
    let isLZ: Bool?
    let isAnonymous: Bool?
    let isDeleted: Bool?
    let isBest: Bool?
    let likeCount: Int?
    let dislikeCount: Int?
    let likeState: Int?
    let parentId: Int?
    let awards: [NativeAward]?
    let length: Int?
}

struct NativeUser: Decodable {
    let id: Int
    let name: String?
    let portraitUrl: String?
    let photourl: String?
    let introduction: String?
    let signatureCode: String?
    let emailAddress: String?
    let gender: Int?
    let qq: String?
    let birthday: String?
    let displayTitleId: Int?
    let userTitleIds: [Int]?
    let postCount: Int?
    let prestige: Int?
    let popularity: Int?
    let fanCount: Int?
    let followCount: Int?
    let registerTime: String?
    let lastLogOnTime: String?
    let displayTitle: String?
    let customTitle: String?
    let lockState: Int?
    let wealth: Int?
    let theme: Int?
    let customBoards: [Int]?
    let isFollowing: Bool?
    let watermarkId: String?

    var avatarURL: URL? {
        guard let raw = portraitUrl ?? photourl, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://www.cc98.org" + (raw.hasPrefix("/") ? raw : "/" + raw))
    }
}

struct DataEnvelope<Value: Decodable>: Decodable {
    let data: Value
}

struct NativeAPIErrorBody: Decodable {
    let message: String?
    let error: String?
    let title: String?
}

struct NativeLikeState: Decodable {
    let likeCount: Int?
    let dislikeCount: Int?
    let likeState: Int?
}

struct NativeBasicUser: Identifiable, Decodable {
    let id: Int
    let name: String?
    let portraitUrl: String?
}

struct NativeTopicBasic: Identifiable, Decodable {
    let id: Int
    let title: String?
    let boardId: Int?
}

struct NativeMessageCounts: Decodable {
    let replyCount: Int?
    let atCount: Int?
    let systemCount: Int?
    let messageCount: Int?
}

struct NativePostBasic: Decodable {
    let id: Int?
    let floor: Int?
    let userId: Int?
    let userName: String?
}

struct NativeNotification: Identifiable, Decodable {
    let id: Int
    let type: Int?
    let topicId: Int?
    let postId: Int?
    let isRead: Bool?
    let time: String?
    let title: String?
    let content: String?
    let postBasicInfo: NativePostBasic?
}

struct NativeRecentContact: Identifiable, Decodable {
    let userId: Int
    let time: String?
    let isRead: Bool?
    let lastContent: String?

    var id: Int { userId }
}

struct NativePrivateMessage: Identifiable, Decodable {
    let id: Int
    let senderId: Int
    let receiverId: Int
    let time: String?
    let isRead: Bool?
    let content: String?
}

struct NativeJudgeReason: Identifiable, Decodable {
    let id: Int
    let reason: String?
    let type: Int?
    let enabled: Bool?
}

struct NativeMyTopic: Identifiable, Decodable {
    let id: Int
    let title: String?
    let boardId: Int?
    let time: String?
}

struct NativeMyPost: Identifiable, Decodable {
    let id: Int
    let topicId: Int?
    let topicTitle: String?
    let content: String?
    let contentType: Int?
    let time: String?
    let floor: Int?
    let boardId: Int?
}

struct NativeMyPostPage: Decodable {
    let data: [NativeMyPost]
    let count: Int?
}

struct NativeVoteItem: Identifiable, Decodable {
    let id: Int
    let description: String?
    let count: Int?
}

struct NativeVoteRecord: Decodable {
    let userId: Int?
    let userName: String?
    let items: [Int]?
    let time: String?
}

struct NativeVoteInfo: Decodable {
    let topicId: Int?
    let voteItems: [NativeVoteItem]?
    let voteRecords: [NativeVoteRecord]?
    let expiredTime: String?
    let isAvailable: Bool?
    let maxVoteCount: Int?
    let canVote: Bool?
    let myRecord: NativeVoteRecord?
    let needVote: Bool?
    let voteUserCount: Int?
}

struct NativeFavoriteGroup: Identifiable, Decodable {
    let id: Int
    let name: String?
    let count: Int?
    let createTime: String?
}

struct NativeFavoriteGroupEnvelope: Decodable {
    let errorCode: Int?
    let data: [NativeFavoriteGroup]?
}

struct NativeAward: Decodable {
    let id: Int?
    let content: String?
    let operatorName: String?
    let reason: String?
    let time: String?
    let type: Int?
}

extension NativeBoard {
    static func placeholder(id: Int) -> NativeBoard {
        NativeBoard(
            id: id,
            name: "版面 #\(id)",
            description: nil,
            topicCount: nil,
            postCount: nil,
            todayCount: nil,
            parentId: nil,
            canEntry: nil,
            isLock: nil,
            internalState: nil,
            canVote: nil,
            bigPaper: nil,
            boardMasters: nil
        )
    }
}
