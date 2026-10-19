import SwiftUI

struct NativeLinkedTopic: Identifiable, Hashable {
    let id: Int
    let page: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(), host == "www.cc98.org" || host == "cc98.org" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "topic", let topicID = Int(parts[1]) else { return nil }
        id = topicID
        page = parts.count >= 3 ? max(1, Int(parts[2]) ?? 1) : 1
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

struct TopicDetailView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary

    let topicID: Int
    let boardID: Int?

    @State private var topic: NativeTopic? = nil
    @State private var posts: [NativePost] = []
    @State private var page: Int
    @State private var loading = false
    @State private var error: String? = nil
    @State private var isFavorite = false
    @State private var favoriteBusy = false
    @State private var showReply = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var hotPosts: [NativePost] = []
    @State private var hotLoaded = false
    @State private var opPost: NativePost? = nil
    @State private var linkedTopic: NativeLinkedTopic? = nil
    @State private var linkedBoard: NativeLinkedBoard? = nil
    @State private var linkedUser: NativeLinkedUser? = nil
    @State private var showNote = false

    private let pageSize = 10

    init(topicID: Int, boardID: Int?, initialPage: Int = 1) {
        self.topicID = topicID
        self.boardID = boardID
        _page = State(initialValue: max(1, initialPage))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let topic { header(topic) }

                if let opPost {
                    PostCard(post: opPost, topicTitle: topic?.title, onChanged: {
                        Task { await load() }
                    })
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
                        PostCard(post: post, topicTitle: topic?.title, onChanged: {
                            Task { await load() }
                        })
                    }
                    if let error {
                        Text(error)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if pageCount > 1 { pager }
                }
            }
            .padding(16)
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle("主题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Label(isFavorite ? "已收藏" : "收藏", systemImage: isFavorite ? "star.fill" : "star")
                }
                .disabled(favoriteBusy)
                Spacer()
                Button {
                    openReply()
                } label: {
                    Label("回复", systemImage: "arrowshape.turn.up.left")
                }
                Spacer()
                Menu {
                    if let topic {
                        Button {
                            library.toggleReadLater(topic)
                        } label: {
                            Label(
                                library.isReadLater(topic.id) ? "取消稍后再看" : "稍后再看",
                                systemImage: library.isReadLater(topic.id) ? "bookmark.slash" : "bookmark"
                            )
                        }
                    }
                    Button {
                        showNote = true
                    } label: {
                        Label("主题备注", systemImage: "note.text")
                    }
                    ShareLink(item: URL(string: "https://www.cc98.org/topic/\(topicID)")!) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .refreshable { await load() }
        .task(id: page) { await load() }
        .task { await loadFavorite() }
        .task { await loadHot() }
        .task { await loadOP() }
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
            TopicDetailView(topicID: link.id, boardID: nil, initialPage: link.page)
        }
        .navigationDestination(item: $linkedBoard) { link in
            BoardTopicsView(board: NativeBoard.placeholder(id: link.id))
        }
        .navigationDestination(item: $linkedUser) { link in
            UserProfileView(userID: link.userID, userName: link.userName)
        }
        .sheet(isPresented: $showReply) {
            ReplyComposer(topicID: topicID) {
                Task {
                    let nextPage = max(1, ((topic?.replyCount ?? 0) + 11) / pageSize)
                    page = nextPage
                    await load()
                }
            }
        }
        .sheet(isPresented: $showNote) {
            TopicNoteView(topicID: topicID, topicTitle: topic?.title ?? "主题 #\(topicID)")
        }
        .alert("提示", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var pageCount: Int {
        let total = (topic?.replyCount ?? 0) + 1
        return max(1, (total + pageSize - 1) / pageSize)
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
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
            ForEach(hotReplyPosts) { post in
                PostCard(post: post, isHot: true)
            }
        }
        .padding(.bottom, 4)
    }

    private func header(_ topic: NativeTopic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title ?? "主题 #\(topic.id)")
                .font(ShellTheme.Fonts.pageTitle)
                .foregroundStyle(ShellTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"))
                Text(NativeFormat.date(topic.time))
                Spacer(minLength: 0)
                Text("回复 \(NativeFormat.count(topic.replyCount))")
                Text("点击 \(NativeFormat.count(topic.hitCount))")
            }
            .font(ShellTheme.Fonts.caption)
            .foregroundStyle(ShellTheme.secondaryText)
            if let boardID {
                Text("版面 #\(boardID)")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
            if !library.note(for: topic.id).isEmpty {
                Text("备注：\(library.note(for: topic.id))")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.warning)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
    }

    private var pager: some View {
        HStack {
            Button("上一页") {
                if page > 1 { page -= 1 }
            }
            .disabled(page <= 1 || loading)
            Spacer()
            Text("第 \(page) / \(pageCount) 页")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
            Spacer()
            Button("下一页") {
                if page < pageCount { page += 1 }
            }
            .disabled(page >= pageCount || loading)
        }
        .buttonStyle(.bordered)
        .tint(ShellTheme.accent)
        .padding(.vertical, 8)
    }

    private func openReply() {
        guard auth.profile != nil else {
            alertMessage = "请先在「我的」登录，再参与回复。"
            showAlert = true
            return
        }
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
    }

    @MainActor
    private func loadOP() async {
        guard opPost == nil else { return }
        opPost = try? await app.api.posts(topicID: topicID, from: 0, size: 1).first
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
        guard !loading else { return }
        loading = true
        error = nil
        do {
            async let topicRequest = app.api.topic(id: topicID)
            async let postsRequest = app.api.posts(topicID: topicID, from: (page - 1) * pageSize, size: pageSize)
            let loadedTopic = try await topicRequest
            let loadedPosts = try await postsRequest
            topic = loadedTopic
            posts = loadedPosts
            library.recordHistory(loadedTopic)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct ReplyComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @Environment(\.dismiss) private var dismiss

    let topicID: Int
    var onSent: () -> Void

    @State private var text = ""
    @State private var sending = false
    @State private var errorMessage: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                if auth.profile == nil {
                    Text("请先在「我的」登录后再回复。")
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.danger)
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240)
                    .padding(8)
                    .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ShellTheme.separator, lineWidth: 0.5)
                    )
                    .disabled(sending)
                ComposerImageButton(text: $text)
                    .disabled(sending)
                ComposerEmoticonButton(text: $text)
                    .disabled(sending)
                HStack {
                    Text("\(text.count) / 8000")
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(text.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
                    Spacer()
                    if let errorMessage {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(ShellTheme.danger)
                            .lineLimit(2)
                    }
                }
            }
            .padding(16)
            .background(ShellTheme.pageBackground)
            .navigationTitle("回复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") {
                        Task { await send() }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    @MainActor
    private func send() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard value.count <= 8000 else {
            errorMessage = "内容不能超过 8000 个字。"
            return
        }
        guard !sending else { return }
        sending = true
        errorMessage = nil
        do {
            try await app.api.reply(topicID: topicID, content: value)
            onSent()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        sending = false
    }
}

struct PostCard: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary

    let post: NativePost
    let isHot: Bool
    let topicTitle: String?
    let onChanged: (() -> Void)?

    @State private var likeState: Int
    @State private var likeCount: Int
    @State private var dislikeCount: Int
    @State private var busy = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var revealBlocked = false
    @State private var showEdit = false
    @State private var showRating = false

    init(post: NativePost, isHot: Bool = false, topicTitle: String? = nil, onChanged: (() -> Void)? = nil) {
        self.post = post
        self.isHot = isHot
        self.topicTitle = topicTitle
        self.onChanged = onChanged
        _likeState = State(initialValue: post.likeState ?? 0)
        _likeCount = State(initialValue: post.likeCount ?? 0)
        _dislikeCount = State(initialValue: post.dislikeCount ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                NativeAvatar(url: nil, name: post.userName, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(post.isAnonymous == true ? "匿名" : (post.userName ?? "未知作者"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ShellTheme.primaryText)
                        if post.isLZ == true { badge("楼主", color: ShellTheme.accent) }
                        if post.isBest == true { badge("精彩", color: ShellTheme.warning) }
                        if isHot { badge("热评", color: ShellTheme.warning) }
                    }
                    Text("\(floorTitle) · \(NativeFormat.date(post.time))")
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)
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
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.danger)
                }
            }

            HStack(spacing: 14) {
                Button {
                    Task { await setLike(1) }
                } label: {
                    Label(NativeFormat.count(likeCount), systemImage: likeState == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .foregroundStyle(likeState == 1 ? ShellTheme.accent : ShellTheme.secondaryText)
                }
                .disabled(busy)
                Button {
                    Task { await setLike(2) }
                } label: {
                    Label(NativeFormat.count(dislikeCount), systemImage: likeState == 2 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .foregroundStyle(likeState == 2 ? ShellTheme.danger : ShellTheme.secondaryText)
                }
                .disabled(busy)
                if canEdit {
                    Button {
                        showEdit = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                            .foregroundStyle(ShellTheme.secondaryText)
                    }
                }
                Button {
                    if auth.profile == nil {
                        alertMessage = "请先在「我的」登录，再参与风评。"
                        showAlert = true
                    } else {
                        showRating = true
                    }
                } label: {
                    Label("风评", systemImage: "star")
                        .foregroundStyle(ShellTheme.secondaryText)
                }
                Spacer(minLength: 0)
                if busy { ProgressView() }
            }
            .font(ShellTheme.Fonts.caption)
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
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
    }

    private var canEdit: Bool {
        guard let myID = auth.profile?.id, let postUser = post.userId else { return false }
        return myID == postUser && post.isAnonymous != true
    }

    private var isBlocked: Bool {
        guard !revealBlocked else { return false }
        return library.isUserBlocked(post.userName) || library.isContentBlocked(post.content)
    }

    private var blockedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
            Text(blockReason)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("显示") {
                revealBlocked = true
            }
            .font(ShellTheme.Fonts.caption.weight(.medium))
            .foregroundStyle(ShellTheme.accent)
        }
        .font(ShellTheme.Fonts.footnote)
        .foregroundStyle(ShellTheme.secondaryText)
        .padding(10)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var blockReason: String {
        if library.isUserBlocked(post.userName) {
            return "已屏蔽用户 \(post.userName ?? "")"
        }
        return "命中屏蔽关键词"
    }

    private var floorTitle: String {
        guard let floor = post.floor, floor > 0 else { return "首楼" }
        return "\(floor) 楼"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
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
            let next = likeState == target ? 0 : target
            try await app.api.setLike(postID: post.id, state: next)
            let state = try await app.api.likeState(postID: post.id)
            likeState = state.likeState ?? next
            likeCount = state.likeCount ?? likeCount
            dislikeCount = state.dislikeCount ?? dislikeCount
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
        busy = false
    }
}
