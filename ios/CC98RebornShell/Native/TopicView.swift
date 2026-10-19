import SwiftUI

struct TopicDetailView: View {
    @EnvironmentObject private var app: NativeAppModel

    let topicID: Int
    let boardID: Int?

    @State private var topic: NativeTopic?
    @State private var posts: [NativePost] = []
    @State private var page = 1
    @State private var loading = false
    @State private var error: String?

    private let pageSize = 10

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
        .refreshable { await load() }
        .task(id: page) { await load() }
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

struct PostCard: View {
    let post: NativePost

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
                Label(NativeFormat.count(post.likeCount), systemImage: "hand.thumbsup")
                Label(NativeFormat.count(post.dislikeCount), systemImage: "hand.thumbsdown")
                Spacer(minLength: 0)
            }
            .font(ShellTheme.Fonts.caption)
            .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
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
}
