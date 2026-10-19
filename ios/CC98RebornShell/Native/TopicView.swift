import SwiftUI

struct TopicDetailView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

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
                    ForEach(posts) { post in
                        PostCard(post: post)
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
                ShareLink(item: URL(string: "https://www.cc98.org/topic/\(topicID)")!) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
        }
        .refreshable { await load() }
        .task(id: page) { await load() }
        .task { await loadFavorite() }
        .sheet(isPresented: $showReply) {
            ReplyComposer(topicID: topicID) {
                Task {
                    let nextPage = max(1, ((topic?.replyCount ?? 0) + 11) / pageSize)
                    page = nextPage
                    await load()
                }
            }
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

    let post: NativePost

    @State private var likeState: Int
    @State private var likeCount: Int
    @State private var dislikeCount: Int
    @State private var busy = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    init(post: NativePost) {
        self.post = post
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
                    }
                    Text("\(floorTitle) · \(NativeFormat.date(post.time))")
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }

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
