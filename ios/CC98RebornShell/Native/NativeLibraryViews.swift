import SwiftUI
import UniformTypeIdentifiers

struct NativeLibraryStatusView: View {
    @EnvironmentObject private var library: NativeLibrary
    var body: some View {
        if let error = library.lastSaveError {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.danger)
                Button("重试保存") { library.retrySave() }
                    .frame(minHeight: 44)
            }
        }
    }
}

struct UserNoteEditor: View {
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss
    let userID: Int
    let userName: String
    @State private var note = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("仅自己可见的备注", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: note) { _, value in if value.count > 80 { note = String(value.prefix(80)) } }
                    Text("\(note.count)/80").font(ShellTheme.Fonts.caption).foregroundStyle(ShellTheme.secondaryText)
                } header: { Text(userName) } footer: { Text("备注保存在当前账号的本机数据中，不会替换原用户名；匿名楼层不显示备注。") }
                NativeLibraryStatusView()
            }
            .navigationTitle("用户备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { if library.setUserNote(note, for: userID) { dismiss() } }
                }
            }
            .onAppear { note = library.userNote(for: userID) }
        }
    }
}

private struct NativeBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct LibraryTransferView: View {
    @EnvironmentObject private var library: NativeLibrary
    let mode: NativeLibraryTransferMode
    @State private var importing = false
    @State private var exporting = false
    @State private var document: NativeBackupDocument?
    @State private var preview: NativeLibraryImportPreview?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Button { export() } label: { Label("导出 JSON 文件", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("library-transfer.export")
                Button { importing = true } label: { Label("选择文件导入", systemImage: "square.and.arrow.down") }
                    .accessibilityIdentifier("library-transfer.import")
            } footer: {
                Text(mode == .library
                     ? "包含置顶版面、置顶联系人、用户备注、主题备注、屏蔽规则和稍后再看。仅可恢复到同一账号。不含登录凭据、草稿、私信正文、搜索或浏览历史及外观设置。"
                     : "仅导入导出主题链接、标题、版面与已读状态，不包含主题正文。可合并到当前账号。")
            }
            Section("导入规则") {
                Text("先预览，再确认合并。同一主题、备注或置顶项已存在时保留本机内容，不覆盖；不会改动其他账号。")
                    .font(ShellTheme.Fonts.footnote)
                Text("备份是明文 JSON，请妥善保存，避免把私人备注发送给他人。")
                    .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
            }
        }
        .accessibilityIdentifier("library-transfer.form")
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5 * 1_024 * 1_024 else { throw NativeLibraryBackup.BackupError.invalid("文件超过 5 MB。") }
                preview = try library.previewImport(Data(contentsOf: url), mode: mode)
            } catch { message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: mode == .library ? "CC98-Reborn-本机增强" : "CC98-Reborn-稍后再看") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .sheet(item: $preview) { item in
            NavigationStack {
                Form {
                    Section("文件内容") {
                        ForEach(item.summary, id: \.0) { row in LabeledContent(row.0, value: "\(row.1)") }
                        LabeledContent("导出时间", value: item.backup.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Section {
                        Text("这些条目将合并到当前账号；已有数据保留，不会删除其他内容。")
                        Button("确认合并到当前账号") {
                            if library.importBackup(item) { preview = nil; message = "已合并到当前账号。" }
                        }.accessibilityIdentifier("library-transfer.confirm")
                        NativeLibraryStatusView()
                    }
                }
                .navigationTitle("导入预览")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { preview = nil } } }
            }
        }
        .alert("本机备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }

    private func export() {
        do { document = NativeBackupDocument(data: try library.exportBackup(mode: mode)); exporting = true }
        catch { message = error.localizedDescription }
    }
}

struct DraftCenterView: View {
    @EnvironmentObject private var library: NativeLibrary
    @State private var query = ""
    @State private var selected: NativeDraftItem?
    @State private var deleting: NativeDraftItem?
    private var items: [NativeDraftItem] {
        library.draftItems.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query) || $0.kindTitle.contains(query) }
    }
    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "没有草稿" : "没有匹配草稿", systemImage: "doc.text",
                                       description: Text("主题、投票、回复、编辑和私信草稿按当前账号保存在本机。"))
            }
            ForEach(items) { item in
                Button { selected = item } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.kindTitle).font(ShellTheme.Fonts.caption).foregroundStyle(ShellTheme.accent)
                            Spacer()
                            if let date = item.updatedAt { Text(date, style: .relative).font(ShellTheme.Fonts.caption).foregroundStyle(ShellTheme.secondaryText) }
                        }
                        Text(item.title).font(ShellTheme.Fonts.body.weight(.medium)).foregroundStyle(ShellTheme.primaryText).lineLimit(2)
                        if !item.body.isEmpty { Text(item.body).font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText).lineLimit(2) }
                    }.padding(.vertical, 6)
                }
                .accessibilityIdentifier("draft-center.item." + item.id)
                .swipeActions { Button("删除", role: .destructive) { deleting = item } }
            }
        }
        .accessibilityIdentifier("draft-center.list")
        .searchable(text: $query, prompt: "搜索草稿")
        .navigationTitle("草稿中心")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { item in DraftRecoveryView(item: item) }
        .confirmationDialog("删除这份草稿？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { item in
            Button("删除草稿", role: .destructive) { library.removeDraft(item); deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { _ in Text("将删除该任务的正文、标题与编辑设置，无法撤销。") }
    }
}

private struct DraftRecoveryView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    let item: NativeDraftItem
    @State private var board: NativeBoard?
    @State private var post: NativePost?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let id = item.targetID, item.kind == .message {
                NavigationStack { PrivateConversationView(contactID: id, contactName: nil, contactAvatar: nil)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } } }
            } else if let board, item.kind == .topic || item.kind == .vote {
                NewTopicComposer(boardID: board.id, boardName: board.name, anonymousState: board.anonymousState ?? 0,
                                 isVote: item.kind == .vote, onCreated: { dismiss() })
            } else if let id = item.targetID, item.kind == .reply {
                ReplyComposer(topicID: id, allowReplyTail: false, onSent: { dismiss() })
            } else if let post, item.kind == .edit {
                EditPostComposer(post: post, topicTitle: item.context?.title, onSaved: { dismiss() })
            } else if let post, let id = item.targetID, item.kind == .quote {
                ReplyComposer(topicID: id, quotedPost: post, allowReplyTail: false, onSent: { dismiss() })
            } else {
                NavigationStack {
                    List {
                        if loading { ProgressView("正在恢复原帖信息…") }
                        if let error {
                            Section { Text(error).foregroundStyle(ShellTheme.danger)
                                if canFetch { Button("重试恢复") { Task { await resolve() } } }
                            }
                        }
                        Section(item.title) { Text(item.body.isEmpty ? "仅有标题" : item.body).textSelection(.enabled) }
                        if !canFetch {
                            Section { Text("这份旧草稿缺少原帖位置。正文仍保留，可长按复制；从原主题进入编辑器也可继续读取对应草稿。")
                                .font(ShellTheme.Fonts.footnote) }
                        }
                        if let id = item.context?.topicID ?? ((item.kind == .quote) ? item.targetID : nil) {
                            NavigationLink("打开原主题") { TopicDetailView(topicID: id, boardID: item.context?.boardID) }
                        }
                    }
                    .navigationTitle(item.kindTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                }
            }
        }
        .task { await resolve() }
    }
    private var canFetch: Bool {
        item.kind == .topic || item.kind == .vote || ((item.kind == .quote || item.kind == .edit) && item.context?.topicID != nil && item.context?.floor != nil)
    }
    @MainActor private func resolve() async {
        guard canFetch, !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            if let id = item.targetID, item.kind == .topic || item.kind == .vote {
                board = try await app.api.board(id: id)
            } else if let topicID = item.context?.topicID, let floor = item.context?.floor {
                let posts = try await app.api.posts(topicID: topicID, from: max(0, floor - 1), size: 1)
                let expectedID = item.kind == .quote ? item.quotedPostID : item.targetID
                guard let matching = posts.first(where: { $0.id == expectedID }) else {
                    throw NativeLibraryBackup.BackupError.invalid("原帖已变动或不可见。草稿仍保留，未替换引用对象。")
                }
                post = matching
            }
        } catch { self.error = error.localizedDescription }
    }
}
