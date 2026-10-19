import SwiftUI

private enum SearchScope: String, CaseIterable, Identifiable {
    case all
    case board
    case user

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全站"
        case .board: return "版内"
        case .user: return "用户"
        }
    }
}

struct SearchView: View {
    @EnvironmentObject private var app: NativeAppModel

    @State private var keyword = ""
    @State private var scope: SearchScope = .all
    @State private var board: NativeBoard? = nil
    @State private var showBoardPicker = false
    @State private var results: [NativeTopicSummary] = []
    @State private var users: [NativeUser] = []
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = false

    private let pageSize = 20

    init(initialBoard: NativeBoard? = nil) {
        _board = State(initialValue: initialBoard)
        _scope = State(initialValue: initialBoard == nil ? .all : .board)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("搜索范围", selection: $scope) {
                ForEach(SearchScope.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if scope == .board {
                Button {
                    showBoardPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                        Text(board?.name ?? "选择版面")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(board == nil ? ShellTheme.secondaryText : ShellTheme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ShellTheme.secondaryText)
                TextField(placeholder, text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { Task { await search(reset: true) } }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        results = []
                        users = []
                        error = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ShellTheme.secondaryText)
                    }
                }
                Button("搜索") {
                    Task { await search(reset: true) }
                }
                .font(ShellTheme.Fonts.footnote.weight(.medium))
                .foregroundStyle(ShellTheme.accent)
                .disabled(loading)
            }
            .padding(12)
            .background(ShellTheme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ShellTheme.separator).frame(height: 0.5)
            }

            Group {
                if isEmpty && loading {
                    ProgressView("正在搜索…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isEmpty, let error {
                    NativeStateView(icon: "magnifyingglass", title: "搜索失败", message: error, action: {
                        Task { await search(reset: true) }
                    })
                } else if isEmpty {
                    NativeStateView(icon: "text.magnifyingglass", title: "搜索 CC98", message: emptyMessage)
                } else {
                    List {
                        if scope == .user {
                            ForEach(users, id: \.id) { user in
                                NavigationLink {
                                    UserProfileView(userID: user.id, userName: user.name)
                                } label: {
                                    userRow(user)
                                }
                            }
                        } else {
                            ForEach(results) { topic in
                                NavigationLink {
                                    TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                                } label: {
                                    TopicLinkRow(topic: topic)
                                }
                            }
                        }

                        if hasMore {
                            Button {
                                Task { await search(reset: false) }
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
                }
            }
            .background(ShellTheme.pageBackground)
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scope) { _, _ in
            results = []
            users = []
            error = nil
            hasMore = false
            page = 0
        }
        .sheet(isPresented: $showBoardPicker) {
            BoardPickerView { selected in
                board = selected
                showBoardPicker = false
            }
        }
    }

    private var isEmpty: Bool {
        results.isEmpty && users.isEmpty
    }

    private var placeholder: String {
        switch scope {
        case .all: return "搜索全站主题"
        case .board: return board.map { "在 \($0.name) 内搜索" } ?? "输入关键词"
        case .user: return "搜索用户名或用户 ID"
        }
    }

    private var emptyMessage: String {
        switch scope {
        case .all: return "输入关键词后搜索全站主题。"
        case .board: return board == nil ? "先选择版面，再搜索版内主题。" : "输入关键词后搜索当前版面。"
        case .user: return "输入用户名或用户 ID 查找用户。"
        }
    }

    private func userRow(_ user: NativeUser) -> some View {
        HStack(spacing: 10) {
            NativeAvatar(
                url: user.avatarURL ?? NativeAvatarURLs.defaultURL(gender: user.gender),
                name: user.name,
                size: 40
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name ?? "CC98 用户")
                    .font(ShellTheme.Fonts.body.weight(.medium))
                    .foregroundStyle(ShellTheme.primaryText)
                let title = user.customTitle ?? user.displayTitle
                if let title, !title.isEmpty {
                    Text(title)
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func search(reset: Bool) async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !loading else { return }
        if scope == .board, board == nil {
            error = "请先选择要搜索的版面。"
            return
        }
        loading = true
        error = nil
        if reset {
            page = 0
            results = []
            users = []
            hasMore = true
        }
        do {
            switch scope {
            case .all:
                let fetched = try await app.api.searchTopics(keyword: query, from: page * pageSize, size: pageSize)
                if reset { results = fetched } else { results.append(contentsOf: fetched) }
                hasMore = fetched.count == pageSize
            case .board:
                guard let board else { loading = false; return }
                let fetched = try await app.api.searchBoardTopics(
                    keyword: query,
                    boardID: board.id,
                    from: page * pageSize,
                    size: pageSize
                )
                if reset { results = fetched } else { results.append(contentsOf: fetched) }
                hasMore = fetched.count == pageSize
            case .user:
                let fetched = try await app.api.searchUsers(keyword: query, from: page * pageSize, size: pageSize)
                if reset { users = fetched } else { users.append(contentsOf: fetched) }
                hasMore = fetched.count == pageSize
            }
            page += 1
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct BoardPickerView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss

    let onSelect: (NativeBoard) -> Void

    @State private var groups: [NativeBoardGroup] = []
    @State private var keyword = ""
    @State private var loading = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if loading && groups.isEmpty {
                    ProgressView("正在加载版面…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groups.isEmpty, let error {
                    NativeStateView(icon: "square.grid.2x2", title: "版面无法加载", message: error, action: {
                        Task { await load() }
                    })
                } else {
                    List {
                        ForEach(filteredGroups) { group in
                            Section(group.name) {
                                ForEach(group.boards ?? []) { board in
                                    Button {
                                        onSelect(board)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text(board.name)
                                                .foregroundStyle(ShellTheme.primaryText)
                                            Spacer(minLength: 0)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("选择版面")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "搜索版面")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var filteredGroups: [NativeBoardGroup] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let boards = (group.boards ?? []).filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
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

struct FavoritesView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    @State private var topics: [NativeTopicSummary] = []
    @State private var groups: [NativeFavoriteGroup] = []
    @State private var selectedGroupID: Int? = nil
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = true
    @State private var showCreateGroup = false
    @State private var newGroupName = ""

    private let pageSize = 20

    var body: some View {
        Group {
            if auth.profile == nil {
                LoginGateView()
            } else if topics.isEmpty && loading {
                ProgressView("正在加载收藏…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if topics.isEmpty, let error {
                NativeStateView(icon: "star.slash", title: "收藏无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if topics.isEmpty {
                NativeStateView(icon: "star", title: "暂无收藏", message: "在主题页点击收藏后，会出现在这里。")
            } else {
                List {
                    ForEach(topics) { topic in
                        NavigationLink {
                            TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                        } label: {
                            TopicLinkRow(topic: topic)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await remove(topic) }
                            } label: {
                                Label("取消收藏", systemImage: "star.slash")
                            }
                        }
                        .contextMenu {
                            ForEach(groups) { group in
                                if group.id != selectedGroupID {
                                    Button("移动到 \(group.name ?? "分组")") {
                                        Task { await move(topic, to: group.id) }
                                    }
                                }
                            }
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
        .background(ShellTheme.pageBackground)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("全部收藏") { selectGroup(nil) }
                    ForEach(groups) { group in
                        Button("\(group.name ?? "分组") (\(group.count ?? 0))") {
                            selectGroup(group.id)
                        }
                    }
                    Divider()
                    Button("新建分组") { showCreateGroup = true }
                } label: {
                    Label(selectedGroupName, systemImage: "folder")
                }
            }
        }
        .alert("新建收藏分组", isPresented: $showCreateGroup) {
            TextField("分组名称", text: $newGroupName)
            Button("取消", role: .cancel) { newGroupName = "" }
            Button("创建") { Task { await createGroup() } }
        }
        .task {
            await loadGroups()
            await load(reset: true)
        }
    }

    private var selectedGroupName: String {
        guard let selectedGroupID else { return "全部分组" }
        return groups.first { $0.id == selectedGroupID }?.name ?? "分组"
    }

    private func selectGroup(_ id: Int?) {
        selectedGroupID = id
        Task { await load(reset: true) }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard auth.profile != nil, !loading else { return }
        loading = true
        error = nil
        if reset { page = 0; hasMore = true }
        do {
            let fetched = try await app.api.favoriteTopics(
                from: page * pageSize,
                size: pageSize,
                groupID: selectedGroupID
            )
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

    @MainActor
    private func remove(_ topic: NativeTopicSummary) async {
        do {
            try await app.api.removeFavorite(topicID: topic.id)
            topics.removeAll { $0.id == topic.id }
            await loadGroups()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadGroups() async {
        guard auth.profile != nil else { return }
        groups = (try? await app.api.favoriteGroups()) ?? []
    }

    @MainActor
    private func createGroup() async {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await app.api.createFavoriteGroup(name: name)
            newGroupName = ""
            await loadGroups()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func move(_ topic: NativeTopicSummary, to groupID: Int) async {
        do {
            try await app.api.addFavorite(topicID: topic.id, groupID: groupID)
            await loadGroups()
            if selectedGroupID != nil {
                topics.removeAll { $0.id == topic.id }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReadLaterView: View {
    @EnvironmentObject private var library: NativeLibrary

    var body: some View {
        Group {
            if library.readLater.isEmpty {
                NativeStateView(icon: "bookmark", title: "暂无稍后再看", message: "在主题页的更多菜单里添加。")
            } else {
                List {
                    ForEach(library.readLater) { item in
                        NavigationLink {
                            TopicDetailView(topicID: item.id, boardID: item.boardID)
                        } label: {
                            SavedTopicRow(item: item)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                library.removeReadLater(item.id)
                            } label: {
                                Label("移除", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle("稍后再看")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.readLater.isEmpty {
                Button("清空", role: .destructive) { library.clearReadLater() }
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var library: NativeLibrary

    var body: some View {
        Group {
            if library.history.isEmpty {
                NativeStateView(icon: "clock", title: "暂无浏览历史", message: "打开过的主题会记录在这里，仅保存在本机。")
            } else {
                List {
                    ForEach(library.history) { item in
                        NavigationLink {
                            TopicDetailView(topicID: item.id, boardID: item.boardID)
                        } label: {
                            SavedTopicRow(item: item)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle("浏览历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.history.isEmpty {
                Button("清空", role: .destructive) { library.clearHistory() }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: NativeLibrary
    @AppStorage("native.appearance") private var appearance = "system"

    @State private var newUser = ""
    @State private var newKeyword = ""

    var body: some View {
        Form {
            Section("外观") {
                Picker("显示模式", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("我的内容") {
                NavigationLink("我的收藏") { FavoritesView() }
                NavigationLink("稍后再看") { ReadLaterView() }
                NavigationLink("浏览历史") { HistoryView() }
            }

            Section("屏蔽用户") {
                HStack {
                    TextField("用户名", text: $newUser)
                    Button("添加") {
                        library.addBlockedUser(newUser)
                        newUser = ""
                    }
                    .disabled(newUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(library.blockedUsers, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            library.removeBlockedUser(name)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(ShellTheme.danger)
                        }
                    }
                }
            }

            Section("屏蔽关键词") {
                HStack {
                    TextField("正文关键词", text: $newKeyword)
                    Button("添加") {
                        library.addBlockedKeyword(newKeyword)
                        newKeyword = ""
                    }
                    .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(library.blockedKeywords, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            library.removeBlockedKeyword(word)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(ShellTheme.danger)
                        }
                    }
                }
            }

            Section("本机数据") {
                Button("清空浏览历史", role: .destructive) { library.clearHistory() }
                    .disabled(library.history.isEmpty)
                Button("清空稍后再看", role: .destructive) { library.clearReadLater() }
                    .disabled(library.readLater.isEmpty)
                Text("浏览历史、稍后再看、备注和屏蔽规则只保存在本机，不会上传。")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct UserProfileView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    let userID: Int?
    let userName: String?

    @State private var user: NativeUser? = nil
    @State private var loading = false
    @State private var error: String? = nil
    @State private var isFollowing = false
    @State private var followBusy = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var topics: [NativeMyTopic] = []
    @State private var topicsLoading = false
    @State private var topicsError: String? = nil
    @State private var topicOffset = 0
    @State private var topicsHasMore = true

    var body: some View {
        Group {
            if let user {
                List {
                    Section {
                        HStack(spacing: 14) {
                            NativeAvatar(url: user.avatarURL ?? NativeAvatarURLs.defaultURL(gender: user.gender), name: user.name, size: 56)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.name ?? "CC98 用户")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(ShellTheme.primaryText)
                                if let title = user.customTitle ?? user.displayTitle, !title.isEmpty {
                                    Text(title)
                                        .font(ShellTheme.Fonts.footnote)
                                        .foregroundStyle(ShellTheme.secondaryText)
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            stat("发帖", user.postCount)
                            stat("威望", user.prestige)
                            stat("风评", user.popularity)
                            stat("关注", user.followCount)
                            stat("粉丝", user.fanCount)
                        }
                    }

                    if let intro = user.introduction, !intro.isEmpty {
                        Section("个人简介") {
                            Text(intro)
                                .font(ShellTheme.Fonts.footnote)
                        }
                    }

                    Section {
                        if let myID = auth.profile?.id, myID != user.id {
                            Button {
                                Task { await toggleFollow(user) }
                            } label: {
                                Label(
                                    isFollowing ? "取消关注" : "关注",
                                    systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus"
                                )
                            }
                            .disabled(followBusy)
                        }
                        NavigationLink {
                            PrivateConversationView(
                                contactID: user.id,
                                contactName: user.name,
                                contactAvatar: user.portraitUrl
                            )
                        } label: {
                            Label("发送私信", systemImage: "bubble.left")
                        }
                    }

                    Section("发帖") {
                        if topicsLoading && topics.isEmpty {
                            ProgressView("正在加载发帖…")
                        } else if topics.isEmpty {
                            Text(topicsError ?? "暂无主题")
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(topicsError == nil ? ShellTheme.secondaryText : ShellTheme.danger)
                        } else {
                            ForEach(topics) { topic in
                                NavigationLink {
                                    TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(topic.title ?? "主题 #\(topic.id)")
                                            .font(ShellTheme.Fonts.footnote.weight(.medium))
                                            .foregroundStyle(ShellTheme.primaryText)
                                            .lineLimit(2)
                                        HStack(spacing: 8) {
                                            if let boardID = topic.boardId {
                                                Text("版面 #\(boardID)")
                                            }
                                            Spacer(minLength: 0)
                                            Text(NativeFormat.date(topic.time))
                                        }
                                        .font(ShellTheme.Fonts.caption)
                                        .foregroundStyle(ShellTheme.secondaryText)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            if topicsHasMore {
                                Button("加载更多发帖") {
                                    Task { await loadTopics(reset: false) }
                                }
                                .font(ShellTheme.Fonts.footnote)
                                .disabled(topicsLoading)
                            }
                        }
                    }

                    Section("资料") {
                        LabeledContent("用户 ID", value: String(user.id))
                        if let register = user.registerTime {
                            LabeledContent("注册时间", value: NativeFormat.date(register))
                        }
                        if let last = user.lastLogOnTime {
                            LabeledContent("最后登录", value: NativeFormat.date(last))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            } else if loading {
                ProgressView("正在加载用户…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                NativeStateView(icon: "person.crop.circle.badge.exclamationmark", title: "用户无法加载", message: error, action: {
                    Task { await load() }
                })
            } else {
                NativeStateView(icon: "person.crop.circle", title: "没有用户信息", message: nil)
            }
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle(user?.name ?? "用户")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("提示", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func stat(_ title: String, _ value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(NativeFormat.count(value))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(ShellTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            if let userID {
                let loaded = try await app.api.user(id: userID)
                user = loaded
                isFollowing = loaded.isFollowing ?? false
                await loadTopics(reset: true)
            } else if let userName {
                let loaded = try await app.api.user(name: userName)
                user = loaded
                isFollowing = loaded.isFollowing ?? false
                await loadTopics(reset: true)
            } else {
                error = "缺少用户标识。"
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func toggleFollow(_ user: NativeUser) async {
        guard auth.profile != nil else {
            alertMessage = "请先登录。"
            showAlert = true
            return
        }
        guard !followBusy else { return }
        followBusy = true
        do {
            if isFollowing {
                try await app.api.unfollow(userID: user.id)
            } else {
                try await app.api.follow(userID: user.id)
            }
            isFollowing.toggle()
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
        followBusy = false
    }

    @MainActor
    private func loadTopics(reset: Bool) async {
        guard let userID = user?.id, !topicsLoading else { return }
        topicsLoading = true
        if reset {
            topicOffset = 0
            topicsHasMore = true
            topicsError = nil
            topics = []
        }
        do {
            let fetched = try await app.api.userTopics(userID: userID, from: topicOffset, size: 10)
            if reset {
                topics = fetched
            } else {
                topics.append(contentsOf: fetched)
            }
            topicOffset += fetched.count
            topicsHasMore = fetched.count == 10
        } catch {
            topicsError = error.localizedDescription
            topicsHasMore = false
        }
        topicsLoading = false
    }
}

struct TopicLinkRow: View {
    let topic: NativeTopicSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.title ?? "主题 #\(topic.id)")
                .font(ShellTheme.Fonts.body.weight(.medium))
                .foregroundStyle(ShellTheme.primaryText)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let boardName = topic.boardName {
                    Text(boardName)
                }
                Text(topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"))
                Text("回复 \(NativeFormat.count(topic.replyCount))")
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

struct SavedTopicRow: View {
    let item: NativeSavedTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(ShellTheme.Fonts.body.weight(.medium))
                .foregroundStyle(ShellTheme.primaryText)
                .lineLimit(2)
            Text(item.savedAt, style: .date)
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(.vertical, 2)
    }
}
