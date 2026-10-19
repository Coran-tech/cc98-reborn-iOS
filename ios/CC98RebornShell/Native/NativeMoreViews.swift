import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var app: NativeAppModel

    @State private var keyword = ""
    @State private var results: [NativeTopicSummary] = []
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = false

    private let pageSize = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ShellTheme.secondaryText)
                TextField("搜索主题、关键词", text: $keyword)
                    .submitLabel(.search)
                    .onSubmit { Task { await search(reset: true) } }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        results = []
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
                if results.isEmpty && loading {
                    ProgressView("正在搜索…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty, let error {
                    NativeStateView(icon: "magnifyingglass", title: "搜索失败", message: error, action: {
                        Task { await search(reset: true) }
                    })
                } else if results.isEmpty {
                    NativeStateView(icon: "text.magnifyingglass", title: "搜索 CC98", message: "输入关键词后搜索全站主题。")
                } else {
                    List {
                        ForEach(results) { topic in
                            NavigationLink {
                                TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                            } label: {
                                TopicLinkRow(topic: topic)
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
    }

    @MainActor
    private func search(reset: Bool) async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !loading else { return }
        loading = true
        error = nil
        if reset { page = 0 }
        do {
            let fetched = try await app.api.searchTopics(keyword: query, from: page * pageSize, size: pageSize)
            if reset {
                results = fetched
            } else {
                results.append(contentsOf: fetched)
            }
            page += 1
            hasMore = fetched.count == pageSize
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
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = true

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
        .task { await load(reset: true) }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard auth.profile != nil, !loading else { return }
        loading = true
        error = nil
        if reset { page = 0; hasMore = true }
        do {
            let fetched = try await app.api.favoriteTopics(from: page * pageSize, size: pageSize)
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

    let userID: Int?
    let userName: String?

    @State private var user: NativeUser? = nil
    @State private var loading = false
    @State private var error: String? = nil

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
                user = try await app.api.user(id: userID)
            } else if let userName {
                user = try await app.api.user(name: userName)
            } else {
                error = "缺少用户标识。"
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
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
