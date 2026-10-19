import SwiftUI

struct NewTopicsView: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var library: NativeLibrary
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

    private let pageSize = 20

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("新帖类型", selection: $mediaOnly) {
                    Text("全部").tag(false)
                    Text("图文").tag(true)
                }
                .pickerStyle(.segmented)
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
                    } else if cardMode {
                        cardFeed
                    } else {
                        listFeed
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
                    }
                    .accessibilityLabel(cardMode ? "切换为列表" : "切换为卡片")

                    Button {
                        showComposePicker = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
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

    private var listFeed: some View {
        List {
            ForEach(visibleTopics) { topic in
                NavigationLink {
                    TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                } label: {
                    NewTopicRow(
                        topic: topic,
                        thumbnail: thumbnails.images[topic.id],
                        boardName: resolvedBoardName(topic)
                    )
                }
                .onAppear { loadMoreIfNeeded(topic) }
                .task {
                    await thumbnails.load(topic: topic, api: app.api)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    topicActions(topic)
                }
            }
            if loading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if error != nil {
                Button("点击继续加载") {
                    Task { await load(reset: false) }
                }
                .font(ShellTheme.Fonts.footnote)
            } else if hasMore {
                Button("点击继续加载") {
                    Task { await load(reset: false) }
                }
                .font(ShellTheme.Fonts.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ShellTheme.pageBackground)
        .refreshable { await load(reset: true) }
    }

    private var cardFeed: some View {
        GeometryReader { geometry in
            let columnWidth = min(260, max(120, (geometry.size.width - 44) / 2))
            ScrollView {
                HStack(alignment: .top, spacing: 12) {
                    LazyVStack(spacing: 12) {
                        ForEach(evenTopics) { topic in
                            cardLink(topic, width: columnWidth)
                        }
                    }
                    .frame(width: columnWidth)

                    LazyVStack(spacing: 12) {
                        ForEach(oddTopics) { topic in
                            cardLink(topic, width: columnWidth)
                        }
                    }
                    .frame(width: columnWidth)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                if loading {
                    ProgressView()
                        .padding(.bottom, 20)
                } else if error != nil {
                    Button("点击继续加载") {
                        Task { await load(reset: false) }
                    }
                    .font(ShellTheme.Fonts.footnote)
                    .padding(.bottom, 20)
                } else if hasMore {
                    Button("点击继续加载") {
                        Task { await load(reset: false) }
                    }
                    .font(ShellTheme.Fonts.footnote)
                    .padding(.bottom, 20)
                }
            }
            .refreshable { await load(reset: true) }
        }
        .background(ShellTheme.pageBackground)
    }

    private func cardLink(_ topic: NativeTopicSummary, width: CGFloat) -> some View {
        NavigationLink {
            TopicDetailView(topicID: topic.id, boardID: topic.boardId)
        } label: {
            NewTopicCard(
                topic: topic,
                thumbnail: thumbnails.images[topic.id],
                boardName: resolvedBoardName(topic),
                width: width
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            topicActions(topic)
        }
        .onAppear { loadMoreIfNeeded(topic) }
        .task {
            await thumbnails.load(topic: topic, api: app.api)
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

    private var evenTopics: [NativeTopicSummary] {
        visibleTopics.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
    }

    private var oddTopics: [NativeTopicSummary] {
        visibleTopics.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element }
    }

    private func loadMoreIfNeeded(_ topic: NativeTopicSummary) {
        guard hasMore, !loading, error == nil else { return }
        let lastIDs = Set([topics.last?.id, evenTopics.last?.id, oddTopics.last?.id].compactMap { $0 })
        guard lastIDs.contains(topic.id) else { return }
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

        if let userID = topic.userId {
            Button(role: .destructive) {
                library.addBlockedUserID(String(userID))
            } label: {
                Label("屏蔽此人", systemImage: "person.crop.circle.badge.xmark")
            }
        } else if let name = topic.userName, !name.isEmpty {
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
        guard !loading else { return }
        loading = true
        error = nil
        if reset {
            page = 0
            hasMore = true
        }
        do {
            let from = page * pageSize
            guard from < 500 else {
                hasMore = false
                loading = false
                return
            }
            let size = from > 480 ? 500 - from : pageSize
            let fetched = try await app.api.newTopics(
                from: from,
                size: size,
                mediaOnly: mediaOnly
            )
            if reset {
                topics = fetched
            } else {
                let existing = Set(topics.map(\.id))
                topics.append(contentsOf: fetched.filter { !existing.contains($0.id) })
            }
            page += 1
            hasMore = fetched.count == size && from + size < 500
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
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
                HStack(spacing: 6) {
                    if let boardName, !boardName.isEmpty {
                        Text(boardName)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(ShellTheme.accentSoft, in: Capsule())
                            .foregroundStyle(ShellTheme.accent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(NativeFormat.date(topic.lastPostTime ?? topic.time))
                        .font(.system(size: 10))
                        .foregroundStyle(ShellTheme.secondaryText)
                }

                Text(topic.title ?? "主题 #\(topic.id)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                if let excerpt {
                    Text(excerpt)
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 2)

                HStack(spacing: 6) {
                    Text(topic.isAnonymous == true ? "匿名" : (topic.userName ?? "未知作者"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Label(NativeFormat.count(topic.replyCount), systemImage: "bubble.left")
                }
                .font(.system(size: 10))
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
        let withoutTags = raw.replacingOccurrences(of: "\\[/?[^\\]]+\\]", with: "", options: .regularExpression)
        let collapsed = withoutTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let value = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
private struct NewTopicRow: View {
    let topic: NativeTopicSummary
    let thumbnail: URL?
    let boardName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title ?? "主题 #\(topic.id)")
                    .font(ShellTheme.Fonts.body.weight(.medium))
                    .foregroundStyle(ShellTheme.primaryText)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let boardName, !boardName.isEmpty {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            if let thumbnail {
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
