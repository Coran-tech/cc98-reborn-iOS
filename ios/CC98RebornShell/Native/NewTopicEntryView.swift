import SwiftUI

struct NewTopicEntryView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @Environment(\.dismiss) private var dismiss

    @AppStorage("native.lastBoardID") private var lastBoardID = 0
    @AppStorage("native.lastBoardName") private var lastBoardName = ""

    let onPublished: () -> Void

    @State private var groups: [NativeBoardGroup] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String? = nil
    @State private var selectedBoard: NativeBoard? = nil
    @State private var isVote = false

    var body: some View {
        NavigationStack {
            Group {
                if auth.profile == nil {
                    LoginGateView()
                } else if groups.isEmpty && loading {
                    ProgressView("正在加载版面…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ShellTheme.pageBackground)
                } else if groups.isEmpty, let error {
                    NativeStateView(icon: "square.grid.2x2", title: "版面无法加载", message: error, action: {
                        Task { await load() }
                    })
                } else {
                    List {
                        if let error { NativeInlineRetry(message: error) { Task { await load() } } }
                        Section {
                            Picker("发布类型", selection: $isVote) {
                                Text("主题").tag(false)
                                Text("投票").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }

                        if let lastBoard {
                            Section("上次发帖") {
                                Button {
                                    selectedBoard = lastBoard
                                } label: {
                                    BoardChoiceRow(board: lastBoard, highlighted: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        ForEach(filteredGroups) { group in
                            Section {
                                ForEach(boards(for: group)) { board in
                                    Button {
                                        selectedBoard = board
                                    } label: {
                                        BoardChoiceRow(board: board, highlighted: false)
                                    }
                                    .buttonStyle(.plain)
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
            .navigationTitle("选择发帖版面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $selectedBoard) { board in
                NewTopicComposer(
                    boardID: board.id,
                    boardName: board.name,
                    anonymousState: board.anonymousState ?? 0,
                    isVote: isVote
                ) {
                    lastBoardID = board.id
                    lastBoardName = board.name
                    onPublished()
                }
            }
        }
    }

    private var lastBoard: NativeBoard? {
        guard lastBoardID != 0 else { return nil }
        return groups
            .flatMap { $0.boards ?? [] }
            .first { $0.id == lastBoardID && (!isVote || $0.canVote == true) }
    }

    private func boards(for group: NativeBoardGroup) -> [NativeBoard] {
        (group.boards ?? []).filter { !isVote || $0.canVote == true }
    }

    private var filteredGroups: [NativeBoardGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            let boards = boards(for: group).filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.description ?? "").localizedCaseInsensitiveContains(query)
            }
            guard !boards.isEmpty else { return nil }
            return NativeBoardGroup(
                id: group.id,
                name: group.name,
                masters: group.masters,
                order: group.order,
                boards: boards
            )
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

private struct BoardChoiceRow: View {
    let board: NativeBoard
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: highlighted ? "clock.arrow.circlepath" : "square.text.square")
                .font(.title3)
                .foregroundStyle(ShellTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
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
                        .font(ShellTheme.Fonts.metadata)
                        .foregroundStyle(ShellTheme.secondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text("今日 \(NativeFormat.count(board.todayCount))")
                    Text("主题 \(NativeFormat.count(board.topicCount))")
                }
                .font(ShellTheme.Fonts.metadata)
                .foregroundStyle(ShellTheme.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(.vertical, 3)
    }
}
