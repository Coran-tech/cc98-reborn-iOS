import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var library: NativeLibrary

    @State private var home: NativeHome?
    @State private var hot: [NativeHotTopic] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let home {
                    List {
                        hotSection
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
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func statsSection(_ home: NativeHome) -> some View {
        Section {
            HStack(spacing: 10) {
                stat("今日帖子", value: NativeFormat.count(home.todayCount))
                stat("在线", value: NativeFormat.count(home.onlineUserCount))
                stat("主题", value: NativeFormat.count(home.topicCount))
            }
            .padding(.vertical, 4)
        }
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(ShellTheme.Fonts.pageTitle)
                .foregroundStyle(ShellTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hotSection: some View {
        Section {
            if hot.isEmpty {
                Text("暂时没有十大内容。")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
            } else {
                ForEach(visibleHot.indices, id: \.self) { index in
                    let topic = visibleHot[index]
                    NavigationLink {
                        TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                    } label: {
                        HotTopicRow(rank: index + 1, topic: topic)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        topicActions(topic)
                    }
                }
            }
        } header: {
            Text("今日十大")
        }
    }

    private var visibleHot: [NativeHotTopic] {
        hot.filter { topic in
            !library.isTopicBlocked(topic.id)
                && !library.isBoardBlocked(id: topic.boardId, name: topic.boardName)
                && !library.isTitleBlocked(topic.title)
                && !library.isUserBlocked(topic.authorName)
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
            }
            hot = topics
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct HotTopicRow: View {
    let rank: Int
    let topic: NativeHotTopic

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .foregroundStyle(rank <= 3 ? ShellTheme.accent : ShellTheme.secondaryText)
                .frame(width: 22, height: 22)
                .background(rank <= 3 ? ShellTheme.accentSoft : ShellTheme.secondarySurface, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title ?? "主题 #\(topic.id)")
                    .font(ShellTheme.Fonts.body.weight(.medium))
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let board = topic.boardName, !board.isEmpty {
                        Text(board)
                    }
                    if let author = topic.authorName, !author.isEmpty {
                        Text(author)
                    }
                    Text("回复 \(NativeFormat.count(topic.replyCount))")
                    Text("点击 \(NativeFormat.count(topic.hitCount))")
                }
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
