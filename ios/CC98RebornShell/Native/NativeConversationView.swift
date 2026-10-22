import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss

    let topicID: Int
    let focusPostID: Int?
    let focusFloor: Int?
    var onJump: (Int) -> Void

    @State private var items: [ConversationItem] = []
    @State private var loading = false
    @State private var progress = 0
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if loading && items.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在加载对话…已读取 \(progress) 楼")
                            .font(ShellTheme.Fonts.metadata)
                            .foregroundStyle(ShellTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty, let error {
                    NativeStateView(icon: "bubble.left.and.bubble.right", title: "对话无法加载", message: error, action: {
                        Task { await load() }
                    })
                } else if items.isEmpty {
                    NativeStateView(icon: "bubble.left.and.bubble.right", title: "没有找到对话", message: "该楼层没有可追溯的引用或回复。")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            Text("已读取本帖前 \(progress) 楼；对话最多追溯 500 楼、4 层回复，不包含范围外内容。")
                                .font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                                .padding(.horizontal, 16)
                            if let error { NativeInlineRetry(message: error) { Task { await load() } }.padding(.horizontal, 16) }
                            ForEach(items) { item in
                                ConversationRow(item: item) {
                                    onJump(item.post.floor ?? 1)
                                    dismiss()
                                }
                            }
                        }
                        .padding(.vertical, 16)
                        .frame(maxWidth: ShellTheme.Metrics.maximumReadingWidth)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("查看对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        var all: [NativePost] = []
        do {
            let maxPages = 50
            for page in 0..<maxPages {
                try Task.checkCancellation()
                let batch = try await app.api.posts(topicID: topicID, from: page * 10, size: 10)
                all.append(contentsOf: batch)
                progress = all.count
                if batch.count < 10 { break }
            }
            let built = buildItems(from: all)
            if built.isEmpty {
                error = "该楼层不在已读取的范围内，或没有引用关系。"
            }
            items = built
        } catch is CancellationError {
            loading = false
            return
        } catch {
            items = buildItems(from: all)
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func buildItems(from posts: [NativePost]) -> [ConversationItem] {
        var byID: [Int: NativePost] = [:]
        for post in posts { byID[post.id] = post }

        let focus = focusPostID.flatMap { byID[$0] } ?? posts.first { $0.floor == focusFloor }
        guard let focus else { return [] }

        var ancestors: [NativePost] = []
        var current = focus
        var seen: Set<Int> = [focus.id]
        while let parentID = current.parentId, parentID > 0, !seen.contains(parentID), let parent = byID[parentID] {
            ancestors.append(parent)
            seen.insert(parentID)
            current = parent
        }
        ancestors.reverse()

        var children: [Int: [NativePost]] = [:]
        for post in posts {
            guard let parentID = post.parentId, parentID > 0 else { continue }
            children[parentID, default: []].append(post)
        }
        for key in children.keys {
            children[key]?.sort { ($0.floor ?? 0) < ($1.floor ?? 0) }
        }

        var result: [ConversationItem] = ancestors.map {
            ConversationItem(post: $0, depth: 0, isFocus: false)
        }
        result.append(ConversationItem(post: focus, depth: 0, isFocus: true))

        var seenIDs = Set(result.map(\.post.id))
        var appended = 0
        func appendChildren(of parentID: Int, depth: Int) {
            guard depth <= 4, appended < 200 else { return }
            for child in children[parentID] ?? [] where !seenIDs.contains(child.id) {
                seenIDs.insert(child.id)
                result.append(ConversationItem(post: child, depth: depth, isFocus: false))
                appended += 1
                appendChildren(of: child.id, depth: depth + 1)
            }
        }
        appendChildren(of: focus.id, depth: 1)
        return result
    }
}

struct ConversationItem: Identifiable {
    let post: NativePost
    let depth: Int
    let isFocus: Bool

    var id: Int { post.id }
}

private struct ConversationRow: View {
    let item: ConversationItem
    var onJump: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if item.depth > 0 {
                Rectangle()
                    .fill(ShellTheme.accent.opacity(0.25))
                    .frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.isFocus ? "当前楼层 · \(item.post.floor ?? 0) 楼" : "\(item.post.floor ?? 0) 楼")
                            .font(ShellTheme.Fonts.metadata.weight(.semibold))
                            .foregroundStyle(item.isFocus ? ShellTheme.accent : ShellTheme.secondaryText)
                        Text(item.post.isAnonymous == true ? "匿名" : (item.post.userName ?? "未知作者"))
                            .font(ShellTheme.Fonts.body.weight(.medium))
                        Text(NativeFormat.date(item.post.time)).font(ShellTheme.Fonts.metadata)
                            .foregroundStyle(ShellTheme.secondaryText)
                        if item.depth > 0 {
                            Text("回复层级 \(item.depth)").font(ShellTheme.Fonts.metadata)
                                .foregroundStyle(ShellTheme.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("定位", action: onJump).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("conversation.floor.\(item.post.floor ?? 0)")
                }

                if item.post.isDeleted == true {
                    Text("该楼层已被删除")
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.danger)
                } else {
                    UBBContentView(source: item.post.content ?? "", markdown: item.post.contentType == 1)
                }
            }
        }
        .padding(16)
        .background(
            item.isFocus ? ShellTheme.accentSoft : ShellTheme.surface,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.isFocus ? ShellTheme.accent.opacity(0.5) : ShellTheme.separator, lineWidth: 0.5)
        )
    }
}
