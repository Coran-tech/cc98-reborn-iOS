import SwiftUI
import PhotosUI
import UIKit

struct ComposerImageButton: View {
    @EnvironmentObject private var app: NativeAppModel
    @Binding var text: String

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
        .onChange(of: item?.itemIdentifier) { _, _ in
            Task { await upload(item) }
        }
        .alert("图片上传失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    @MainActor
    private func upload(_ selection: PhotosPickerItem?) async {
        guard let selection else { return }
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                throw NSError(domain: "CC98Reborn", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取所选图片。"])
            }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            let url = try await app.api.uploadImage(jpeg)
            text += "\n[img]\(url)[/img]\n"
            item = nil
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
    var onCreated: () -> Void

    @State private var title = ""
    @State private var content = ""
    @State private var anonymous = false
    @State private var sending = false
    @State private var errorMessage: String? = nil
    @FocusState private var focused: Bool

    private var titleKey: String { "newtopic.title:\(boardID)" }
    private var bodyKey: String { "newtopic.body:\(boardID)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(boardName)
                        .font(ShellTheme.Fonts.caption)
                        .foregroundStyle(ShellTheme.secondaryText)

                    TextField("主题标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)

                    UBBFormatBar(text: $content)
                    TextEditor(text: $content)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(8)
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ShellTheme.separator, lineWidth: 0.5)
                        )

                    HStack {
                        ComposerImageButton(text: $content)
                        ComposerEmoticonButton(text: $content)
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

                    Toggle("匿名发布", isOn: $anonymous)
                        .font(ShellTheme.Fonts.footnote)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ShellTheme.Fonts.footnote)
                            .foregroundStyle(ShellTheme.danger)
                    }
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
                focused = true
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
        guard !sending else { return }
        sending = true
        errorMessage = nil
        do {
            try await app.api.newTopic(
                boardID: boardID,
                title: trimmedTitle,
                content: content,
                isAnonymous: anonymous
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
    @State private var saving = false
    @State private var errorMessage: String? = nil

    private var titleKey: String { "edit.title:\(post.id)" }
    private var bodyKey: String { "edit.body:\(post.id)" }

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

                    UBBFormatBar(text: $content)
                    TextEditor(text: $content)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 260)
                        .padding(8)
                        .background(ShellTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ShellTheme.separator, lineWidth: 0.5)
                        )

                    HStack {
                        ComposerImageButton(text: $content)
                        ComposerEmoticonButton(text: $content)
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

struct UBBFormatBar: View {
    @Binding var text: String

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
        text += "\n\(prefix)\(placeholder)\(suffix)\n"
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