import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct ComposerImageButton: View {
    @EnvironmentObject private var app: NativeAppModel
    @Binding var text: String
    @Binding var selection: NSRange

    @State private var item: PhotosPickerItem?
    @State private var uploading = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label(uploading ? "上传中…" : "插入图片", systemImage: uploading ? "arrow.up.circle" : "photo")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.accent)
        }
        .disabled(uploading)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { await upload(newItem) }
        }
        .alert("图片上传失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @MainActor
    private func upload(_ pickerItem: PhotosPickerItem) async {
        uploading = true
        defer {
            uploading = false
            item = nil
        }
        do {
            guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                throw NSError(domain: "CC98Reborn", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取所选图片。"])
            }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            let url = try await app.api.uploadImage(jpeg)
            UBBEditorInsertion.insert("\n[img]\(url)[/img]\n", text: &text, selection: &selection)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

struct ComposerFileButton: View {
    @EnvironmentObject private var app: NativeAppModel
    @Binding var text: String
    @Binding var selection: NSRange

    @State private var showImporter = false
    @State private var uploading = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        Button {
            showImporter = true
        } label: {
            Label(uploading ? "上传中…" : "上传文件", systemImage: uploading ? "arrow.up.circle" : "paperclip")
                .font(ShellTheme.Fonts.footnote)
                .foregroundStyle(ShellTheme.accent)
        }
        .disabled(uploading)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    Task { await upload(url) }
                }
            case let .failure(error):
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        .alert("文件上传失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @MainActor
    private func upload(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        uploading = true
        defer { uploading = false }
        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            let remote = try await app.api.uploadAttachment(data, fileName: url.lastPathComponent, mimeType: mime)
            let tag = ext.isEmpty ? "file" : ext
            UBBEditorInsertion.insert("\n[upload=\(tag)]\(remote)[/upload]\n", text: &text, selection: &selection)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

struct NewTopicComposer: View {
    @EnvironmentObject private var app: NativeAppModel
    @EnvironmentObject private var auth: NativeAuth
    @EnvironmentObject private var library: NativeLibrary
    @Environment(\.dismiss) private var dismiss

    let boardID: Int
    let boardName: String
    var anonymousState: Int = 0
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
    @State private var sending = false
    @State private var errorMessage: String? = nil
    @FocusState private var focused: Bool

    private var titleKey: String { "newtopic.title:\(boardID)" }
    private var bodyKey: String { "newtopic.body:\(boardID)" }

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
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(ShellTheme.Fonts.footnote)
            .foregroundStyle(selected.wrappedValue == nil ? ShellTheme.secondaryText : ShellTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ShellTheme.secondarySurface, in: Capsule())
        }
    }

    private func tagName(_ options: [NativeTag], _ id: Int?) -> String? {
        guard let id else { return nil }
        return options.first { $0.id == id }?.name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)

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

                    TextField("主题标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)

                    if contentType == 0 {
                        UBBFormatBar(text: $content, selection: $selection)
                    } else {
                        MarkdownFormatBar(text: $content, selection: $selection)
                    }
                    UBBTextEditor(text: $content, selection: $selection, minHeight: 260)
                        .padding(4)
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ShellTheme.separator, lineWidth: 0.5)
                        )

                    HStack {
                        ComposerImageButton(text: $content, selection: $selection)
                        ComposerEmoticonButton(text: $content, selection: $selection)
                        ComposerFileButton(text: $content, selection: $selection)
                        Spacer()
                        Text("\(content.count) / 8000")
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(content.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
                    }

                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DisclosureGroup("预览") {
                            UBBContentView(source: content, markdown: contentType == 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(ShellTheme.Fonts.caption)
                    }

                    HStack(spacing: 16) {
                        Button {
                            contentType = contentType == 1 ? 0 : 1
                        } label: {
                            Text("Markdown")
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(contentType == 1 ? ShellTheme.accent : ShellTheme.secondaryText)
                        }
                        .buttonStyle(.plain)

                        Button {
                            library.setDraft(content, for: bodyKey)
                            library.setDraft(title, for: titleKey)
                        } label: {
                            Text("草稿")
                                .font(ShellTheme.Fonts.footnote)
                                .foregroundStyle(ShellTheme.secondaryText)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }

                    Toggle("接收新回复通知", isOn: $notifyPoster)
                        .font(ShellTheme.Fonts.footnote)

                    if effectiveAnonymousState == 1 {
                        Text("本版强制匿名发帖")
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.secondaryText)
                    } else if effectiveAnonymousState == 2 || effectiveAnonymousState == 3 {
                        Toggle("匿名发布（消耗 10000 财富值）", isOn: $anonymous)
                            .font(ShellTheme.Fonts.footnote)
                    }

                    Picker("帖子类型", selection: $postKind) {
                        Text("普通帖").tag(0)
                        Text("学术通知").tag(2)
                        if canPostActivity {
                            Text("校园活动").tag(1)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if sending { ProgressView().tint(.white) }
                            Text(sending ? "发布中…" : "发表")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(ShellTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(sending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("发表主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { Task { await submit() } }
                        .disabled(sending || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if title.isEmpty { title = library.draft(for: titleKey) }
                if content.isEmpty { content = library.draft(for: bodyKey) }
                anonymous = effectiveAnonymousState == 1
                focused = true
                Task {
                    if let detail = try? await app.api.board(id: boardID) {
                        boardAnonymousState = detail.anonymousState ?? 0
                        boardMasters = detail.boardMasters ?? []
                        anonymous = (detail.anonymousState ?? 0) == 1
                    }
                    if let tagGroup = try? await app.api.boardTags(boardID: boardID) {
                        tags = tagGroup
                    }
                }
            }
            .onChange(of: title) { _, value in
                library.setDraft(value, for: titleKey)
            }
            .onChange(of: content) { _, value in
                library.setDraft(value, for: bodyKey)
            }
        }
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
        guard !sending else { return }
        sending = true
        errorMessage = nil
        do {
            try await app.api.newTopic(
                boardID: boardID,
                title: trimmedTitle,
                content: content,
                isAnonymous: effectiveAnonymousState == 1 || anonymous,
                contentType: contentType,
                notifyPoster: notifyPoster,
                type: postKind,
                tag1: tag1ID,
                tag2: tag2ID
            )
            library.clearDraft(for: titleKey)
            library.clearDraft(for: bodyKey)
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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
    @State private var saving = false
    @State private var errorMessage: String? = nil

    private var titleKey: String { "edit.title:\(post.id)" }
    private var bodyKey: String { "edit.body:\(post.id)" }
    private var contentType: Int { post.contentType ?? 0 }

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
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)

                    if post.floor == 1 {
                        TextField("主题标题", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    if contentType == 0 {
                        UBBFormatBar(text: $content, selection: $selection)
                    } else {
                        MarkdownFormatBar(text: $content, selection: $selection)
                    }
                    UBBTextEditor(text: $content, selection: $selection, minHeight: 260)
                        .padding(4)
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ShellTheme.separator, lineWidth: 0.5)
                        )

                    HStack {
                        ComposerImageButton(text: $content, selection: $selection)
                        ComposerEmoticonButton(text: $content, selection: $selection)
                        ComposerFileButton(text: $content, selection: $selection)
                        Spacer()
                        Text("\(content.count) / 8000")
                            .font(ShellTheme.Fonts.caption)
                            .foregroundStyle(content.count > 8000 ? ShellTheme.danger : ShellTheme.secondaryText)
                    }

                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DisclosureGroup("预览") {
                            UBBContentView(source: content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(ShellTheme.Fonts.caption)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }
                }
                .padding(16)
            }
            .background(ShellTheme.pageBackground)
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                let savedTitle = library.draft(for: titleKey)
                let savedBody = library.draft(for: bodyKey)
                if !savedTitle.isEmpty { title = savedTitle }
                if !savedBody.isEmpty { content = savedBody }
            }
            .onChange(of: title) { _, value in
                library.setDraft(value, for: titleKey)
            }
            .onChange(of: content) { _, value in
                library.setDraft(value, for: bodyKey)
            }
        }
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
        guard !saving else { return }
        saving = true
        errorMessage = nil
        do {
            try await app.api.editPost(
                postID: post.id,
                title: post.floor == 1 ? title.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                content: content,
                contentType: post.contentType ?? 0
            )
            library.clearDraft(for: titleKey)
            library.clearDraft(for: bodyKey)
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

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(topicTitle)
                    .font(ShellTheme.Fonts.footnote)
                    .foregroundStyle(ShellTheme.secondaryText)
                    .lineLimit(2)
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ShellTheme.separator, lineWidth: 0.5)
                    )
                Text("\(text.count) / 500 · 仅保存在本机")
                    .font(ShellTheme.Fonts.caption)
                    .foregroundStyle(ShellTheme.secondaryText)
            }
            .padding(16)
            .background(ShellTheme.pageBackground)
            .navigationTitle("主题备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        library.setNote(text, for: topicID)
                        dismiss()
                    }
                }
            }
            .onAppear { text = library.note(for: topicID) }
        }
    }
}

struct MarkdownFormatBar: View {
    @Binding var text: String
    @Binding var selection: NSRange

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                button("B", prefix: "**", suffix: "**", bold: true)
                button("I", prefix: "*", suffix: "*")
                button("S", prefix: "~~", suffix: "~~")
                button("代码", prefix: "`", suffix: "`")
                button("引用", prefix: "> ", suffix: "")
                button("标题", prefix: "## ", suffix: "")
                button("列表", prefix: "- ", suffix: "")
                button("链接", prefix: "[", suffix: "](https://)")
                button("图片", prefix: "![", suffix: "](https://)")
                button("分割线", prefix: "\n---\n", suffix: "")
            }
        }
    }

    private func button(_ title: String, prefix: String, suffix: String, bold: Bool = false) -> some View {
        Button {
            UBBEditorInsertion.wrap(prefix, suffix, text: &text, selection: &selection)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: bold ? .bold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ShellTheme.secondarySurface, in: Capsule())
                .foregroundStyle(ShellTheme.primaryText)
        }
        .buttonStyle(.plain)
    }
}

struct UBBFormatBar: View {
    @Binding var text: String
    @Binding var selection: NSRange

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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

                format("引用", prefix: "[quote]", suffix: "[/quote]", placeholder: "引用内容")
                format("代码", prefix: "[code]", suffix: "[/code]", placeholder: "代码")
                format("链接", prefix: "[url=链接]", suffix: "[/url]", placeholder: "链接文字")
                format("列表", prefix: "[list]\n[*]", suffix: "\n[/list]", placeholder: "项目一\n[*]项目二")
                format("表格", prefix: "[table]\n[tr][th]标题1[/th][th]标题2[/th][/tr]\n[tr][td]", suffix: "[/td][td]内容2[/td][/tr]\n[/table]", placeholder: "内容1")
                format("分割线", prefix: "[hr]", suffix: "", placeholder: "")
            }
        }
    }

    private func menuLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ShellTheme.secondarySurface, in: Capsule())
            .foregroundStyle(ShellTheme.primaryText)
    }

    private func wrap(_ prefix: String, _ suffix: String, placeholder: String) {
        UBBEditorInsertion.wrap(prefix, suffix, text: &text, selection: &selection)
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
                .font(.system(size: 12, weight: bold ? .bold : .regular))
                .underline(underline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ShellTheme.secondarySurface, in: Capsule())
                .foregroundStyle(ShellTheme.primaryText)
        }
        .buttonStyle(.plain)
    }
}