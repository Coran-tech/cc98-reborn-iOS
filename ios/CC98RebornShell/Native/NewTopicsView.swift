import SwiftUI

struct NewTopicsView: View {
    @EnvironmentObject private var app: NativeAppModel

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
                    } else {
                        List {
                            ForEach(topics) { topic in
                                NavigationLink {
                                    TopicDetailView(topicID: topic.id, boardID: topic.boardId)
                                } label: {
                                    NewTopicRow(topic: topic)
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
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("新帖")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
