import SwiftUI

struct NewTopicsView: View {
    @EnvironmentObject private var app: NativeAppModel

    @AppStorage("native.newTopicsCardMode") private var cardMode = false

    @State private var topics: [NativeTopicSummary] = []
    @State private var page = 0
    @State private var loading = false
    @State private var hasMore = true
    @State private var error: String? = nil
    @State private var mediaOnly = false
    @State private var showComposePicker = false

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
            ForEach(topics) { topic in
                NavigationLink {
                    TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                } label: {
                    NewTopicRow(topic: topic)
                }
                .onAppear { loadMoreIfNeeded(topic) }
            }
            if loading && hasMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ShellTheme.pageBackground)
        .refreshable { await load(reset: true) }
    }

    private var cardFeed: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                LazyVStack(spacing: 12) {
                    ForEach(evenTopics) { topic in
                        cardLink(topic)
                    }
                }
                LazyVStack(spacing: 12) {
                    ForEach(oddTopics) { topic in
                        cardLink(topic)
                    }
                }
            }
            .padding(16)

            if loading && hasMore {
                ProgressView()
                    .padding(.bottom, 20)
            }
        }
        .background(ShellTheme.pageBackground)
        .refreshable { await load(reset: true) }
    }

    private func cardLink(_ topic: NativeTopicSummary) -> some View {
        NavigationLink {
            TopicDetailView(topicID: topic.id, boardID: topic.boardId)
        } label: {
            NewTopicCard(topic: topic)
        }
        .buttonStyle(.plain)
        .onAppear { loadMoreIfNeeded(topic) }
    }

    private var evenTopics: [NativeTopicSummary] {
        topics.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
    }

    private var oddTopics: [NativeTopicSummary] {
        topics.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element }
    }

    private func loadMoreIfNeeded(_ topic: NativeTopicSummary) {
        guard hasMore, !loading, topic.id == topics.last?.id else { return }
        Task { await load(reset: false) }
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
            let fetched = try await app.api.newTopics(
                from: page * pageSize,
                size: pageSize,
                mediaOnly: mediaOnly
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
}

private struct NewTopicCard: View {
    let topic: NativeTopicSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(topic.boardName ?? "版面")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ShellTheme.accentSoft, in: Capsule())
                    .foregroundStyle(ShellTheme.accent)
                    .lineLimit(1)
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
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner))
        .overlay(
            RoundedRectangle(cornerRadius: ShellTheme.Metrics.corner)
                .stroke(ShellTheme.separator, lineWidth: 0.5)
        )
    }

    private var excerpt: String? {
        guard let raw = topic.lastPostContent, !raw.isEmpty else { return nil }
        let stripped = raw.replacingOccurrences(of: "[img][/img]", with: "")
        let withoutTags = stripped.replacingOccurrences(of: "\\[/?[^\\]]+\\]", with: "", options: .regularExpression)
        let collapsed = withoutTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let value = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct NewTopicRow: View {
    let topic: NativeTopicSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.title ?? "主题 #\(topic.id)")
                .font(ShellTheme.Fonts.body.weight(.medium))
                .foregroundStyle(ShellTheme.primaryText)
                .lineLimit(2)
            HStack(spacing: 8) {
                if let boardName = topic.boardName, !boardName.isEmpty {
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
