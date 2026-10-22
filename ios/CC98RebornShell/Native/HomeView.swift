import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var library: NativeLibrary

    @State private var home: NativeHome?
    @State private var hot: [NativeHotTopic] = []
    @State private var loading = false
    @State private var error: String?
    @State private var hotTitle = "今日十大"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if let home {
                    List {
                        hotSection
                        if let error {
                            Section { NativeInlineRetry(message: error) { Task { await load() } } }
                        }
                        NativeLibraryStatusView()
                        statsSection(home)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(ShellTheme.pageBackground)
                    .refreshable { await load() }
                } else if loading {
                    ProgressView("正在连接 CC98…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ShellTheme.pageBackground)
                } else if let error {
                    NativeStateView(icon: "wifi.exclamationmark", title: "暂时无法加载", message: error, action: {
                        Task { await load() }
                    })
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("首页")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SearchView()
                    } label: {
                        Image(systemName: "magnifyingglass").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("搜索主题")
                    .accessibilityIdentifier("home.search")
                }
            }
        }
        .task { await load() }
    }

    private func statsSection(_ home: NativeHome) -> some View {
        Section("论坛概况") {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                stat("今日帖子", value: NativeFormat.count(home.todayCount))
                stat("在线", value: NativeFormat.count(home.onlineUserCount))
                stat("主题", value: NativeFormat.count(home.topicCount))
            }
            .padding(.vertical, 8)
        }
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(ShellTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(title)
                .font(ShellTheme.Fonts.metadata)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hotSection: some View {
        Section {
            if hot.isEmpty && error == nil {
                Text("暂时没有榜单内容。")
                    .font(ShellTheme.Fonts.metadata)
                    .foregroundStyle(ShellTheme.secondaryText)
            } else {
                ForEach(visibleHot, id: \.topic.id) { item in
                    HStack(alignment: .top, spacing: 0) {
                        NavigationLink {
                            TopicDetailView(topicID: item.topic.id, boardID: item.topic.boardId)
                        } label: {
                            HotTopicRow(rank: item.rank, topic: item.topic)
                        }
                        .accessibilityIdentifier("home.hot.\(item.topic.id)")
                        Menu { topicActions(item.topic) } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("主题操作")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { topicActions(item.topic) }
                }
                if visibleHot.count < hot.count {
                    Text("已按屏蔽规则隐藏 \(hot.count - visibleHot.count) 个主题，保留原始排名。")
                        .font(ShellTheme.Fonts.metadata)
                        .foregroundStyle(ShellTheme.secondaryText)
                }
            }
        } header: {
            Text(hotTitle)
        }
    }

    private var visibleHot: [(rank: Int, topic: NativeHotTopic)] {
        hot.enumerated().compactMap { index, topic in
            guard !library.isTopicBlocked(topic.id),
                  !library.isBoardBlocked(id: topic.boardId, name: topic.boardName),
                  !library.isTitleBlocked(topic.title),
                  !library.isUserBlocked(topic.authorName) else { return nil }
            return (index + 1, topic)
        }
    }

    @ViewBuilder
    private func topicActions(_ topic: NativeHotTopic) -> some View {
        Button {
            library.addReadLater(topicID: topic.id, title: topic.title, boardID: topic.boardId)
        } label: {
            Label("加入稍后再看", systemImage: "bookmark")
        }

        Button(role: .destructive) {
            library.addBlockedTopic(topic.id)
        } label: {
            Label("屏蔽此帖", systemImage: "eye.slash")
        }

        if let author = topic.authorName, !author.isEmpty {
            Button(role: .destructive) {
                library.addBlockedUser(author)
            } label: {
                Label("屏蔽此人", systemImage: "person.crop.circle.badge.xmark")
            }
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            let index = try await app.api.home()
            home = index
            var topics = index.hotTopic ?? []
            if topics.isEmpty || topics.allSatisfy({ ($0.title ?? "").isEmpty }) {
                topics = try await app.api.hotTopics()
                hotTitle = "周热榜"
            } else {
                hotTitle = "今日十大"
            }
            hot = topics
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct HotTopicRow: View {
    @ScaledMetric(relativeTo: .footnote) private var rankSize: CGFloat = 22
    let rank: Int
    let topic: NativeHotTopic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .foregroundStyle(rank <= 3 ? ShellTheme.accent : ShellTheme.secondaryText)
                .frame(width: rankSize, height: rankSize)
                .background(rank <= 3 ? ShellTheme.accentSoft : ShellTheme.secondarySurface, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title ?? "主题 #\(topic.id)")
                    .font(ShellTheme.Fonts.body.weight(.medium))
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(3)
                NativeTopicMetadata(
                    board: topic.boardName, author: topic.authorName,
                    replyCount: topic.replyCount, hitCount: topic.hitCount, date: nil
                )
            }
        }
        .padding(.vertical, 6)
    }
}
