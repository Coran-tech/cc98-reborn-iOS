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
                        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !library.pinnedBoards.isEmpty {
                            Section("置顶版面") {
                                ForEach(library.pinnedBoards.filter { !library.isBoardBlocked(id: $0.id, name: $0.name) }) { pinned in
                                    HStack(spacing: 0) {
                                        NavigationLink {
                                            BoardTopicsView(board: allBoards.first { $0.id == pinned.id } ?? .placeholder(id: pinned.id))
                                        } label: {
                                            Label(pinned.name, systemImage: "pin.fill")
                                                .font(ShellTheme.Fonts.body.weight(.medium))
                                                .padding(.vertical, 8)
                                        }
                                        .accessibilityIdentifier("board.pinned.\(pinned.id)")
                                        Button {
                                            library.togglePinnedBoard(id: pinned.id, name: pinned.name)
                                        } label: {
                                            Image(systemName: "pin.slash").frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("取消置顶\(pinned.name)")
                                    }
                                }
                            }
                        }
                        NativeLibraryStatusView()
                        if let error { NativeInlineRetry(message: error) { Task { await load() } } }
                        if filteredGroups.isEmpty { Text("没有匹配的版面").foregroundStyle(ShellTheme.secondaryText) }
                        ForEach(filteredGroups) { group in
                            Section {
                                ForEach(visibleBoards(group)) { board in
                                    HStack(alignment: .top, spacing: 0) {
                                        NavigationLink {
                                            BoardTopicsView(board: board)
                                        } label: {
                                            BoardRow(board: board)
                                        }
                                        .accessibilityIdentifier("board.\(board.id)")
                                        Menu {
                                            Button {
                                                library.togglePinnedBoard(id: board.id, name: board.name)
                                            } label: {
                                                Label(library.isBoardPinned(board.id) ? "取消置顶" : "置顶版面", systemImage: "pin")
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                        }
                                        .accessibilityLabel("\(board.name)操作")
                                        .accessibilityIdentifier("board.more.\(board.id)")
                                    }
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name)
                                    if let masters = group.masters, !masters.isEmpty {
                                        Text(masters.joined(separator: " · "))
                                            .font(ShellTheme.Fonts.metadata)
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
                        Image(systemName: "magnifyingglass").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("搜索主题")
                }
            }
        }
        .task { await load() }
    }

    private var allBoards: [NativeBoard] { groups.flatMap { $0.boards ?? [] } }

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
            .font(ShellTheme.Fonts.metadata)
            .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(.vertical, 6)
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
    @State private var showVoteCompose = false
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
            } else {
                List {
                    NativeLibraryStatusView()
                    if let error { NativeInlineRetry(message: error) { Task { await load(reset: true) } } }
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

                    if visibleTopics.isEmpty {
                        Text(topics.isEmpty ? "本版暂无主题" : "当前已加载主题均被屏蔽规则筛选。")
                            .font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                    }
                    ForEach(visibleTopics) { topic in
                        NavigationLink {
                            TopicDetailView(topicID: topic.id, boardID: topic.boardId ?? board.id)
                        } label: {
                            TopicSummaryRow(topic: topic)
                        }
                        .accessibilityIdentifier("board.topic.\(topic.id)")
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    SearchView(initialBoard: resolvedBoard)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("版内搜索")

                Menu {
                    Button {
                        library.togglePinnedBoard(id: resolvedBoard.id, name: resolvedBoard.name)
                    } label: {
                        Label(library.isBoardPinned(resolvedBoard.id) ? "取消置顶" : "置顶版面", systemImage: "pin")
                    }
                    if resolvedBoard.canVote == true {
                        Button {
                            if auth.profile == nil {
                                alertMessage = "请先在「我的」登录，再发表投票。"
                                showAlert = true
                            } else { showVoteCompose = true }
                        } label: { Label("发表投票", systemImage: "chart.bar.doc.horizontal") }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("版面操作")
                .accessibilityIdentifier("board.actions")

                Button {
                    if auth.profile == nil {
                        alertMessage = "请先在「我的」登录，再发表主题。"
                        showAlert = true
                    } else {
                        showCompose = true
                    }
                } label: {
                    Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("发表主题")
                .accessibilityIdentifier("board.compose")
            }
        }
        .sheet(isPresented: $showVoteCompose) {
            NewTopicComposer(
                boardID: resolvedBoard.id,
                boardName: resolvedBoard.name,
                anonymousState: 0,
                isVote: true
            ) {
                Task { await load(reset: true) }
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
        error = nil
        let requestedPage = reset ? 0 : page
        do {
            let fetched = try await app.api.topics(boardID: board.id, from: requestedPage * pageSize, size: pageSize)
            if reset {
                topics = fetched
            } else {
                let existing = Set(topics.map(\.id))
                topics.append(contentsOf: fetched.filter { !existing.contains($0.id) })
            }
            page = requestedPage + 1
            hasMore = fetched.count == pageSize
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct TopicSummaryRow: View {
    @EnvironmentObject private var library: NativeLibrary
    let topic: NativeTopicSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if (topic.topState ?? 0) > 0 {
                    Text("置顶")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ShellTheme.accentSoft, in: Capsule())
                        .foregroundStyle(ShellTheme.accent)
                }
                if (topic.bestState ?? 0) > 0 {
                    Text("精华")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ShellTheme.warning.opacity(0.15), in: Capsule())
                        .foregroundStyle(ShellTheme.warning)
                }
                if topic.isVote == true {
                    Text("投票")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(ShellTheme.link.opacity(0.15), in: Capsule())
                        .foregroundStyle(ShellTheme.link)
                }
            }
            Text(topic.title ?? "主题 #\(topic.id)")
                .font(ShellTheme.Fonts.body.weight(.medium))
                .foregroundStyle(ShellTheme.primaryText)
                .lineLimit(3)
            NativeTopicMetadata(
                author: topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"),
                userNote: topic.isAnonymous == true ? nil : topic.userId.map { library.userNote(for: $0) },
                replyCount: topic.replyCount, hitCount: topic.hitCount,
                date: NativeFormat.date(topic.lastPostTime ?? topic.time)
            )
        }
        .padding(.vertical, 6)
    }
}
