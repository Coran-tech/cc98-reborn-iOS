import SwiftUI

enum NativeMessageSection: String, CaseIterable, Identifiable {
    case reply, at, system, privateMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: return "回复"
        case .at: return "@我"
        case .system: return "系统"
        case .privateMessages: return "私信"
        }
    }

    var kind: NativeNotificationKind? {
        switch self {
        case .reply: return .reply
        case .at: return .at
        case .system: return .system
        case .privateMessages: return nil
        }
    }
}

struct MessagesView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    @State private var section: NativeMessageSection = .reply
    @State private var counts: NativeMessageCounts? = nil
    @State private var refreshID = 0
    @State private var markingRead = false
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            if auth.profile == nil {
                LoginGateView()
                    .navigationTitle("消息")
            } else {
                VStack(spacing: 0) {
                    messageTabs

                    Group {
                        switch section {
                        case .reply, .at, .system:
                            NotificationListView(kind: section.kind ?? .reply)
                                .id(refreshID)
                        case .privateMessages:
                            PrivateMessageListView()
                        }
                    }
                }
                .background(ShellTheme.pageBackground)
                .navigationTitle("消息")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if section != .privateMessages {
                            Button("全部已读") {
                                Task { await markAllRead() }
                            }
                            .disabled(markingRead)
                        }
                    }
                }
                .alert("提示", isPresented: $showAlert) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(alertMessage)
                }
                .task { await loadCounts() }
            }
        }
    }

    private var messageTabs: some View {
        HStack(spacing: 4) {
            ForEach(NativeMessageSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    VStack(spacing: 1) {
                        Text(count(for: item))
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                        Text(item.title)
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        section == item ? ShellTheme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(section == item ? ShellTheme.accent : ShellTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func count(for section: NativeMessageSection) -> String {
        switch section {
        case .reply:
            return NativeFormat.count(counts?.replyCount)
        case .at:
            return NativeFormat.count(counts?.atCount)
        case .system:
            return NativeFormat.count(counts?.systemCount)
        case .privateMessages:
            return NativeFormat.count(counts?.messageCount)
        }
    }

    @MainActor
    private func loadCounts() async {
        counts = try? await app.api.messageCounts()
    }

    @MainActor
    private func markAllRead() async {
        guard let kind = section.kind, !markingRead else { return }
        markingRead = true
        do {
            try await app.api.markAllRead(kind: kind)
            await loadCounts()
            refreshID += 1
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
        markingRead = false
    }
}

private struct NotificationListView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    let kind: NativeNotificationKind

    @State private var items: [NativeNotification] = []
    @State private var topicTitles: [Int: String] = [:]
    @State private var page = 0
    @State private var loading = false
    @State private var hasMore = true
    @State private var error: String? = nil

    private let pageSize = 10

    var body: some View {
        Group {
            if items.isEmpty && loading {
                ProgressView("正在加载消息…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if items.isEmpty, let error {
                NativeStateView(icon: "bell.slash", title: "消息无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if items.isEmpty {
                NativeStateView(icon: "bell", title: "暂无消息", message: "这一分类还没有新消息。")
            } else {
                List {
                    ForEach(items) { item in
                        notificationRow(item)
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
                    if let error {
                        Text(error)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ShellTheme.pageBackground)
                .refreshable { await load(reset: true) }
            }
        }
        .task { await load(reset: true) }
    }

    @ViewBuilder
    private func notificationRow(_ item: NativeNotification) -> some View {
        if let topicID = item.topicId {
            NavigationLink {
                TopicDetailView(
                    topicID: topicID,
                    boardID: nil,
                    initialPage: pageForFloor(item.postBasicInfo?.floor),
                    initialFloor: item.postBasicInfo?.floor
                )
            } label: {
                NotificationRow(item: item, kind: kind, topicTitle: topicTitles[topicID])
            }
        } else {
            NotificationRow(item: item, kind: kind, topicTitle: nil)
        }
    }

    private func pageForFloor(_ floor: Int?) -> Int {
        let value = max(1, floor ?? 1)
        return max(1, (value + 9) / 10)
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
            let fetched = try await app.api.notifications(kind: kind, from: page * pageSize, size: pageSize)
            if reset {
                items = fetched
            } else {
                items.append(contentsOf: fetched)
            }
            page += 1
            hasMore = fetched.count == pageSize
            await loadTopicTitles(for: fetched)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func loadTopicTitles(for fetched: [NativeNotification]) async {
        let ids = Array(Set(fetched.compactMap(\.topicId))).filter { topicTitles[$0] == nil }
        guard !ids.isEmpty else { return }
        guard let basics = try? await app.api.topicBasics(ids: ids) else { return }
        for basic in basics {
            if let title = basic.title { topicTitles[basic.id] = title }
        }
    }
}

private struct NotificationRow: View {
    let item: NativeNotification
    let kind: NativeNotificationKind
    let topicTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isRead == false ? ShellTheme.accent : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(ShellTheme.Fonts.body)
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(3)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.secondaryText)
                        .lineLimit(kind == .system ? 4 : 2)
                }
                HStack(spacing: 8) {
                    if let time = item.time {
                        Text(NativeFormat.date(time))
                    }
                    if let topicID = item.topicId {
                        Text(topicTitle ?? "主题 #\(topicID)")
                            .lineLimit(1)
                    }
                }
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var headline: String {
        switch kind {
        case .system:
            return item.title ?? "系统通知"
        case .reply, .at:
            let user = item.postBasicInfo?.userName ?? "有人"
            let title = topicTitle ?? item.topicId.map { "主题 #\($0)" } ?? "你的帖子"
            let action = kind == .reply ? "回复了你" : "@了你"
            return "\(user) 在《\(title)》中\(action)"
        }
    }

    private var detail: String? {
        if kind == .system { return item.content }
        if let floor = item.postBasicInfo?.floor, floor > 0 {
            return "第 \(floor) 楼"
        }
        return nil
    }
}

private struct PrivateMessageListView: View {
    @EnvironmentObject private var app: NativeAppModel

    @State private var contacts: [NativeRecentContact] = []
    @State private var users: [Int: NativeBasicUser] = [:]
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = true

    var body: some View {
        Group {
            if contacts.isEmpty && loading {
                ProgressView("正在加载私信…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if contacts.isEmpty, let error {
                NativeStateView(icon: "bubble.left.and.exclamationmark.bubble.right", title: "私信无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if contacts.isEmpty {
                NativeStateView(icon: "bubble.left.and.bubble.right", title: "暂无私信", message: "还没有最近联系人。")
            } else {
                List {
                    ForEach(contacts) { contact in
                        NavigationLink {
                            PrivateConversationView(
                                contactID: contact.userId,
                                contactName: users[contact.userId]?.name,
                                contactAvatar: users[contact.userId]?.portraitUrl
                            )
                        } label: {
                            contactRow(contact)
                        }
                    }

                    if error != nil {
                        Button("加载失败，点击重试") {
                            Task { await load(reset: false) }
                        }
                        .font(ShellTheme.Fonts.footnote)
                    } else if hasMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .onAppear {
                            Task { await load(reset: false) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(ShellTheme.pageBackground)
                .refreshable { await load(reset: true) }
            }
        }
        .task { await load(reset: true) }
    }

    private func contactRow(_ contact: NativeRecentContact) -> some View {
        HStack(spacing: 10) {
            NativeAvatar(url: avatarURL(users[contact.userId]?.portraitUrl) ?? NativeAvatarURLs.defaultURL(gender: nil), name: users[contact.userId]?.name, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(users[contact.userId]?.name ?? "用户 #\(contact.userId)")
                        .font(ShellTheme.Fonts.body.weight(.medium))
                        .foregroundStyle(ShellTheme.primaryText)
                    if contact.isRead == false {
                        Circle().fill(ShellTheme.accent).frame(width: 7, height: 7)
                    }
                }
                Text(contact.lastContent ?? "")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(NativeFormat.date(contact.time))
                .font(ShellTheme.Fonts.caption)
                .foregroundStyle(ShellTheme.secondaryText)
        }
        .padding(.vertical, 2)
    }

    private func avatarURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://www.cc98.org" + (raw.hasPrefix("/") ? raw : "/" + raw))
    }

    @MainActor
    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        error = nil
        if reset {
            page = 0
            hasMore = true
        }
        let pageSize = 10
        do {
            let fetched = try await app.api.recentContacts(from: page * pageSize, size: pageSize)
            if reset {
                contacts = fetched
            } else {
                let existing = Set(contacts.map(\.userId))
                contacts.append(contentsOf: fetched.filter { !existing.contains($0.userId) })
            }
            hasMore = fetched.count >= pageSize
            page += 1

            let known = Set(users.keys)
            let newIDs = Array(Set(fetched.map(\.userId)).subtracting(known))
            if !newIDs.isEmpty, let basics = try? await app.api.userBasics(ids: newIDs) {
                for user in basics { users[user.id] = user }
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct PrivateConversationView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth

    let contactID: Int
    let contactName: String?
    let contactAvatar: String?

    @State private var messages: [NativePrivateMessage] = []
    @State private var text = ""
    @State private var loading = false
    @State private var sending = false
    @State private var hasMore = true
    @State private var offset = 0
    @State private var errorMessage: String? = nil
    @State private var showError = false
    @FocusState private var focused: Bool

    private let pageSize = 10

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if hasMore {
                            Button("加载更早") {
                                Task { await load(reset: false) }
                            }
                            .font(ShellTheme.Fonts.caption)
                            .disabled(loading)
                        }
                        if messages.isEmpty && loading {
                            ProgressView("正在加载私信…")
                                .padding(.top, 40)
                        }
                        ForEach(messages.indices, id: \.self) { index in
                            bubble(messages[index], showTime: shouldShowTime(at: index))
                                .id(messages[index].id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
            }
            composer
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle(contactName ?? "私信")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(reset: true) }
        .alert("发送失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func bubble(_ message: NativePrivateMessage, showTime: Bool) -> some View {
        let mine = message.senderId == auth.profile?.id
        let otherAvatar = contactAvatarURL ?? NativeAvatarURLs.defaultURL(gender: nil)
        let myAvatar = auth.profile?.avatarURL ?? NativeAvatarURLs.defaultURL(gender: auth.profile?.gender)
        return HStack(alignment: .bottom, spacing: 6) {
            if !mine {
                NativeAvatar(url: otherAvatar, name: contactName, size: 24)
            }
            if mine { Spacer(minLength: 30) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                UBBContentView(source: message.content ?? "")
                    .padding(10)
                    .background(
                        mine ? ShellTheme.accent.opacity(0.16) : ShellTheme.surface,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                if showTime {
                    Text(NativeFormat.date(message.time))
                        .font(.system(size: 10))
                        .foregroundStyle(ShellTheme.secondaryText)
                }
            }
            if !mine { Spacer(minLength: 30) }
            if mine {
                NativeAvatar(url: myAvatar, name: auth.profile?.name, size: 24)
            }
        }
    }

    private var contactAvatarURL: URL? {
        guard let contactAvatar, !contactAvatar.isEmpty else { return nil }
        if let url = URL(string: contactAvatar), url.scheme != nil { return url }
        return URL(string: "https://www.cc98.org" + (contactAvatar.hasPrefix("/") ? contactAvatar : "/" + contactAvatar))
    }

    private func shouldShowTime(at index: Int) -> Bool {
        guard index > 0, messages.indices.contains(index) else { return true }
        guard let current = NativeFormat.dateValue(messages[index].time),
              let previous = NativeFormat.dateValue(messages[index - 1].time) else {
            return true
        }
        return current.timeIntervalSince(previous) > 300
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入私信…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                .focused($focused)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(ShellTheme.accent)
            .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(ShellTheme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(ShellTheme.separator).frame(height: 0.5)
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        do {
            let fetched = try await app.api.privateMessages(userID: contactID, from: reset ? 0 : offset, size: pageSize)
            let ordered = fetched.reversed()
            if reset {
                messages = Array(ordered)
                offset = fetched.count
                hasMore = fetched.count == pageSize
            } else {
                let existing = Set(messages.map(\.id))
                let older = ordered.filter { !existing.contains($0.id) }
                messages = older + messages
                offset += fetched.count
                hasMore = fetched.count == pageSize
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        loading = false
    }

    @MainActor
    private func send() async {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !sending else { return }
        sending = true
        do {
            try await app.api.sendPrivateMessage(receiverID: contactID, content: value)
            text = ""
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        sending = false
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        withAnimation {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
