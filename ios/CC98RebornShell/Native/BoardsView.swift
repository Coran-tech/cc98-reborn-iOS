import SwiftUI

struct BoardsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var library: NativeLibrary
    @State private var groups: [NativeBoardGroup] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty && loading {
                    ProgressView("正在加载版面…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ShellTheme.pageBackground)
                } else if groups.isEmpty, let error {
                    NativeStateView(icon: "square.grid.2x2", title: "版面无法加载", message: error, action: {
                        Task { await load() }
                    })
                } else {
                    List {
                        ForEach(filteredGroups) { group in
                            Section {
                                ForEach(visibleBoards(group)) { board in
                                    NavigationLink {
                                        BoardTopicsView(board: board)
                                    } label: {
                                        BoardRow(board: board)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(group.name)
                                    if let masters = group.masters, !masters.isEmpty {
                                        Spacer()
                                        Text(masters.joined(separator: " · "))
                                            .font(ShellTheme.Fonts.caption)
                                            .foregroundStyle(ShellTheme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(ShellTheme.pageBackground)
                    .searchable(text: $search, prompt: "搜索版面")
                    .refreshable { await load() }
                }
            }
            .navigationTitle("版面")
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

    private func visibleBoards(_ group: NativeBoardGroup) -> [NativeBoard] {
        (group.boards ?? []).filter { !library.isBoardBlocked(id: $0.id, name: $0.name) }
    }

    private var filteredGroups: [NativeBoardGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            let boards = visibleBoards(group).filter { board in
                query.isEmpty
                    || board.name.localizedCaseInsensitiveContains(query)
                    || (board.description ?? "").localizedCaseInsensitiveContains(query)
            }
            guard !boards.isEmpty else { return nil }
            return NativeBoardGroup(id: group.id, name: group.name, masters: group.masters, order: group.order, boards: boards)
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            groups = try await app.api.boardGroups()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct BoardRow: View {
    let board: NativeBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(board.name)
                    .font(ShellTheme.Fonts.body.weight(.medium))
                    .foregroundStyle(ShellTheme.primaryText)
                if board.isLock == true {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(ShellTheme.warning)
                }
            }
            if let description = board.description, !description.isEmpty {
                Text(description)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Text("今日 \(NativeFormat.count(board.todayCount))")
                Text("主题 \(NativeFormat.count(board.topicCount))")
            }
            .font(ShellTheme.Fonts.caption)
            .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

struct BoardTopicsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary
    let board: NativeBoard

    @AppStorage("native.lastBoardID") private var lastBoardID = 0
    @AppStorage("native.lastBoardName") private var lastBoardName = ""

    @State private var topics: [NativeTopicSummary] = []
    @State private var boardDetail: NativeBoard? = nil
    @State private var page = 0
    @State private var loading = false
    @State private var hasMore = true
    @State private var error: String?
    @State private var showCompose = false
    @State private var bigPaperExpanded = true
    @State private var alertMessage = ""
    @State private var showAlert = false

    private let pageSize = 20

    var body: some View {
        Group {
            if topics.isEmpty && loading {
                ProgressView("正在加载主题…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if topics.isEmpty, let error {
                NativeStateView(icon: "list.bullet.rectangle", title: "主题无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if topics.isEmpty {
                NativeStateView(icon: "tray", title: "本版暂无主题", message: nil)
            } else {
                List {
                    if let bigPaper = (boardDetail?.bigPaper ?? board.bigPaper)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !bigPaper.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $bigPaperExpanded) {
                                UBBContentView(source: bigPaper)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Label("本版大字报", systemImage: "megaphone")
                                    .font(ShellTheme.Fonts.footnote.weight(.semibold))
                                    .foregroundStyle(ShellTheme.accent)
                            }
                        }
                    }

                    ForEach(visibleTopics) { topic in
                        NavigationLink {
                            TopicDetailView(topicID: topic.id, boardID: topic.boardId ?? board.id)
                        } label: {
                            TopicSummaryRow(topic: topic)
                        }
                    }
                    if hasMore {
                        Button {
                            Task { await load(reset: false) }
                        } label: {
                            HStack {
                                Spacer()
                                if loading { ProgressView() }
                                Text(loading ? "正在加载…" : "加载更多")
                                Spacer()
                            }
                        }
                        .disabled(loading)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ShellTheme.pageBackground)
                .refreshable { await load(reset: true) }
            }
        }
        .navigationTitle(resolvedBoard.name)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    SearchView(initialBoard: resolvedBoard)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("版内搜索")

                Button {
                    if auth.profile == nil {
                        alertMessage = "请先在「我的」登录，再发表主题。"
                        showAlert = true
                    } else {
                        showCompose = true
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showCompose) {
            NewTopicComposer(
                boardID: resolvedBoard.id,
                boardName: resolvedBoard.name,
                anonymousState: resolvedBoard.anonymousState ?? 0
            ) {
                lastBoardID = resolvedBoard.id
                lastBoardName = resolvedBoard.name
                Task { await load(reset: true) }
            }
        }
        .alert("提示", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .task { await load(reset: true) }
        .task { await loadBoardDetail() }
    }

    private var resolvedBoard: NativeBoard {
        boardDetail ?? board
    }

    @MainActor
    private func loadBoardDetail() async {
        if let detail = try? await app.api.board(id: board.id) {
            boardDetail = detail
        }
    }

    private var visibleTopics: [NativeTopicSummary] {
        topics.filter { topic in
            !library.isTopicBlocked(topic.id)
                && !library.isBoardBlocked(id: topic.boardId, name: topic.boardName)
                && !library.isTitleBlocked(topic.title)
                && !library.isUserBlocked(id: topic.userId, name: topic.userName)
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        if reset {
            page = 0
            hasMore = true
            error = nil
        }
        do {
            let fetched = try await app.api.topics(boardID: board.id, from: page * pageSize, size: pageSize)
            if reset {
                topics = fetched
            } else {
                topics.append(contentsOf: fetched)
            }
            page += 1
            hasMore = fetched.count == pageSize
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct TopicSummaryRow: View {
    let topic: NativeTopicSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if (topic.topState ?? 0) > 0 {
                    Text("置顶")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ShellTheme.accentSoft, in: Capsule())
                        .foregroundStyle(ShellTheme.accent)
                }
                if (topic.bestState ?? 0) > 0 {
                    Text("精华")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ShellTheme.warning.opacity(0.15), in: Capsule())
                        .foregroundStyle(ShellTheme.warning)
                }
                if topic.isVote == true {
                    Text("投票")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ShellTheme.link.opacity(0.15), in: Capsule())
                        .foregroundStyle(ShellTheme.link)
                }
                Text(topic.title ?? "主题 #\(topic.id)")
                    .font(ShellTheme.Fonts.body.weight(.medium))
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"))
                Text("回复 \(NativeFormat.count(topic.replyCount))")
                Text("点击 \(NativeFormat.count(topic.hitCount))")
                Spacer(minLength: 0)
                Text(NativeFormat.date(topic.lastPostTime ?? topic.time))
            }
            .font(ShellTheme.Fonts.caption)
            .foregroundStyle(ShellTheme.secondaryText)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
