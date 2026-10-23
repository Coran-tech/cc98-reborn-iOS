import SwiftUI
import UIKit

struct NativeLinkedTopic: Identifiable, Hashable {
    let id: Int
    let page: Int
    let floor: Int?

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), host == "www.cc98.org" || host == "cc98.org" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "topic", let topicID = Int(parts[1]) else { return nil }
        id = topicID
        page = parts.count >= 3 ? max(1, Int(parts[2]) ?? 1) : 1
        if let fragment = url.fragment?.trimmingCharacters(in: .whitespacesAndNewlines), !fragment.isEmpty {
            if let value = Int(fragment) {
                floor = value
            } else if fragment.lowercased().hasPrefix("floor"),
                      let value = Int(fragment.dropFirst(5)) {
                floor = value
            } else {
                floor = nil
            }
        } else {
            floor = nil
        }
    }
}

struct NativeLinkedBoard: Identifiable, Hashable {
    let id: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), host == "www.cc98.org" || host == "cc98.org" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "board", let boardID = Int(parts[1]) else { return nil }
        id = boardID
    }
}

struct NativeLinkedUser: Identifiable, Hashable {
    let id: String
    let userID: Int?
    let userName: String?

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), host == "www.cc98.org" || host == "cc98.org" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "user" else { return nil }
        if parts.count >= 3, parts[1] == "id", let value = Int(parts[2]) {
            id = "id:\(value)"
            userID = value
            userName = nil
        } else if parts.count >= 3, parts[1] == "name" {
            let raw = parts[2].removingPercentEncoding ?? parts[2]
            guard !raw.isEmpty else { return nil }
            id = "name:\(raw)"
            userID = nil
            userName = raw
        } else if parts.count == 2, let value = Int(parts[1]) {
            id = "id:\(value)"
            userID = value
            userName = nil
        } else {
            return nil
        }
    }
}

struct NativeTraceRequest: Identifiable {
    let id = UUID()
    let postID: Int?
    let floor: Int?
}

/// A requested page is not a reading position until its posts arrive.
struct NativeTopicPaging {
    private(set) var requestedPage: Int
    private(set) var displayedPage: Int?

    init(initialPage: Int) { requestedPage = max(1, initialPage) }

    var visiblePage: Int { displayedPage ?? requestedPage }
    var isShowingRequestedPage: Bool { displayedPage == requestedPage }

    mutating func request(_ page: Int) { requestedPage = max(1, page) }

    @discardableResult
    mutating func accept(_ page: Int) -> Bool {
        guard page == requestedPage else { return false }
        displayedPage = page
        return true
    }
}

struct TopicDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary

    let topicID: Int
    let boardID: Int?

    @State private var topic: NativeTopic? = nil
    @State private var board: NativeBoard? = nil
    @State private var posts: [NativePost] = []
    @State private var paging: NativeTopicPaging
    @State private var loading = false
    @State private var error: String? = nil
    @State private var isFavorite = false
    @State private var favoriteBusy = false
    @State private var showReply = false
    @State private var quotedPost: NativePost? = nil
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var hotPosts: [NativePost] = []
    @State private var hotLoaded = false
    @State private var opPost: NativePost? = nil
    @State private var linkedTopic: NativeLinkedTopic? = nil
    @State private var linkedBoard: NativeLinkedBoard? = nil
    @State private var linkedUser: NativeLinkedUser? = nil
    @State private var showNote = false
    @State private var voteInfo: NativeVoteInfo? = nil
    @State private var voteLoaded = false
    @State private var signatures: [Int: String] = [:]
    @State private var signatureChecked: Set<Int> = []
    @State private var avatars: [Int: URL] = [:]
    @State private var genders: [Int: Int] = [:]
    @State private var targetFloor: Int? = nil
    @State private var highlightedPostID: Int? = nil
    @State private var scrollNonce = 0
    @State private var showFloorJump = false
    @State private var showFullTextSearch = false
    @State private var traceRequest: NativeTraceRequest? = nil
    @AppStorage("native.saveBrowseProgress") private var saveBrowseProgress = false
    @State private var scrollToTopOnNextLoad = false
    @State private var didAutoResume: Bool
    @State private var pullNextTriggered = false
    @State private var loadID = UUID()

    private let pageSize = 10

    init(topicID: Int, boardID: Int?, initialPage: Int = 1, initialFloor: Int? = nil) {
        self.topicID = topicID
        self.boardID = boardID
        let resolvedPage = initialFloor.map { max(1, ($0 + 9) / 10) } ?? max(1, initialPage)
        _paging = State(initialValue: NativeTopicPaging(initialPage: resolvedPage))
        _targetFloor = State(initialValue: initialFloor)
        _didAutoResume = State(initialValue: initialPage != 1 || initialFloor != nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                if let topic { header(topic) }
                NativeLibraryStatusView().padding(.horizontal, 16)

                if let topic, topic.isPosterOnly == true {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                        Text("该主题仅楼主可见")
                            .font(ShellTheme.Fonts.footnote)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ShellTheme.warning)
                    .padding(10)
                    .background(ShellTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if page == 1, let opPost {
                    PostCard(
                        post: opPost,
                        topicTitle: topic?.title,
                        signature: opPost.userId.flatMap { signatures[$0] },
                        highlighted: highlightedPostID == opPost.id,
                        avatarURL: opPost.userId.flatMap { avatars[$0] },
                        gender: opPost.userId.flatMap { genders[$0] },
                        onChanged: {
                            Task { await load() }
                        },
                        onTrace: {
                            traceRequest = NativeTraceRequest(postID: opPost.id, floor: opPost.floor)
                        },
                        onQuote: {
                            openReply(quoted: opPost)
                        }
                    )
                    .id(floorAnchor(opPost.id))
                    .accessibilityIdentifier("topic.floor.\(opPost.floor ?? 1)")
                }

                if page == 1, let voteInfo {
                    NativeVoteCard(topicID: topicID, info: voteInfo) {
                        Task { await loadVote(force: true) }
                    }
                }

                if page == 1, !hotReplyPosts.isEmpty { hotReplies }

                if posts.isEmpty && loading {
                    ProgressView("正在加载楼层…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if posts.isEmpty, let error {
                    NativeStateView(icon: "exclamationmark.bubble", title: "主题无法加载", message: error, action: {
                        Task { await load() }
                    })
                    .frame(minHeight: 280)
                } else {
                    ForEach(displayPosts) { post in
                        PostCard(
                            post: post,
                            topicTitle: topic?.title,
                            signature: post.userId.flatMap { signatures[$0] },
                            highlighted: highlightedPostID == post.id,
                            avatarURL: post.userId.flatMap { avatars[$0] },
                            gender: post.userId.flatMap { genders[$0] },
                            onChanged: {
                                Task { await load() }
                            },
                            onTrace: {
                                traceRequest = NativeTraceRequest(postID: post.id, floor: post.floor)
                            },
                            onQuote: {
                                openReply(quoted: post)
                            }
                        )
                        .id(floorAnchor(post.id))
                        .accessibilityIdentifier("topic.floor.\(post.floor ?? 0)")
                    }
                    if page < pageCount, posts.count >= pageSize {
                        Text("上拉进入下一页")
                            .font(ShellTheme.Fonts.metadata)
                            .foregroundStyle(ShellTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    }
                    Color.clear
                        .frame(height: 1)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: ShellTheme.Metrics.maximumReadingWidth)
            .frame(maxWidth: .infinity)
            .id("topic-top")
            .background(
                ScrollBottomObserver(threshold: 100) {
                    handlePullNext()
                }
            )
            }
            .onChange(of: page) { _, _ in
                pullNextTriggered = false
            }
            .onChange(of: loading) { _, value in
                if !value { scrollToTarget(proxy) }
            }
            .onChange(of: scrollNonce) { _, _ in
                scrollToTarget(proxy)
            }
            .onAppear {
                scrollToTarget(proxy)
            }
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBars
        }
        .refreshable { await load() }
        .task(id: paging.requestedPage) { await load() }
        .task { await loadFavorite() }
        .task { await loadHot() }
        .onDisappear {
            if saveBrowseProgress, let displayedPage = paging.displayedPage {
                library.recordPosition(topicID: topicID, page: displayedPage, floor: posts.first?.floor)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let topic = NativeLinkedTopic(url: url) {
                linkedTopic = topic
                return .handled
            }
            if let board = NativeLinkedBoard(url: url) {
                linkedBoard = board
                return .handled
            }
            if let user = NativeLinkedUser(url: url) {
                linkedUser = user
                return .handled
            }
            return .systemAction
        })
        .navigationDestination(item: $linkedTopic) { link in
            TopicDetailView(topicID: link.id, boardID: nil, initialPage: link.page, initialFloor: link.floor)
        }
        .navigationDestination(item: $linkedBoard) { link in
            BoardTopicsView(board: NativeBoard.placeholder(id: link.id))
        }
        .navigationDestination(item: $linkedUser) { link in
            UserProfileView(userID: link.userID, userName: link.userName)
        }
        .sheet(isPresented: $showReply, onDismiss: { quotedPost = nil }) {
            ReplyComposer(topicID: topicID, quotedPost: quotedPost, allowReplyTail: topic != nil && board != nil && topic?.isAnonymous != true && topic?.isPosterOnly != true && (topic?.allowedViewerState ?? 0) == 0 && (board?.anonymousState ?? 0) == 0) {
                let nextPage = max(1, ((topic?.replyCount ?? 0) + 11) / pageSize)
                requestPage(nextPage)
            }
        }
        .sheet(isPresented: $showNote) {
            TopicNoteView(topicID: topicID, topicTitle: topic?.title ?? "主题 #\(topicID)")
        }
        .sheet(isPresented: $showFloorJump) {
            FloorJumpView(maxFloor: max(1, (topic?.replyCount ?? 0) + 1)) { floor in
                jumpToFloor(floor)
            }
        }
        .sheet(isPresented: $showFullTextSearch) {
            TopicFullTextSearchView(
                topicID: topicID,
                maxPage: pageCount
            ) { floor in
                jumpToFloor(floor)
            }
        }
        .sheet(item: $traceRequest) { request in
            ConversationView(
                topicID: topicID,
                focusPostID: request.postID,
                focusFloor: request.floor
            ) { floor in
                jumpToFloor(floor)
            }
        }
        .alert("提示", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var page: Int { paging.visiblePage }

    private func pageLoadError(_ error: String) -> String {
        guard let displayedPage = paging.displayedPage, displayedPage != paging.requestedPage else { return error }
        return "第 \(paging.requestedPage) 页未能加载，仍显示第 \(displayedPage) 页。\n\(error)"
    }

    private var pageCount: Int {
        let total = (topic?.replyCount ?? 0) + 1
        return max(1, (total + pageSize - 1) / pageSize)
    }

    private var resolvedBoardID: Int? {
        boardID ?? topic?.boardId ?? board?.id
    }

    private var displayPosts: [NativePost] {
        guard let opPost else { return posts }
        return posts.filter { $0.id != opPost.id }
    }

    private var hotReplyPosts: [NativePost] {
        guard let opPost else { return hotPosts }
        return hotPosts.filter { $0.id != opPost.id }
    }

    private var hotReplies: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("热评")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ShellTheme.primaryText)
                Text("\(hotReplyPosts.count)")
                    .font(ShellTheme.Fonts.metadata)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
            .padding(.horizontal, 16)
            ForEach(hotReplyPosts) { post in
                PostCard(
                    post: post,
                    isHot: true,
                    signature: post.userId.flatMap { signatures[$0] },
                    highlighted: highlightedPostID == post.id,
                    avatarURL: post.userId.flatMap { avatars[$0] },
                    gender: post.userId.flatMap { genders[$0] },
                    onTrace: {
                        traceRequest = NativeTraceRequest(postID: post.id, floor: post.floor)
                    },
                    onQuote: {
                        openReply(quoted: post)
                    }
                )
                .id(hotAnchor(post.id))
            }
        }
        .padding(.bottom, 4)
    }

    private func header(_ topic: NativeTopic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title ?? "主题 #\(topic.id)")
                .font(ShellTheme.Fonts.topicTitle)
                .foregroundStyle(ShellTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("topic.title")
            NativeTopicMetadata(
                author: topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"),
                userNote: topic.isAnonymous == true ? nil : topic.userId.map { library.userNote(for: $0) },
                replyCount: topic.replyCount, hitCount: topic.hitCount,
                date: NativeFormat.date(topic.time)
            )
            if let resolvedBoardID {
                NavigationLink {
                    BoardTopicsView(board: board ?? NativeBoard.placeholder(id: resolvedBoardID))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                        Text(board?.name ?? "版面 #\(resolvedBoardID)")
                    }
                    .font(ShellTheme.Fonts.metadata)
                    .foregroundStyle(ShellTheme.link)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityIdentifier("topic.board")
            }
            if !library.note(for: topic.id).isEmpty {
                Text("备注：\(library.note(for: topic.id))")
                    .font(ShellTheme.Fonts.metadata)
                    .foregroundStyle(ShellTheme.warning)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
    }

    private var bottomBars: some View {
        VStack(spacing: 4) {
            if !posts.isEmpty, let error {
                NativeInlineRetry(message: pageLoadError(error)) { Task { await load() } }
                    .accessibilityIdentifier("topic.pageError")
            } else if loading, paging.requestedPage != page {
                ProgressView("正在加载第 \(paging.requestedPage) 页…")
                    .font(ShellTheme.Fonts.metadata)
            }
            if pageCount > 1 {
                if dynamicTypeSize.isAccessibilitySize {
                    pageIndicator
                    HStack(spacing: 8) { previousPageButton; nextPageButton }
                } else {
                    HStack(spacing: 8) { previousPageButton; pageIndicator; nextPageButton }
                }
            }
            HStack(spacing: 12) {
                Button { Task { await toggleFavorite() } } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .frame(minWidth: 44, minHeight: 48)
                }
                .accessibilityLabel(isFavorite ? "取消收藏" : "收藏主题")
                .accessibilityIdentifier("topic.favorite")
                .disabled(favoriteBusy)

                Button { openReply() } label: {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NativePrimaryButtonStyle())
                .accessibilityIdentifier("topic.reply")

                Menu {
                    if let topic {
                        Button { library.toggleReadLater(topic) } label: {
                            Label(library.isReadLater(topic.id) ? "取消稍后再看" : "稍后再看", systemImage: "bookmark")
                        }
                    }
                    Button { showFloorJump = true } label: { Label("跳转楼层", systemImage: "number") }
                    Button { showFullTextSearch = true } label: { Label("全文搜索", systemImage: "text.magnifyingglass") }
                    Button { showNote = true } label: { Label("主题备注", systemImage: "note.text") }
                    ShareLink(item: URL(string: "https://www.cc98.org/topic/\(topicID)")!) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 48)
                }
                .accessibilityLabel("主题更多操作")
                .accessibilityIdentifier("topic.more")
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: ShellTheme.Metrics.maximumReadingWidth)
        .frame(maxWidth: .infinity)
        .background(ShellTheme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private var pageIndicator: some View {
        Button { showFloorJump = true } label: {
            Text("\(page) / \(pageCount)")
                .font(ShellTheme.Fonts.metadata).monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("第\(page)页，共\(pageCount)页；跳转楼层")
        .accessibilityIdentifier("topic.pageIndicator")
    }

    private var previousPageButton: some View {
        Button { turnPage(-1) } label: {
            Label("上一页", systemImage: "chevron.left")
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(ShellTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(page <= 1 ? ShellTheme.secondaryText : ShellTheme.accent)
        .disabled(page <= 1 || loading)
        .accessibilityIdentifier("topic.previousPage")
    }

    private var nextPageButton: some View {
        Button { turnPage(1) } label: {
            Label("下一页", systemImage: "chevron.right")
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(ShellTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(page >= pageCount ? ShellTheme.secondaryText : ShellTheme.accent)
        .disabled(page >= pageCount || loading)
        .accessibilityIdentifier("topic.nextPage")
    }

    private func handlePullNext() {
        guard page < pageCount,
              !loading,
              error == nil,
              !pullNextTriggered,
              posts.count >= pageSize else {
            return
        }
        pullNextTriggered = true
        turnPage(1)
    }

    private func turnPage(_ delta: Int) {
        let target = page + delta
        guard target >= 1, target <= pageCount else { return }
        targetFloor = nil
        scrollToTopOnNextLoad = true
        requestPage(target)
    }

    private func requestPage(_ target: Int) {
        if paging.requestedPage == target {
            // A retry of a failed page must run even though the task ID is unchanged.
            Task { await load() }
        } else {
            paging.request(target)
        }
    }

    private func openReply(quoted: NativePost? = nil) {
        guard auth.profile != nil else {
            alertMessage = "请先在「我的」登录，再参与回复。"
            showAlert = true
            return
        }
        if topic?.isPosterOnly == true, auth.profile?.id != topic?.userId {
            alertMessage = "该主题仅楼主可见，无法回复。"
            showAlert = true
            return
        }
        quotedPost = quoted
        showReply = true
    }

    @MainActor
    private func loadFavorite() async {
        guard auth.profile != nil else { return }
        isFavorite = (try? await app.api.isFavorite(topicID: topicID)) ?? false
    }

    @MainActor
    private func loadHot() async {
        guard !hotLoaded else { return }
        hotLoaded = true
        hotPosts = (try? await app.api.hotPosts(topicID: topicID)) ?? []
        await loadSignatures(for: hotPosts)
    }

    @MainActor
    private func loadVote(force: Bool = false) async {
        guard force || !voteLoaded else { return }
        voteLoaded = true
        voteInfo = try? await app.api.voteInfo(topicID: topicID)
    }

    @MainActor
    private func loadSignatures(for posts: [NativePost]) async {
        let ids = Set(posts.filter { $0.isAnonymous != true }.compactMap(\.userId)).filter { $0 > 0 && !signatureChecked.contains($0) }
        guard !ids.isEmpty else { return }
        for id in ids {
            signatureChecked.insert(id)
            Task {
                if let user = try? await app.api.user(id: id) {
                    await MainActor.run {
                        if let signature = user.signatureCode, !signature.isEmpty {
                            signatures[id] = signature
                        }
                        if let avatar = user.avatarURL {
                            avatars[id] = avatar
                        }
                        if let gender = user.gender {
                            genders[id] = gender
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard paging.isShowingRequestedPage else { return }
        if let targetFloor {
            var candidates: [NativePost] = []
            if let opPost { candidates.append(opPost) }
            candidates.append(contentsOf: posts)
            if let post = candidates.first(where: { $0.floor == targetFloor }) {
                withAnimation(reduceMotion ? nil : .default) {
                    proxy.scrollTo(floorAnchor(post.id), anchor: .top)
                }
                highlightedPostID = post.id
                self.targetFloor = nil
                scrollToTopOnNextLoad = false
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if highlightedPostID == post.id {
                        highlightedPostID = nil
                    }
                }
            }
            return
        }

        if scrollToTopOnNextLoad {
            withAnimation(reduceMotion ? nil : .default) {
                proxy.scrollTo("topic-top", anchor: .top)
            }
            scrollToTopOnNextLoad = false
        }
    }

    private func jumpToFloor(_ floor: Int) {
        let maxFloor = max(1, (topic?.replyCount ?? 0) + 1)
        let clamped = min(max(1, floor), maxFloor)
        targetFloor = clamped
        scrollToTopOnNextLoad = false
        let targetPage = max(1, (clamped + 9) / pageSize)
        if paging.requestedPage != targetPage || paging.displayedPage != targetPage {
            requestPage(targetPage)
        } else {
            scrollNonce += 1
        }
    }

    private func floorAnchor(_ postID: Int) -> String {
        "floor-\(postID)"
    }

    private func hotAnchor(_ postID: Int) -> String {
        "hot-\(postID)"
    }

    @MainActor
    private func toggleFavorite() async {
        guard auth.profile != nil else {
            alertMessage = "请先在「我的」登录，再收藏主题。"
            showAlert = true
            return
        }
        guard !favoriteBusy else { return }
        favoriteBusy = true
        do {
            if isFavorite {
                try await app.api.removeFavorite(topicID: topicID)
            } else {
                try await app.api.addFavorite(topicID: topicID)
            }
            isFavorite.toggle()
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
        favoriteBusy = false
    }

    @MainActor
    private func load() async {
        let requestID = UUID()
        loadID = requestID
        let requestedPage = paging.requestedPage
        loading = true
        error = nil
        do {
            async let topicRequest = app.api.topic(id: topicID)
            async let postsRequest = app.api.posts(topicID: topicID, from: (requestedPage - 1) * pageSize, size: pageSize)
            let loadedTopic = try await topicRequest
            let loadedPosts = try await postsRequest
            guard requestID == loadID, paging.accept(requestedPage) else { return }
            topic = loadedTopic
            posts = loadedPosts
            if page == 1 {
                opPost = loadedPosts.first
            }
            if board == nil, let boardID = loadedTopic.boardId ?? self.boardID {
                Task {
                    if let loaded = try? await app.api.board(id: boardID) {
                        board = loaded
                    }
                }
            }
            library.recordHistory(loadedTopic)
            if page == 1, saveBrowseProgress, !didAutoResume,
               let saved = library.lastPosition(for: topicID),
               saved.page > 1 || (saved.floor ?? 1) > 1 {
                didAutoResume = true
                targetFloor = saved.floor
                if saved.page > 1 {
                    loading = false
                    paging.request(saved.page)
                    return
                }
            }
            if saveBrowseProgress, page > 1 {
                library.recordPosition(topicID: topicID, page: page, floor: loadedPosts.first?.floor)
            }
            if loadedTopic.isVote == true {
                await loadVote()
            }
            await loadSignatures(for: loadedPosts)
        } catch {
            guard requestID == loadID else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if requestID == loadID { loading = false }
    }
}

enum NativeReplyTail {
    static let text = "[align=right]——来自「[url=https://www.cc98.org/topic/6521472][color=#eb2f96]C[/color][color=#de2f9d]C[/color][color=#d02fa3]9[/color][color=#c32faa]8[/color] [color=#b52fb0]R[/color][color=#a82eb7]e[/color][color=#9a2ebd]b[/color][color=#8d2ec4]o[/color][color=#7f2eca]r[/color][color=#722ed1]n[/color][/url] [color=#13c2c2]i[/color][color=#159de1]O[/color][color=#1677ff]S[/color]」[/align]"

    static func appending(to content: String) -> String {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("——来自「"), !value.contains("topic/6521472") else { return content }
        return value + "\n\n" + text
    }
}

struct ReplyComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss

    let topicID: Int
    let quotedPost: NativePost?
    let allowReplyTail: Bool
    var onSent: () -> Void
    @AppStorage("native.replyRebornTail") private var replyTail = true

    @State private var text: String
    @State private var selection = NSRange(location: 0, length: 0)
    @StateObject private var editor = UBBEditorController()
    @State private var sending = false
    @State private var uploading = false
    @State private var showExitConfirmation = false
    @State private var didRestoreDraft = false
    @State private var completed = false
    @State private var errorMessage: String? = nil
    @FocusState private var focused: Bool

    private var draftKey: String {
        if let quotedPost {
            return "reply.quote:\(topicID):\(quotedPost.id)"
        }
        return "reply:\(topicID)"
    }

    init(topicID: Int, quotedPost: NativePost? = nil, allowReplyTail: Bool = true, onSent: @escaping () -> Void) {
        self.topicID = topicID
        self.quotedPost = quotedPost
        self.allowReplyTail = allowReplyTail
        self.onSent = onSent
        _text = State(initialValue: quotedPost.map { ReplyComposer.quoteText(topicID: topicID, post: $0) } ?? "")
    }

    private static func quoteText(topicID: Int, post: NativePost) -> String {
        let floor = post.floor ?? 0
        let page = max(1, (max(1, floor) + 9) / 10)
        let name = post.isAnonymous == true ? "匿名" : (post.userName ?? "用户")
        let time = NativeFormat.date(post.time)
        return "[quote][b]以下是引用\(floor)楼：用户\(name)在\(time)的发言：\n[color=blue][url=/topic/\(topicID)/\(page)#\(floor)]>>查看原帖<<[/url][/color][/b]\(post.content ?? "")[/quote]\n"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                if auth.profile == nil {
                    Text("请先在「我的」登录后再回复。")
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.danger)
                }
                UBBFormatBar(text: $text, selection: $selection, editor: editor)
                    .disabled(sending)
                UBBTextEditor(text: $text, selection: $selection, controller: editor, minHeight: 240)
                    .frame(minHeight: 240)
                    .padding(4)
                    .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ShellTheme.separator, lineWidth: 0.5)
                    )
                    .disabled(sending)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("预览") {
                        UBBContentView(source: text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(ShellTheme.Fonts.metadata)
                }
                ComposerAttachmentsBar(text: $text, selection: $selection, editor: editor) { uploading = $0 }
                    .disabled(sending)
                Text("\(submittedContent.count) / 8000")
                    .font(ShellTheme.Fonts.metadata)
                    .foregroundStyle(submittedContent.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
                if shouldAppendTail {
                    Text("发送时附加 Reborn 小尾巴，已计入字数。")
                        .font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                }
                if let errorMessage {
                    Text(errorMessage).font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reply.error")
                }
                NativeLibraryStatusView()
                if library.lastSaveError == nil, library.draft(for: draftKey) == text, !text.isEmpty {
                    Text("草稿已保存到本机").font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                }
                }
                .padding(16)
            }
            .background(ShellTheme.pageBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("回复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dismiss() }
                        else { showExitConfirmation = true }
                    }
                    .disabled(sending || uploading)
                    .accessibilityIdentifier("reply.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "发送中…" : "发送") { Task { await send() } }
                        .disabled(sending || uploading || auth.profile == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submittedContent.count > 8000)
                        .accessibilityIdentifier("reply.send")
                }
            }
            .onAppear {
                guard !didRestoreDraft else { return }
                didRestoreDraft = true
                let saved = library.draft(for: draftKey)
                if !saved.isEmpty { text = saved }
                library.setDraftContext(for: draftKey, topicID: topicID, boardID: quotedPost?.boardId, floor: quotedPost?.floor)
                if !text.isEmpty { library.setDraft(text, for: draftKey) }
                focused = true
            }
            .onChange(of: text) { _, value in
                if !completed { library.setDraft(value, for: draftKey) }
            }
            .interactiveDismissDisabled(sending || uploading || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .confirmationDialog("保留这份回复草稿？", isPresented: $showExitConfirmation, titleVisibility: .visible) {
                Button("保存草稿并退出") {
                    if library.setDraft(text, for: draftKey) { dismiss() }
                }
                Button("丢弃草稿并退出", role: .destructive) {
                    if library.clearDraft(for: draftKey) { completed = true; dismiss() }
                }
                Button("继续编辑", role: .cancel) {}
            }
        }
    }

    private var shouldAppendTail: Bool { replyTail && allowReplyTail && quotedPost?.isAnonymous != true }

    private var submittedContent: String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        return shouldAppendTail ? NativeReplyTail.appending(to: base) : base
    }

    @MainActor
    private func send() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        let value = submittedContent
        guard value.count <= 8000 else {
            errorMessage = "内容不能超过 8000 个字。"
            return
        }
        guard !sending, !uploading else { return }
        sending = true
        errorMessage = nil
        do {
            try await app.api.reply(topicID: topicID, content: value, parentID: quotedPost?.id)
            completed = true
            library.clearDraft(for: draftKey)
            onSent()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription + "\n正文和草稿已保留；若发送结果不明，请先检查原帖，勿重复发送。"
        }
        sending = false
    }
}

struct PostCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary

    let post: NativePost
    let isHot: Bool
    let topicTitle: String?
    let signature: String?
    let highlighted: Bool
    let avatarURL: URL?
    let gender: Int?
    let onChanged: (() -> Void)?
    let onTrace: (() -> Void)?
    let onQuote: (() -> Void)?

    @State private var likeState: Int
    @State private var likeCount: Int?
    @State private var dislikeCount: Int?
    @State private var busy = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var revealBlocked = false
    @State private var showEdit = false
    @State private var showRating = false
    @State private var awards: [NativeAward]
    @State private var awardsChecked: Bool
    @State private var editingUserNote = false
    @State private var noteInput = ""

    init(
        post: NativePost,
        isHot: Bool = false,
        topicTitle: String? = nil,
        signature: String? = nil,
        highlighted: Bool = false,
        avatarURL: URL? = nil,
        gender: Int? = nil,
        onChanged: (() -> Void)? = nil,
        onTrace: (() -> Void)? = nil,
        onQuote: (() -> Void)? = nil
    ) {
        self.post = post
        self.isHot = isHot
        self.topicTitle = topicTitle
        self.signature = signature
        self.highlighted = highlighted
        self.avatarURL = avatarURL
        self.gender = gender
        self.onChanged = onChanged
        self.onTrace = onTrace
        self.onQuote = onQuote
        _likeState = State(initialValue: post.likeState ?? 0)
        _likeCount = State(initialValue: post.likeCount)
        _dislikeCount = State(initialValue: post.dislikeCount)
        _awards = State(initialValue: post.awards ?? [])
        _awardsChecked = State(initialValue: post.awards != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if post.isAnonymous != true, let userID = post.userId, userID > 0 {
                    NavigationLink {
                        UserProfileView(userID: userID, userName: post.userName)
                    } label: {
                        NativeAvatar(url: displayAvatarURL, name: post.isAnonymous == true ? "匿名" : post.userName, size: 36)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                } else {
                    NativeAvatar(url: displayAvatarURL, name: post.isAnonymous == true ? "匿名" : post.userName, size: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.isAnonymous == true ? "匿名" : (post.userName ?? "未知作者"))
                            .font(.body.weight(.medium))
                            .foregroundStyle(ShellTheme.primaryText)
                        HStack(spacing: 6) {
                            if post.isLZ == true { badge("楼主", color: ShellTheme.accent) }
                            if post.isBest == true { badge("精彩", color: ShellTheme.warning) }
                            if isHot { badge("热评", color: ShellTheme.warning) }
                        }
                        if post.isAnonymous != true, let userID = post.userId, !library.userNote(for: userID).isEmpty {
                            Text("备注：\(library.userNote(for: userID))")
                                .font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("\(floorTitle) · \(NativeFormat.date(post.time))")
                        .font(ShellTheme.Fonts.metadata)
                        .foregroundStyle(ShellTheme.secondaryText)
                        .contextMenu {
                            if let topicID = post.topicId, let floor = post.floor, floor > 0 {
                                Button {
                                    let page = max(1, (floor + 9) / 10)
                                    UIPasteboard.general.string = "https://www.cc98.org/topic/\(topicID)/\(page)#\(floor)"
                                } label: {
                                    Label("复制楼层链接", systemImage: "link")
                                }
                            }
                        }
                }
                Spacer(minLength: 0)
            }

            if isBlocked {
                blockedNotice
            } else {
                if let content = post.content, !content.isEmpty {
                    UBBContentView(source: content, markdown: post.contentType == 1)
                        .textSelection(.enabled)
                } else {
                    Text("（内容为空）")
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.secondaryText)
                }

                if post.isDeleted == true {
                    Text("该楼层已被删除")
                        .font(ShellTheme.Fonts.metadata)
                        .foregroundStyle(ShellTheme.danger)
                }
            }

            if !isBlocked, post.isAnonymous != true, let signature, !signature.isEmpty {
                Divider().overlay(ShellTheme.separator)
                UBBContentView(source: signature)
                    .opacity(0.85)
            }

            if !isBlocked, !awards.isEmpty {
                RatingRecordTable(awards: awards)
            }

            ViewThatFits(in: .horizontal) {
                postActions(compact: false)
                postActions(compact: true)
            }
            NativeLibraryStatusView()

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(
                    highlighted ? ShellTheme.accent : ShellTheme.separator,
                    lineWidth: highlighted ? 1.5 : 0.5
                )
        )
        .alert("提示", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showEdit) {
            EditPostComposer(post: post, topicTitle: topicTitle) {
                onChanged?()
            }
        }
        .sheet(isPresented: $showRating) {
            RatingComposer(post: post)
        }
        .alert("用户备注", isPresented: $editingUserNote) {
            TextField("最多 80 字", text: $noteInput)
                .onChange(of: noteInput) { _, value in noteInput = String(value.prefix(80)) }
            Button("保存") {
                if let userID = post.userId { library.setUserNote(noteInput, for: userID) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅保存在当前账号的本机数据中，真实用户名保持不变。")
        }
        .task(id: post.id) {
            guard !awardsChecked else { return }
            awardsChecked = true
            awards = (try? await app.api.postAwards(postID: post.id)) ?? []
        }
    }

    private func postActions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { Task { await setLike(1) } } label: {
                Label(NativeFormat.count(likeCount), systemImage: likeState == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(likeState == 1 ? ShellTheme.accent : ShellTheme.secondaryText)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(busy)
            .accessibilityLabel("\(likeState == 1 ? "取消赞" : "赞")，\(NativeFormat.count(likeCount))")
            Button { Task { await setLike(2) } } label: {
                Label(NativeFormat.count(dislikeCount), systemImage: likeState == 2 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(likeState == 2 ? ShellTheme.danger : ShellTheme.secondaryText)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(busy)
            .accessibilityLabel("\(likeState == 2 ? "取消踩" : "踩")，\(NativeFormat.count(dislikeCount))")
            Spacer(minLength: 0)
            if let onQuote {
                Button(action: onQuote) {
                    if compact { Image(systemName: "quote.bubble").frame(minWidth: 44, minHeight: 44) }
                    else { Label("引用", systemImage: "quote.bubble").frame(minWidth: 44, minHeight: 44) }
                }
                .accessibilityLabel("引用\(floorTitle)")
                .accessibilityIdentifier("topic.quote.\(post.floor ?? 0)")
            }
            Menu {
                if let onTrace { Button(action: onTrace) { Label("查看对话", systemImage: "bubble.left.and.bubble.right") } }
                Button {
                    if auth.profile == nil {
                        alertMessage = "请先在「我的」登录，再参与风评。"; showAlert = true
                    } else { showRating = true }
                } label: { Label("风评", systemImage: "star") }
                if canEdit { Button { showEdit = true } label: { Label("编辑原帖", systemImage: "pencil") } }
                if let topicID = post.topicId, let floor = post.floor, floor > 0 {
                    Button {
                        UIPasteboard.general.string = "https://www.cc98.org/topic/\(topicID)/\(max(1, (floor + 9) / 10))#\(floor)"
                    } label: { Label("复制楼层链接", systemImage: "link") }
                }
                if post.isAnonymous != true, let userID = post.userId, userID > 0 {
                    Button {
                        noteInput = library.userNote(for: userID); editingUserNote = true
                    } label: { Label("用户备注", systemImage: "note.text") }
                    Button(role: .destructive) { library.addBlockedUserID(String(userID)) } label: {
                        Label("屏蔽此用户", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("\(floorTitle)更多操作")
            .accessibilityIdentifier("topic.postMore.\(post.floor ?? 0)")
        }
        .font(ShellTheme.Fonts.metadata)
        .buttonStyle(.plain)
    }

    private var canEdit: Bool {
        guard let myID = auth.profile?.id, let postUser = post.userId else { return false }
        return myID == postUser && post.isAnonymous != true
    }

    private var displayAvatarURL: URL? {
        NativeAvatarURLs.resolved(
            url: avatarURL,
            gender: gender,
            anonymous: post.isAnonymous == true
        )
    }

    private var isBlocked: Bool {
        guard !revealBlocked else { return false }
        return library.shouldBlock(post: post)
    }

    private var blockedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
            Text(blockReason)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("显示") {
                revealBlocked = true
            }
            .font(ShellTheme.Fonts.metadata.weight(.medium))
            .foregroundStyle(ShellTheme.accent)
            .frame(minWidth: 44, minHeight: 44)
        }
        .font(ShellTheme.Fonts.footnote)
        .foregroundStyle(ShellTheme.secondaryText)
        .padding(10)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var blockReason: String {
        if library.isUserBlocked(id: post.userId, name: post.userName) {
            return post.isAnonymous == true ? "命中用户屏蔽规则" : "已屏蔽用户 \(post.userName ?? "")"
        }
        return "命中屏蔽关键词"
    }

    private var floorTitle: String {
        guard let floor = post.floor, floor > 0 else { return "首楼" }
        return "\(floor) 楼"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @MainActor
    private func setLike(_ target: Int) async {
        guard auth.profile != nil else {
            alertMessage = "请先在「我的」登录，再参与赞踩。"
            showAlert = true
            return
        }
        guard !busy else { return }
        busy = true
        do {
            let clearing = likeState == target
            if clearing {
                try await app.api.clearLike(postID: post.id)
            } else {
                try await app.api.setLike(postID: post.id, state: target)
            }
            let state = try await app.api.likeState(postID: post.id)
            let resolved = state.likeState ?? (clearing ? 0 : target)
            likeState = resolved
            likeCount = state.likeCount ?? likeCount
            dislikeCount = state.dislikeCount ?? dislikeCount
            if clearing, resolved != 0 {
                alertMessage = "CC98 没有接受取消操作，赞踩状态没有改变。"
                showAlert = true
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
        busy = false
    }
}

struct FloorJumpView: View {
    let maxFloor: Int
    var onJump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("跳转到楼层") {
                    TextField("1 – \(max(1, maxFloor))", text: $text)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .accessibilityIdentifier("topic.floorInput")
                    Button("跳转") {
                        jump()
                    }
                    .disabled(Int(text) == nil)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("topic.floorGo")
                }
            }
            .navigationTitle("跳转楼层")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func jump() {
        guard let value = Int(text) else { return }
        let clamped = min(max(1, value), max(1, maxFloor))
        onJump(clamped)
        dismiss()
    }
}
