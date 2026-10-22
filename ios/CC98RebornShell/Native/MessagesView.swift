import SwiftUI
import UIKit

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
    @State private var countUnavailable = false
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
                    if countUnavailable {
                        Text("暂无法确认未读数量，下次打开时重试。")
                            .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                            .padding(.horizontal, 16)
                    }

                    Group {
                        switch section {
                        case .reply, .at, .system:
                            NotificationListView(kind: section.kind ?? .reply)
                                .id("\(section.rawValue)-\(refreshID)")
                        case .privateMessages:
                            PrivateMessageListView()
                        }
                    }
                }
                .background(ShellTheme.pageBackground)
                .navigationTitle("消息")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if section != .privateMessages {
                            Menu {
                                Button("将\(section.title)全部标为已读") { Task { await markAllRead() } }
                            } label: {
                                Image(systemName: "checkmark.circle").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("当前分类已读操作")
                            .accessibilityIdentifier("messages.markRead")
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
                    VStack(spacing: 4) {
                        Text(item.title).font(ShellTheme.Fonts.footnote.weight(.semibold))
                        Text(count(for: item)).font(.footnote.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .padding(.vertical, 4)
                    .background(
                        section == item ? ShellTheme.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(section == item ? ShellTheme.accent : ShellTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("messages.\(item.rawValue)")
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
        }
        .padding(4)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func count(for section: NativeMessageSection) -> String {
        guard counts != nil else { return "—" }
        switch section {
        case .reply:
            return counts?.replyCount.map { NativeFormat.count($0) } ?? "—"
        case .at:
            return counts?.atCount.map { NativeFormat.count($0) } ?? "—"
        case .system:
            return counts?.systemCount.map { NativeFormat.count($0) } ?? "—"
        case .privateMessages:
            return counts?.messageCount.map { NativeFormat.count($0) } ?? "—"
        }
    }

    @MainActor
    private func loadCounts() async {
        do { counts = try await app.api.messageCounts(); countUnavailable = false }
        catch { countUnavailable = true }
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
        .task(id: kind) { await load(reset: true) }
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
                .font(ShellTheme.Fonts.footnote)
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
    @EnvironmentObject private var library: NativeLibrary

    @State private var contacts: [NativeRecentContact] = []
    @State private var users: [Int: NativeBasicUser] = [:]
    @State private var loading = false
    @State private var error: String? = nil
    @State private var page = 0
    @State private var hasMore = true

    private var orderedContacts: [NativeRecentContact] {
        let byID = Dictionary(contacts.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = library.pinnedContactIDs.map { byID[$0] ?? NativeRecentContact(userId: $0, time: nil, isRead: nil, lastContent: nil) }
        return pinned + contacts.filter { !library.isContactPinned($0.userId) }
    }

    var body: some View {
        Group {
            if orderedContacts.isEmpty && loading {
                ProgressView("正在加载私信…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ShellTheme.pageBackground)
            } else if orderedContacts.isEmpty, let error {
                NativeStateView(icon: "bubble.left.and.exclamationmark.bubble.right", title: "私信无法加载", message: error, action: {
                    Task { await load(reset: true) }
                })
            } else if orderedContacts.isEmpty {
                NativeStateView(icon: "bubble.left.and.bubble.right", title: "暂无私信", message: "还没有最近联系人。")
            } else {
                List {
                    ForEach(orderedContacts) { contact in
                        NavigationLink {
                            PrivateConversationView(
                                contactID: contact.userId,
                                contactName: users[contact.userId]?.name,
                                contactAvatar: users[contact.userId]?.portraitUrl
                            )
                        } label: {
                            contactRow(contact)
                        }
                        .accessibilityIdentifier("message.contact.\(contact.userId)")
                        .contextMenu {
                            Button(library.isContactPinned(contact.userId) ? "取消置顶联系人" : "置顶联系人", systemImage: "pin") {
                                library.togglePinnedContact(userID: contact.userId)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button(library.isContactPinned(contact.userId) ? "取消置顶" : "置顶", systemImage: "pin") {
                                library.togglePinnedContact(userID: contact.userId)
                            }.tint(ShellTheme.accent)
                        }
                    }
                    NativeLibraryStatusView()

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
                    if library.isContactPinned(contact.userId) {
                        Image(systemName: "pin.fill").font(.footnote).foregroundStyle(ShellTheme.accent)
                            .accessibilityLabel("已置顶")
                    }
                    if contact.isRead == false {
                        Circle().fill(ShellTheme.accent).frame(width: 7, height: 7)
                    }
                }
                if !library.userNote(for: contact.userId).isEmpty {
                    Text("备注：\(library.userNote(for: contact.userId))")
                        .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                        .lineLimit(2)
                }
                if !library.draft(for: "pm:\(contact.userId)").isEmpty {
                    Text("草稿：\(library.draft(for: "pm:\(contact.userId)"))")
                        .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.accent).lineLimit(2)
                }
                Text(contact.lastContent ?? "")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(NativeFormat.date(contact.time))
                .font(ShellTheme.Fonts.footnote)
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
            let newIDs = Array(Set(fetched.map(\.userId) + library.pinnedContactIDs).subtracting(known))
            if !newIDs.isEmpty, let basics = try? await app.api.userBasics(ids: newIDs) {
                for user in basics { users[user.id] = user }
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct ConversationScrollRequest: Equatable {
    let id = UUID()
    let messageID: Int
    let bottom: Bool
}

private struct ConversationBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PrivateConversationView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let contactID: Int
    let contactName: String?
    let contactAvatar: String?

    @State private var messages: [NativePrivateMessage] = []
    @State private var text = ""
    @State private var loading = false
    @State private var sending = false
    @State private var hasMore = true
    @State private var offset = 0
    @State private var errorMessage: String?
    @State private var errorTitle = "私信暂不可用"
    @State private var showError = false
    @State private var restoredDraft = false
    @State private var showExit = false
    @State private var atBottom = true
    @State private var newMessagesAvailable = false
    @State private var scrollRequest: ConversationScrollRequest?
    @State private var showNote = false
    @FocusState private var focused: Bool

    private let pageSize = 10
    private var draftKey: String { "pm:\(contactID)" }
    private var displayName: String { contactName ?? "用户 #\(contactID)" }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if hasMore {
                                Button(loading ? "正在加载…" : "加载更早的私信") { Task { await loadEarlier() } }
                                    .font(ShellTheme.Fonts.footnote)
                                    .frame(minHeight: 44)
                                    .disabled(loading)
                                    .accessibilityIdentifier("message.earlier")
                            }
                            if messages.isEmpty && loading { ProgressView("正在加载私信…").padding(.top, 40) }
                            if messages.isEmpty && !loading {
                                Text(errorMessage ?? "还没有私信，发送第一条消息吧。")
                                    .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                                    .padding(.vertical, 24)
                            }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                bubble(message, showTime: shouldShowTime(at: index), availableWidth: geometry.size.width - 32)
                                    .id(message.id)
                            }
                            Color.clear.frame(height: 1)
                                .background(GeometryReader { marker in
                                    Color.clear.preference(key: ConversationBottomPreference.self,
                                        value: marker.frame(in: .named("conversationScroll")).maxY)
                                })
                        }
                        .padding(16)
                    }
                    .coordinateSpace(name: "conversationScroll")
                    .scrollDismissesKeyboard(.interactively)
                    .onPreferenceChange(ConversationBottomPreference.self) { bottom in
                        atBottom = bottom >= 0 && bottom <= geometry.size.height + 64
                        if atBottom { newMessagesAvailable = false }
                    }
                    .onChange(of: scrollRequest) { _, request in
                        guard let request else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(request.messageID, anchor: request.bottom ? .bottom : .top)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if newMessagesAvailable {
                            Button("查看新消息", systemImage: "arrow.down") { requestBottom() }
                                .font(ShellTheme.Fonts.footnote)
                                .buttonStyle(.borderedProminent)
                                .padding(12)
                        }
                    }
                }
            }
            NativeLibraryStatusView().padding(.horizontal, 16)
            composer
        }
        .background(ShellTheme.pageBackground)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { close() } label: { Label("返回", systemImage: "chevron.left").frame(minHeight: 44) }
                    .disabled(sending)
                    .accessibilityIdentifier("message.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(library.isContactPinned(contactID) ? "取消置顶联系人" : "置顶联系人", systemImage: "pin") {
                        library.togglePinnedContact(userID: contactID)
                    }
                    Button("用户备注", systemImage: "note.text") { showNote = true }
                    NavigationLink("查看用户主页") { UserProfileView(userID: contactID, userName: contactName) }
                    Button("刷新会话", systemImage: "arrow.clockwise") { Task { await refreshLatest(follow: atBottom) } }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("联系人操作")
                .accessibilityIdentifier("message.contactActions")
            }
        }
        .sheet(isPresented: $showNote) { UserNoteEditor(userID: contactID, userName: displayName) }
        .task {
            guard !restoredDraft else { return }
            text = library.draft(for: draftKey)
            restoredDraft = true
            await initialLoad()
        }
        .onChange(of: text) { _, value in
            if restoredDraft { library.setDraft(value, for: draftKey) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && restoredDraft { library.setDraft(text, for: draftKey) }
        }
        .confirmationDialog("私信草稿尚未保存", isPresented: $showExit, titleVisibility: .visible) {
            Button("重试保存并返回") { if library.setDraft(text, for: draftKey) { dismiss() } }
            Button("复制私信") { UIPasteboard.general.string = text }
            Button("丢弃本会话草稿并返回", role: .destructive) { library.clearDraft(for: draftKey); dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
        .alert(errorTitle, isPresented: $showError) {
            Button("好", role: .cancel) { }
        } message: { Text(errorMessage ?? "") }
    }

    private func bubble(_ message: NativePrivateMessage, showTime: Bool, availableWidth: CGFloat) -> some View {
        let mine = message.senderId == auth.profile?.id
        let otherAvatar = contactAvatarURL ?? NativeAvatarURLs.defaultURL(gender: nil)
        let myAvatar = auth.profile?.avatarURL ?? NativeAvatarURLs.defaultURL(gender: auth.profile?.gender)
        return HStack(alignment: .bottom, spacing: 6) {
            if !mine { NativeAvatar(url: otherAvatar, name: contactName, size: 24) }
            if mine { Spacer(minLength: 8) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
                UBBContentView(source: message.content ?? "")
                    .font(ShellTheme.Fonts.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(mine ? ShellTheme.accentSoft : ShellTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                if showTime {
                    Text(NativeFormat.date(message.time))
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.secondaryText)
                }
            }
            .frame(maxWidth: max(120, availableWidth * 0.82), alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 8) }
            if mine { NativeAvatar(url: myAvatar, name: auth.profile?.name, size: 24) }
        }
    }

    private var contactAvatarURL: URL? {
        guard let contactAvatar, !contactAvatar.isEmpty else { return nil }
        if let url = URL(string: contactAvatar), url.scheme != nil { return url }
        return URL(string: "https://www.cc98.org" + (contactAvatar.hasPrefix("/") ? contactAvatar : "/" + contactAvatar))
    }

    private func shouldShowTime(at index: Int) -> Bool {
        guard index > 0, messages.indices.contains(index),
              let current = NativeFormat.dateValue(messages[index].time),
              let previous = NativeFormat.dateValue(messages[index - 1].time) else { return true }
        return current.timeIntervalSince(previous) > 300
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("以 \(auth.profile?.name ?? "当前账号") 发送给 \(displayName)")
                .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("输入私信…", text: $text, axis: .vertical)
                    .font(ShellTheme.Fonts.body)
                    .lineLimit(1...5)
                    .padding(12)
                    .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 12))
                    .focused($focused)
                    .accessibilityIdentifier("message.input")
                Button { Task { await send() } } label: {
                    Group {
                        if sending { ProgressView() }
                        else { Image(systemName: "paperplane.fill") }
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(NativePrimaryButtonStyle())
                .accessibilityLabel(sending ? "正在发送" : "发送私信")
                .accessibilityIdentifier("message.send")
                .disabled(sending || loading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(ShellTheme.surface)
        .overlay(alignment: .top) { Rectangle().fill(ShellTheme.separator).frame(height: 0.5) }
    }

    private func close() {
        if library.setDraft(text, for: draftKey) { dismiss() }
        else { showExit = true }
    }

    private func requestBottom() {
        guard let last = messages.last else { return }
        scrollRequest = ConversationScrollRequest(messageID: last.id, bottom: true)
        newMessagesAvailable = false
    }

    @MainActor
    private func initialLoad() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await app.api.privateMessages(userID: contactID, from: 0, size: pageSize)
            messages = Array(fetched.reversed())
            offset = fetched.count
            hasMore = fetched.count == pageSize
            errorMessage = nil
            requestBottom()
        } catch { errorTitle = "私信加载失败"; errorMessage = error.localizedDescription; showError = true }
    }

    @MainActor
    private func loadEarlier() async {
        guard !loading, hasMore else { return }
        loading = true
        let anchor = messages.first?.id
        defer { loading = false }
        do {
            let fetched = try await app.api.privateMessages(userID: contactID, from: offset, size: pageSize)
            let existing = Set(messages.map(\.id))
            let older = fetched.reversed().filter { !existing.contains($0.id) }
            messages = older + messages
            offset += fetched.count
            hasMore = fetched.count == pageSize
            if let anchor { scrollRequest = ConversationScrollRequest(messageID: anchor, bottom: false) }
            else { requestBottom() }
        } catch { errorTitle = "更早私信加载失败"; errorMessage = error.localizedDescription; showError = true }
    }

    @MainActor
    private func refreshLatest(follow: Bool, sent: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await app.api.privateMessages(userID: contactID, from: 0, size: pageSize)
            let existing = Set(messages.map(\.id))
            let newer = fetched.reversed().filter { !existing.contains($0.id) }
            messages.append(contentsOf: newer)
            offset += newer.count
            if follow { requestBottom() }
            else if !newer.isEmpty { newMessagesAvailable = true }
        } catch {
            errorTitle = sent ? "私信已发送，刷新会话失败" : "刷新会话失败"
            errorMessage = sent ? "请刷新会话核对，不要重复发送。\n" + error.localizedDescription : error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func send() async {
        let original = text
        let value = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !sending, !loading else { return }
        let follow = atBottom
        sending = true
        defer { sending = false }
        do {
            try await app.api.sendPrivateMessage(receiverID: contactID, content: value)
            if text == original { text = ""; library.clearDraft(for: draftKey) }
            await refreshLatest(follow: follow, sent: true)
        } catch {
            errorTitle = "私信发送未完成"
            errorMessage = error.localizedDescription + "\n输入已保留；若请求超时，请先刷新会话核对后再重试。"
            showError = true
        }
    }
}
