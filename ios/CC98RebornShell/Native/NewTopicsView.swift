import SwiftUI

struct NewTopicsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var thumbnails = NewTopicThumbnailLoader()

    @AppStorage("native.newTopicsCardMode") private var cardMode = false

    @State private var topics: [NativeTopicSummary] = []
    @State private var page = 0
    @State private var loading = false
    @State private var hasMore = true
    @State private var error: String? = nil
    @State private var mediaOnly = false
    @State private var showComposePicker = false
    @State private var boardNames: [Int: String] = [:]

    @State private var visibleTopicID: Int?
    @State private var loadID = UUID()
    @State private var loadedMediaOnly = false

    private let pageSize = 20

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("新帖类型", selection: $mediaOnly) {
                    Text("全部").tag(false)
                    Text("图文").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("newTopics.filter")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Group {
                    if topics.isEmpty && loading {
                        ProgressView("正在加载新帖…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(ShellTheme.pageBackground)
                    } else if topics.isEmpty, let error {
                        NativeStateView(icon: "doc.text", title: "新帖无法加载", message: error, action: {
                            Task { await load(reset: true) }
                        })
                    } else if topics.isEmpty {
                        NativeStateView(icon: "doc.text", title: "暂无新帖", message: nil)
                    } else {
                        feed
                    }
                }
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("新帖")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        cardMode.toggle()
                    } label: {
                        Image(systemName: cardMode ? "list.bullet" : "square.grid.2x2")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(cardMode ? "切换为列表" : "切换为卡片")
                    .accessibilityIdentifier("newTopics.layout")

                    Button {
                        showComposePicker = true
                    } label: {
                        Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("发表主题或投票")
                    .accessibilityIdentifier("newTopics.compose")
                }
            }
            .task(id: mediaOnly) { await load(reset: true) }
            .task { await loadBoardNames() }
            .sheet(isPresented: $showComposePicker) {
                NewTopicEntryView {
                    showComposePicker = false
                    Task { await load(reset: true) }
                }
            }
        }
    }

    private var feed: some View {
        GeometryReader { geometry in
            let contentWidth = min(geometry.size.width, ShellTheme.Metrics.maximumReadingWidth)
            let margin: CGFloat = geometry.size.width <= 320 ? 12 : 16
            let columns = contentWidth >= 390 && dynamicTypeSize < .xxxLarge ? 2 : 1
            let cardWidth = (contentWidth - margin * 2 - CGFloat(columns - 1) * 12) / CGFloat(columns)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        NativeLibraryStatusView()
                        if visibleTopics.isEmpty {
                            Text("当前已加载主题均被屏蔽规则筛选，可继续读取或前往「我的」管理规则。")
                                .font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                        }
                        if cardMode {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: 12) {
                                ForEach(visibleTopics) { topic in
                                    VStack(spacing: 0) {
                                        NavigationLink {
                                            TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                                        } label: {
                                            NewTopicCard(topic: topic, thumbnail: thumbnails.images[topic.id], boardName: resolvedBoardName(topic), width: cardWidth)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("newTopics.topic.\(topic.id)")
                                        HStack {
                                            Spacer()
                                            topicMenu(topic)
                                        }
                                        .padding(.horizontal, 8)
                                    }
                                    .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .id(topic.id)
                                    .onAppear { loadMoreIfNeeded(topic) }
                                    .task { await thumbnails.load(topic: topic, api: app.api) }
                                }
                            }
                            .scrollTargetLayout()
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(visibleTopics) { topic in
                                    HStack(alignment: .top, spacing: 0) {
                                        NavigationLink {
                                            TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                                        } label: {
                                            NewTopicRow(topic: topic, thumbnail: thumbnails.images[topic.id], boardName: resolvedBoardName(topic))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("newTopics.topic.\(topic.id)")
                                        topicMenu(topic)
                                    }
                                    .padding(.vertical, 12)
                                    .id(topic.id)
                                    .onAppear { loadMoreIfNeeded(topic) }
                                    .task { await thumbnails.load(topic: topic, api: app.api) }
                                    Divider()
                                }
                            }
                            .scrollTargetLayout()
                        }
                        feedFooter
                    }
                    .padding(.horizontal, margin)
                    .padding(.vertical, 12)
                    .frame(maxWidth: ShellTheme.Metrics.maximumReadingWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $visibleTopicID, anchor: .top)
                .onChange(of: cardMode) { _, _ in
                    if let visibleTopicID { proxy.scrollTo(visibleTopicID, anchor: .top) }
                }
                .refreshable { await load(reset: true) }
            }
        }
    }

    private func topicMenu(_ topic: NativeTopicSummary) -> some View {
        Menu { topicActions(topic) } label: {
            Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .accessibilityLabel("主题操作")
        .accessibilityIdentifier("newTopics.more.\(topic.id)")
    }

    @ViewBuilder private var feedFooter: some View {
        if loading {
            ProgressView("正在加载…").padding(16)
        } else if let error {
            NativeInlineRetry(message: error) { Task { await load(reset: loadedMediaOnly != mediaOnly) } }
        } else if hasMore {
            Button("继续加载") { Task { await load(reset: false) } }
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            Text("已显示本次可读取的最新内容，可下拉刷新或进入版面继续浏览。")
                .font(ShellTheme.Fonts.metadata).foregroundStyle(ShellTheme.secondaryText)
                .padding(.vertical, 12)
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

    private func loadMoreIfNeeded(_ topic: NativeTopicSummary) {
        guard hasMore, !loading, error == nil, loadedMediaOnly == mediaOnly else { return }
        guard visibleTopics.suffix(2).contains(where: { $0.id == topic.id }) else { return }
        Task { await load(reset: false) }
    }

    @ViewBuilder
    private func topicActions(_ topic: NativeTopicSummary) -> some View {
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

        if topic.isAnonymous != true, let userID = topic.userId {
            Button(role: .destructive) {
                library.addBlockedUserID(String(userID))
            } label: {
                Label("屏蔽此人", systemImage: "person.crop.circle.badge.xmark")
            }
        } else if topic.isAnonymous != true, let name = topic.userName, !name.isEmpty {
            Button(role: .destructive) {
                library.addBlockedUser(name)
            } label: {
                Label("屏蔽此人", systemImage: "person.crop.circle.badge.xmark")
            }
        }
    }

    private func resolvedBoardName(_ topic: NativeTopicSummary) -> String? {
        if let name = topic.boardName, !name.isEmpty {
            return name
        }
        if let boardID = topic.boardId, let name = boardNames[boardID] {
            return name
        }
        return nil
    }

    @MainActor
    private func loadBoardNames() async {
        guard boardNames.isEmpty else { return }
        guard let groups = try? await app.api.boardGroups() else { return }
        var map: [Int: String] = [:]
        for board in groups.flatMap({ $0.boards ?? [] }) {
            map[board.id] = board.name
        }
        boardNames = map
    }

    @MainActor
    private func load(reset: Bool) async {
        guard reset || !loading else { return }
        let requestID = UUID()
        loadID = requestID
        let requestedMedia = mediaOnly
        let requestedPage = reset ? 0 : page
        loading = true
        error = nil
        // Switching feeds starts a distinct query; stale responses must not overwrite it.
        if reset && requestedMedia != loadedMediaOnly {
            topics = []
            visibleTopicID = nil
        }
        do {
            let from = requestedPage * pageSize
            guard from < 500 else { hasMore = false; loading = false; return }
            let size = min(pageSize, 500 - from)
            let fetched = try await app.api.newTopics(from: from, size: size, mediaOnly: requestedMedia)
            guard loadID == requestID, mediaOnly == requestedMedia else { return }
            if reset {
                topics = fetched
            } else {
                let existing = Set(topics.map(\.id))
                topics.append(contentsOf: fetched.filter { !existing.contains($0.id) })
            }
            loadedMediaOnly = requestedMedia
            page = requestedPage + 1
            hasMore = fetched.count == size && from + size < 500
        } catch {
            guard loadID == requestID else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if loadID == requestID { loading = false }
    }

}

@MainActor
final class NewTopicThumbnailLoader: ObservableObject {
    @Published private(set) var images: [Int: URL] = [:]

    private var attempted: Set<Int> = []
    private var loading: Set<Int> = []

    func load(topic: NativeTopicSummary, api: CC98API) async {
        guard !attempted.contains(topic.id), !loading.contains(topic.id) else { return }
        loading.insert(topic.id)
        defer {
            loading.remove(topic.id)
            attempted.insert(topic.id)
        }

        if let local = UBBFirstImage.first(in: topic.lastPostContent ?? "") {
            images[topic.id] = local
            return
        }
        if let url = try? await api.firstTopicImage(topicID: topic.id) {
            images[topic.id] = url
        }
    }
}

private struct NewTopicCard: View {
    @EnvironmentObject private var library: NativeLibrary
    let topic: NativeTopicSummary
    let thumbnail: URL?
    let boardName: String?
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if let thumbnail {
                AsyncImage(url: thumbnail) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        thumbnailPlaceholder
                    case .empty:
                        ZStack {
                            ShellTheme.secondarySurface
                            ProgressView()
                        }
                    @unknown default:
                        thumbnailPlaceholder
                    }
                }
                .frame(width: width, height: 112)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityLabel("帖子图片缩略图")
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if let boardName, !boardName.isEmpty {
                        Text(boardName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(ShellTheme.accentSoft, in: Capsule())
                            .foregroundStyle(ShellTheme.accent)
                            .lineLimit(1)
                    }
                    Text(NativeFormat.date(topic.lastPostTime ?? topic.time))
                        .font(ShellTheme.Fonts.metadata)
                        .foregroundStyle(ShellTheme.secondaryText)
                }

                Text(topic.title ?? "主题 #\(topic.id)")
                    .font(ShellTheme.Fonts.body.weight(.semibold))
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                if let excerpt {
                    Text(excerpt)
                        .font(ShellTheme.Fonts.metadata)
                        .foregroundStyle(ShellTheme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"))
                        .fixedSize(horizontal: false, vertical: true)
                    if topic.isAnonymous != true, let userID = topic.userId, !library.userNote(for: userID).isEmpty {
                        Text("备注：\(library.userNote(for: userID))").fixedSize(horizontal: false, vertical: true)
                    }
                    Label(NativeFormat.count(topic.replyCount), systemImage: "bubble.left")
                }
                .font(ShellTheme.Fonts.metadata)
                .foregroundStyle(ShellTheme.secondaryText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        }
        .frame(width: width, alignment: .topLeading)
        .background(ShellTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
        .clipped()
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            ShellTheme.secondarySurface
            Image(systemName: "photo")
                .font(.title3)
                .foregroundStyle(ShellTheme.secondaryText)
        }
    }

    private var excerpt: String? {
        guard let raw = topic.lastPostContent, !raw.isEmpty else { return nil }
        // Do not turn hidden image/attachment URLs into visible excerpt text.
        let withoutMedia = raw.replacingOccurrences(of: "(?is)\\[(img|upload)(?:=[^\\]]*)?\\].*?\\[/\\1\\]", with: "", options: .regularExpression)
        let withoutTags = withoutMedia.replacingOccurrences(of: "\\[/?[^\\]]+\\]", with: "", options: .regularExpression)
        let collapsed = withoutTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let value = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
private struct NewTopicRow: View {
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let topic: NativeTopicSummary
    let thumbnail: URL?
    let boardName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title ?? "主题 #\(topic.id)")
                    .font(ShellTheme.Fonts.body.weight(.medium))
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(3)
                NativeTopicMetadata(
                    board: boardName,
                    author: topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"),
                    userNote: topic.isAnonymous == true ? nil : topic.userId.map { library.userNote(for: $0) },
                    replyCount: topic.replyCount, date: NativeFormat.date(topic.lastPostTime ?? topic.time)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let thumbnail, !dynamicTypeSize.isAccessibilitySize {
                AsyncImage(url: thumbnail) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        rowThumbnailPlaceholder
                    case .empty:
                        ZStack {
                            ShellTheme.secondarySurface
                            ProgressView()
                                .controlSize(.small)
                        }
                    @unknown default:
                        rowThumbnailPlaceholder
                    }
                }
                .frame(width: 74, height: 74)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ShellTheme.separator, lineWidth: 0.5)
                )
                .accessibilityLabel("帖子图片缩略图")
            }
        }
        .padding(.vertical, 2)
    }

    private var rowThumbnailPlaceholder: some View {
        ZStack {
            ShellTheme.secondarySurface
            Image(systemName: "photo")
                .foregroundStyle(ShellTheme.secondaryText)
        }
    }
}
