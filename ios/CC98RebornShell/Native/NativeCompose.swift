import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

enum NativePostingError {
    static func message(_ raw: String) -> String {
        let value = raw.lowercased()
        if value.contains("board_minimum_post_count_request") { return "该版面有最小发帖数限制。" }
        if value.contains("cannot_post_in_this_board") { return "你在该版面被禁言中。" }
        if value.contains("cannot_post_anonymous") { return "匿名发言处罚未到期，无法匿名发帖。" }
        if value.contains("wealth_not_enough_for_anonymous_topic") { return "财富值不足 10000，无法匿名发帖。" }
        if value.contains("tag_id_error") { return "标签选择无效，请重新选择。" }
        if value.contains("cannot_post_school_event") { return "没有权限发布校园活动类型。" }
        if value.contains("last_post_in_10_seconds") || value.contains("request_too_fast") { return "发言过快，请稍后再试。" }
        if value.contains("board_cannot_vote") { return "该版面无法发布投票。" }
        if value.contains("vote_topic_cannot_be_anonymous") { return "投票帖不能匿名发表。" }
        if value.contains("vote_item_error") || value.contains("max_vote_count_error") || value.contains("vote_expired_days_error") {
            return "投票设置不合法，请检查选项、天数和最大投票数。"
        }
        if value.contains("cannot_entry_board") { return "没有进入该版面的权限。" }
        return raw
    }
}

struct ComposerKeyboardToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("收起键盘") { Self.dismissKeyboard() }
                .accessibilityIdentifier("compose.dismissKeyboard")
        }
    }

    static func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct ComposerImageButton: View {
    @EnvironmentObject private var app: NativeAppModel
    @Binding var text: String
    @Binding var selection: NSRange
    let editor: UBBEditorController
    var onUploadingChanged: (Bool) -> Void = { _ in }

    @State private var item: PhotosPickerItem?
    @State private var pendingData: Data?
    @State private var uploading = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picker
            if pendingData != nil && !uploading {
                Button("图片未上传 · 重试或移除") { showError = true }
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.danger)
                    .frame(minHeight: 44)
            }
        }
    }

    private var picker: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label(uploading ? "图片上传中…" : "图片", systemImage: uploading ? "arrow.up.circle" : "photo")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("compose.image")
        .disabled(uploading)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { await readAndUpload(newItem) }
        }
        .alert("所选图片上传失败", isPresented: $showError) {
            if pendingData != nil {
                Button("重试上传") { Task { await uploadPending() } }
            }
            Button("移除待上传图片", role: .destructive) { pendingData = nil }
            Button("保留，稍后重试", role: .cancel) { }
        } message: { Text(errorMessage + "\n正文和已上传内容不会删除。") }
        .contextMenu {
            if pendingData != nil, !uploading {
                Button("重试待上传图片") { Task { await uploadPending() } }
                Button("移除待上传图片", role: .destructive) { pendingData = nil }
            }
        }
    }

    @MainActor
    private func readAndUpload(_ pickerItem: PhotosPickerItem) async {
        uploading = true
        onUploadingChanged(true)
        defer { uploading = false; onUploadingChanged(false); item = nil }
        do {
            guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                throw NSError(domain: "CC98Reborn", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取所选图片。"])
            }
            pendingData = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            try await sendPending()
        } catch { errorMessage = error.localizedDescription; showError = true }
    }

    @MainActor
    private func uploadPending() async {
        guard !uploading else { return }
        uploading = true
        onUploadingChanged(true)
        defer { uploading = false; onUploadingChanged(false) }
        do { try await sendPending() }
        catch { errorMessage = error.localizedDescription; showError = true }
    }

    @MainActor
    private func sendPending() async throws {
        guard let pendingData else { return }
        let url = try await app.api.uploadImage(pendingData)
        let snippet = "\n[img]\(url)[/img]\n"
        if !editor.insert(snippet) {
            UBBEditorInsertion.insert(snippet, text: &text, selection: &selection)
        }
        self.pendingData = nil
    }
}

struct ComposerFileButton: View {
    @EnvironmentObject private var app: NativeAppModel
    @Binding var text: String
    @Binding var selection: NSRange
    let editor: UBBEditorController
    var onUploadingChanged: (Bool) -> Void = { _ in }

    @State private var showImporter = false
    @State private var uploading = false
    @State private var pendingData: Data?
    @State private var fileName = "文件"
    @State private var fileExtension = ""
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePicker
            if pendingData != nil && !uploading {
                Button("文件未上传 · 重试或移除") { showError = true }
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.danger)
                    .frame(minHeight: 44)
            }
        }
    }

    private var filePicker: some View {
        Button { showImporter = true } label: {
            Label(uploading ? "\(fileName) 上传中…" : "文件", systemImage: uploading ? "arrow.up.circle" : "paperclip")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("compose.file")
        .disabled(uploading)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { Task { await readAndUpload(url) } }
            case let .failure(error):
                errorMessage = error.localizedDescription; showError = true
            }
        }
        .alert("\(fileName) 上传失败", isPresented: $showError) {
            if pendingData != nil {
                Button("重试上传") { Task { await uploadPending() } }
            }
            Button("移除待上传文件", role: .destructive) { pendingData = nil }
            Button("保留，稍后重试", role: .cancel) { }
        } message: { Text(errorMessage + "\n正文和已上传内容不会删除。") }
        .contextMenu {
            if pendingData != nil, !uploading {
                Button("重试 \(fileName)") { Task { await uploadPending() } }
                Button("移除待上传文件", role: .destructive) { pendingData = nil }
            }
        }
    }

    @MainActor
    private func readAndUpload(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        fileName = url.lastPathComponent
        fileExtension = url.pathExtension.lowercased()
        do { pendingData = try Data(contentsOf: url) }
        catch { errorMessage = error.localizedDescription; showError = true; return }
        await uploadPending()
    }

    @MainActor
    private func uploadPending() async {
        guard let pendingData, !uploading else { return }
        uploading = true
        onUploadingChanged(true)
        defer { uploading = false; onUploadingChanged(false) }
        do {
            let mime = UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
            let remote = try await app.api.uploadAttachment(pendingData, fileName: fileName, mimeType: mime)
            let tag = fileExtension.isEmpty ? "file" : fileExtension
            let snippet = "\n[upload=\(tag)]\(remote)[/upload]\n"
            if !editor.insert(snippet) {
                UBBEditorInsertion.insert(snippet, text: &text, selection: &selection)
            }
            self.pendingData = nil
        } catch { errorMessage = error.localizedDescription; showError = true }
    }
}

struct ComposerAttachmentsBar: View {
    @Binding var text: String
    @Binding var selection: NSRange
    let editor: UBBEditorController
    var onUploadingChanged: (Bool) -> Void = { _ in }
    @State private var imageUploading = false
    @State private var fileUploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ComposerImageButton(text: $text, selection: $selection, editor: editor) { value in
                        imageUploading = value
                        onUploadingChanged(value || fileUploading)
                    }
                    ComposerEmoticonButton(text: $text, selection: $selection, editor: editor)
                    ComposerFileButton(text: $text, selection: $selection, editor: editor) { value in
                        fileUploading = value
                        onUploadingChanged(imageUploading || value)
                    }
                }
            }
            Text(imageUploading || fileUploading ? "正在上传，请完成后再发布或退出。" : "选择图片或文件后立即上传到 CC98。")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
        }
    }
}

private struct NativeTopicDraftSettings: Codable, Equatable {
    var contentType: Int
    var anonymous: Bool
    var notifyPoster: Bool
    var postKind: Int
    var tag1ID: Int?
    var tag2ID: Int?
    var voteItems: [String]
    var expiredDays: Int
    var maxVoteCount: Int
    var needVote: Bool
}

private struct NativeTopicDraftSnapshot: Equatable {
    let title: String
    let body: String
    let settings: NativeTopicDraftSettings
}

struct NewTopicComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss

    let boardID: Int
    let boardName: String
    var anonymousState: Int = 0
    var isVote: Bool = false
    var onCreated: () -> Void

    @State private var title = ""
    @State private var content = ""
    @State private var anonymous = false
    @State private var contentType = 0
    @State private var notifyPoster = true
    @State private var postKind = 0
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var boardAnonymousState: Int? = nil
    @State private var tags: NativeTagV2? = nil
    @State private var tag1ID: Int? = nil
    @State private var tag2ID: Int? = nil
    @State private var boardMasters: [String] = []
    @State private var voteItems = ["", ""]
    @State private var expiredDays = 7
    @State private var maxVoteCount = 1
    @State private var needVote = false
    @State private var draftStatus = ""
    @StateObject private var editor = UBBEditorController()
    @State private var sending = false
    @State private var uploading = false
    @State private var draftReady = false
    @State private var savedSnapshot: NativeTopicDraftSnapshot?
    @State private var showExit = false
    @State private var showRestore = false
    @State private var showClearDraft = false
    @State private var showModeChange = false
    @State private var published = false
    @State private var showMentionWarning = false
    @State private var errorMessage: String? = nil
    @FocusState private var focused: Bool

    private var draftPrefix: String { isVote ? "newvote" : "newtopic" }
    private var titleKey: String { "\(draftPrefix).title:\(boardID)" }
    private var bodyKey: String { "\(draftPrefix).body:\(boardID)" }
    private var settingsKey: String { "\(draftPrefix).settings:\(boardID)" }
    private var hasInput: Bool { !title.isEmpty || !content.isEmpty || voteItems.contains { !$0.isEmpty } }
    private var settings: NativeTopicDraftSettings {
        NativeTopicDraftSettings(contentType: contentType, anonymous: anonymous, notifyPoster: notifyPoster,
            postKind: postKind, tag1ID: tag1ID, tag2ID: tag2ID, voteItems: voteItems,
            expiredDays: expiredDays, maxVoteCount: maxVoteCount, needVote: needVote)
    }

    private var snapshot: NativeTopicDraftSnapshot { NativeTopicDraftSnapshot(title: title, body: content, settings: settings) }
    private var savedAtDescription: String {
        if let date = library.draftItems.first(where: { $0.keys.contains(bodyKey) || $0.keys.contains(titleKey) })?.updatedAt {
            return "保存时间：\(date.formatted(date: .abbreviated, time: .shortened))。"
        }
        return "旧草稿未记录保存时间。"
    }

    private var effectiveAnonymousState: Int {
        boardAnonymousState ?? anonymousState
    }

    private var canPostActivity: Bool {
        if auth.profile?.userTitleIds?.contains(91) == true { return true }
        guard let name = auth.profile?.name else { return false }
        return boardMasters.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func tagMenu(
        _ title: String,
        options: [NativeTag],
        selected: Binding<Int?>,
        onChange: @escaping () -> Void
    ) -> some View {
        Menu {
            ForEach(options) { tag in
                Button(tag.name) {
                    selected.wrappedValue = tag.id
                    onChange()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(tagName(options, selected.wrappedValue) ?? title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .font(ShellTheme.Fonts.footnote)
            .foregroundStyle(selected.wrappedValue == nil ? ShellTheme.secondaryText : ShellTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(ShellTheme.secondarySurface, in: Capsule())
        }
    }

    private func tagName(_ options: [NativeTag], _ id: Int?) -> String? {
        guard let id else { return nil }
        return options.first { $0.id == id }?.name
    }

    var body: some View {
        NavigationStack {
            publishingDialogs
                .task { await prepareDraft() }
                .onChange(of: title) { _, _ in saveDraftIfChanged() }
                .onChange(of: content) { _, _ in saveDraftIfChanged() }
                .onChange(of: settings) { _, _ in saveDraftIfChanged() }
        }
    }

    private var composerScreen: some View {
        ScrollView { composerContents }
        .accessibilityIdentifier("compose.scroll")
        .scrollDismissesKeyboard(.interactively)
        .background(ShellTheme.pageBackground)
        .navigationTitle(isVote ? "发表投票" : "发表主题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ComposerKeyboardToolbar()
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { if hasInput { showExit = true } else { dismiss() } }
                    .frame(minHeight: 44)
                    .disabled(sending || uploading || published)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "发布中…" : "发布") { Task { await submit() } }
                    .font(ShellTheme.Fonts.body.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("compose.submit")
                    .disabled(sending || uploading || published || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(hasInput || uploading || sending || published)
    }

    private var composerContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleFields
            sourceFields
            if isVote { voteSettings }
            draftControls
            NativeLibraryStatusView()
            publishingOptions
            if let errorMessage {
                Text(errorMessage)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.danger)
            }
        }
        .disabled(sending || published)
        .padding(16)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var titleFields: some View {
        HStack(spacing: 8) {
            Text("使用账号：")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
            NativeAvatar(
                url: auth.profile?.avatarURL ?? NativeAvatarURLs.defaultURL(gender: auth.profile?.gender),
                name: auth.profile?.name,
                size: 24
            )
            Text(auth.profile?.name ?? "CC98 用户")
                .font(ShellTheme.Fonts.footnote.weight(.medium))
                .foregroundStyle(ShellTheme.primaryText)
        }

        Text(boardName)
            .font(ShellTheme.Fonts.footnote)
            .foregroundStyle(ShellTheme.secondaryText)

        Text("主题标题").font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
        TextField("输入主题标题", text: $title)
            .font(ShellTheme.Fonts.body)
            .accessibilityIdentifier("compose.title")
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { ComposerKeyboardToolbar.dismissKeyboard() }
    }

    @ViewBuilder
    private var sourceFields: some View {
        Text(contentType == 0 ? "正文 · UBB 源码" : "正文 · Markdown 源码")
            .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
        if contentType == 0 {
            UBBFormatBar(text: $content, selection: $selection, editor: editor)
        } else {
            MarkdownFormatBar(text: $content, selection: $selection, editor: editor)
        }
        UBBTextEditor(text: $content, selection: $selection, controller: editor, minHeight: 260)
            .accessibilityIdentifier("compose.body")
            .frame(minHeight: 260)
            .padding(4)
            .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(ShellTheme.separator, lineWidth: 0.5)
            )

        ComposerAttachmentsBar(text: $content, selection: $selection, editor: editor) { uploading = $0 }
        Text("\(content.count) / 8000")
            .font(ShellTheme.Fonts.footnote)
            .foregroundStyle(content.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .trailing)

        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup("预览") {
                UBBContentView(source: content, markdown: contentType == 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(ShellTheme.Fonts.body)
            .accessibilityIdentifier("compose.preview")
        }
    }

    private var voteSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("投票设置")
                .font(ShellTheme.Fonts.footnote.weight(.semibold))
                .foregroundStyle(ShellTheme.primaryText)
            Stepper("有效天数：\(expiredDays)", value: $expiredDays, in: 1...1000)
                .font(ShellTheme.Fonts.footnote)
            Stepper(
                "最多可投：\(maxVoteCount)",
                value: $maxVoteCount,
                in: 1...max(1, voteItems.count)
            )
            .font(ShellTheme.Fonts.footnote)

            ForEach(voteItems.indices, id: \.self) { index in
                HStack {
                    TextField("选项 \(index + 1)", text: $voteItems[index])
                        .textFieldStyle(.roundedBorder)
                    if voteItems.count > 2 {
                        Button {
                            voteItems.remove(at: index)
                            maxVoteCount = min(maxVoteCount, max(1, voteItems.count))
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(ShellTheme.danger)
                                .frame(width: 44, height: 44)
                                .accessibilityLabel("删除选项 \(index + 1)")
                        }
                    }
                }
            }

            if voteItems.count < 20 {
                Button {
                    voteItems.append("")
                } label: {
                    Label("添加选项", systemImage: "plus.circle")
                        .frame(minHeight: 44)
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.accent)
                }
            }

            Toggle("投票后结果可见", isOn: $needVote)
                .font(ShellTheme.Fonts.footnote)
        }
        .padding(12)
        .background(ShellTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var publishingOptions: some View {
        Button(contentType == 0 ? "格式：UBB · 切换为 Markdown" : "格式：Markdown · 切换为 UBB") {
            showModeChange = true
        }
        .font(ShellTheme.Fonts.footnote)
        .frame(minHeight: 44)
        .accessibilityIdentifier("compose.format")

        if let tagGroup = tags, tagGroup.layers > 0 {
            HStack(spacing: 8) {
                tagMenu(
                    "一级标签",
                    options: tagGroup.tags,
                    selected: $tag1ID
                ) {
                    tag2ID = nil
                }
                if tagGroup.layers == 2 {
                    tagMenu(
                        "二级标签",
                        options: tagGroup.tags.first { $0.id == tag1ID }?.subTags ?? [],
                        selected: $tag2ID
                    ) {}
                }
            }
        }

        Toggle("接收新回复通知", isOn: $notifyPoster)
            .font(ShellTheme.Fonts.footnote)

        if !isVote {
            if effectiveAnonymousState == 1 {
                Text("本版强制匿名发帖")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
            } else if effectiveAnonymousState == 2 || effectiveAnonymousState == 3 {
                Toggle("匿名发布（消耗 10000 财富值）", isOn: $anonymous)
                    .font(ShellTheme.Fonts.footnote)
            }
        }

        if !isVote {
            Picker("帖子类型", selection: $postKind) {
                Text("普通帖").tag(0)
                Text("学术通知").tag(2)
                if canPostActivity {
                    Text("校园活动").tag(1)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var draftDialogs: some View {
        composerScreen
            .confirmationDialog("退出当前任务？", isPresented: $showExit, titleVisibility: .visible) {
                Button("保存草稿并退出") { if saveDraft() { dismiss() } }
                Button("丢弃本任务草稿并退出", role: .destructive) { if clearDraft() { dismiss() } }
                Button("继续编辑", role: .cancel) { }
            } message: { Text("仅影响这个版面的当前\(isVote ? "投票" : "主题")草稿。") }
            .alert("恢复\(boardName)的草稿？", isPresented: $showRestore) {
                Button("取消", role: .cancel) { }
                Button("恢复") { restoreDraft(); draftStatus = "已恢复草稿" }
            } message: { Text(savedAtDescription + "将用本机保存的草稿替换当前标题、正文和发布设置。") }
            .alert("清除本任务草稿？", isPresented: $showClearDraft) {
                Button("取消", role: .cancel) { }
                Button("仅清除已保存草稿", role: .destructive) { clearDraft() }
            } message: { Text("当前编辑区保留；下次修改会重新自动保存。") }
    }

    private var publishingDialogs: some View {
        draftDialogs
            .alert("切换源码格式？", isPresented: $showModeChange) {
                Button("取消", role: .cancel) { }
                Button("切换并检查预览") { contentType = contentType == 0 ? 1 : 0 }
            } message: { Text("保留全部原文，不自动转换 UBB 与 Markdown 语法。发布前请检查预览。") }
            .alert("主题已发布，部分提醒未完成", isPresented: $showMentionWarning) {
                Button("完成") { onCreated(); dismiss() }
            } message: { Text("请到主题内核对 @ 提醒。不要重新发布主题。") }
    }

    @MainActor
    private func prepareDraft() async {
        guard !draftReady else { return }
        anonymous = effectiveAnonymousState == 1
        restoreDraft()
        if isVote { postKind = 0; anonymous = false }
        savedSnapshot = snapshot
        draftReady = true
        if let detail = try? await app.api.board(id: boardID) {
            boardAnonymousState = detail.anonymousState ?? 0
            boardMasters = detail.boardMasters ?? []
            if detail.anonymousState == 1 { anonymous = true }
        }
        if let tagGroup = try? await app.api.boardTags(boardID: boardID) { tags = tagGroup }
    }

    private func saveDraftIfChanged() {
        if draftReady && !published && snapshot != savedSnapshot { saveDraft() }
    }

    private var draftControls: some View {
        HStack(alignment: .top) {
            Menu {
                Button("保存当前草稿") { saveDraft() }
                Button("恢复已保存草稿") { showRestore = true }
                Button("清除本任务草稿", role: .destructive) { showClearDraft = true }
                Button("复制正文") { UIPasteboard.general.string = content }
            } label: { Label("草稿", systemImage: "doc.badge.ellipsis").frame(minHeight: 44) }
            .accessibilityIdentifier("compose.draft")
            Spacer()
            Text(draftStatus.isEmpty ? "按账号保存在本机" : draftStatus)
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.secondaryText)
                .padding(.top, 12)
        }
    }

    @discardableResult
    private func saveDraft() -> Bool {
        guard let encoded = (try? JSONEncoder().encode(settings)).flatMap({ String(data: $0, encoding: .utf8) }) else {
            draftStatus = "草稿未保存，请重试或复制正文"
            return false
        }
        let saved = library.setDrafts([titleKey: title, bodyKey: content, settingsKey: encoded])
        if saved { savedSnapshot = snapshot }
        draftStatus = saved ? "草稿已保存到本机" : "草稿未保存，请重试或复制正文"
        return saved
    }

    private func restoreDraft() {
        title = library.draft(for: titleKey)
        content = library.draft(for: bodyKey)
        selection = NSRange(location: (content as NSString).length, length: 0)
        guard let data = library.draft(for: settingsKey).data(using: .utf8),
              let saved = try? JSONDecoder().decode(NativeTopicDraftSettings.self, from: data) else { return }
        contentType = saved.contentType == 1 ? 1 : 0
        anonymous = saved.anonymous
        notifyPoster = saved.notifyPoster
        postKind = saved.postKind
        tag1ID = saved.tag1ID; tag2ID = saved.tag2ID
        voteItems = saved.voteItems.count >= 2 ? Array(saved.voteItems.prefix(20)) : ["", ""]
        expiredDays = min(1000, max(1, saved.expiredDays))
        maxVoteCount = min(voteItems.count, max(1, saved.maxVoteCount))
        needVote = saved.needVote
    }

    @discardableResult
    private func clearDraft() -> Bool {
        let success = library.clearDrafts(for: [titleKey, bodyKey, settingsKey])
        if success { savedSnapshot = snapshot }
        draftStatus = success ? "已清除本任务草稿，编辑区保留" : "清除未保存到本机，请重试"
        return success
    }

    private static func mentionedNames(in content: String) -> [String] {
        let text = content.replacingOccurrences(
            of: "(?is)\\[quote\\].*?\\[/quote\\]",
            with: " ",
            options: .regularExpression
        )
        guard let regex = try? NSRegularExpression(pattern: "@([^ \\n]{1,10})\\s") else { return [] }
        let ns = text as NSString
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            if !result.contains(name) { result.append(name) }
            if result.count >= 10 { break }
        }
        return result
    }

    @MainActor
    private func submit() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "请输入标题。"
            return
        }
        guard !trimmedContent.isEmpty else {
            errorMessage = "请输入正文。"
            return
        }
        guard trimmedContent.count <= 8000 else {
            errorMessage = "正文不能超过 8000 个字。"
            return
        }
        if let tagGroup = tags {
            if tagGroup.layers >= 1, tag1ID == nil {
                errorMessage = "请选择一级标签。"
                return
            }
            if tagGroup.layers == 2, tag2ID == nil {
                errorMessage = "请选择二级标签。"
                return
            }
        }
        if postKind == 1, !canPostActivity {
            errorMessage = "没有权限发布校园活动类型。"
            return
        }
        if isVote {
            if voteItems.count < 2 || voteItems.count > 20 {
                errorMessage = "投票选项需为 2–20 项。"
                return
            }
            if voteItems.contains(where: {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value.count > 50
            }) {
                errorMessage = "投票选项不能为空，且每项不超过 50 字。"
                return
            }
            if expiredDays < 1 || expiredDays > 1000 {
                errorMessage = "投票有效天数需为 1–1000 天。"
                return
            }
            if maxVoteCount < 1 || maxVoteCount > voteItems.count {
                errorMessage = "最大投票数需为 1–\(voteItems.count)。"
                return
            }
        }
        guard !sending, !uploading, !published else { return }
        sending = true
        errorMessage = nil
        do {
            let topicID = try await app.api.newTopic(
                boardID: boardID,
                title: trimmedTitle,
                content: content,
                isAnonymous: !isVote && (effectiveAnonymousState == 1 || anonymous),
                contentType: contentType,
                notifyPoster: notifyPoster,
                type: isVote ? 0 : postKind,
                tag1: tag1ID,
                tag2: tag2ID,
                isVote: isVote,
                voteInfo: isVote ? NativeVoteDraft(
                    voteItems: voteItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                    expiredDays: expiredDays,
                    maxVoteCount: maxVoteCount,
                    needVote: needVote
                ) : nil
            )
            published = true
            clearDraft()
            if let topicID, !isVote {
                let mentions = Self.mentionedNames(in: content)
                if !mentions.isEmpty {
                    do { try await app.api.notifyMentions(topicID: topicID, names: mentions) }
                    catch { showMentionWarning = true; sending = false; return }
                }
            }
            onCreated()
            dismiss()
        } catch {
            errorMessage = NativePostingError.message(error.localizedDescription)
        }
        sending = false
    }
}

struct EditPostComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss

    let post: NativePost
    let topicTitle: String?
    var onSaved: () -> Void

    @State private var title: String
    @State private var content: String
    @State private var selection = NSRange(location: 0, length: 0)
    @StateObject private var editor = UBBEditorController()
    @State private var saving = false
    @State private var uploading = false
    @State private var loaded = false
    @State private var savedFields: [String] = []
    @State private var completed = false
    @State private var showExit = false
    @State private var showRestore = false
    @State private var showClear = false
    @State private var draftStatus = ""
    @State private var errorMessage: String? = nil

    private var titleKey: String { "edit.title:\(post.id)" }
    private var bodyKey: String { "edit.body:\(post.id)" }
    private var settingsKey: String { "edit.settings:\(post.id)" }
    private var contentType: Int { post.contentType ?? 0 }
    private var savedAtDescription: String {
        if let date = library.draftItems.first(where: { $0.keys.contains(bodyKey) || $0.keys.contains(titleKey) || $0.keys.contains(settingsKey) })?.updatedAt {
            return "保存时间：\(date.formatted(date: .abbreviated, time: .shortened))。"
        }
        return "旧草稿未记录保存时间。"
    }
    private var changed: Bool { title != (post.floor == 1 ? topicTitle ?? "" : "") || content != (post.content ?? "") }

    init(post: NativePost, topicTitle: String?, onSaved: @escaping () -> Void) {
        self.post = post
        self.topicTitle = topicTitle
        self.onSaved = onSaved
        _title = State(initialValue: post.floor == 1 ? (topicTitle ?? "") : "")
        _content = State(initialValue: post.content ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(post.floor == 1 ? "编辑主题" : "编辑 \(post.floor ?? 0) 楼")
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(ShellTheme.secondaryText)

                    if post.floor == 1 {
                        TextField("主题标题", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .font(ShellTheme.Fonts.body)
                            .accessibilityIdentifier("compose.title")
                            .submitLabel(.done)
                            .onSubmit { ComposerKeyboardToolbar.dismissKeyboard() }
                    }

                    Text(contentType == 0 ? "正文 · UBB 源码" : "正文 · Markdown 源码")
                        .font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                    if contentType == 0 {
                        UBBFormatBar(text: $content, selection: $selection, editor: editor)
                    } else {
                        MarkdownFormatBar(text: $content, selection: $selection, editor: editor)
                    }
                    UBBTextEditor(text: $content, selection: $selection, controller: editor, minHeight: 260)
                        .accessibilityIdentifier("compose.body")
                        .frame(minHeight: 260)
                        .padding(4)
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ShellTheme.separator, lineWidth: 0.5)
                        )

                    ComposerAttachmentsBar(text: $content, selection: $selection, editor: editor) { uploading = $0 }
                    Text("\(content.count) / 8000")
                        .font(ShellTheme.Fonts.footnote)
                        .foregroundStyle(content.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    HStack {
                        Menu {
                            Button("保存当前草稿") { saveDraft() }
                            Button("恢复已保存草稿") { showRestore = true }
                            Button("清除本任务草稿", role: .destructive) { showClear = true }
                            Button("复制正文") { UIPasteboard.general.string = content }
                        } label: { Label("草稿", systemImage: "doc.badge.ellipsis").frame(minHeight: 44) }
                        .accessibilityIdentifier("compose.draft")
                        Spacer()
                        Text(draftStatus).font(ShellTheme.Fonts.footnote).foregroundStyle(ShellTheme.secondaryText)
                    }
                    NativeLibraryStatusView()

                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DisclosureGroup("预览") {
                            UBBContentView(source: content, markdown: contentType == 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(ShellTheme.Fonts.body)
                        .accessibilityIdentifier("compose.preview")
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }
                }
                .disabled(saving)
                .padding(16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("编辑")
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ComposerKeyboardToolbar()
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if changed { showExit = true } else { dismiss() } }
                        .frame(minHeight: 44)
                        .disabled(saving || uploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("compose.submit")
                        .disabled(saving || uploading || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(changed || saving || uploading)
            .confirmationDialog("退出编辑？", isPresented: $showExit, titleVisibility: .visible) {
                Button("保存草稿并退出") { if saveDraft() { dismiss() } }
                Button("丢弃本任务草稿并退出", role: .destructive) { if clearDraft() { dismiss() } }
                Button("继续编辑", role: .cancel) { }
            }
            .alert("恢复本楼层草稿？", isPresented: $showRestore) {
                Button("取消", role: .cancel) { }
                Button("恢复") { restoreDraft() }
            } message: { Text(savedAtDescription + "将替换当前编辑区；原站帖子不会改变。") }
            .alert("清除本楼层草稿？", isPresented: $showClear) {
                Button("取消", role: .cancel) { }
                Button("仅清除草稿", role: .destructive) { clearDraft() }
            } message: { Text("当前编辑区保留，下次修改会重新保存草稿。") }
            .onAppear {
                guard !loaded else { return }
                restoreDraft()
                library.setDraftContext(for: bodyKey, topicID: post.topicId, boardID: post.boardId, floor: post.floor, title: topicTitle)
                savedFields = [title, content]
                loaded = true
            }
            .onChange(of: title) { _, _ in if loaded && !completed && [title, content] != savedFields { saveDraft() } }
            .onChange(of: content) { _, _ in if loaded && !completed && [title, content] != savedFields { saveDraft() } }

        }
    }

    @discardableResult
    private func saveDraft() -> Bool {
        guard let encoded = try? NativeEditorDraftRecovery.encode(title: title, body: content) else {
            draftStatus = "草稿未保存，请重试或复制正文"
            return false
        }
        library.setDraftContext(for: bodyKey, topicID: post.topicId, boardID: post.boardId, floor: post.floor, title: topicTitle)
        let success = library.setDrafts([titleKey: title, bodyKey: content, settingsKey: encoded])
        if success { savedFields = [title, content] }
        draftStatus = success ? "草稿已保存到本机" : "草稿未保存，请重试或复制正文"
        return success
    }

    private func restoreDraft() {
        let saved = NativeEditorDraftRecovery.restore(
            snapshot: library.draft(for: settingsKey),
            legacyTitle: library.draft(for: titleKey),
            legacyBody: library.draft(for: bodyKey),
            originalTitle: post.floor == 1 ? topicTitle ?? "" : "",
            originalBody: post.content ?? ""
        )
        title = saved.title
        content = saved.body
        selection = NSRange(location: (content as NSString).length, length: 0)
    }

    @discardableResult
    private func clearDraft() -> Bool {
        let success = library.clearDrafts(for: [titleKey, bodyKey, settingsKey])
        if success { savedFields = [title, content] }
        draftStatus = success ? "已清除草稿，编辑区保留" : "清除未保存到本机"
        return success
    }

    @MainActor
    private func save() async {
        guard auth.profile != nil else {
            errorMessage = "请先登录。"
            return
        }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            errorMessage = "请输入正文。"
            return
        }
        guard trimmedContent.count <= 8000 else {
            errorMessage = "正文不能超过 8000 个字。"
            return
        }
        guard !saving, !uploading else { return }
        saving = true
        errorMessage = nil
        do {
            try await app.api.editPost(
                postID: post.id,
                title: post.floor == 1 ? title.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                content: content,
                contentType: post.contentType ?? 0
            )
            completed = true
            clearDraft()
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }
}

struct TopicNoteView: View {
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss

    let topicID: Int
    let topicTitle: String

    @State private var text = ""
    @State private var initialText = ""
    @State private var loaded = false
    @State private var showExit = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(topicTitle)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .lineLimit(2)
                TextEditor(text: $text)
                    .font(ShellTheme.Fonts.body)
                    .accessibilityLabel("主题备注")
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ShellTheme.separator, lineWidth: 0.5)
                    )
                Text("\(text.count) / 500 · 仅保存在本机")
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(text.count > 500 ? ShellTheme.danger : ShellTheme.secondaryText)
                NativeLibraryStatusView()
            }
            .padding(16)
            .background(ShellTheme.pageBackground)
            .navigationTitle("主题备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if text != initialText { showExit = true } else { dismiss() } }
                        .frame(minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .frame(minHeight: 44)
                        .disabled(text.count > 500)
                }
            }
            .interactiveDismissDisabled(text != initialText)
            .confirmationDialog("备注尚未保存", isPresented: $showExit, titleVisibility: .visible) {
                Button("保存并退出") { save() }.disabled(text.count > 500)
                Button("丢弃本次修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .onAppear {
                guard !loaded else { return }
                text = library.note(for: topicID); initialText = text; loaded = true
            }
        }
    }
    private func save() {
        guard text.count <= 500 else { return }
        library.setNote(text, for: topicID)
        if library.lastSaveError == nil { dismiss() }
    }
}

struct MarkdownFormatBar: View {
    @Binding var text: String
    @Binding var selection: NSRange
    @ObservedObject var editor: UBBEditorController

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    button("B", prefix: "**", suffix: "**", bold: true)
                    button("I", prefix: "*", suffix: "*")
                    button("S", prefix: "~~", suffix: "~~")
                    button("代码", prefix: "`", suffix: "`")
                    button("引用", prefix: "> ", suffix: "")
                    button("标题", prefix: "## ", suffix: "")
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    button("列表", prefix: "- ", suffix: "")
                    button("链接", prefix: "[", suffix: "](https://)")
                    button("图片", prefix: "![", suffix: "](https://)")
                    button("分割线", prefix: "\n---\n", suffix: "")
                }
            }
        }
    }

    private func button(_ title: String, prefix: String, suffix: String, bold: Bool = false) -> some View {
        Button {
            if !editor.wrap(prefix, suffix) {
                UBBEditorInsertion.wrap(prefix, suffix, text: &text, selection: &selection)
            }
        } label: {
            Text(title)
                .font(ShellTheme.Fonts.body.weight(bold ? .bold : .regular))
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .background(ShellTheme.secondarySurface, in: Capsule())
                .foregroundStyle(ShellTheme.primaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title == "B" ? "粗体" : title == "I" ? "斜体" : title == "S" ? "删除线" : title)
    }
}

struct UBBFormatBar: View {
    @Binding var text: String
    @Binding var selection: NSRange
    @ObservedObject var editor: UBBEditorController

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    format("B", prefix: "[b]", suffix: "[/b]", placeholder: "粗体", bold: true)
                    format("I", prefix: "[i]", suffix: "[/i]", placeholder: "斜体", italic: true)
                    format("U", prefix: "[u]", suffix: "[/u]", placeholder: "下划线", underline: true)
                    format("S", prefix: "[del]", suffix: "[/del]", placeholder: "删除线")

                    Menu {
                        ForEach([2, 3, 4, 5, 6], id: \.self) { size in
                            Button("字号 \(size)") {
                                wrap("[size=\(size)]", "[/size]", placeholder: "文字")
                            }
                        }
                    } label: {
                        menuLabel("字号")
                    }

                    Menu {
                        Button("红") { wrap("[color=red]", "[/color]", placeholder: "彩色文字") }
                        Button("橙") { wrap("[color=orange]", "[/color]", placeholder: "彩色文字") }
                        Button("蓝") { wrap("[color=blue]", "[/color]", placeholder: "彩色文字") }
                        Button("绿") { wrap("[color=green]", "[/color]", placeholder: "彩色文字") }
                        Button("紫") { wrap("[color=purple]", "[/color]", placeholder: "彩色文字") }
                    } label: {
                        menuLabel("颜色")
                    }

                    Menu {
                        Button("左对齐") { wrap("[align=left]", "[/align]", placeholder: "内容") }
                        Button("居中") { wrap("[align=center]", "[/align]", placeholder: "内容") }
                        Button("右对齐") { wrap("[align=right]", "[/align]", placeholder: "内容") }
                    } label: {
                        menuLabel("对齐")
                    }
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    format("引用", prefix: "[quote]", suffix: "[/quote]", placeholder: "引用内容")
                    format("代码", prefix: "[code]", suffix: "[/code]", placeholder: "代码")
                    format("链接", prefix: "[url=链接]", suffix: "[/url]", placeholder: "链接文字")
                    format("列表", prefix: "[list]\n[*]", suffix: "\n[/list]", placeholder: "项目一\n[*]项目二")
                    format("表格", prefix: "[table]\n[tr][th]标题1[/th][th]标题2[/th][/tr]\n[tr][td]", suffix: "[/td][td]内容2[/td][/tr]\n[/table]", placeholder: "内容1")
                    format("分割线", prefix: "[hr]", suffix: "", placeholder: "")
                }
            }
        }
    }

    private func menuLabel(_ title: String) -> some View {
        Text(title)
            .font(ShellTheme.Fonts.footnote)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(ShellTheme.secondarySurface, in: Capsule())
            .foregroundStyle(ShellTheme.primaryText)
    }

    private func wrap(_ prefix: String, _ suffix: String, placeholder: String) {
        if !editor.wrap(prefix, suffix) {
            UBBEditorInsertion.wrap(prefix, suffix, text: &text, selection: &selection)
        }
    }

    private func format(
        _ title: String,
        prefix: String,
        suffix: String,
        placeholder: String,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false
    ) -> some View {
        Button {
            wrap(prefix, suffix, placeholder: placeholder)
        } label: {
            Text(title)
                .font(ShellTheme.Fonts.body.weight(bold ? .bold : .regular))
                .italic(italic)
                .underline(underline)
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .background(ShellTheme.secondarySurface, in: Capsule())
                .foregroundStyle(ShellTheme.primaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(placeholder.isEmpty ? title : placeholder)
    }
}
